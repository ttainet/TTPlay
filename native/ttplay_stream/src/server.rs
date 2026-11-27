use std::collections::HashMap;
use std::convert::Infallible;
use std::io;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Instant;

use bytes::Bytes;
use http_body_util::combinators::BoxBody;
use http_body_util::{BodyExt, Full, StreamBody};
use hyper::body::Frame;
use hyper::header::{ACCEPT_RANGES, CONTENT_LENGTH, CONTENT_RANGE, CONTENT_TYPE, RANGE};
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::{TokioExecutor, TokioIo};
use hyper_util::server::conn::auto::Builder;
use parking_lot::RwLock;
use tokio::net::TcpListener;
use tokio::sync::{mpsc, watch};

use crate::scheduler::StreamSession;

type HttpBody = BoxBody<Bytes, io::Error>;

pub fn start_http_server(
    streams: Arc<RwLock<HashMap<String, Arc<StreamSession>>>>,
    mut shutdown_rx: watch::Receiver<bool>,
) -> io::Result<(u16, tokio::task::JoinHandle<()>)> {
    let std_listener = std::net::TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], 0)))?;
    std_listener.set_nonblocking(true)?;
    let port = std_listener.local_addr()?.port();
    let listener = TcpListener::from_std(std_listener)?;

    let handle = tokio::spawn(async move {
        loop {
            tokio::select! {
                accepted = listener.accept() => {
                    let Ok((stream, _)) = accepted else { break; };
                    let _ = stream.set_nodelay(true);
                    let streams_ref = Arc::clone(&streams);
                    tokio::spawn(async move {
                        let service = service_fn(move |req| {
                            handle_request(req, Arc::clone(&streams_ref))
                        });
                        let io = TokioIo::new(stream);
                        let _ = Builder::new(TokioExecutor::new()).serve_connection(io, service).await;
                    });
                }
                _ = shutdown_rx.changed() => {
                    if *shutdown_rx.borrow() {
                        break;
                    }
                }
            }
        }
    });

    Ok((port, handle))
}

fn empty_response(status: StatusCode) -> Response<HttpBody> {
    Response::builder()
        .status(status)
        .header(CONTENT_LENGTH, "0")
        .body(Full::new(Bytes::new()).map_err(|n| match n {}).boxed())
        .unwrap()
}

