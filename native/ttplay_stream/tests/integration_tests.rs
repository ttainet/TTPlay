use std::collections::HashMap;
use std::convert::Infallible;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use bytes::Bytes;
use http_body_util::combinators::BoxBody;
use http_body_util::{BodyExt, Full, StreamBody};
use hyper::body::Frame;
use hyper::header::{AUTHORIZATION, CONTENT_RANGE, COOKIE, LOCATION, RANGE};
use hyper::service::service_fn;
use hyper::{Request, Response, StatusCode};
use hyper_util::rt::{TokioExecutor, TokioIo};
use hyper_util::server::conn::auto::Builder;
use parking_lot::Mutex;
use tokio::net::TcpListener;
use tokio::sync::mpsc;

use ttplay_stream::config::{
    DriveTransferProfile, LinkUpdatePayload, PlaybackDemandUpdate, StreamRegistration,
};
use ttplay_stream::NativeEngine;

type BoxHttpBody = BoxBody<Bytes, std::io::Error>;

#[derive(Clone, Default)]
struct MockOriginConfig {
    content: Bytes,
    per_conn_delay: Duration,
    shared_cap_bytes_per_sec: Option<u64>,
    force_412_until_path: Option<(String, usize)>,
    force_429_count: Arc<AtomicUsize>,
    delay_first_range_start_once: Option<(u64, Duration)>,
    // Track observed requests
    requests: Arc<Mutex<Vec<ObservedReq>>>,
    shared_tokens: Arc<Mutex<TokenBucket>>,
}

#[derive(Debug, Clone)]
struct ObservedReq {
    has_auth: bool,
    has_cookie: bool,
}

#[derive(Default)]
struct TokenBucket {
    last: Option<Instant>,
    avail: f64,
}

async fn spawn_mock_server<F, Fut>(handler: F) -> (u16, tokio::task::JoinHandle<()>)
where
    F: Fn(Request<hyper::body::Incoming>) -> Fut + Send + Sync + Clone + 'static,
    Fut: std::future::Future<Output = Response<BoxHttpBody>> + Send + 'static,
{
    let listener = TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], 0)))
        .await
        .unwrap();
    let port = listener.local_addr().unwrap().port();
    let handle = tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                break;
            };
            let h = handler.clone();
            tokio::spawn(async move {
                let svc = service_fn(move |req| {
                    let h2 = h.clone();
                    async move { Ok::<_, Infallible>(h2(req).await) }
                });
                let _ = Builder::new(TokioExecutor::new())
                    .serve_connection(TokioIo::new(stream), svc)
                    .await;
            });
        }
    });
    (port, handle)
}

fn parse_range(h: Option<&str>, len: usize) -> Option<(usize, usize)> {
    let h = h?.strip_prefix("bytes=")?;
    let (a, b) = h.split_once('-')?;
    let start: usize = a.parse().ok()?;
    let end: usize = if b.is_empty() {
        len - 1
    } else {
        b.parse().ok()?
    };
    Some((start, end.min(len - 1)))
}

