use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use parking_lot::Mutex;
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use reqwest::{Client, Response, StatusCode};
use tokio::sync::oneshot;
use url::Url;

use crate::config::{DriveTransferProfile, LinkUpdatePayload};

const MAX_REDIRECTS: usize = 5;
const CREDENTIAL_HEADERS: &[&str] = &[
    "authorization",
    "proxy-authorization",
    "www-authenticate",
    "cookie",
    "cookie2",
];

pub type RefreshCallback = Arc<dyn Fn(&str, u64) + Send + Sync>;

#[derive(Debug, Clone)]
pub struct OriginLink {
    pub url: Url,
    pub headers: HashMap<String, String>,
    pub generation: u64,
}

#[derive(Debug, Clone)]
struct RedirectCacheEntry {
    url: Url,
    headers: HashMap<String, String>,
    generation: u64,
    expires_at: Instant,
}

#[derive(Debug)]
pub struct OpenedResponse {
    pub response: Response,
    pub ttfb_ms: u64,
    pub redirects: u64,
    pub final_host: String,
    pub link_generation: u64,
}

#[derive(Debug)]
pub enum OpenError {
    RateLimited { host: String },
    RangeUnsupported { response: Response },
    HttpStatus { status: u16, host: String },
    Network(String),
    RefreshFailed(String),
}

struct PendingRefresh {
    in_flight: Option<(u64, u64)>, // (base_generation, request_id)
    waiters: Vec<oneshot::Sender<Result<OriginLink, String>>>,
}

pub struct LinkManager {
    token: String,
    client: Client,
    profile: DriveTransferProfile,
    on_refresh: Option<RefreshCallback>,
    origin: Mutex<OriginLink>,
    cached_redirect: Mutex<Option<RedirectCacheEntry>>,
    refresh_state: Mutex<PendingRefresh>,
    next_req_id: AtomicU64,
}

impl LinkManager {
    pub fn new(
        token: String,
        url: Url,
        headers: HashMap<String, String>,
        profile: DriveTransferProfile,
        on_refresh: Option<RefreshCallback>,
        client: Client,
    ) -> Self {
        Self {
            token,
            client,
            profile,
            on_refresh,
            origin: Mutex::new(OriginLink {
                url,
                headers,
                generation: 1,
            }),
            cached_redirect: Mutex::new(None),
            refresh_state: Mutex::new(PendingRefresh {
                in_flight: None,
                waiters: Vec::new(),
            }),
            next_req_id: AtomicU64::new(1),
        }
    }

    pub fn update_profile_and_link(&self, url: Url, headers: HashMap<String, String>) {
        let mut guard = self.origin.lock();
        guard.url = url;
        guard.headers = headers;
        guard.generation += 1;
        *self.cached_redirect.lock() = None;
    }

