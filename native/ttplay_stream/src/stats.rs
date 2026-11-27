use std::time::Instant;

use parking_lot::Mutex;

use crate::config::StreamStatsSnapshot;

struct StatsInner {
    window_start: Instant,
    upstream_bytes: u64,
    delivered_bytes: u64,
    up_wait_us: u64,
    down_wait_us: u64,
    down_pauses: u64,
    requests: u64,
    ttfb_ms_sum: u64,
    ttfb_count: u64,
    ttfb_max_ms: u64,
    redirects: u64,
    work_steals: u64,
    retries: u64,
    rate_limits: u64,
    peak_conns: usize,
    final_host: Option<String>,
    last_error: Option<String>,
}

pub struct StreamStats {
    token: String,
    inner: Mutex<StatsInner>,
}

impl StreamStats {
    pub fn new(token: String) -> Self {
        Self {
            token,
            inner: Mutex::new(StatsInner {
                window_start: Instant::now(),
                upstream_bytes: 0,
                delivered_bytes: 0,
                up_wait_us: 0,
                down_wait_us: 0,
                down_pauses: 0,
                requests: 0,
                ttfb_ms_sum: 0,
                ttfb_count: 0,
                ttfb_max_ms: 0,
                redirects: 0,
                work_steals: 0,
                retries: 0,
                rate_limits: 0,
                peak_conns: 0,
                final_host: None,
                last_error: None,
            }),
        }
    }

    pub fn record_error(&self, msg: String) {
        if !msg.is_empty() {
            self.inner.lock().last_error = Some(msg);
        }
    }

    pub fn record_request(&self) {
        self.inner.lock().requests += 1;
    }

    pub fn record_upstream_bytes(&self, bytes: u64) {
        self.inner.lock().upstream_bytes += bytes;
    }

    pub fn record_delivered_bytes(&self, bytes: u64) {
        self.inner.lock().delivered_bytes += bytes;
    }

    pub fn record_up_wait_us(&self, us: u64) {
        self.inner.lock().up_wait_us += us;
    }

    pub fn record_down_wait_us(&self, us: u64) {
        self.inner.lock().down_wait_us += us;
    }

    pub fn record_down_pause(&self) {
        self.inner.lock().down_pauses += 1;
    }

    pub fn record_open(&self, ttfb_ms: u64, redirects: u64, host: String) {
        let mut g = self.inner.lock();
        g.ttfb_ms_sum += ttfb_ms;
        g.ttfb_count += 1;
        if ttfb_ms > g.ttfb_max_ms {
            g.ttfb_max_ms = ttfb_ms;
        }
        g.redirects += redirects;
        if !host.is_empty() {
            g.final_host = Some(host);
        }
    }

    pub fn record_work_steal(&self) {
        self.inner.lock().work_steals += 1;
    }

    pub fn record_retry(&self) {
        self.inner.lock().retries += 1;
    }

    pub fn record_rate_limit(&self) {
        self.inner.lock().rate_limits += 1;
    }

    pub fn record_active_conns(&self, active: usize) {
        let mut g = self.inner.lock();
        if active > g.peak_conns {
            g.peak_conns = active;
        }
    }

    pub fn snapshot_and_reset(
        &self,
        active_conns: usize,
        target_conns: usize,
        effective_max_conns: usize,
        cache_bytes: usize,
        playback_started: bool,
        demand_bitrate_bps: u64,
        active_readers: usize,
    ) -> StreamStatsSnapshot {
        let mut g = self.inner.lock();
        let now = Instant::now();
        let elapsed_us = now.duration_since(g.window_start).as_micros().max(1) as f64;
        let elapsed_ms = (elapsed_us / 1000.0).round() as u64;
        let ttfb_avg_ms = if g.ttfb_count > 0 {
            g.ttfb_ms_sum / g.ttfb_count
        } else {
            0
        };
        let snap = StreamStatsSnapshot {
            token: self.token.clone(),
            elapsed_ms,
            upstream_bytes: g.upstream_bytes,
            delivered_bytes: g.delivered_bytes,
            active_conns,
            target_conns,
            effective_max_conns,
            peak_conns: g.peak_conns.max(active_conns),
            cache_bytes,
            ttfb_avg_ms,
            ttfb_max_ms: g.ttfb_max_ms,
            redirects: g.redirects,
            work_steals: g.work_steals,
            retries: g.retries,
            rate_limits: g.rate_limits,
            up_wait_pct: ((g.up_wait_us as f64 / elapsed_us) * 100.0).clamp(0.0, 100.0),
            down_wait_pct: ((g.down_wait_us as f64 / elapsed_us) * 100.0).clamp(0.0, 100.0),
            pauses: g.down_pauses,
            requests: g.requests,
            final_host: g.final_host.clone(),
            playback_started,
            demand_bitrate_bps,
            active_readers,
            last_error: g.last_error.take(),
        };

        g.window_start = now;
        g.upstream_bytes = 0;
        g.delivered_bytes = 0;
        g.up_wait_us = 0;
        g.down_wait_us = 0;
        g.down_pauses = 0;
        g.requests = 0;
        g.ttfb_ms_sum = 0;
        g.ttfb_count = 0;
        g.ttfb_max_ms = 0;
        g.redirects = 0;
        g.work_steals = 0;
        g.retries = 0;
        g.rate_limits = 0;
        g.peak_conns = active_conns;
        snap
    }
}
