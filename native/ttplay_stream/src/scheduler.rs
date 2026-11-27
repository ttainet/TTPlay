use std::collections::{BTreeMap, HashMap, VecDeque};
use std::io;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use bytes::Bytes;
use futures_util::StreamExt;
use parking_lot::Mutex;
use reqwest::{Client, StatusCode};
use tokio::sync::{watch, Notify};
use url::Url;

use crate::config::{
    DriveTransferProfile, LinkUpdatePayload, PlaybackDemandUpdate, StreamLiveStatus,
    StreamRegistration, StreamStatsSnapshot,
};
use crate::link_manager::{LinkManager, OpenError, RefreshCallback};
use crate::stats::StreamStats;

const MAX_RETRIES_PER_TASK: usize = 3;

/// Bounded in-memory range cache supporting non-overlapping inserts, streaming reads,
/// and behind-cursor LRU eviction.
struct RangeCache {
    pieces: BTreeMap<u64, Bytes>,
    total_bytes: usize,
    max_bytes: usize,
}

impl RangeCache {
    fn new(max_bytes: usize) -> Self {
        Self {
            pieces: BTreeMap::new(),
            total_bytes: 0,
            max_bytes: max_bytes.max(1024 * 1024),
        }
    }

    fn insert_piece(&mut self, offset: u64, data: Bytes) {
        if data.is_empty() {
            return;
        }
        let mut start = offset;
        let mut slice = data;
        let end = start + slice.len() as u64 - 1;

        // Trim leading overlap if an earlier piece already covers `[k, k_end]`.
        if let Some((&prev_start, prev_bytes)) = self.pieces.range(..=start).next_back() {
            let prev_end = prev_start + prev_bytes.len() as u64 - 1;
            if prev_end >= end {
                return;
            }
            if prev_end >= start {
                let skip = (prev_end - start + 1) as usize;
                slice = slice.slice(skip..);
                start = prev_end + 1;
            }
        }

        // Trim trailing overlap against the next piece if any.
        if let Some((&next_start, _)) = self.pieces.range(start..).next() {
            let cur_end = start + slice.len() as u64 - 1;
            if next_start <= cur_end {
                let keep = (next_start - start) as usize;
                if keep == 0 {
                    return;
                }
                slice = slice.slice(..keep);
            }
        }

        self.total_bytes += slice.len();
        self.pieces.insert(start, slice);
    }

    fn read_at(&self, pos: u64, max_end: u64) -> Option<Bytes> {
        let (&k, v) = self.pieces.range(..=pos).next_back()?;
        let piece_end = k + v.len() as u64 - 1;
        if pos > piece_end {
            return None;
        }
        let rel = (pos - k) as usize;
        let avail = (piece_end - pos + 1).min(max_end - pos + 1) as usize;
        Some(v.slice(rel..rel + avail))
    }

    fn evict_outside(&mut self, protected: &[(u64, u64)]) {
        let to_remove: Vec<u64> = self
            .pieces
            .iter()
            .filter_map(|(&k, v)| {
                if v.is_empty() {
                    return Some(k);
                }
                let end = k + v.len() as u64 - 1;
                let keep = protected.iter().any(|&(ps, pe)| end >= ps && k <= pe);
                if !keep {
                    Some(k)
                } else {
                    None
                }
            })
            .collect();
        for k in to_remove {
            if let Some(removed) = self.pieces.remove(&k) {
                self.total_bytes = self.total_bytes.saturating_sub(removed.len());
            }
        }
        // If still over budget (e.g. far-apart active readers or giant stall),
        // evict the boundary block farthest from the newest reader's protected window.
        let (anchor_s, anchor_e) = protected.first().copied().unwrap_or((0, 0));
        let dist_from_anchor = |k: u64| -> u64 {
            if k < anchor_s {
                anchor_s - k
            } else if k > anchor_e {
                k - anchor_e
            } else {
                0
            }
        };
        while self.total_bytes > self.max_bytes {
            let victim_key = match (self.pieces.keys().next().copied(), self.pieces.keys().next_back().copied()) {
                (Some(first_k), Some(last_k)) => {
                    if dist_from_anchor(first_k) > dist_from_anchor(last_k) {
                        first_k
                    } else {
                        last_k
                    }
                }
                _ => break,
            };
            if let Some(removed) = self.pieces.remove(&victim_key) {
                self.total_bytes = self.total_bytes.saturating_sub(removed.len());
            }
        }
    }

    /// Returns uncovered sub-ranges inside `[from, to]`.
    fn uncovered_ranges(&self, mut from: u64, to: u64) -> Vec<(u64, u64)> {
        if from > to {
            return Vec::new();
        }
        let mut out = Vec::new();
        // Check a piece overlapping `from`.
        if let Some((&k, v)) = self.pieces.range(..=from).next_back() {
            let end = k + v.len() as u64 - 1;
            if end >= from {
                if end >= to {
                    return out;
                }
                from = end + 1;
            }
        }
        for (&k, v) in self.pieces.range(from..=to) {
            if k > from {
                out.push((from, (k - 1).min(to)));
            }
            let end = k + v.len() as u64 - 1;
            if end >= to {
                return out;
            }
            from = end + 1;
        }
        if from <= to {
            out.push((from, to));
        }
        out
    }

