use std::collections::HashMap;

use serde::{Deserialize, Serialize};

/// Generic, drive-agnostic transfer policy supplied by the Dart control plane.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default)]
pub struct DriveTransferProfile {
    pub min_connections: usize,
    pub max_connections: usize,
    pub window_bytes: u64,
    pub min_segment_bytes: u64,
    pub max_segment_bytes: u64,
    pub probe_bypass_bytes: u64,
    pub cache_redirect_url: bool,
    pub redirect_cache_ttl_secs: u64,
    pub stale_statuses: Vec<u16>,
    pub scale_up_eval_secs: u64,
    pub scale_up_min_gain_ratio: f64,
    pub rate_limit_cooldown_secs: u64,
    pub work_steal_min_remaining_secs: f64,
    pub stall_timeout_secs: u64,
    pub demand_driven_scale_up: bool,
    pub bitrate_safety_factor: f64,
    pub low_buffer_secs: f64,
    pub high_buffer_secs: f64,
    pub allow_runtime_max_upgrade: bool,
    pub user_agent: Option<String>,
}

impl Default for DriveTransferProfile {
    fn default() -> Self {
        Self {
            min_connections: 1,
            max_connections: 5,
            window_bytes: 24 * 1024 * 1024,
            min_segment_bytes: 2 * 1024 * 1024,
            max_segment_bytes: 16 * 1024 * 1024,
            probe_bypass_bytes: 512 * 1024,
            cache_redirect_url: true,
            redirect_cache_ttl_secs: 90,
            stale_statuses: vec![401, 403, 404, 410, 412],
            scale_up_eval_secs: 3,
            scale_up_min_gain_ratio: 1.15,
            rate_limit_cooldown_secs: 60,
            work_steal_min_remaining_secs: 4.0,
            stall_timeout_secs: 20,
            demand_driven_scale_up: true,
            bitrate_safety_factor: 1.8,
            low_buffer_secs: 10.0,
            high_buffer_secs: 20.0,
            allow_runtime_max_upgrade: false,
            user_agent: None,
        }
    }
}

/// Real-time playback demand and deferred tier limits pushed from Dart.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct PlaybackDemandUpdate {
    pub playback_started: Option<bool>,
    pub bitrate_bps: Option<u64>,
    pub buffered_secs: Option<f64>,
    pub is_buffering: Option<bool>,
    pub max_connections: Option<usize>,
}

/// Payload passed from Dart to register or update a stream served at `/s/<token>/...`.
#[derive(Debug, Clone, Deserialize)]
pub struct StreamRegistration {
    pub token: String,
    pub total_size: u64,
    #[serde(default)]
    pub content_type: Option<String>,
    pub url: String,
    #[serde(default)]
    pub headers: HashMap<String, String>,
    #[serde(default)]
    pub profile: DriveTransferProfile,
}

/// Asynchronous response sent back from Dart after resolving a stale-link callback.
#[derive(Debug, Clone, Deserialize)]
pub struct LinkUpdatePayload {
    pub url: Option<String>,
    pub headers: Option<HashMap<String, String>>,
    pub error: Option<String>,
}

/// Rolling telemetry snapshot serialized to Dart for unified playback diagnostics.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StreamStatsSnapshot {
    pub token: String,
    pub elapsed_ms: u64,
    pub upstream_bytes: u64,
    pub delivered_bytes: u64,
    pub active_conns: usize,
    pub target_conns: usize,
    pub effective_max_conns: usize,
    pub peak_conns: usize,
    pub cache_bytes: usize,
    pub ttfb_avg_ms: u64,
    pub ttfb_max_ms: u64,
    pub redirects: u64,
    pub work_steals: u64,
    pub retries: u64,
    pub rate_limits: u64,
    pub up_wait_pct: f64,
    pub down_wait_pct: f64,
    pub pauses: u64,
    pub requests: u64,
    pub final_host: Option<String>,
    pub playback_started: bool,
    pub demand_bitrate_bps: u64,
    pub active_readers: usize,
    pub last_error: Option<String>,
}

/// Non-destructive live snapshot of stream concurrency and cache usage.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StreamLiveStatus {
    pub active_conns: usize,
    pub target_conns: usize,
    pub effective_max_conns: usize,
    pub cache_bytes: usize,
}