async fn serve_origin(
    req: Request<hyper::body::Incoming>,
    cfg: Arc<Mutex<MockOriginConfig>>,
) -> Response<BoxHttpBody> {
    let path = req.uri().path().to_string();
    let range_hdr = req
        .headers()
        .get(RANGE)
        .and_then(|v| v.to_str().ok())
        .map(str::to_string);
    let has_auth = req.headers().contains_key(AUTHORIZATION);
    let has_cookie = req.headers().contains_key(COOKIE);

    let (content, per_conn_delay, shared_cap, delay_once, stale_info, req_log, shared_tokens, f429) = {
        let mut g = cfg.lock();
        g.requests.lock().push(ObservedReq {
            has_auth,
            has_cookie,
        });
        let stale = g.force_412_until_path.as_ref().cloned();
        let d_once = g.delay_first_range_start_once.take();
        (
            g.content.clone(),
            g.per_conn_delay,
            g.shared_cap_bytes_per_sec,
            d_once,
            stale,
            Arc::clone(&g.requests),
            Arc::clone(&g.shared_tokens),
            Arc::clone(&g.force_429_count),
        )
    };
    let _ = req_log;

    if let Some((stale_path, _)) = stale_info {
        if path == stale_path {
            return Response::builder()
                .status(StatusCode::PRECONDITION_FAILED)
                .body(Full::new(Bytes::new()).map_err(|n| match n {}).boxed())
                .unwrap();
        }
    }

    if f429
        .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |v| {
            if v > 0 { Some(v - 1) } else { None }
        })
        .is_ok()
    {
        return Response::builder()
            .status(StatusCode::TOO_MANY_REQUESTS)
            .body(Full::new(Bytes::new()).map_err(|n| match n {}).boxed())
            .unwrap();
    }

    let (start, end) = parse_range(range_hdr.as_deref(), content.len())
        .unwrap_or((0, content.len() - 1));

    if let Some((target_start, dur)) = delay_once {
        if start as u64 == target_start {
            tokio::time::sleep(dur).await;
        } else {
            // Put it back if not the target start.
            cfg.lock().delay_first_range_start_once = Some((target_start, dur));
        }
    }

    let slice = content.slice(start..=end);
    let (tx, rx) = mpsc::channel::<Result<Bytes, std::io::Error>>(4);
    tokio::spawn(async move {
        for chunk in slice.chunks(64 * 1024) {
            if !per_conn_delay.is_zero() {
                tokio::time::sleep(per_conn_delay).await;
            }
            if let Some(bps) = shared_cap {
                loop {
                    let wait = {
                        let mut b = shared_tokens.lock();
                        let now = Instant::now();
                        let elapsed = b
                            .last
                            .map(|l| now.duration_since(l).as_secs_f64())
                            .unwrap_or(0.05);
                        b.last = Some(now);
                        b.avail = (b.avail + elapsed * bps as f64).min(bps as f64 * 0.25);
                        if b.avail >= chunk.len() as f64 {
                            b.avail -= chunk.len() as f64;
                            Duration::ZERO
                        } else {
                            let need = chunk.len() as f64 - b.avail;
                            Duration::from_secs_f64(need / bps as f64)
                        }
                    };
                    if wait.is_zero() {
                        break;
                    }
                    tokio::time::sleep(wait).await;
                }
            }
            if tx.send(Ok(Bytes::copy_from_slice(chunk))).await.is_err() {
                break;
            }
        }
    });

    let stream = futures_util::stream::unfold(rx, |mut rx| async move {
        let item = rx.recv().await?;
        Some((item.map(Frame::data), rx))
    });
    Response::builder()
        .status(if range_hdr.is_some() {
            StatusCode::PARTIAL_CONTENT
        } else {
            StatusCode::OK
        })
        .header(
            CONTENT_RANGE,
            format!("bytes {start}-{end}/{}", content.len()),
        )
        .header(hyper::header::CONTENT_LENGTH, (end - start + 1).to_string())
        .body(StreamBody::new(stream).boxed())
        .unwrap()
}

fn make_test_data(size: usize) -> Bytes {
    let v: Vec<u8> = (0..size).map(|i| ((i * 31 + 7) % 251) as u8).collect();
    Bytes::from(v)
}

async fn stop_engine(engine: NativeEngine) {
    tokio::task::spawn_blocking(move || engine.stop())
        .await
        .unwrap();
}

#[tokio::test]
async fn serves_head_full_bounded_and_suffix_ranges_accurately() {
    let data = make_test_data(1500 * 1024);
    let origin = Arc::new(Mutex::new(MockOriginConfig {
        content: data.clone(),
        ..Default::default()
    }));
    let (origin_port, _srv) = spawn_mock_server({
        let o = Arc::clone(&origin);
        move |req| serve_origin(req, Arc::clone(&o))
    })
    .await;

    let engine = NativeEngine::start(None).unwrap();
    engine
        .register_stream(StreamRegistration {
            token: "tok1".into(),
            total_size: data.len() as u64,
            content_type: Some("video/x-matroska".into()),
            url: format!("http://127.0.0.1:{origin_port}/video"),
            headers: HashMap::new(),
            profile: DriveTransferProfile {
                min_connections: 2,
                max_connections: 3,
                window_bytes: 1024 * 1024,
                min_segment_bytes: 256 * 1024,
                max_segment_bytes: 512 * 1024,
                probe_bypass_bytes: 128 * 1024,
                ..Default::default()
            },
        })
        .unwrap();

    let client = reqwest::Client::new();
    let base = format!("http://127.0.0.1:{}/s/tok1/movie.mkv", engine.port());

    let head = client.head(&base).send().await.unwrap();
    assert_eq!(head.status(), StatusCode::OK);
    assert_eq!(
        head.headers()
            .get(hyper::header::CONTENT_LENGTH)
            .unwrap()
            .to_str()
            .unwrap(),
        data.len().to_string()
    );

    // Bounded probe
    let probe = client
        .get(&base)
        .header(RANGE, "bytes=100-1123")
        .send()
        .await
        .unwrap();
    assert_eq!(probe.status(), StatusCode::PARTIAL_CONTENT);
    assert_eq!(probe.bytes().await.unwrap(), data.slice(100..=1123));

    // Suffix range
    let suffix = client
        .get(&base)
        .header(RANGE, "bytes=-4096")
        .send()
        .await
        .unwrap();
    assert_eq!(suffix.status(), StatusCode::PARTIAL_CONTENT);
    assert_eq!(
        suffix.bytes().await.unwrap(),
        data.slice(data.len() - 4096..)
    );

    // Full multi-conn range
    let full = client.get(&base).send().await.unwrap();
    assert_eq!(full.status(), StatusCode::OK);
    assert_eq!(full.bytes().await.unwrap(), data);

    stop_engine(engine).await;
}