    /// Opens an HTTP GET request for byte range `[from, to]` (inclusive),
    /// handling 302 redirect caching, cross-host credential stripping, and
    /// deduplicated stale-link refresh callbacks.
    pub async fn open_range(
        &self,
        from: u64,
        to: Option<u64>,
        allow_full_ok: bool,
    ) -> Result<OpenedResponse, OpenError> {
        let mut refreshed_once = false;
        let mut used_cached_redirect = false;

        loop {
            let (mut link, from_cache) = self.pick_link(used_cached_redirect);
            let started = Instant::now();
            match self.send_with_redirects(&link, from, to).await {
                Ok((resp, hops, final_url, final_headers)) => {
                    let ttfb_ms = started.elapsed().as_millis() as u64;
                    let status = resp.status();
                    let final_host = final_url.host_str().unwrap_or_default().to_string();

                    if status == StatusCode::PARTIAL_CONTENT
                        || (allow_full_ok && status == StatusCode::OK)
                    {
                        if status == StatusCode::OK && !allow_full_ok {
                            return Err(OpenError::RangeUnsupported { response: resp });
                        }
                        if hops > 0 && self.profile.cache_redirect_url && !from_cache {
                            let ttl = Duration::from_secs(self.profile.redirect_cache_ttl_secs.max(5));
                            *self.cached_redirect.lock() = Some(RedirectCacheEntry {
                                url: final_url,
                                headers: final_headers,
                                generation: link.generation,
                                expires_at: Instant::now() + ttl,
                            });
                        }
                        return Ok(OpenedResponse {
                            response: resp,
                            ttfb_ms,
                            redirects: hops,
                            final_host,
                            link_generation: link.generation,
                        });
                    }

                    if status == StatusCode::OK {
                        return Err(OpenError::RangeUnsupported { response: resp });
                    }

                    if status == StatusCode::TOO_MANY_REQUESTS {
                        return Err(OpenError::RateLimited { host: final_host });
                    }

                    let code = status.as_u16();
                    if self.profile.stale_statuses.contains(&code) {
                        if from_cache {
                            // Cached redirect target expired first; drop cache and retry origin link.
                            *self.cached_redirect.lock() = None;
                            used_cached_redirect = true;
                            continue;
                        }
                        if !refreshed_once && self.on_refresh.is_some() {
                            refreshed_once = true;
                            used_cached_redirect = false;
                            link = self.request_refresh(link.generation).await?;
                            let _ = link;
                            continue;
                        }
                    }

                    return Err(OpenError::HttpStatus {
                        status: code,
                        host: final_host,
                    });
                }
                Err(e) => {
                    if from_cache {
                        *self.cached_redirect.lock() = None;
                        used_cached_redirect = true;
                        continue;
                    }
                    return Err(e);
                }
            }
        }
    }

    fn pick_link(&self, bypass_cache: bool) -> (OriginLink, bool) {
        let origin = self.origin.lock().clone();
        if !bypass_cache && self.profile.cache_redirect_url {
            let mut cache = self.cached_redirect.lock();
            if let Some(entry) = cache.as_ref() {
                if entry.generation == origin.generation && entry.expires_at > Instant::now() {
                    return (
                        OriginLink {
                            url: entry.url.clone(),
                            headers: entry.headers.clone(),
                            generation: entry.generation,
                        },
                        true,
                    );
                }
            }
            *cache = None;
        }
        (origin, false)
    }

    async fn send_with_redirects(
        &self,
        initial: &OriginLink,
        from: u64,
        to: Option<u64>,
    ) -> Result<(Response, u64, Url, HashMap<String, String>), OpenError> {
        let mut uri = initial.url.clone();
        let mut headers = initial.headers.clone();
        let mut hops = 0u64;

        loop {
            let mut req = self.client.get(uri.clone());
            let mut hdr_map = HeaderMap::new();
            for (k, v) in &headers {
                if let (Ok(name), Ok(val)) = (
                    HeaderName::from_bytes(k.as_bytes()),
                    HeaderValue::from_str(v),
                ) {
                    hdr_map.insert(name, val);
                }
            }
            if let Some(ref ua) = self.profile.user_agent {
                if let Ok(val) = HeaderValue::from_str(ua) {
                    hdr_map.entry(reqwest::header::USER_AGENT).or_insert(val);
                }
            }
            let range_val = match to {
                Some(end) => format!("bytes={from}-{end}"),
                None => format!("bytes={from}-"),
            };
            if let Ok(val) = HeaderValue::from_str(&range_val) {
                hdr_map.insert(reqwest::header::RANGE, val);
            }
            hdr_map.insert(
                reqwest::header::ACCEPT_ENCODING,
                HeaderValue::from_static("identity"),
            );
            req = req.headers(hdr_map);

            let resp = req
                .send()
                .await
                .map_err(|e| OpenError::Network(format!("{}: {e}", uri.host_str().unwrap_or(""))))?;

            if resp.status().is_redirection() {
                let loc = resp
                    .headers()
                    .get(reqwest::header::LOCATION)
                    .and_then(|v| v.to_str().ok())
                    .map(str::to_string);
                if let Some(loc_str) = loc {
                    if hops >= MAX_REDIRECTS as u64 {
                        return Err(OpenError::Network("Too many redirects".into()));
                    }
                    let target = uri
                        .join(&loc_str)
                        .map_err(|e| OpenError::Network(format!("Invalid redirect URL: {e}")))?;
                    if target.scheme() != "http" && target.scheme() != "https" {
                        return Err(OpenError::Network("Invalid redirect scheme".into()));
                    }
                    headers = strip_headers_on_redirect(&uri, &target, &headers);
                    uri = target;
                    hops += 1;
                    continue;
                }
            }

            return Ok((resp, hops, uri, headers));
        }
    }