    fn buffered_ahead_from(&self, mut pos: u64, limit: u64) -> u64 {
        let mut total = 0u64;
        while total < limit {
            if let Some((&k, v)) = self.pieces.range(..=pos).next_back() {
                let end = k + v.len() as u64 - 1;
                if end >= pos {
                    let step = end - pos + 1;
                    total += step;
                    pos = end + 1;
                    continue;
                }
            }
            break;
        }
        total
    }
}

#[derive(Clone)]
struct ActiveTaskHandle {
    id: u64,
    cur_pos: Arc<AtomicU64>,
    soft_end: Arc<AtomicU64>,
    started_at: Instant,
    last_progress_at: Arc<Mutex<Instant>>,
    recent_bytes: Arc<Mutex<VecDeque<(Instant, u64)>>>,
    cancel_tx: watch::Sender<bool>,
}

impl ActiveTaskHandle {
    fn recent_speed_bps(&self) -> f64 {
        let mut q = self.recent_bytes.lock();
        let now = Instant::now();
        while let Some((ts, _)) = q.front() {
            if now.duration_since(*ts) > Duration::from_secs(3) {
                q.pop_front();
            } else {
                break;
            }
        }
        let sum: u64 = q.iter().map(|(_, b)| *b).sum();
        if q.len() < 2 {
            let elapsed = now.duration_since(self.started_at).as_secs_f64();
            if elapsed > 0.25 {
                return sum as f64 / elapsed;
            }
            return 0.0;
        }
        let span = now
            .duration_since(q.front().unwrap().0)
            .as_secs_f64()
            .max(0.2);
        sum as f64 / span
    }
}

#[derive(Debug, Clone)]
struct PlaybackDemandState {
    playback_started: bool,
    bitrate_bps: u64,
    smoothed_bitrate_bps: f64,
    buffered_secs: f64,
    is_buffering: bool,
}

impl Default for PlaybackDemandState {
    fn default() -> Self {
        Self {
            playback_started: false,
            bitrate_bps: 0,
            smoothed_bitrate_bps: 0.0,
            buffered_secs: -1.0,
            is_buffering: false,
        }
    }
}

struct AdaptiveController {
    min_conns: usize,
    configured_max: usize,
    current_conns: usize,
    cooldown_max: Option<(usize, Instant)>,
    rate_limit_max: Option<(usize, Instant)>,
    scale_trial: Option<ScaleTrial>,
    throughput_samples: VecDeque<(Instant, u64)>,
    last_eval_at: Instant,
    demand: PlaybackDemandState,
}

struct ScaleTrial {
    prev_conns: usize,
    prev_bps: f64,
    started_at: Instant,
    trial_bytes: u64,
}

impl AdaptiveController {
    fn new(profile: &DriveTransferProfile) -> Self {
        let min_c = profile.min_connections.max(1);
        let max_c = profile.max_connections.max(min_c);
        Self {
            min_conns: min_c,
            configured_max: max_c,
            current_conns: min_c,
            cooldown_max: None,
            rate_limit_max: None,
            scale_trial: None,
            throughput_samples: VecDeque::new(),
            last_eval_at: Instant::now(),
            demand: PlaybackDemandState::default(),
        }
    }

    fn apply_demand(&mut self, upd: PlaybackDemandUpdate, profile: &DriveTransferProfile) {
        let now = Instant::now();
        if let Some(max_c) = upd.max_connections {
            self.configured_max = max_c.max(self.min_conns).max(1);
            let eff = self.effective_max(now);
            self.current_conns = self.current_conns.min(eff);
        }
        if let Some(started) = upd.playback_started {
            if started && !self.demand.playback_started {
                let eval_secs = profile.scale_up_eval_secs.max(1);
                self.last_eval_at = now
                    .checked_sub(Duration::from_secs(eval_secs.saturating_sub(1)))
                    .unwrap_or(now);
            } else if !started && self.demand.playback_started {
                self.current_conns = self.min_conns;
                self.scale_trial = None;
                self.demand.smoothed_bitrate_bps = 0.0;
            }
            self.demand.playback_started = started;
        }
        if let Some(br) = upd.bitrate_bps {
            self.demand.bitrate_bps = br;
            if br > 0 {
                if self.demand.smoothed_bitrate_bps <= 0.0 {
                    self.demand.smoothed_bitrate_bps = br as f64;
                } else {
                    self.demand.smoothed_bitrate_bps =
                        self.demand.smoothed_bitrate_bps * 0.7 + (br as f64) * 0.3;
                }
            }
        }
        if let Some(buf) = upd.buffered_secs {
            self.demand.buffered_secs = buf;
        }
        if let Some(buffering) = upd.is_buffering {
            self.demand.is_buffering = buffering;
        }
    }

    fn effective_max(&mut self, now: Instant) -> usize {
        let mut limit = self.configured_max;
        if let Some((cap, until)) = self.cooldown_max {
            if now < until {
                limit = limit.min(cap);
            } else {
                self.cooldown_max = None;
            }
        }
        if let Some((cap, until)) = self.rate_limit_max {
            if now < until {
                limit = limit.min(cap);
            } else {
                self.rate_limit_max = None;
            }
        }
        limit.max(1)
    }