#[tokio::test]
async fn caches_redirect_and_strips_credentials_across_hosts() {
    let data = make_test_data(600 * 1024);
    let cdn_origin = Arc::new(Mutex::new(MockOriginConfig {
        content: data.clone(),
        ..Default::default()
    }));
    let (cdn_port, _cdn_srv) = spawn_mock_server({
        let o = Arc::clone(&cdn_origin);
        move |req| serve_origin(req, Arc::clone(&o))
    })
    .await;

    let redir_hits = Arc::new(AtomicUsize::new(0));
    let (_redir_port, _redir_srv) = {
        let hits = Arc::clone(&redir_hits);
        spawn_mock_server(move |_req| {
            let hits = Arc::clone(&hits);
            async move {
                hits.fetch_add(1, Ordering::SeqCst);
                // 127.0.0.1 -> localhost is a cross-host redirect!
                Response::builder()
                    .status(StatusCode::FOUND)
                    .header(LOCATION, format!("http://localhost:{cdn_port}/cdn/file"))
                    .body(Full::new(Bytes::new()).map_err(|n| match n {}).boxed())
                    .unwrap()
            }
        })
        .await
    };

    let engine = NativeEngine::start(None).unwrap();
    let mut headers = HashMap::new();
    headers.insert("Authorization".into(), "Bearer secret-token".into());
    headers.insert("Cookie".into(), "session=supersecret".into());
    headers.insert("User-Agent".into(), "TestAgent/1.0".into());

    engine
        .register_stream(StreamRegistration {
            token: "redir".into(),
            total_size: data.len() as u64,
            content_type: None,
            url: format!("http://127.0.0.1:{_redir_port}/entry"),
            headers,
            profile: DriveTransferProfile {
                min_connections: 1,
                max_connections: 2,
                probe_bypass_bytes: 64 * 1024,
                min_segment_bytes: 128 * 1024,
                cache_redirect_url: true,
                redirect_cache_ttl_secs: 60,
                ..Default::default()
            },
        })
        .unwrap();

    let client = reqwest::Client::new();
    let url = format!("http://127.0.0.1:{}/s/redir/video.mp4", engine.port());

    let p1 = client
        .get(&url)
        .header(RANGE, "bytes=0-131071")
        .send()
        .await
        .unwrap()
        .bytes()
        .await
        .unwrap();
    assert_eq!(p1, data.slice(0..131072));
    assert_eq!(redir_hits.load(Ordering::SeqCst), 1);

    // Second request must reuse the cached CDN target directly without hitting redirect server again.
    let p2 = client
        .get(&url)
        .header(RANGE, "bytes=131072-262143")
        .send()
        .await
        .unwrap()
        .bytes()
        .await
        .unwrap();
    assert_eq!(p2, data.slice(131072..262144));
    assert_eq!(redir_hits.load(Ordering::SeqCst), 1);

    // Verify credentials were stripped across 127.0.0.1 -> localhost redirect.
    let observed = cdn_origin.lock().requests.lock().clone();
    assert!(!observed.is_empty());
    assert!(observed.iter().all(|r| !r.has_auth && !r.has_cookie));

    stop_engine(engine).await;
}