    async fn request_refresh(&self, failed_generation: u64) -> Result<OriginLink, OpenError> {
        // Fast check: another task already refreshed while we were failing.
        {
            let cur = self.origin.lock().clone();
            if cur.generation > failed_generation {
                return Ok(cur);
            }
        }

        let (tx, rx) = oneshot::channel();
        let trigger_req_id = {
            let mut state = self.refresh_state.lock();
            let cur = self.origin.lock().clone();
            if cur.generation > failed_generation {
                return Ok(cur);
            }
            state.waiters.push(tx);
            if state.in_flight.is_some() {
                None
            } else {
                let req_id = self.next_req_id.fetch_add(1, Ordering::Relaxed);
                state.in_flight = Some((failed_generation, req_id));
                Some(req_id)
            }
        };

        if let Some(req_id) = trigger_req_id {
            if let Some(cb) = &self.on_refresh {
                cb(&self.token, req_id);
            } else {
                self.apply_link_update(
                    req_id,
                    LinkUpdatePayload {
                        url: None,
                        headers: None,
                        error: Some("No refresh callback registered".into()),
                    },
                );
            }
        }

        match tokio::time::timeout(Duration::from_secs(15), rx).await {
            Ok(Ok(Ok(link))) => Ok(link),
            Ok(Ok(Err(msg))) => Err(OpenError::RefreshFailed(msg)),
            Ok(Err(_)) => Err(OpenError::RefreshFailed("Refresh channel dropped".into())),
            Err(_) => {
                // Clear in-flight state if Dart timed out so future requests can retry.
                let mut state = self.refresh_state.lock();
                state.in_flight = None;
                state.waiters.clear();
                Err(OpenError::RefreshFailed("Link refresh timed out".into()))
            }
        }
    }

    pub fn apply_link_update(&self, req_id: u64, payload: LinkUpdatePayload) {
        let res = match payload.url {
            Some(ref u) if payload.error.is_none() => match Url::parse(u) {
                Ok(parsed) => {
                    let mut origin = self.origin.lock();
                    origin.url = parsed;
                    if let Some(h) = payload.headers {
                        origin.headers = h;
                    }
                    origin.generation += 1;
                    *self.cached_redirect.lock() = None;
                    Ok(origin.clone())
                }
                Err(e) => Err(format!("Invalid refreshed URL: {e}")),
            },
            _ => Err(payload
                .error
                .unwrap_or_else(|| "Link refresh rejected".into())),
        };

        let waiters = {
            let mut state = self.refresh_state.lock();
            if let Some((_, active_id)) = state.in_flight {
                if active_id != req_id {
                    return;
                }
            }
            state.in_flight = None;
            std::mem::take(&mut state.waiters)
        };

        for tx in waiters {
            let _ = tx.send(res.clone());
        }
    }
}

pub fn strip_headers_on_redirect(
    from: &Url,
    to: &Url,
    headers: &HashMap<String, String>,
) -> HashMap<String, String> {
    let same_scheme = from.scheme().eq_ignore_ascii_case(to.scheme());
    let same_port = from.port_or_known_default() == to.port_or_known_default();
    let from_host = from.host_str().unwrap_or_default().to_ascii_lowercase();
    let to_host = to.host_str().unwrap_or_default().to_ascii_lowercase();
    let can_forward_creds =
        same_scheme && same_port && (to_host == from_host || to_host.ends_with(&format!(".{from_host}")));

    headers
        .iter()
        .filter(|(k, _)| {
            let lower = k.to_ascii_lowercase();
            lower != "host"
                && (can_forward_creds || !CREDENTIAL_HEADERS.contains(&lower.as_str()))
        })
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect()
}
