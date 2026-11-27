pub mod config;
pub mod ffi;
pub mod link_manager;
pub mod scheduler;
pub mod server;
pub mod stats;

use std::collections::HashMap;
use std::io;
use std::sync::Arc;
use std::time::Duration;

use parking_lot::RwLock;
use reqwest::redirect::Policy;
use reqwest::Client;
use tokio::runtime::{Builder, Runtime};
use tokio::sync::watch;
use tokio::task::JoinHandle;
use url::Url;

use config::{
    LinkUpdatePayload, PlaybackDemandUpdate, StreamLiveStatus, StreamRegistration,
    StreamStatsSnapshot,
};
use link_manager::RefreshCallback;
use scheduler::StreamSession;
use server::start_http_server;

pub struct NativeEngine {
    runtime: Runtime,
    client: Client,
    port: u16,
    streams: Arc<RwLock<HashMap<String, Arc<StreamSession>>>>,
    on_refresh: Option<RefreshCallback>,
    shutdown_tx: watch::Sender<bool>,
    server_handle: Option<JoinHandle<()>>,
}

impl NativeEngine {
    pub fn start(on_refresh: Option<RefreshCallback>) -> io::Result<Self> {
        let cores = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(2)
            .clamp(2, 4);
        let runtime = Builder::new_multi_thread()
            .worker_threads(cores)
            .thread_name("ttplay-stream")
            .enable_all()
            .build()?;

        let client = Client::builder()
            .redirect(Policy::none())
            .connect_timeout(Duration::from_secs(15))
            .pool_idle_timeout(Duration::from_secs(30))
            .tcp_keepalive(Duration::from_secs(15))
            .pool_max_idle_per_host(8)
            .build()
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;

        let streams = Arc::new(RwLock::new(HashMap::new()));
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (port, server_handle) = {
            let _guard = runtime.enter();
            start_http_server(Arc::clone(&streams), shutdown_rx)?
        };

        Ok(Self {
            runtime,
            client,
            port,
            streams,
            on_refresh,
            shutdown_tx,
            server_handle: Some(server_handle),
        })
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn register_stream(&self, reg: StreamRegistration) -> Result<(), String> {
        if reg.token.trim().is_empty() {
            return Err("Token cannot be empty".into());
        }
        Url::parse(&reg.url).map_err(|e| format!("Invalid URL: {e}"))?;

        let _guard = self.runtime.enter();
        let prev = self.streams.write().insert(
            reg.token.clone(),
            Arc::new(StreamSession::new(
                reg,
                self.on_refresh.clone(),
                self.client.clone(),
            )),
        );
        if let Some(old) = prev {
            old.shutdown();
        }
        Ok(())
    }

    pub fn update_link(&self, token: &str, req_id: u64, payload: LinkUpdatePayload) -> bool {
        if let Some(session) = self.streams.read().get(token).cloned() {
            let _guard = self.runtime.enter();
            session.update_link(req_id, payload);
            true
        } else {
            false
        }
    }

    pub fn update_demand(&self, token: &str, update: PlaybackDemandUpdate) -> bool {
        if let Some(session) = self.streams.read().get(token).cloned() {
            let _guard = self.runtime.enter();
            session.update_demand(update);
            true
        } else {
            false
        }
    }

    pub fn unregister_stream(&self, token: &str) -> bool {
        if let Some(session) = self.streams.write().remove(token) {
            session.shutdown();
            true
        } else {
            false
        }
    }

    pub fn poll_stats(&self) -> Vec<StreamStatsSnapshot> {
        let sessions: Vec<Arc<StreamSession>> = self.streams.read().values().cloned().collect();
        sessions.into_iter().map(|s| s.poll_stats()).collect()
    }

    pub fn peek_stream_status(&self, token: &str) -> Option<StreamLiveStatus> {
        let session = self.streams.read().get(token).cloned()?;
        Some(session.peek_status())
    }

    pub fn stop(mut self) {
        let _ = self.shutdown_tx.send(true);
        let sessions: Vec<Arc<StreamSession>> =
            self.streams.write().drain().map(|(_, s)| s).collect();
        for s in sessions {
            s.shutdown();
        }
        if let Some(h) = self.server_handle.take() {
            h.abort();
        }
        self.runtime.shutdown_timeout(Duration::from_millis(500));
    }
}