    fn target_conns(&mut self, now: Instant) -> usize {
        let eff = self.effective_max(now);
        self.current_conns.clamp(self.min_conns.min(eff), eff)
    }

    fn record_bytes(&mut self, bytes: u64) {
        let now = Instant::now();
        if let Some(trial) = self.scale_trial.as_mut() {
            trial.trial_bytes += bytes;
        }
        self.throughput_samples.push_back((now, bytes));
        while let Some((ts, _)) = self.throughput_samples.front() {
            if now.duration_since(*ts) > Duration::from_secs(4) {
                self.throughput_samples.pop_front();
            } else {
                break;
            }
        }
    }

    fn current_bps(&mut self) -> f64 {
        let now = Instant::now();
        while let Some((ts, _)) = self.throughput_samples.front() {
            if now.duration_since(*ts) > Duration::from_secs(4) {
                self.throughput_samples.pop_front();
            } else {
                break;
            }
        }
        let sum: u64 = self.throughput_samples.iter().map(|(_, b)| *b).sum();
        if sum == 0 {
            return 0.0;
        }
        let span = now
            .duration_since(self.throughput_samples.front().unwrap().0)
            .as_secs_f64()
            .max(0.5);
        sum as f64 / span
    }

    fn on_rate_limit(&mut self, cooldown_secs: u64) {
        let now = Instant::now();
        let cur_eff = self.effective_max(now);
        let next = (cur_eff / 2).max(1);
        self.rate_limit_max = Some((next, now + Duration::from_secs(cooldown_secs.max(10))));
        self.current_conns = self.current_conns.min(next);
        self.scale_trial = None;
    }

    /// Evaluates whether to scale up concurrency or roll back an ineffective scale-up.
    fn evaluate(&mut self, profile: &DriveTransferProfile, buffered_ahead: u64, reader_waiting: bool) {
        let now = Instant::now();
        let eval_dur = Duration::from_secs(profile.scale_up_eval_secs.max(1));
        let player_buffer_healthy = !self.demand.is_buffering
            && self.demand.buffered_secs >= profile.high_buffer_secs;
        let proxy_window_full = !reader_waiting
            && !self.demand.is_buffering
            && buffered_ahead >= (profile.window_bytes * 3) / 4;

        if let Some((prev_conns, prev_bps, started_at, trial_bytes)) = self
            .scale_trial
            .as_ref()
            .map(|t| (t.prev_conns, t.prev_bps, t.started_at, t.trial_bytes))
        {
            if profile.demand_driven_scale_up && (player_buffer_healthy || proxy_window_full) {
                // Downstream backpressure or full buffer occurred mid-trial; abort cleanly
                // without blaming the network or entering cooldown.
                self.current_conns = prev_conns.max(1);
                self.scale_trial = None;
                self.last_eval_at = now;
                return;
            }
            let elapsed = now.duration_since(started_at);
            if elapsed >= eval_dur {
                let trial_bps = trial_bytes as f64 / elapsed.as_secs_f64().max(0.5);
                let needed = prev_bps * profile.scale_up_min_gain_ratio;
                let improved = prev_bps < 64.0 * 1024.0 || trial_bps >= needed;
                if !improved {
                    let rollback_to = prev_conns.max(1);
                    self.current_conns = rollback_to;
                    self.cooldown_max = Some((
                        rollback_to,
                        now + Duration::from_secs(profile.rate_limit_cooldown_secs.max(10)),
                    ));
                }
                self.scale_trial = None;
                self.last_eval_at = now;
            }
            return;
        }

        if profile.demand_driven_scale_up && !self.demand.playback_started {
            self.current_conns = self.min_conns;
            return;
        }

        if profile.demand_driven_scale_up && (player_buffer_healthy || proxy_window_full) {
            return;
        }

        let buffer_critical =
            self.demand.playback_started && self.demand.buffered_secs >= 0.0 && self.demand.buffered_secs < 3.0;
        let wait_dur = if profile.demand_driven_scale_up && (self.demand.is_buffering || buffer_critical) {
            Duration::from_secs(1)
        } else {
            eval_dur
        };
        if now.duration_since(self.last_eval_at) < wait_dur {
            return;
        }
        self.last_eval_at = now;

        let eff = self.effective_max(now);
        if self.current_conns >= eff {
            return;
        }

        let needs_more = if profile.demand_driven_scale_up {
            let cur_bps = self.current_bps();
            let has_speed = cur_bps > 0.0;
            let eff_bitrate = if self.demand.smoothed_bitrate_bps > 0.0 {
                self.demand.smoothed_bitrate_bps
            } else {
                self.demand.bitrate_bps as f64
            };
            let required_bytes_per_sec = if eff_bitrate > 0.0 {
                (eff_bitrate / 8.0) * profile.bitrate_safety_factor.max(1.0)
            } else {
                0.0
            };
            let bitrate_tight =
                has_speed && required_bytes_per_sec > 0.0 && cur_bps < required_bytes_per_sec;
            let buffer_low =
                self.demand.buffered_secs >= 0.0 && self.demand.buffered_secs < profile.low_buffer_secs;
            self.demand.is_buffering
                || buffer_critical
                || bitrate_tight
                || (buffer_low
                    && has_speed
                    && (required_bytes_per_sec == 0.0 || cur_bps < required_bytes_per_sec * 1.25))
        } else {
            let low_buffer = buffered_ahead < (profile.window_bytes / 2);
            reader_waiting || low_buffer
        };

        if needs_more {
            let prev_bps = self.current_bps();
            self.scale_trial = Some(ScaleTrial {
                prev_conns: self.current_conns,
                prev_bps,
                started_at: now,
                trial_bytes: 0,
            });
            self.current_conns = (self.current_conns + 1).min(eff);
        }
    }
}