async fn handle_request(
    req: Request<hyper::body::Incoming>,
    streams: Arc<RwLock<HashMap<String, Arc<StreamSession>>>>,
) -> Result<Response<HttpBody>, Infallible> {
    let method = req.method().clone();
    if method != Method::GET && method != Method::HEAD {
        return Ok(empty_response(StatusCode::METHOD_NOT_ALLOWED));
    }

    let path = req.uri().path();
    let parts: Vec<&str> = path.trim_start_matches('/').split('/').collect();
    if parts.len() < 2 || parts[0] != "s" {
        return Ok(empty_response(StatusCode::NOT_FOUND));
    }
    let token = parts[1];
    let session = streams.read().get(token).cloned();
    let Some(session) = session else {
        return Ok(empty_response(StatusCode::NOT_FOUND));
    };

    let size = session.total_size;
    if size == 0 {
        return Ok(empty_response(StatusCode::OK));
    }

    let range_header = req.headers().get(RANGE).and_then(|v| v.to_str().ok());
    let parsed_range = match range_header {
        None => Ok((0u64, size - 1, false)),
        Some(h) => parse_range_header(h, size).map(|(s, e)| (s, e, true)),
    };

    let (start, end, is_partial) = match parsed_range {
        Ok(v) => v,
        Err(()) => {
            let mut resp = empty_response(StatusCode::RANGE_NOT_SATISFIABLE);
            resp.headers_mut().insert(
                CONTENT_RANGE,
                format!("bytes */{size}").parse().unwrap(),
            );
            return Ok(resp);
        }
    };

    let length = end - start + 1;
    let ctype = session
        .content_type
        .as_deref()
        .unwrap_or("application/octet-stream");

    if method == Method::HEAD {
        let status = if is_partial {
            StatusCode::PARTIAL_CONTENT
        } else {
            StatusCode::OK
        };
        let mut builder = Response::builder()
            .status(status)
            .header(ACCEPT_RANGES, "bytes")
            .header(CONTENT_TYPE, ctype)
            .header(CONTENT_LENGTH, length.to_string());
        if is_partial {
            builder = builder.header(CONTENT_RANGE, format!("bytes {start}-{end}/{size}"));
        }
        return Ok(builder
            .body(Full::new(Bytes::new()).map_err(|n| match n {}).boxed())
            .unwrap());
    }

    let mut reader = session.open_reader(start, end);
    let stats = Arc::clone(&session.stats);
    let (tx, rx) = mpsc::channel::<Result<Bytes, io::Error>>(16);

    tokio::spawn(async move {
        loop {
            let up_start = Instant::now();
            let chunk_res = tokio::select! {
                _ = tx.closed() => break,
                res = reader.next_chunk() => res,
            };
            stats.record_up_wait_us(up_start.elapsed().as_micros() as u64);

            match chunk_res {
                Ok(Some(chunk)) => {
                    let len = chunk.len() as u64;
                    match tx.try_reserve() {
                        Ok(permit) => {
                            stats.record_delivered_bytes(len);
                            permit.send(Ok(chunk));
                        }
                        Err(mpsc::error::TrySendError::Full(_)) => {
                            let down_start = Instant::now();
                            match tx.reserve().await {
                                Ok(permit) => {
                                    let waited_us = down_start.elapsed().as_micros() as u64;
                                    stats.record_down_wait_us(waited_us);
                                    if waited_us >= 1000 {
                                        stats.record_down_pause();
                                    }
                                    stats.record_delivered_bytes(len);
                                    permit.send(Ok(chunk));
                                }
                                Err(_) => break,
                            }
                        }
                        Err(mpsc::error::TrySendError::Closed(_)) => break,
                    }
                }
                Ok(None) => break,
                Err(e) => {
                    let _ = tx.send(Err(e)).await;
                    break;
                }
            }
        }
    });

    let body_stream = futures_util::stream::unfold(rx, |mut rx| async move {
        let item = rx.recv().await?;
        Some((item.map(Frame::data), rx))
    });
    let body = StreamBody::new(body_stream).boxed();

    let status = if is_partial {
        StatusCode::PARTIAL_CONTENT
    } else {
        StatusCode::OK
    };
    let mut builder = Response::builder()
        .status(status)
        .header(ACCEPT_RANGES, "bytes")
        .header(CONTENT_TYPE, ctype)
        .header(CONTENT_LENGTH, length.to_string());
    if is_partial {
        builder = builder.header(CONTENT_RANGE, format!("bytes {start}-{end}/{size}"));
    }
    Ok(builder.body(body).unwrap())
}

fn parse_range_header(header: &str, size: u64) -> Result<(u64, u64), ()> {
    let trimmed = header.trim();
    let rest = trimmed.strip_prefix("bytes=").ok_or(())?;
    if rest.contains(',') {
        return Err(());
    }
    let (start_s, end_s) = rest.split_once('-').ok_or(())?;
    let start_s = start_s.trim();
    let end_s = end_s.trim();

    if start_s.is_empty() {
        let suffix: u64 = end_s.parse().map_err(|_| ())?;
        if suffix == 0 {
            return Err(());
        }
        let start = size.saturating_sub(suffix);
        return Ok((start, size - 1));
    }

    let start: u64 = start_s.parse().map_err(|_| ())?;
    if start >= size {
        return Err(());
    }
    let end = if end_s.is_empty() {
        size - 1
    } else {
        let e: u64 = end_s.parse().map_err(|_| ())?;
        if e < start {
            return Err(());
        }
        e.min(size - 1)
    };
    Ok((start, end))
}