#[tokio::test]
async fn refreshes_expired_412_link_via_callback_seamlessly() {
    let data = make_test_data(400 * 1024);
    let origin = Arc::new(Mutex::new(MockOriginConfig {
        content: data.clone(),
        force_412_until_path: Some(("/stale".into(), 1)),
        ..Default::default()
    }));
    let (origin_port, _srv) = spawn_mock_server({
        let o = Arc::clone(&origin);
        move |req| serve_origin(req, Arc::clone(&o))
    })
    .await;

    let engine_slot: Arc<Mutex<Option<std::sync::Weak<NativeEngine>>>> = Arc::new(Mutex::new(None));
    let refresh_calls = Arc::new(AtomicUsize::new(0));
    let slot_cb = Arc::clone(&engine_slot);
    let calls_cb = Arc::clone(&refresh_calls);

    let engine = Arc::new(
        NativeEngine::start(Some(Arc::new(move |token: &str, req_id: u64| {
            calls_cb.fetch_add(1, Ordering::SeqCst);
            let tok = token.to_string();
            let slot = Arc::clone(&slot_cb);
            std::thread::spawn(move || {
                if let Some(eng) = slot.lock().as_ref().and_then(|w| w.upgrade()) {
                    eng.update_link(
                        &tok,
                        req_id,
                        LinkUpdatePayload {
                            url: Some(format!("http://127.0.0.1:{origin_port}/fresh")),
                            headers: Some(HashMap::new()),
                            error: None,
                        },
                    );
                }
            });
        })))
        .unwrap(),
    );
    *engine_slot.lock() = Some(Arc::downgrade(&engine));

    engine
        .register_stream(StreamRegistration {
            token: "refresh-tok".into(),
            total_size: data.len() as u64,
            content_type: None,
            url: format!("http://127.0.0.1:{origin_port}/stale"),
            headers: HashMap::new(),
            profile: DriveTransferProfile {
                min_connections: 2,
                max_connections: 2,
                probe_bypass_bytes: 32 * 1024,
                min_segment_bytes: 128 * 1024,
                ..Default::default()
            },
        })
        .unwrap();

    let client = reqwest::Client::new();
    let body = client
        .get(format!(
            "http://127.0.0.1:{}/s/refresh-tok/v.mkv",
            engine.port()
        ))
        .send()
        .await
        .unwrap()
        .bytes()
        .await
        .unwrap();
    assert_eq!(body, data);
    // Deduplication ensures only 1 refresh callback even with 2 concurrent connections hitting 412.
    assert_eq!(refresh_calls.load(Ordering::SeqCst), 1);

    let eng = Arc::try_unwrap(engine).ok().unwrap();
    stop_engine(eng).await;
}

#[tokio::test]
async fn throttled_per_conn_scales_up_while_shared_cap_rolls_back() {
    // 1. Per-connection delay (same total benefits from scale-up): starts at 1, scales to >=2
    let data = make_test_data(1536 * 1024);
    let per_conn_origin = Arc::new(Mutex::new(MockOriginConfig {
        content: data.clone(),
        per_conn_delay: Duration::from_millis(60), // ~1.0 MB/s per conn -> 1s+ total
        ..Default::default()
    }));
    let (p1, _s1) = spawn_mock_server({
        let o = Arc::clone(&per_conn_origin);
        move |req| serve_origin(req, Arc::clone(&o))
    })
    .await;

    let engine = NativeEngine::start(None).unwrap();
    engine
        .register_stream(StreamRegistration {
            token: "scale-up".into(),
            total_size: data.len() as u64,
            content_type: None,
            url: format!("http://127.0.0.1:{p1}/f"),
            headers: HashMap::new(),
            profile: DriveTransferProfile {
                min_connections: 1,
                max_connections: 3,
                window_bytes: 1024 * 1024,
                min_segment_bytes: 256 * 1024,
                max_segment_bytes: 512 * 1024,
                probe_bypass_bytes: 64 * 1024,
                scale_up_eval_secs: 1,
                scale_up_min_gain_ratio: 1.15,
                ..Default::default()
            },
        })
        .unwrap();
    engine.update_demand(
        "scale-up",
        PlaybackDemandUpdate {
            playback_started: Some(true),
            bitrate_bps: Some(20_000_000),
            buffered_secs: Some(2.0),
            is_buffering: Some(false),
            max_connections: None,
        },
    );

    let client = reqwest::Client::new();
    let got = client
        .get(format!("http://127.0.0.1:{}/s/scale-up/f.mkv", engine.port()))
        .send()
        .await
        .unwrap()
        .bytes()
        .await
        .unwrap();
    assert_eq!(got, data);
    let snaps = engine.poll_stats();
    let scale_snap = snaps.iter().find(|s| s.token == "scale-up").unwrap();
    assert!(scale_snap.peak_conns >= 2, "expected adaptive scale up, got {:?}", scale_snap);

    // 2. Shared bandwidth cap (scale-up does NOT add >= 15% gain): rolls back effective_max to 1
    let shared_origin = Arc::new(Mutex::new(MockOriginConfig {
        content: data.clone(),
        shared_cap_bytes_per_sec: Some(500 * 1024),
        ..Default::default()
    }));
    let (p2, _s2) = spawn_mock_server({
        let o = Arc::clone(&shared_origin);
        move |req| serve_origin(req, Arc::clone(&o))
    })
    .await;

    engine
        .register_stream(StreamRegistration {
            token: "rollback".into(),
            total_size: data.len() as u64,
            content_type: None,
            url: format!("http://127.0.0.1:{p2}/f"),
            headers: HashMap::new(),
            profile: DriveTransferProfile {
                min_connections: 1,
                max_connections: 3,
                window_bytes: 1024 * 1024,
                min_segment_bytes: 256 * 1024,
                max_segment_bytes: 512 * 1024,
                probe_bypass_bytes: 64 * 1024,
                scale_up_eval_secs: 1,
                scale_up_min_gain_ratio: 1.25,
                rate_limit_cooldown_secs: 30,
                ..Default::default()
            },
        })
        .unwrap();
    engine.update_demand(
        "rollback",
        PlaybackDemandUpdate {
            playback_started: Some(true),
            bitrate_bps: Some(20_000_000),
            buffered_secs: Some(2.0),
            is_buffering: Some(false),
            max_connections: None,
        },
    );

    let got2 = client
        .get(format!("http://127.0.0.1:{}/s/rollback/f.mkv", engine.port()))
        .send()
        .await
        .unwrap()
        .bytes()
        .await
        .unwrap();
    assert_eq!(got2, data);
    let snaps2 = engine.poll_stats();
    let rb_snap = snaps2.iter().find(|s| s.token == "rollback").unwrap();
    assert_eq!(rb_snap.effective_max_conns, 1, "expected rollback cooldown on shared cap: {:?}", rb_snap);

    stop_engine(engine).await;
}