struct CoordinatorState {
    cache: RangeCache,
    tasks: HashMap<u64, ActiveTaskHandle>,
    readers: HashMap<u64, u64>, // reader_id -> cursor_pos
    adaptive: AdaptiveController,
    range_unsupported: bool,
    fatal_error: Option<String>,
    next_id: u64,
}

pub struct StreamSession {
    pub total_size: u64,
    pub content_type: Option<String>,
    profile: DriveTransferProfile,
    links: Arc<LinkManager>,
    pub stats: Arc<StreamStats>,
    state: Arc<Mutex<CoordinatorState>>,
    notify: Arc<Notify>,
    direct_readers: AtomicUsize,
}

impl StreamSession {
    pub fn new(reg: StreamRegistration, on_refresh: Option<RefreshCallback>, client: Client) -> Self {
        let parsed = Url::parse(&reg.url).expect("validated registration url");
        let cache_budget = (reg.profile.window_bytes as usize).saturating_add(4 * 1024 * 1024);
        let adaptive = AdaptiveController::new(&reg.profile);
        let token = reg.token.clone();
        Self {
            links: Arc::new(LinkManager::new(
                reg.token,
                parsed,
                reg.headers,
                reg.profile.clone(),
                on_refresh,
                client,
            )),
            stats: Arc::new(StreamStats::new(token)),
            total_size: reg.total_size,
            content_type: reg.content_type,
            state: Arc::new(Mutex::new(CoordinatorState {
                cache: RangeCache::new(cache_budget),
                tasks: HashMap::new(),
                readers: HashMap::new(),
                adaptive,
                range_unsupported: false,
                fatal_error: None,
                next_id: 1,
            })),
            profile: reg.profile,
            notify: Arc::new(Notify::new()),
            direct_readers: AtomicUsize::new(0),
        }
    }

    pub fn update_link(&self, req_id: u64, payload: LinkUpdatePayload) {
        self.links.apply_link_update(req_id, payload);
        self.notify.notify_waiters();
    }

    pub fn update_demand(self: &Arc<Self>, upd: PlaybackDemandUpdate) {
        let should_schedule = {
            let mut g = self.state.lock();
            g.adaptive.apply_demand(upd, &self.profile);
            !g.readers.is_empty()
        };
        if should_schedule {
            self.ensure_scheduled(false);
        }
    }

    pub fn poll_stats(&self) -> StreamStatsSnapshot {
        let mut g = self.state.lock();
        let now = Instant::now();
        let active = g.tasks.len() + self.direct_readers.load(Ordering::Relaxed);
        let active_readers = g.readers.len() + self.direct_readers.load(Ordering::Relaxed);
        let target = g.adaptive.target_conns(now);
        let eff_max = g.adaptive.effective_max(now);
        let cache_bytes = g.cache.total_bytes;
        let playback_started = g.adaptive.demand.playback_started;
        let demand_bitrate_bps = g.adaptive.demand.bitrate_bps;
        self.stats.snapshot_and_reset(
            active,
            target,
            eff_max,
            cache_bytes,
            playback_started,
            demand_bitrate_bps,
            active_readers,
        )
    }

    pub fn peek_status(&self) -> StreamLiveStatus {
        let mut g = self.state.lock();
        let now = Instant::now();
        let active = g.tasks.len() + self.direct_readers.load(Ordering::Relaxed);
        let target = g.adaptive.target_conns(now);
        let eff_max = g.adaptive.effective_max(now);
        StreamLiveStatus {
            active_conns: active,
            target_conns: target,
            effective_max_conns: eff_max,
            cache_bytes: g.cache.total_bytes,
        }
    }

    pub fn shutdown(&self) {
        let tasks: Vec<ActiveTaskHandle> = {
            let mut g = self.state.lock();
            g.tasks.drain().map(|(_, t)| t).collect()
        };
        for t in tasks {
            let _ = t.cancel_tx.send(true);
        }
        self.notify.notify_waiters();
    }

    pub fn open_reader(self: &Arc<Self>, start: u64, end: u64) -> StreamReader {
        self.stats.record_request();
        let span = end.saturating_sub(start).saturating_add(1);
        let (range_unsupported, can_multi) = {
            let g = self.state.lock();
            (
                g.range_unsupported,
                g.adaptive.configured_max > 1 || self.profile.allow_runtime_max_upgrade,
            )
        };
        let use_direct = span < self.profile.probe_bypass_bytes || !can_multi || range_unsupported;

        if use_direct {
            StreamReader::Direct(DirectRangeReader::new(Arc::clone(self), start, end))
        } else {
            let reader_id = {
                let mut g = self.state.lock();
                let id = g.next_id;
                g.next_id += 1;
                g.readers.insert(id, start);
                g.fatal_error = None;
                id
            };
            self.ensure_scheduled(false);
            StreamReader::Prefetch(PrefetchRangeReader {
                session: Arc::clone(self),
                reader_id,
                cursor: start,
                end,
            })
        }
    }