#[tokio::test]
async fn idle_work_steal_splits_stalled_segment_via_soft_range_end() {
    let data = make_test_data(1024 * 1024);
    let origin = Arc::new(Mutex::new(MockOriginConfig {
        content: data.clone(),
        // Delay first task [0..512K) headers slightly while second finishes fast and steals.
        delay_first_range_start_once: Some((0, Duration::from_millis(180))),
        ..Default::default()
    }));
    let (origin_port, _srv) = spawn_mock_server({
        let o = Arc::clone(&origin);
        move |req| serve_origin(req, Arc::clone(&o))
    })
    .await;

    let engine = NativeEngine::start(None).unwrap();
    engine
        .register_stream(StreamRegistration {
            token: "steal".into(),
            total_size: data.len() as u64,
            content_type: None,
            url: format!("http://127.0.0.1:{origin_port}/v"),
            headers: HashMap::new(),
            profile: DriveTransferProfile {
                min_connections: 2,
                max_connections: 2,
                window_bytes: 1024 * 1024,
                min_segment_bytes: 128 * 1024,
                max_segment_bytes: 512 * 1024,
                probe_bypass_bytes: 64 * 1024,
                ..Default::default()
            },
        })
        .unwrap();

    let client = reqwest::Client::new();
    let got = client
        .get(format!("http://127.0.0.1:{}/s/steal/v.mkv", engine.port()))
        .send()
        .await
        .unwrap()
        .bytes()
        .await
        .unwrap();
    assert_eq!(got, data);
    stop_engine(engine).await;
}

#[tokio::test]
async fn http_429_halves_concurrency_and_still_completes() {
    let data = make_test_data(512 * 1024);
    let origin = Arc::new(Mutex::new(MockOriginConfig {
        content: data.clone(),
        force_429_count: Arc::new(AtomicUsize::new(1)),
        ..Default::default()
    }));
    let (origin_port, _srv) = spawn_mock_server({
        let o = Arc::clone(&origin);
        move |req| serve_origin(req, Arc::clone(&o))
    })
    .await;

    let engine = NativeEngine::start(None).unwrap();
    engine
        .register_stream(StreamRegistration {
            token: "rl".into(),
            total_size: data.len() as u64,
            content_type: None,
            url: format!("http://127.0.0.1:{origin_port}/v"),
            headers: HashMap::new(),
            profile: DriveTransferProfile {
                min_connections: 2,
                max_connections: 4,
                window_bytes: 512 * 1024,
                min_segment_bytes: 128 * 1024,
                probe_bypass_bytes: 64 * 1024,
                ..Default::default()
            },
        })
        .unwrap();

    let client = reqwest::Client::new();
    let got = client
        .get(format!("http://127.0.0.1:{}/s/rl/v.mkv", engine.port()))
        .send()
        .await
        .unwrap()
        .bytes()
        .await
        .unwrap();
    assert_eq!(got, data);
    let snaps = engine.poll_stats();
    let rl_snap = snaps.iter().find(|s| s.token == "rl").unwrap();
    assert_eq!(rl_snap.rate_limits, 1);
    assert!(rl_snap.effective_max_conns <= 2);

    stop_engine(engine).await;
}

#[tokio::test]
async fn startup_locks_to_single_connection_until_playback_started() {
    let data = make_test_data(1536 * 1024);
    let origin = Arc::new(Mutex::new(MockOriginConfig {
        content: data.clone(),
        per_conn_delay: Duration::from_millis(50),
        ..Default::default()
    }));
    let (port, _srv) = spawn_mock_server({
        let o = Arc::clone(&origin);
        move |req| serve_origin(req, Arc::clone(&o))
    })
    .await;

    let engine = NativeEngine::start(None).unwrap();
    engine
        .register_stream(StreamRegistration {
            token: "locked-startup".into(),
            total_size: data.len() as u64,
            content_type: None,
            url: format!("http://127.0.0.1:{port}/v"),
            headers: HashMap::new(),
            profile: DriveTransferProfile {
                min_connections: 1,
                max_connections: 4,
                window_bytes: 1024 * 1024,
                min_segment_bytes: 256 * 1024,
                max_segment_bytes: 512 * 1024,
                probe_bypass_bytes: 64 * 1024,
                scale_up_eval_secs: 1,
                ..Default::default()
            },
        })
        .unwrap();

    let client = reqwest::Client::new();
    let got = client
        .get(format!("http://127.0.0.1:{}/s/locked-startup/v.mp4", engine.port()))
        .send()
        .await
        .unwrap()
        .bytes()
        .await
        .unwrap();
    assert_eq!(got, data);

    let snaps = engine.poll_stats();
    let snap = snaps.iter().find(|s| s.token == "locked-startup").unwrap();
    assert_eq!(snap.peak_conns, 1, "expected startup locked to 1 conn: {:?}", snap);
    assert!(!snap.playback_started);

    stop_engine(engine).await;
}

#[tokio::test]
async fn fast_single_connection_stays_at_one_when_exceeding_bitrate_demand() {
    let data = make_test_data(1536 * 1024);
    let origin = Arc::new(Mutex::new(MockOriginConfig {
        content: data.clone(),
        ..Default::default()
    }));
    let (port, _srv) = spawn_mock_server({
        let o = Arc::clone(&origin);
        move |req| serve_origin(req, Arc::clone(&o))
    })
    .await;

    let engine = NativeEngine::start(None).unwrap();
    engine
        .register_stream(StreamRegistration {
            token: "fast-single".into(),
            total_size: data.len() as u64,
            content_type: None,
            url: format!("http://127.0.0.1:{port}/v"),
            headers: HashMap::new(),
            profile: DriveTransferProfile {
                min_connections: 1,
                max_connections: 4,
                window_bytes: 1024 * 1024,
                min_segment_bytes: 256 * 1024,
                max_segment_bytes: 512 * 1024,
                probe_bypass_bytes: 64 * 1024,
                scale_up_eval_secs: 1,
                ..Default::default()
            },
        })
        .unwrap();
    engine.update_demand(
        "fast-single",
        PlaybackDemandUpdate {
            playback_started: Some(true),
            bitrate_bps: Some(1_000_000),
            buffered_secs: Some(30.0),
            is_buffering: Some(false),
            max_connections: None,
        },
    );

    let client = reqwest::Client::new();
    let got = client
        .get(format!("http://127.0.0.1:{}/s/fast-single/v.mp4", engine.port()))
        .send()
        .await
        .unwrap()
        .bytes()
        .await
        .unwrap();
    assert_eq!(got, data);

    let peek = engine.peek_stream_status("fast-single").unwrap();
    assert_eq!(peek.effective_max_conns, 4);

    let snaps = engine.poll_stats();
    let snap = snaps.iter().find(|s| s.token == "fast-single").unwrap();
    assert!(snap.upstream_bytes > 0);
    assert_eq!(snap.peak_conns, 1, "expected fast single conn to stay at 1: {:?}", snap);
    assert!(snap.playback_started);
    assert_eq!(snap.demand_bitrate_bps, 1_000_000);

    stop_engine(engine).await;
}

#[tokio::test]
async fn seek_to_tail_preempts_old_task_immediately_at_single_connection() {
    let data = make_test_data(2 * 1024 * 1024);
    let origin = Arc::new(Mutex::new(MockOriginConfig {
        content: data.clone(),
        delay_first_range_start_once: Some((0, Duration::from_secs(2))),
        ..Default::default()
    }));
    let (port, _srv) = spawn_mock_server({
        let o = Arc::clone(&origin);
        move |req| serve_origin(req, Arc::clone(&o))
    })
    .await;

    let engine = NativeEngine::start(None).unwrap();
    engine
        .register_stream(StreamRegistration {
            token: "preempt".into(),
            total_size: data.len() as u64,
            content_type: None,
            url: format!("http://127.0.0.1:{port}/v"),
            headers: HashMap::new(),
            profile: DriveTransferProfile {
                min_connections: 1,
                max_connections: 4,
                window_bytes: 512 * 1024,
                min_segment_bytes: 256 * 1024,
                max_segment_bytes: 512 * 1024,
                probe_bypass_bytes: 64 * 1024,
                ..Default::default()
            },
        })
        .unwrap();

    let client = reqwest::Client::new();
    let url = format!("http://127.0.0.1:{}/s/preempt/v.mp4", engine.port());

    // Start an open-ended reader at offset 0 whose upstream task sleeps 2s before answering.
    let head_client = client.clone();
    let head_url = url.clone();
    let head_task = tokio::spawn(async move {
        let resp = head_client
            .get(&head_url)
            .header(RANGE, "bytes=0-")
            .send()
            .await
            .unwrap();
        let _ = resp.bytes().await;
    });

    tokio::time::sleep(Duration::from_millis(60)).await;

    let t0 = Instant::now();
    let tail = client
        .get(&url)
        .header(RANGE, "bytes=1572864-")
        .send()
        .await
        .unwrap()
        .bytes()
        .await
        .unwrap();
    let elapsed = t0.elapsed();

    assert_eq!(tail, data.slice(1572864..));
    assert!(
        elapsed < Duration::from_millis(800),
        "tail seek should preempt stalled head task quickly, took {:?}",
        elapsed
    );

    head_task.abort();
    stop_engine(engine).await;
}