    /// Schedules missing holes inside active reader windows (newest reader first),
    /// prunes abandoned out-of-window tasks, preempts stale tasks when a new seek
    /// arrives at concurrency cap, and handles soft_end cutoffs / work-stealing.
    fn ensure_scheduled(self: &Arc<Self>, reader_waiting: bool) {
        let mut to_spawn: Vec<(u64, u64, u64, bool)> = Vec::new();
        {
            let mut g = self.state.lock();
            if g.readers.is_empty() || g.range_unsupported || g.total_active_fatal() {
                return;
            }
            let max_file_end = self.total_size.saturating_sub(1);
            let mut ordered_readers: Vec<(u64, u64)> =
                g.readers.iter().map(|(&id, &cur)| (id, cur)).collect();
            ordered_readers.sort_by(|a, b| b.0.cmp(&a.0));
            let newest_cursor = ordered_readers[0].1;
            let reader_windows: Vec<(u64, u64)> = ordered_readers
                .iter()
                .map(|&(_, c)| (c, (c + self.profile.window_bytes).min(max_file_end)))
                .collect();

            // Cancel tasks whose remaining range falls outside all active reader windows,
            // or whose current position lags >512 KiB behind every active reader cursor
            // (forward seek inside a large segment).
            const MAX_ORPHAN_CATCHUP_BYTES: u64 = 512 * 1024;
            let stale_task_ids: Vec<u64> = g
                .tasks
                .iter()
                .filter_map(|(&id, t)| {
                    let t_start = t.cur_pos.load(Ordering::Acquire);
                    let t_end = t.soft_end.load(Ordering::Acquire);
                    let useful = reader_windows.iter().any(|&(ws, we)| {
                        let keep_start = ws.saturating_sub(256 * 1024);
                        t_start <= we
                            && t_end >= keep_start
                            && ws.saturating_sub(t_start) <= MAX_ORPHAN_CATCHUP_BYTES
                    });
                    if !useful {
                        Some(id)
                    } else {
                        None
                    }
                })
                .collect();
            for id in stale_task_ids {
                if let Some(t) = g.tasks.remove(&id) {
                    let _ = t.cancel_tx.send(true);
                }
            }

            // Protect each active reader's [cursor - 2 MiB, window_end] so concurrent readers
            // don't evict each other's buffered data.
            let protected: Vec<(u64, u64)> = reader_windows
                .iter()
                .map(|&(ws, we)| (ws.saturating_sub(2 * 1024 * 1024), we))
                .collect();
            g.cache.evict_outside(&protected);

            let buffered_ahead = g
                .cache
                .buffered_ahead_from(newest_cursor, self.profile.window_bytes);
            g.adaptive
                .evaluate(&self.profile, buffered_ahead, reader_waiting);
            let now = Instant::now();
            let target_conns = g.adaptive.target_conns(now);

            // If the newest reader's cursor isn't covered by cache or an active task
            // and we're already at target concurrency, preempt the oldest non-overlapping task.
            let newest_in_cache = g.cache.read_at(newest_cursor, newest_cursor).is_some();
            let newest_in_tasks = g.tasks.values().any(|t| {
                let ts = t.cur_pos.load(Ordering::Acquire);
                let te = t.soft_end.load(Ordering::Acquire);
                ts <= newest_cursor
                    && newest_cursor <= te
                    && newest_cursor.saturating_sub(ts) <= MAX_ORPHAN_CATCHUP_BYTES
            });
            if !newest_in_cache && !newest_in_tasks && g.tasks.len() >= target_conns {
                let protect_end = newest_cursor
                    .saturating_add(self.profile.min_segment_bytes)
                    .min(max_file_end);
                let victim_id = g
                    .tasks
                    .values()
                    .filter(|t| {
                        let ts = t.cur_pos.load(Ordering::Acquire);
                        let te = t.soft_end.load(Ordering::Acquire);
                        te < newest_cursor || ts > protect_end
                    })
                    .min_by_key(|t| t.id)
                    .or_else(|| {
                        g.tasks
                            .values()
                            .filter(|t| {
                                let ts = t.cur_pos.load(Ordering::Acquire);
                                let te = t.soft_end.load(Ordering::Acquire);
                                !(ts <= newest_cursor
                                    && newest_cursor <= te
                                    && newest_cursor.saturating_sub(ts) <= MAX_ORPHAN_CATCHUP_BYTES)
                            })
                            .min_by_key(|t| t.id)
                    })
                    .map(|t| t.id);
                if let Some(vid) = victim_id {
                    if let Some(t) = g.tasks.remove(&vid) {
                        let _ = t.cancel_tx.send(true);
                    }
                }
            }

            let allow_full_ok = g.tasks.is_empty() && g.cache.pieces.is_empty();
            let seg_size = (self.profile.window_bytes / (target_conns as u64).max(1))
                .clamp(self.profile.min_segment_bytes, self.profile.max_segment_bytes);

            let mut active_count = g.tasks.len();
            for &(win_start, win_end) in &reader_windows {
                if active_count >= target_conns {
                    break;
                }
                let mut gaps = g.cache.uncovered_ranges(win_start, win_end);
                for t in g.tasks.values() {
                    let t_start = t.cur_pos.load(Ordering::Acquire);
                    let t_end = t.soft_end.load(Ordering::Acquire);
                    if t_start <= t_end {
                        gaps = subtract_range(gaps, t_start, t_end);
                    }
                }
                for &(_, s, e, _) in &to_spawn {
                    gaps = subtract_range(gaps, s, e);
                }

                for (mut gap_start, gap_end) in gaps {
                    while gap_start <= gap_end && active_count < target_conns {
                        let piece_end = (gap_start + seg_size - 1).min(gap_end);
                        let id = g.next_id;
                        g.next_id += 1;
                        to_spawn.push((
                            id,
                            gap_start,
                            piece_end,
                            allow_full_ok && active_count == 0 && gap_start == 0,
                        ));
                        gap_start = piece_end + 1;
                        active_count += 1;
                    }
                    if active_count >= target_conns {
                        break;
                    }
                }
            }

            // Continuous scale-up / idle work-stealing: if slots remain free and no gaps
            // exist, split the slowest large active task at midpoint via soft_end.
            while active_count < target_conns {
                let candidate = g
                    .tasks
                    .values()
                    .filter_map(|t| {
                        let cur = t.cur_pos.load(Ordering::Acquire);
                        let end = t.soft_end.load(Ordering::Acquire);
                        if end <= cur {
                            return None;
                        }
                        let rem = end - cur + 1;
                        if rem < self.profile.min_segment_bytes.saturating_mul(2) {
                            return None;
                        }
                        let bps = t.recent_speed_bps();
                        let stalled = Instant::now().duration_since(*t.last_progress_at.lock())
                            >= Duration::from_secs(3);
                        let slow_rem = bps > 0.0
                            && (rem as f64 / bps) > self.profile.work_steal_min_remaining_secs;
                        if stalled || slow_rem || reader_waiting {
                            Some((t.id, cur, end, rem))
                        } else {
                            None
                        }
                    })
                    .max_by_key(|x| x.3);

                let Some((task_id, cur, old_end, _rem)) = candidate else {
                    break;
                };
                let mid = cur + (old_end - cur) / 2;
                if mid <= cur || mid >= old_end {
                    break;
                }
                if let Some(task) = g.tasks.get(&task_id) {
                    // Atomically narrow the existing hot task without cancelling its socket.
                    let prev = task.soft_end.fetch_min(mid, Ordering::AcqRel);
                    let steal_end = prev.min(old_end);
                    if mid < steal_end {
                        let new_id = g.next_id;
                        g.next_id += 1;
                        to_spawn.push((new_id, mid + 1, steal_end, false));
                        self.stats.record_work_steal();
                        active_count += 1;
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            }

            let mut spawned_handles = Vec::with_capacity(to_spawn.len());
            for &(id, start, end, full_ok) in &to_spawn {
                let (cancel_tx, cancel_rx) = watch::channel(false);
                let now_i = Instant::now();
                let handle = ActiveTaskHandle {
                    id,
                    cur_pos: Arc::new(AtomicU64::new(start)),
                    soft_end: Arc::new(AtomicU64::new(end)),
                    started_at: now_i,
                    last_progress_at: Arc::new(Mutex::new(now_i)),
                    recent_bytes: Arc::new(Mutex::new(VecDeque::new())),
                    cancel_tx,
                };
                g.tasks.insert(id, handle.clone());
                spawned_handles.push((handle, start, end, full_ok, cancel_rx));
            }
            self.stats.record_active_conns(g.tasks.len());

            for (handle, start, end, full_ok, cancel_rx) in spawned_handles {
                let session = Arc::clone(self);
                tokio::spawn(async move {
                    session.run_task(handle, start, end, full_ok, cancel_rx).await;
                });
            }
        }
    }

    async fn run_task(
        self: Arc<Self>,
        handle: ActiveTaskHandle,
        initial_start: u64,
        _initial_end: u64,
        allow_full_ok: bool,
        mut cancel_rx: watch::Receiver<bool>,
    ) {
        let mut attempt = 0usize;
        loop {
            if *cancel_rx.borrow() {
                break;
            }
            let from = handle.cur_pos.load(Ordering::Acquire);
            let to = handle.soft_end.load(Ordering::Acquire);
            if from > to {
                break;
            }

            const OPEN_HEADER_TIMEOUT_SECS: u64 = 12;
            let open_res = tokio::select! {
                res = tokio::time::timeout(
                    Duration::from_secs(OPEN_HEADER_TIMEOUT_SECS),
                    self.links.open_range(from, Some(to), allow_full_ok && attempt == 0 && from == initial_start),
                ) => match res {
                    Ok(inner) => inner,
                    Err(_) => Err(OpenError::Network(format!("Upstream open timed out after {OPEN_HEADER_TIMEOUT_SECS}s"))),
                },
                _ = cancel_rx.changed() => {
                    if *cancel_rx.borrow() { break; }
                    continue;
                }
            };

            match open_res {
                Ok(opened) => {
                    self.stats
                        .record_open(opened.ttfb_ms, opened.redirects, opened.final_host);
                    let status = opened.response.status();
                    if status == StatusCode::OK {
                        // Server ignored Range and returned 200 OK full body; mark range unsupported
                        // so subsequent reads fall back cleanly.
                        self.state.lock().range_unsupported = true;
                    }
                    let mut stream = opened.response.bytes_stream();
                    let stall_dur = Duration::from_secs(self.profile.stall_timeout_secs.max(5));
                    let mut interrupted_reason: Option<String> = None;

                    loop {
                        let cur = handle.cur_pos.load(Ordering::Acquire);
                        let target_end = handle.soft_end.load(Ordering::Acquire);
                        if cur > target_end {
                            break;
                        }
                        tokio::select! {
                            chunk_opt = tokio::time::timeout(stall_dur, stream.next()) => {
                                match chunk_opt {
                                    Ok(Some(Ok(mut bytes))) => {
                                        if bytes.is_empty() {
                                            continue;
                                        }
                                        let cur_now = handle.cur_pos.load(Ordering::Acquire);
                                        let end_now = handle.soft_end.load(Ordering::Acquire);
                                        if cur_now > end_now {
                                            break;
                                        }
                                        let max_need = (end_now - cur_now + 1) as usize;
                                        if bytes.len() > max_need {
                                            bytes = bytes.slice(..max_need);
                                        }
                                        let len = bytes.len() as u64;
                                        {
                                            let mut g = self.state.lock();
                                            g.cache.insert_piece(cur_now, bytes);
                                            g.adaptive.record_bytes(len);
                                        }
                                        handle.cur_pos.store(cur_now + len, Ordering::Release);
                                        *handle.last_progress_at.lock() = Instant::now();
                                        handle.recent_bytes.lock().push_back((Instant::now(), len));
                                        self.stats.record_upstream_bytes(len);
                                        self.notify.notify_waiters();
                                    }
                                    Ok(Some(Err(e))) => {
                                        interrupted_reason = Some(format!("Upstream chunk error: {e}"));
                                        break;
                                    }
                                    Err(_) => {
                                        interrupted_reason = Some(format!("Upstream stream stalled after {}s", stall_dur.as_secs()));
                                        break;
                                    }
                                    Ok(None) => {
                                        if handle.cur_pos.load(Ordering::Acquire) <= handle.soft_end.load(Ordering::Acquire) {
                                            interrupted_reason = Some("Upstream stream closed prematurely".into());
                                        }
                                        break;
                                    }
                                }
                            }
                            _ = cancel_rx.changed() => {
                                if *cancel_rx.borrow() { break; }
                            }
                        }
                    }

                    if *cancel_rx.borrow() {
                        break;
                    }
                    let Some(reason) = interrupted_reason else {
                        break;
                    };
                    self.stats.record_error(reason);
                    attempt += 1;
                    if attempt >= MAX_RETRIES_PER_TASK {
                        self.record_fatal("Upstream stream interrupted after retries".into());
                        break;
                    }
                    self.stats.record_retry();
                }
                Err(OpenError::RateLimited { .. }) => {
                    self.stats.record_rate_limit();
                    self.stats.record_error("Origin rate-limited (HTTP 429)".into());
                    self.state
                        .lock()
                        .adaptive
                        .on_rate_limit(self.profile.rate_limit_cooldown_secs);
                    attempt += 1;
                    if attempt >= MAX_RETRIES_PER_TASK {
                        self.record_fatal("Origin rate-limited (HTTP 429)".into());
                        break;
                    }
                    tokio::time::sleep(Duration::from_millis(500 * attempt as u64)).await;
                }
                Err(OpenError::RangeUnsupported { .. }) => {
                    self.state.lock().range_unsupported = true;
                    self.notify.notify_waiters();
                    break;
                }
                Err(OpenError::Network(msg)) => {
                    self.stats.record_error(msg.clone());
                    attempt += 1;
                    if attempt >= MAX_RETRIES_PER_TASK {
                        self.record_fatal(msg);
                        break;
                    }
                    self.stats.record_retry();
                    tokio::time::sleep(Duration::from_millis(300 * attempt as u64)).await;
                }
                Err(OpenError::HttpStatus { status, .. }) => {
                    let msg = format!("Origin answered HTTP {status}");
                    self.stats.record_error(msg.clone());
                    self.record_fatal(msg);
                    break;
                }
                Err(OpenError::RefreshFailed(msg)) => {
                    self.stats.record_error(msg.clone());
                    self.record_fatal(msg);
                    break;
                }
            }
        }

        {
            let mut g = self.state.lock();
            g.tasks.remove(&handle.id);
        }
        self.notify.notify_waiters();
        self.ensure_scheduled(false);
    }

    fn record_fatal(&self, msg: String) {
        self.state.lock().fatal_error = Some(msg);
        self.notify.notify_waiters();
    }
}

impl CoordinatorState {
    fn total_active_fatal(&self) -> bool {
        self.fatal_error.is_some()
    }
}

fn subtract_range(gaps: Vec<(u64, u64)>, rem_start: u64, rem_end: u64) -> Vec<(u64, u64)> {
    let mut out = Vec::with_capacity(gaps.len());
    for (s, e) in gaps {
        if rem_end < s || rem_start > e {
            out.push((s, e));
        } else {
            if rem_start > s {
                out.push((s, rem_start - 1));
            }
            if rem_end < e {
                out.push((rem_end + 1, e));
            }
        }
    }
    out
}

pub enum StreamReader {
    Prefetch(PrefetchRangeReader),
    Direct(DirectRangeReader),
}

impl StreamReader {
    pub async fn next_chunk(&mut self) -> io::Result<Option<Bytes>> {
        match self {
            Self::Prefetch(r) => r.next_chunk().await,
            Self::Direct(r) => r.next_chunk().await,
        }
    }
}

pub struct PrefetchRangeReader {
    session: Arc<StreamSession>,
    reader_id: u64,
    cursor: u64,
    end: u64,
}

impl PrefetchRangeReader {
    async fn next_chunk(&mut self) -> io::Result<Option<Bytes>> {
        if self.cursor > self.end {
            return Ok(None);
        }
        loop {
            let notified = self.session.notify.notified();
            let (err_opt, range_fallback_done) = {
                let mut g = self.session.state.lock();
                if let Some(chunk) = g.cache.read_at(self.cursor, self.end) {
                    self.cursor += chunk.len() as u64;
                    g.readers.insert(self.reader_id, self.cursor);
                    drop(g);
                    self.session.ensure_scheduled(false);
                    return Ok(Some(chunk));
                }
                (g.fatal_error.clone(), g.range_unsupported && g.tasks.is_empty())
            };

            if let Some(err) = err_opt {
                return Err(io::Error::new(io::ErrorKind::Other, err));
            }

            if range_fallback_done {
                return Err(io::Error::new(
                    io::ErrorKind::Unsupported,
                    "Origin does not support Range requests",
                ));
            }

            self.session.ensure_scheduled(true);
            let _ = tokio::time::timeout(Duration::from_millis(250), notified).await;
        }
    }
}

impl Drop for PrefetchRangeReader {
    fn drop(&mut self) {
        let cancel_tasks: Vec<ActiveTaskHandle> = {
            let mut g = self.session.state.lock();
            g.readers.remove(&self.reader_id);
            if g.readers.is_empty() {
                g.tasks.drain().map(|(_, t)| t).collect()
            } else {
                Vec::new()
            }
        };
        for t in cancel_tasks {
            let _ = t.cancel_tx.send(true);
        }
        self.session.notify.notify_waiters();
    }
}

pub struct DirectRangeReader {
    session: Arc<StreamSession>,
    cursor: u64,
    end: u64,
    stream: Option<std::pin::Pin<Box<dyn futures_util::Stream<Item = Result<Bytes, reqwest::Error>> + Send>>>,
}

impl DirectRangeReader {
    fn new(session: Arc<StreamSession>, start: u64, end: u64) -> Self {
        let count = session.direct_readers.fetch_add(1, Ordering::Relaxed) + 1;
        session.stats.record_active_conns(count);
        Self {
            session,
            cursor: start,
            end,
            stream: None,
        }
    }

    async fn next_chunk(&mut self) -> io::Result<Option<Bytes>> {
        if self.cursor > self.end {
            return Ok(None);
        }
        if self.stream.is_none() {
            const DIRECT_OPEN_TIMEOUT_SECS: u64 = 12;
            let opened = tokio::time::timeout(
                Duration::from_secs(DIRECT_OPEN_TIMEOUT_SECS),
                self.session.links.open_range(self.cursor, Some(self.end), true),
            )
            .await
            .map_err(|_| {
                let msg = format!("Direct open timed out after {DIRECT_OPEN_TIMEOUT_SECS}s");
                self.session.stats.record_error(msg.clone());
                io::Error::new(io::ErrorKind::TimedOut, msg)
            })?
            .map_err(|e| {
                let msg = format!("{e:?}");
                self.session.stats.record_error(msg.clone());
                io::Error::new(io::ErrorKind::Other, msg)
            })?;
            self.session
                .stats
                .record_open(opened.ttfb_ms, opened.redirects, opened.final_host);
            self.stream = Some(Box::pin(opened.response.bytes_stream()));
        }

        let stall_dur = Duration::from_secs(self.session.profile.stall_timeout_secs.max(5));
        let stream = self.stream.as_mut().unwrap();
        loop {
            let chunk_opt = tokio::time::timeout(stall_dur, stream.next())
                .await
                .map_err(|_| {
                    let msg = format!("Direct stream stalled after {}s", stall_dur.as_secs());
                    self.session.stats.record_error(msg.clone());
                    io::Error::new(io::ErrorKind::TimedOut, msg)
                })?;
            let Some(res) = chunk_opt else {
                break;
            };
            let mut bytes = res.map_err(|e| {
                self.session.stats.record_error(e.to_string());
                io::Error::new(io::ErrorKind::BrokenPipe, e)
            })?;
            if bytes.is_empty() {
                continue;
            }
            let remaining = (self.end - self.cursor + 1) as usize;
            if bytes.len() > remaining {
                bytes = bytes.slice(..remaining);
            }
            let len = bytes.len() as u64;
            self.cursor += len;
            self.session.stats.record_upstream_bytes(len);
            return Ok(Some(bytes));
        }
        Ok(None)
    }
}

impl Drop for DirectRangeReader {
    fn drop(&mut self) {
        self.session.direct_readers.fetch_sub(1, Ordering::Relaxed);
    }
}