#[tokio::test]
async fn high_player_buffer_blocks_scale_up_even_on_high_bitrate() {
    let data = make_test_data(1536 * 1024);
    let origin = Arc::new(Mutex::new(MockOriginConfig {
        content: data.clone(),
        per_conn_delay: Duration::from_millis(50),
        ..Default::default()
    }));
    let (port, _srv) = spawn_mock_server({
        let o = Arc::clone(&origin);
        move |req| serve_origin(req, Arc::clone(&o))
    })
    .await;

    let engine = NativeEngine::start(None).unwrap();
    engine
        .register_stream(StreamRegistration {
            token: "high-buf".into(),
            total_size: data.len() as u64,
            content_type: None,
            url: format!("http://127.0.0.1:{port}/v"),
            headers: HashMap::new(),
            profile: DriveTransferProfile {
                min_connections: 1,
                max_connections: 4,
                window_bytes: 1024 * 1024,
                min_segment_bytes: 256 * 1024,
                max_segment_bytes: 512 * 1024,
                probe_bypass_bytes: 64 * 1024,
                scale_up_eval_secs: 1,
                ..Default::default()
            },
        })
        .unwrap();
    engine.update_demand(
        "high-buf",
        PlaybackDemandUpdate {
            playback_started: Some(true),
            bitrate_bps: Some(50_000_000),
            buffered_secs: Some(60.0),
            is_buffering: Some(false),
            max_connections: None,
        },
    );

    let client = reqwest::Client::new();
    let got = client
        .get(format!("http://127.0.0.1:{}/s/high-buf/v.mp4", engine.port()))
        .send()
        .await
        .unwrap()
        .bytes()
        .await
        .unwrap();
    assert_eq!(got, data);

    let snaps = engine.poll_stats();
    let snap = snaps.iter().find(|s| s.token == "high-buf").unwrap();
    assert_eq!(snap.peak_conns, 1, "expected high player buffer to block scale up: {:?}", snap);

    stop_engine(engine).await;
}

#[tokio::test]
async fn forward_seek_into_active_segment_preempts_and_resumes_immediately() {
    let data = make_test_data(6 * 1024 * 1024);
    let data_for_srv = data.clone();
    let head_started = Arc::new(AtomicUsize::new(0));
    let head_started_srv = Arc::clone(&head_started);

    let (port, _srv) = spawn_mock_server(move |req| {
        let data = data_for_srv.clone();
        let head_started = Arc::clone(&head_started_srv);
        async move {
            let range_hdr = req
                .headers()
                .get(RANGE)
                .and_then(|v| v.to_str().ok())
                .map(str::to_string);
            let (s, e) = parse_range(range_hdr.as_deref(), data.len()).unwrap_or((0, data.len() - 1));
            let slice = data.slice(s..=e);
            if s < 512 * 1024 {
                head_started.fetch_add(1, Ordering::Relaxed);
                // Drip chunks very slowly after initial 64 KiB so the active task remains stuck
                // near offset 64 KiB while covering [0, 4 MiB - 1].
                let (tx, rx) = mpsc::channel::<Result<Frame<Bytes>, std::io::Error>>(16);
                tokio::spawn(async move {
                    let first = slice.slice(..(64 * 1024).min(slice.len()));
                    let _ = tx.send(Ok(Frame::data(first))).await;
                    let mut pos = (64 * 1024).min(slice.len());
                    while pos < slice.len() {
                        tokio::time::sleep(Duration::from_millis(250)).await;
                        let next_end = (pos + 16 * 1024).min(slice.len());
                        if tx.send(Ok(Frame::data(slice.slice(pos..next_end)))).await.is_err() {
                            break;
                        }
                        pos = next_end;
                    }
                });
                let stream = futures_util::stream::unfold(rx, |mut rx| async move {
                    let item = rx.recv().await?;
                    Some((item, rx))
                });
                let body = StreamBody::new(stream).boxed();
                return Response::builder()
                    .status(StatusCode::PARTIAL_CONTENT)
                    .header(CONTENT_RANGE, format!("bytes {s}-{e}/{}", data.len()))
                    .body(body)
                    .unwrap();
            }

            let body = BodyExt::boxed(
                Full::new(slice).map_err(|n| match n {}),
            );
            Response::builder()
                .status(StatusCode::PARTIAL_CONTENT)
                .header(CONTENT_RANGE, format!("bytes {s}-{e}/{}", data.len()))
                .body(body)
                .unwrap()
        }
    })
    .await;

    let engine = NativeEngine::start(None).unwrap();
    engine
        .register_stream(StreamRegistration {
            token: "fwd-seek-in-seg".into(),
            total_size: data.len() as u64,
            content_type: None,
            url: format!("http://127.0.0.1:{port}/v"),
            headers: HashMap::new(),
            profile: DriveTransferProfile {
                min_connections: 1,
                max_connections: 1,
                window_bytes: 4 * 1024 * 1024,
                min_segment_bytes: 2 * 1024 * 1024,
                max_segment_bytes: 4 * 1024 * 1024,
                probe_bypass_bytes: 64 * 1024,
                ..Default::default()
            },
        })
        .unwrap();

    let client = reqwest::Client::new();
    let url = format!("http://127.0.0.1:{}/s/fwd-seek-in-seg/v.mp4", engine.port());

    let head_client = client.clone();
    let head_url = url.clone();
    let head_task = tokio::spawn(async move {
        let resp = head_client
            .get(&head_url)
            .header(RANGE, "bytes=0-")
            .send()
            .await
            .unwrap();
        let _ = resp.bytes().await;
    });

    for _ in 0..40 {
        if head_started.load(Ordering::Relaxed) > 0 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    tokio::time::sleep(Duration::from_millis(60)).await;

    // Seek forward to +2 MiB, which sits inside the active [64 KiB, 4 MiB - 1] task segment.
    let t0 = Instant::now();
    let tail = client
        .get(&url)
        .header(RANGE, "bytes=2097152-")
        .send()
        .await
        .unwrap()
        .bytes()
        .await
        .unwrap();
    let elapsed = t0.elapsed();

    assert_eq!(tail, data.slice(2097152..));
    assert!(
        elapsed < Duration::from_millis(900),
        "forward seek inside active segment should preempt slow lagging task immediately, took {:?}",
        elapsed
    );

    head_task.abort();
    stop_engine(engine).await;
}

#[tokio::test]
async fn critical_empty_buffer_scales_up_even_with_low_bitrate_estimate() {
    let data = make_test_data(2 * 1024 * 1024);
    let origin = Arc::new(Mutex::new(MockOriginConfig {
        content: data.clone(),
        delay_first_range_start_once: Some((0, Duration::from_millis(1100))),
        ..Default::default()
    }));
    let (port, _srv) = spawn_mock_server({
        let o = Arc::clone(&origin);
        move |req| serve_origin(req, Arc::clone(&o))
    })
    .await;

    let engine = NativeEngine::start(None).unwrap();
    engine
        .register_stream(StreamRegistration {
            token: "crit-buf".into(),
            total_size: data.len() as u64,
            content_type: None,
            url: format!("http://127.0.0.1:{port}/v"),
            headers: HashMap::new(),
            profile: DriveTransferProfile {
                min_connections: 1,
                max_connections: 4,
                window_bytes: 1024 * 1024,
                min_segment_bytes: 256 * 1024,
                max_segment_bytes: 512 * 1024,
                probe_bypass_bytes: 64 * 1024,
                scale_up_eval_secs: 10,
                ..Default::default()
            },
        })
        .unwrap();
    engine.update_demand(
        "crit-buf",
        PlaybackDemandUpdate {
            playback_started: Some(true),
            bitrate_bps: Some(500_000),
            buffered_secs: Some(0.5),
            is_buffering: Some(false),
            max_connections: None,
        },
    );

    let client = reqwest::Client::new();
    let got = client
        .get(format!("http://127.0.0.1:{}/s/crit-buf/v.mp4", engine.port()))
        .send()
        .await
        .unwrap()
        .bytes()
        .await
        .unwrap();
    assert_eq!(got, data);

    let snaps = engine.poll_stats();
    let snap = snaps.iter().find(|s| s.token == "crit-buf").unwrap();
    assert!(
        snap.peak_conns >= 2,
        "expected critical buffer (<3s) to trigger scale-up within 1s even with 0.5Mbps bitrate: {:?}",
        snap
    );

    stop_engine(engine).await;
}
