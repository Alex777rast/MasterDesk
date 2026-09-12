#[cfg(not(any(target_os = "android", target_os = "ios")))]
use crate::clipboard::{update_clipboard, ClipboardSide};
#[cfg(not(any(target_os = "ios")))]
use crate::{audio_service, clipboard::CLIPBOARD_INTERVAL, ConnInner, CLIENT_SERVER};
use crate::{
    client::{
        self, new_voice_call_request, Client, Data, Interface, MediaData, MediaSender,
        QualityStatus, MILLI1, SEC30,
    },
    common::get_default_sound_input,
    ui_session_interface::{InvokeUiSession, Session},
};

// Empirical no-data window before exposing the restart reconnect state to the UI.
// Restart msgbox text is kept as a legacy UI fallback; Flutter handles the type as a control event.
const RESTART_REMOTE_DEVICE_NO_DATA_TIMEOUT: Duration = Duration::from_secs(5);
const KCP_CLOSE_REASON_FLUSH_DELAY: Duration = Duration::from_millis(30);
#[cfg(feature = "unix-file-copy-paste")]
use crate::{clipboard::try_empty_clipboard_files, clipboard_file::unix_file_clip};
#[cfg(any(
    target_os = "windows",
    all(target_os = "macos", feature = "unix-file-copy-paste")
))]
use clipboard::ContextSend;
use crossbeam_queue::ArrayQueue;
#[cfg(not(target_os = "ios"))]
use hbb_common::tokio::sync::mpsc::error::TryRecvError;
#[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
use hbb_common::tokio::sync::Mutex as TokioMutex;
use hbb_common::{
    allow_err,
    config::{self, LocalConfig, PeerConfig, TransferSerde},
    fs::{
        self, can_enable_overwrite_detection, get_job, get_string, new_send_confirm,
        DigestCheckResult, RemoveJobMeta,
    },
    get_time, log,
    message_proto::{permission_info::Permission, *},
    protobuf::Message as _,
    rendezvous_proto::ConnType,
    timeout,
    tokio::{
        self,
        sync::{mpsc, oneshot},
        time::{self, Duration, Instant},
    },
    ResultType, Stream,
};
use scrap::CodecFormat;
use serde::Serialize;
use std::{
    collections::{HashMap, VecDeque},
    ffi::c_void,
    num::NonZeroI64,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicI32, AtomicU64, AtomicUsize, Ordering},
        Arc, Mutex, RwLock,
    },
};

const PARALLEL_FILE_MIN_SIZE: u64 = 64 * 1024 * 1024;
const PARALLEL_FILE_BLOCK_SIZE: usize = 256 * 1024;
const PARALLEL_DYNAMIC_CHUNK_SIZE: u64 = 8 * 1024 * 1024;
const PARALLEL_AUTO_STAGE_PER_WORKER: u64 = 2 * 1024 * 1024;
const PARALLEL_AUTO_MIN_GAIN: f64 = 1.05;
const PARALLEL_POOL_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(10);
const TRANSFER_TELEMETRY_INTERVAL: Duration = Duration::from_millis(500);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ParallelMode {
    Auto,
    Fixed(usize),
}

const PARALLEL_WORKER_CONNECTING: usize = 1;
const PARALLEL_WORKER_TRANSFERRING: usize = 2;
const PARALLEL_WORKER_AWAITING_ACK: usize = 3;
const PARALLEL_WORKER_COMPLETE: usize = 4;
const PARALLEL_WORKER_ERROR: usize = 5;
const PARALLEL_PHASE_PREPARING: usize = 1;
const PARALLEL_PHASE_TRANSFERRING: usize = 2;
const PARALLEL_PHASE_COMPLETE: usize = 3;
const PARALLEL_PHASE_FALLBACK: usize = 4;

struct ParallelWorkerTelemetry {
    worker_id: u32,
    range_start: AtomicU64,
    range_end: AtomicU64,
    bytes_transferred: AtomicU64,
    last_snapshot_bytes: AtomicU64,
    chunks_completed: AtomicU64,
    jobs_completed: AtomicU64,
    state: AtomicUsize,
}

struct ParallelTransferTelemetry {
    transfer_id: String,
    mode: ParallelMode,
    file_name: String,
    file_size: u64,
    file_count: usize,
    max_workers: usize,
    total_transferred: Arc<AtomicU64>,
    queued_chunks: Arc<AtomicUsize>,
    open_connections: Arc<AtomicUsize>,
    phase: Arc<AtomicUsize>,
    started: Instant,
    last_snapshot: Instant,
    last_snapshot_bytes: u64,
    peak_speed: f64,
    workers: Vec<Arc<ParallelWorkerTelemetry>>,
    scale_history: Vec<usize>,
}

#[derive(Serialize)]
struct ParallelWorkerSnapshot {
    worker_id: u32,
    bytes_transferred: u64,
    bytes_per_second: f64,
    state: &'static str,
    range_start: u64,
    range_end: u64,
    chunks_completed: u64,
    jobs_completed: u64,
}

#[derive(Serialize)]
struct ParallelTransferSnapshot {
    transfer_id: String,
    mode: String,
    phase: &'static str,
    active_workers: usize,
    busy_workers: usize,
    open_connections: usize,
    target_workers: usize,
    max_workers: usize,
    total_speed: f64,
    peak_speed: f64,
    average_speed: f64,
    elapsed_ms: u64,
    file_name: String,
    file_size: u64,
    file_count: usize,
    bytes_transferred: u64,
    queued_chunks: usize,
    completed_chunks: u64,
    queued_jobs: usize,
    completed_jobs: u64,
    scale_history: Vec<usize>,
    workers: Vec<ParallelWorkerSnapshot>,
}

lazy_static::lazy_static! {
    static ref PARALLEL_TRANSFER_TELEMETRY: Mutex<HashMap<i32, ParallelTransferTelemetry>> =
        Mutex::new(HashMap::new());
}

static NEXT_PARALLEL_CLIPBOARD_JOB_ID: AtomicI32 = AtomicI32::new(-1_000_000);

#[cfg(target_os = "windows")]
static PARALLEL_CLIPBOARD_CACHE_SUPPORTED: AtomicBool = AtomicBool::new(false);

#[cfg(target_os = "windows")]
pub(crate) fn refresh_parallel_clipboard_cache_mode() {
    let enabled = PARALLEL_CLIPBOARD_CACHE_SUPPORTED.load(Ordering::Acquire)
        && !matches!(configured_parallel_mode(), ParallelMode::Fixed(1));
    if let Err(err) = ContextSend::proc(|context| -> ResultType<()> {
        context
            .set_parallel_file_cache_enabled(enabled)
            .map_err(|err| err.into())
    }) {
        log::debug!(
            "Explorer parallel clipboard mode will be applied when the clipboard channel is ready: {}",
            err
        );
    }
}

fn parallel_mode_label(mode: ParallelMode) -> String {
    match mode {
        ParallelMode::Auto => "AUTO".to_owned(),
        ParallelMode::Fixed(streams) => format!("FIXED {streams}x"),
    }
}

fn parallel_worker_state_label(state: usize) -> &'static str {
    match state {
        PARALLEL_WORKER_CONNECTING => "connecting",
        PARALLEL_WORKER_TRANSFERRING => "transferring",
        PARALLEL_WORKER_AWAITING_ACK => "awaiting_ack",
        PARALLEL_WORKER_COMPLETE => "complete",
        PARALLEL_WORKER_ERROR => "error",
        _ => "waiting",
    }
}

fn parallel_phase_label(phase: usize) -> &'static str {
    match phase {
        PARALLEL_PHASE_PREPARING => "PREPARING",
        PARALLEL_PHASE_TRANSFERRING => "TRANSFERRING",
        PARALLEL_PHASE_COMPLETE => "COMPLETE",
        PARALLEL_PHASE_FALLBACK => "LEGACY FALLBACK",
        _ => "WAITING",
    }
}

fn register_parallel_transfer(
    job_id: i32,
    transfer_id: &str,
    mode: ParallelMode,
    file_name: &str,
    file_size: u64,
    file_count: usize,
    total_transferred: Arc<AtomicU64>,
) {
    let Ok(mut telemetry) = PARALLEL_TRANSFER_TELEMETRY.lock() else {
        log::error!("parallel transfer telemetry lock is poisoned");
        return;
    };
    if telemetry.len() >= 64 {
        telemetry.retain(|_, item| {
            !matches!(
                item.phase.load(Ordering::Relaxed),
                PARALLEL_PHASE_COMPLETE | PARALLEL_PHASE_FALLBACK
            )
        });
    }
    let now = Instant::now();
    telemetry.insert(
        job_id,
        ParallelTransferTelemetry {
            transfer_id: transfer_id.to_owned(),
            mode,
            file_name: file_name.to_owned(),
            file_size,
            file_count,
            max_workers: match mode {
                ParallelMode::Auto => 8,
                ParallelMode::Fixed(streams) => streams,
            },
            total_transferred,
            queued_chunks: Arc::new(AtomicUsize::new(0)),
            open_connections: Arc::new(AtomicUsize::new(0)),
            phase: Arc::new(AtomicUsize::new(PARALLEL_PHASE_PREPARING)),
            started: now,
            last_snapshot: now,
            last_snapshot_bytes: 0,
            peak_speed: 0.0,
            workers: Vec::new(),
            scale_history: Vec::new(),
        },
    );
}

fn begin_parallel_telemetry_stage(
    transfer_id: &str,
    streams: usize,
    queued_chunks: Arc<AtomicUsize>,
    open_connections: Arc<AtomicUsize>,
) {
    let Ok(mut telemetry) = PARALLEL_TRANSFER_TELEMETRY.lock() else {
        return;
    };
    if let Some(item) = telemetry
        .values_mut()
        .find(|item| item.transfer_id == transfer_id)
    {
        item.workers.clear();
        item.queued_chunks = queued_chunks;
        item.open_connections = open_connections;
        if item.scale_history.last().copied() != Some(streams) {
            item.scale_history.push(streams);
        }
    }
}

fn register_parallel_worker(
    transfer_id: &str,
    worker_id: u32,
    range_start: u64,
    range_len: u64,
) -> Option<(Arc<ParallelWorkerTelemetry>, Arc<AtomicUsize>)> {
    let Ok(mut telemetry) = PARALLEL_TRANSFER_TELEMETRY.lock() else {
        return None;
    };
    let item = telemetry
        .values_mut()
        .find(|item| item.transfer_id == transfer_id)?;
    let worker = Arc::new(ParallelWorkerTelemetry {
        worker_id,
        range_start: AtomicU64::new(range_start),
        range_end: AtomicU64::new(range_start.saturating_add(range_len)),
        bytes_transferred: AtomicU64::new(0),
        last_snapshot_bytes: AtomicU64::new(0),
        chunks_completed: AtomicU64::new(0),
        jobs_completed: AtomicU64::new(0),
        state: AtomicUsize::new(PARALLEL_WORKER_CONNECTING),
    });
    item.workers.push(worker.clone());
    Some((worker, item.phase.clone()))
}

fn mark_parallel_transfer_phase(transfer_id: &str, phase: usize) {
    let Ok(telemetry) = PARALLEL_TRANSFER_TELEMETRY.lock() else {
        return;
    };
    if let Some(item) = telemetry
        .values()
        .find(|item| item.transfer_id == transfer_id)
    {
        item.phase.store(phase, Ordering::Relaxed);
    }
}

pub(crate) fn parallel_transfer_stats_json(job_id: i32) -> Option<String> {
    let Ok(mut telemetry) = PARALLEL_TRANSFER_TELEMETRY.lock() else {
        return None;
    };
    let item = telemetry.get_mut(&job_id)?;
    let now = Instant::now();
    let sample_seconds = now
        .saturating_duration_since(item.last_snapshot)
        .as_secs_f64()
        .max(0.001);
    let total = item.total_transferred.load(Ordering::Relaxed);
    let total_speed = total.saturating_sub(item.last_snapshot_bytes) as f64 / sample_seconds;
    item.peak_speed = item.peak_speed.max(total_speed);
    item.last_snapshot = now;
    item.last_snapshot_bytes = total;

    let elapsed = now.saturating_duration_since(item.started);
    let workers = item
        .workers
        .iter()
        .map(|worker| {
            let bytes = worker.bytes_transferred.load(Ordering::Relaxed);
            let previous = worker.last_snapshot_bytes.swap(bytes, Ordering::Relaxed);
            ParallelWorkerSnapshot {
                worker_id: worker.worker_id,
                bytes_transferred: bytes,
                bytes_per_second: bytes.saturating_sub(previous) as f64 / sample_seconds,
                state: parallel_worker_state_label(worker.state.load(Ordering::Relaxed)),
                range_start: worker.range_start.load(Ordering::Relaxed),
                range_end: worker.range_end.load(Ordering::Relaxed),
                chunks_completed: worker.chunks_completed.load(Ordering::Relaxed),
                jobs_completed: worker.jobs_completed.load(Ordering::Relaxed),
            }
        })
        .collect::<Vec<_>>();
    let active_workers = workers
        .iter()
        .filter(|worker| matches!(worker.state, "connecting" | "transferring" | "awaiting_ack"))
        .count();
    let busy_workers = workers
        .iter()
        .filter(|worker| matches!(worker.state, "transferring" | "awaiting_ack"))
        .count();
    let completed_chunks = workers.iter().map(|worker| worker.chunks_completed).sum();
    let completed_jobs = workers.iter().map(|worker| worker.jobs_completed).sum();
    let queued_jobs = item.queued_chunks.load(Ordering::Relaxed);
    let snapshot = ParallelTransferSnapshot {
        transfer_id: item.transfer_id.clone(),
        mode: parallel_mode_label(item.mode),
        phase: parallel_phase_label(item.phase.load(Ordering::Relaxed)),
        active_workers,
        busy_workers,
        open_connections: item.open_connections.load(Ordering::Relaxed),
        target_workers: item.scale_history.last().copied().unwrap_or(0),
        max_workers: item.max_workers,
        total_speed,
        peak_speed: item.peak_speed,
        average_speed: total as f64 / elapsed.as_secs_f64().max(0.001),
        elapsed_ms: elapsed.as_millis().min(u128::from(u64::MAX)) as u64,
        file_name: item.file_name.clone(),
        file_size: item.file_size,
        file_count: item.file_count,
        bytes_transferred: total,
        queued_chunks: queued_jobs,
        completed_chunks,
        queued_jobs,
        completed_jobs,
        scale_history: item.scale_history.clone(),
        workers,
    };
    serde_json::to_string(&snapshot).ok()
}

#[derive(Clone)]
struct ParallelUploadArgs {
    id: i32,
    file_num: i32,
    source_selection: PathBuf,
    destination: String,
    files: Vec<FileEntry>,
    include_hidden: bool,
    source_paths: Option<Vec<PathBuf>>,
    clipboard_cache: bool,
}

impl ParallelUploadArgs {
    fn total_size(&self) -> u64 {
        self.files.iter().map(|file| file.size).sum()
    }

    fn last_file_num(&self) -> i32 {
        self.file_num
            .saturating_add(self.files.len().saturating_sub(1) as i32)
    }

    fn label(&self) -> String {
        if self.clipboard_cache {
            if self
                .source_paths
                .as_ref()
                .map_or(false, |paths| paths.len() == 1)
            {
                if let Some(name) = self
                    .source_paths
                    .as_ref()
                    .and_then(|paths| paths.first())
                    .and_then(|path| path.file_name())
                    .and_then(|name| name.to_str())
                    .filter(|name| !name.is_empty())
                {
                    return name.to_owned();
                }
            }
            return format!("Explorer clipboard cache ({} files)", self.files.len());
        }
        if self.files.len() == 1 {
            let name = self.files[0].name.trim();
            if !name.is_empty() {
                return name.to_owned();
            }
        }
        self.source_selection
            .file_name()
            .and_then(|name| name.to_str())
            .filter(|name| !name.is_empty())
            .map(str::to_owned)
            .unwrap_or_else(|| format!("{} files", self.files.len()))
    }

    fn source_path(&self, index: usize, file: &FileEntry) -> PathBuf {
        self.source_paths
            .as_ref()
            .and_then(|paths| paths.get(index))
            .cloned()
            .unwrap_or_else(|| fs::TransferJob::join(&self.source_selection, &file.name))
    }
}

#[derive(Clone)]
struct ParallelWorkItem {
    file_num: i32,
    source: PathBuf,
    file_size: u64,
    range_start: u64,
    range_len: u64,
}

struct ParallelSendJob {
    transfer_id: String,
    auth_token: String,
    args: ParallelUploadArgs,
    mode: ParallelMode,
    sent: Arc<AtomicU64>,
    cancelled: Arc<AtomicBool>,
    started: bool,
}

#[derive(Clone)]
struct ParallelDownloadArgs {
    id: i32,
    file_num: i32,
    remote_path: String,
    destination: PathBuf,
    file: FileEntry,
}

struct ParallelReceiveJob {
    transfer_id: String,
    auth_token: String,
    remote_path: String,
    mode: ParallelMode,
    received: Arc<AtomicU64>,
    cancelled: Arc<AtomicBool>,
    file: Option<FileEntry>,
    started: bool,
    completion: Option<tokio::task::JoinHandle<()>>,
}

impl ParallelDownloadArgs {
    fn target_path(&self) -> ResultType<PathBuf> {
        fs::resolve_transfer_path(&self.destination, &self.file.name)
    }
}

type ParallelChunkQueue = Arc<Mutex<VecDeque<ParallelWorkItem>>>;

struct ParallelWorkerCommand {
    transfer_id: String,
    auth_token: String,
    args: ParallelUploadArgs,
    chunks: ParallelChunkQueue,
    queued_chunks: Arc<AtomicUsize>,
    sent: Arc<AtomicU64>,
    cancelled: Arc<AtomicBool>,
    telemetry: Option<(Arc<ParallelWorkerTelemetry>, Arc<AtomicUsize>)>,
    done: oneshot::Sender<Result<(), String>>,
}

#[derive(Clone)]
struct ParallelWorkerPool {
    workers: Vec<mpsc::UnboundedSender<ParallelWorkerCommand>>,
    auto_cached_streams: Arc<AtomicUsize>,
    open_connections: Arc<AtomicUsize>,
}

impl ParallelWorkerPool {
    fn new<T: InvokeUiSession>(handler: Session<T>, key: String, token: String) -> Self {
        let mut workers = Vec::with_capacity(8);
        let open_connections = Arc::new(AtomicUsize::new(0));
        for worker in 1..=8u32 {
            let (tx, rx) = mpsc::unbounded_channel();
            workers.push(tx);
            tokio::spawn(run_parallel_pool_worker(
                handler.clone(),
                key.clone(),
                token.clone(),
                worker,
                rx,
                open_connections.clone(),
            ));
        }
        Self {
            workers,
            auto_cached_streams: Arc::new(AtomicUsize::new(0)),
            open_connections,
        }
    }
}

fn configured_parallel_mode() -> ParallelMode {
    let configured = config::Config::get_option(config::keys::OPTION_PARALLEL_FILE_TRANSFER_MODE);
    let value = if configured.trim().is_empty() {
        std::env::var("MASTERDESK_FILE_TRANSFER_STREAMS").unwrap_or_else(|_| "auto".to_owned())
    } else {
        configured
    };
    parallel_mode_from_value(&value)
}

fn parallel_mode_from_value(value: &str) -> ParallelMode {
    match value.trim().to_ascii_lowercase().as_str() {
        "off" => ParallelMode::Fixed(1),
        "1" => ParallelMode::Fixed(1),
        "2" => ParallelMode::Fixed(2),
        "4" => ParallelMode::Fixed(4),
        "8" => ParallelMode::Fixed(8),
        _ => ParallelMode::Auto,
    }
}

fn split_parallel_chunks(start: u64, len: u64, streams: usize) -> VecDeque<(u64, u64)> {
    if len == 0 {
        return VecDeque::new();
    }
    let streams = streams.max(1).min(8);
    let per_worker = len.saturating_add(streams as u64 - 1) / streams as u64;
    let chunk_size = PARALLEL_DYNAMIC_CHUNK_SIZE.min(per_worker.max(1));
    let mut cursor = start;
    let end = start.saturating_add(len);
    let mut chunks = VecDeque::new();
    while cursor < end {
        let chunk_len = (end - cursor).min(chunk_size);
        chunks.push_back((cursor, chunk_len));
        cursor += chunk_len;
    }
    chunks
}

fn split_parallel_work_items(
    args: &ParallelUploadArgs,
    start: u64,
    len: u64,
    streams: usize,
) -> VecDeque<ParallelWorkItem> {
    let mut work = VecDeque::new();
    let stage_end = start.saturating_add(len);
    let mut global_start = 0u64;
    for (index, file) in args.files.iter().enumerate() {
        let global_end = global_start.saturating_add(file.size);
        if file.size > 0 && start < global_end && stage_end > global_start {
            let overlap_start = start.max(global_start);
            let overlap_end = stage_end.min(global_end);
            let file_start = overlap_start.saturating_sub(global_start);
            let file_len = overlap_end.saturating_sub(overlap_start);
            let source = args.source_path(index, file);
            let ranges = if file.size <= PARALLEL_DYNAMIC_CHUNK_SIZE {
                VecDeque::from([(file_start, file_len)])
            } else {
                split_parallel_chunks(file_start, file_len, streams)
            };
            for (range_start, range_len) in ranges {
                work.push_back(ParallelWorkItem {
                    file_num: args.file_num.saturating_add(index as i32),
                    source: source.clone(),
                    file_size: file.size,
                    range_start,
                    range_len,
                });
            }
        }
        global_start = global_end;
        if global_start >= stage_end {
            break;
        }
    }
    work
}

fn parallel_auxiliary_connection_is_allowed(peer_id: &str, is_secured: bool) -> bool {
    is_secured || crate::common::is_direct_ip_access(peer_id)
}

fn parallel_auto_stage_len(streams: usize, remaining: u64) -> u64 {
    (PARALLEL_AUTO_STAGE_PER_WORKER * streams as u64).min(remaining)
}

fn parallel_auto_stage_is_better(best_rate: f64, rate: f64) -> bool {
    best_rate == 0.0 || rate >= best_rate * PARALLEL_AUTO_MIN_GAIN
}

async fn run_parallel_stage(
    pool: &ParallelWorkerPool,
    transfer_id: &str,
    auth_token: &str,
    args: &ParallelUploadArgs,
    start: u64,
    len: u64,
    streams: usize,
    sent: Arc<AtomicU64>,
    cancelled: Arc<AtomicBool>,
) -> ResultType<Duration> {
    let started = Instant::now();
    let streams = streams.max(1).min(pool.workers.len());
    let chunks = split_parallel_work_items(args, start, len, streams);
    let queued_chunks = Arc::new(AtomicUsize::new(chunks.len()));
    let chunks = Arc::new(Mutex::new(chunks));
    begin_parallel_telemetry_stage(
        transfer_id,
        streams,
        queued_chunks.clone(),
        pool.open_connections.clone(),
    );
    let mut completions = Vec::with_capacity(streams);
    for index in 0..streams {
        let worker_id = index as u32 + 1;
        let telemetry = register_parallel_worker(transfer_id, worker_id, start, 0);
        let (done, completed) = oneshot::channel();
        let command = ParallelWorkerCommand {
            transfer_id: transfer_id.to_owned(),
            auth_token: auth_token.to_owned(),
            args: args.clone(),
            chunks: chunks.clone(),
            queued_chunks: queued_chunks.clone(),
            sent: sent.clone(),
            cancelled: cancelled.clone(),
            telemetry: telemetry.clone(),
            done,
        };
        if pool.workers[index].send(command).is_err() {
            if let Some((worker, _)) = telemetry {
                worker.state.store(PARALLEL_WORKER_ERROR, Ordering::Relaxed);
            }
            hbb_common::bail!("parallel worker pool is closed");
        }
        completions.push((completed, telemetry));
    }
    for (completed, telemetry) in completions {
        let result = match completed.await {
            Ok(result) => result,
            Err(_) => hbb_common::bail!("parallel worker pool dropped completion"),
        };
        if let Some((worker, _)) = telemetry {
            worker.state.store(
                if result.is_ok() {
                    PARALLEL_WORKER_COMPLETE
                } else {
                    PARALLEL_WORKER_ERROR
                },
                Ordering::Relaxed,
            );
        }
        if let Err(err) = result {
            hbb_common::bail!("{err}");
        }
    }
    Ok(started.elapsed())
}

async fn run_parallel_upload(
    pool: ParallelWorkerPool,
    transfer_id: &str,
    auth_token: &str,
    args: &ParallelUploadArgs,
    mode: ParallelMode,
    start_offset: u64,
    sent: Arc<AtomicU64>,
    cancelled: Arc<AtomicBool>,
) -> ResultType<usize> {
    let total = args.total_size();
    let start_offset = start_offset.min(total);
    if start_offset >= total {
        return Ok(0);
    }
    let remaining = total - start_offset;
    match mode {
        ParallelMode::Fixed(streams) => {
            run_parallel_stage(
                &pool,
                transfer_id,
                auth_token,
                args,
                start_offset,
                remaining,
                streams,
                sent,
                cancelled,
            )
            .await?;
            Ok(streams)
        }
        ParallelMode::Auto => {
            let cached = pool.auto_cached_streams.load(Ordering::Relaxed);
            if matches!(cached, 1 | 2 | 4 | 8) {
                run_parallel_stage(
                    &pool,
                    transfer_id,
                    auth_token,
                    args,
                    start_offset,
                    remaining,
                    cached,
                    sent,
                    cancelled,
                )
                .await?;
                log::info!(
                    "parallel file transfer {} auto reused_cached_streams={}",
                    transfer_id,
                    cached
                );
                return Ok(cached);
            }
            let mut cursor = start_offset;
            let mut previous_rate = None;
            let mut selected = 1usize;
            let mut best_rate = 0.0;
            for streams in [1usize, 2, 4, 8] {
                if cursor >= total {
                    break;
                }
                let stage_len = parallel_auto_stage_len(streams, total - cursor);
                let elapsed = run_parallel_stage(
                    &pool,
                    transfer_id,
                    auth_token,
                    args,
                    cursor,
                    stage_len,
                    streams,
                    sent.clone(),
                    cancelled.clone(),
                )
                .await?;
                cursor += stage_len;
                let rate = stage_len as f64 / elapsed.as_secs_f64().max(0.001);
                let gain = previous_rate.map(|previous| rate / previous).unwrap_or(1.0);
                log::info!(
                    "parallel file transfer {} auto stage streams={} bytes={} rate_mib_s={:.2} gain={:.2}",
                    transfer_id,
                    streams,
                    stage_len,
                    rate / 1024.0 / 1024.0,
                    gain
                );
                if parallel_auto_stage_is_better(best_rate, rate) {
                    best_rate = rate;
                    selected = streams;
                }
                previous_rate = Some(rate);
            }
            if cursor < total {
                run_parallel_stage(
                    &pool,
                    transfer_id,
                    auth_token,
                    args,
                    cursor,
                    total - cursor,
                    selected,
                    sent,
                    cancelled,
                )
                .await?;
            }
            pool.auto_cached_streams.store(selected, Ordering::Relaxed);
            log::info!(
                "parallel file transfer {} auto selected_streams={}",
                transfer_id,
                selected
            );
            Ok(selected)
        }
    }
}

struct ParallelWorkerConnection {
    peer: Stream,
    _keep_alive: Option<mpsc::UnboundedSender<()>>,
    active_transfer_id: String,
}

fn configure_parallel_worker_login(
    mut login: client::LoginConfigHandler,
    worker: u32,
    transfer_id: &str,
    auth_token: &str,
) -> client::LoginConfigHandler {
    login.conn_type = ConnType::FILE_TRANSFER;
    login.parallel_transfer_id = transfer_id.to_owned();
    login.parallel_worker = worker;
    login.parallel_auth_token = auth_token.to_owned();
    login.direct = None;
    login.received = false;
    login
}

async fn connect_parallel_worker<T: InvokeUiSession>(
    handler: Session<T>,
    key: &str,
    token: &str,
    worker: u32,
    transfer_id: &str,
    auth_token: &str,
) -> ResultType<ParallelWorkerConnection> {
    let mut worker_handler = handler.clone();
    let worker_lc = configure_parallel_worker_login(
        handler.lc.read().unwrap().clone(),
        worker,
        transfer_id,
        auth_token,
    );
    worker_handler.lc = Arc::new(RwLock::new(worker_lc));
    worker_handler.sender = Arc::new(RwLock::new(None));

    let ((mut peer, _, _, _, _), (feedback, rendezvous_server)) = Client::start(
        &worker_handler.get_id(),
        key,
        token,
        ConnType::FILE_TRANSFER,
        worker_handler.clone(),
    )
    .await?;
    if !parallel_auxiliary_connection_is_allowed(&worker_handler.get_id(), peer.is_secured()) {
        hbb_common::bail!("parallel auxiliary connection is not secured");
    }
    let keep_alive = client::hc_connection(feedback, rendezvous_server, token).await;
    let login_deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if Instant::now() >= login_deadline {
            hbb_common::bail!("parallel auxiliary login timed out");
        }
        let Some(bytes) = time::timeout(Duration::from_secs(5), peer.next()).await? else {
            hbb_common::bail!("parallel auxiliary connection closed during login");
        };
        let bytes = bytes?;
        let message = Message::parse_from_bytes(&bytes)?;
        match message.union {
            Some(message::Union::Hash(hash)) => {
                worker_handler
                    .handle_hash(&worker_handler.password.clone(), hash, &mut peer)
                    .await;
            }
            Some(message::Union::LoginResponse(response)) => match response.union {
                Some(login_response::Union::PeerInfo(_)) => break,
                Some(login_response::Union::Error(err)) => {
                    hbb_common::bail!("parallel auxiliary login failed: {err}")
                }
                _ => {}
            },
            _ => {}
        }
    }

    Ok(ParallelWorkerConnection {
        peer,
        _keep_alive: keep_alive,
        active_transfer_id: transfer_id.to_owned(),
    })
}

async fn run_parallel_pool_worker<T: InvokeUiSession>(
    handler: Session<T>,
    key: String,
    token: String,
    worker: u32,
    mut receiver: mpsc::UnboundedReceiver<ParallelWorkerCommand>,
    open_connections: Arc<AtomicUsize>,
) {
    let mut connection: Option<ParallelWorkerConnection> = None;
    let mut heartbeat = time::interval(PARALLEL_POOL_HEARTBEAT_INTERVAL);
    heartbeat.set_missed_tick_behavior(time::MissedTickBehavior::Delay);
    loop {
        let command = tokio::select! {
            command = receiver.recv() => {
                let Some(command) = command else {
                    break;
                };
                command
            }
            _ = heartbeat.tick(), if connection.is_some() => {
                let failed = if let Some(active) = connection.as_mut() {
                    active.peer.send_bytes(bytes::Bytes::new()).await.is_err()
                } else {
                    false
                };
                if failed && connection.take().is_some() {
                    open_connections.fetch_sub(1, Ordering::Relaxed);
                    log::warn!(
                        "parallel worker {} idle heartbeat failed; reconnecting on next job",
                        worker
                    );
                }
                continue;
            }
        };
        let result = async {
            if connection.is_none() {
                let connected = connect_parallel_worker(
                    handler.clone(),
                    &key,
                    &token,
                    worker,
                    &command.transfer_id,
                    &command.auth_token,
                )
                .await?;
                connection = Some(connected);
                open_connections.fetch_add(1, Ordering::Relaxed);
            }
            let Some(active) = connection.as_mut() else {
                hbb_common::bail!("parallel worker connection was not created");
            };
            run_parallel_worker_command(active, worker, &command).await
        }
        .await;
        let result = result.map_err(|err| err.to_string());
        if result.is_err() {
            if connection.take().is_some() {
                open_connections.fetch_sub(1, Ordering::Relaxed);
            }
        }
        let _ = command.done.send(result);
    }
    if connection.is_some() {
        open_connections.fetch_sub(1, Ordering::Relaxed);
    }
}

async fn run_parallel_worker_command(
    connection: &mut ParallelWorkerConnection,
    worker: u32,
    command: &ParallelWorkerCommand,
) -> ResultType<()> {
    use hbb_common::tokio::io::{AsyncReadExt, AsyncSeekExt};

    if command.cancelled.load(Ordering::Relaxed) {
        hbb_common::bail!("parallel transfer cancelled");
    }
    let mut open_source: Option<(PathBuf, tokio::fs::File)> = None;
    let mut buffer = vec![0u8; PARALLEL_FILE_BLOCK_SIZE];
    loop {
        if command.cancelled.load(Ordering::Relaxed) {
            hbb_common::bail!("parallel transfer cancelled");
        }
        let chunk = match command.chunks.lock() {
            Ok(mut chunks) => chunks.pop_front(),
            Err(_) => hbb_common::bail!("parallel chunk queue lock is poisoned"),
        };
        let Some(work) = chunk else {
            return Ok(());
        };
        command.queued_chunks.fetch_sub(1, Ordering::Relaxed);
        if open_source
            .as_ref()
            .map(|(path, _)| path != &work.source)
            .unwrap_or(true)
        {
            let file = tokio::fs::File::open(&work.source).await?;
            let metadata = file.metadata().await?;
            if metadata.len() != work.file_size {
                hbb_common::bail!("source file changed size during parallel transfer");
            }
            open_source = Some((work.source.clone(), file));
        }
        let Some((_, file)) = open_source.as_mut() else {
            hbb_common::bail!("parallel source file was not opened");
        };
        let range_start = work.range_start;
        let range_len = work.range_len;
        let range_end = range_start.saturating_add(range_len);
        if let Some((telemetry, phase)) = &command.telemetry {
            telemetry.range_start.store(range_start, Ordering::Relaxed);
            telemetry.range_end.store(range_end, Ordering::Relaxed);
            telemetry
                .state
                .store(PARALLEL_WORKER_TRANSFERRING, Ordering::Relaxed);
            phase.store(PARALLEL_PHASE_TRANSFERRING, Ordering::Relaxed);
        }

        let reattach = connection.active_transfer_id != command.transfer_id;
        let mut action = FileAction::new();
        action.set_receive(FileTransferReceiveRequest {
            id: command.args.id,
            path: command.args.destination.clone(),
            file_num: work.file_num,
            parallel_transfer_id: command.transfer_id.clone(),
            parallel_auth_token: if reattach {
                command.auth_token.clone()
            } else {
                String::new()
            },
            range_start,
            range_len,
            parallel_worker: worker,
            ..Default::default()
        });
        let mut attach = Message::new();
        attach.set_file_action(action);
        connection.peer.send(&attach).await?;
        connection.active_transfer_id = command.transfer_id.clone();

        file.seek(std::io::SeekFrom::Start(range_start)).await?;
        let mut offset = range_start;
        while offset < range_end {
            if command.cancelled.load(Ordering::Relaxed) {
                hbb_common::bail!("parallel transfer cancelled");
            }
            let wanted = (range_end - offset).min(buffer.len() as u64) as usize;
            let read = file.read(&mut buffer[..wanted]).await?;
            if read == 0 {
                hbb_common::bail!("unexpected end of source file in parallel chunk");
            }
            let mut response = FileResponse::new();
            response.set_block(FileTransferBlock {
                id: command.args.id,
                file_num: work.file_num,
                data: buffer[..read].to_vec().into(),
                offset,
                parallel_transfer_id: command.transfer_id.clone(),
                parallel_worker: worker,
                ..Default::default()
            });
            let mut message = Message::new();
            message.set_file_response(response);
            connection.peer.send(&message).await?;
            offset += read as u64;
            command.sent.fetch_add(read as u64, Ordering::Relaxed);
            if let Some((telemetry, _)) = &command.telemetry {
                telemetry
                    .bytes_transferred
                    .fetch_add(read as u64, Ordering::Relaxed);
            }
        }

        if let Some((telemetry, _)) = &command.telemetry {
            telemetry
                .state
                .store(PARALLEL_WORKER_AWAITING_ACK, Ordering::Relaxed);
        }
        let mut response = FileResponse::new();
        response.set_done(FileTransferDone {
            id: command.args.id,
            file_num: work.file_num,
            parallel_transfer_id: command.transfer_id.clone(),
            parallel_worker: worker,
            ..Default::default()
        });
        let mut done = Message::new();
        done.set_file_response(response);
        connection.peer.send(&done).await?;
        log::debug!(
            "parallel file transfer {} worker {} sent range completion for file {} [{}, {})",
            command.transfer_id,
            worker,
            work.file_num,
            range_start,
            range_end
        );
        loop {
            let Some(bytes) =
                time::timeout(Duration::from_secs(30), connection.peer.next()).await?
            else {
                hbb_common::bail!("parallel auxiliary connection closed before acknowledgement");
            };
            let bytes = bytes?;
            if bytes.is_empty() {
                connection.peer.send_bytes(bytes::Bytes::new()).await?;
                continue;
            }
            let message = Message::parse_from_bytes(&bytes)?;
            match message.union {
                Some(message::Union::FileResponse(response)) => match response.union {
                    Some(file_response::Union::Done(done)) => {
                        if done.worker_ack
                            && done.parallel_transfer_id == command.transfer_id
                            && done.parallel_worker == worker
                            && done.file_num == work.file_num
                        {
                            log::debug!(
                                "parallel file transfer {} worker {} received range acknowledgement for file {}",
                                command.transfer_id,
                                worker,
                                work.file_num
                            );
                            if let Some((telemetry, _)) = &command.telemetry {
                                telemetry.chunks_completed.fetch_add(1, Ordering::Relaxed);
                                telemetry.jobs_completed.fetch_add(1, Ordering::Relaxed);
                            }
                            break;
                        }
                        log::warn!(
                            "parallel file transfer {} worker {} ignored mismatched acknowledgement: transfer={} worker={} file={} worker_ack={} finalize={} transfer_complete={}",
                            command.transfer_id,
                            worker,
                            done.parallel_transfer_id,
                            done.parallel_worker,
                            done.file_num,
                            done.worker_ack,
                            done.finalize,
                            done.transfer_complete
                        );
                    }
                    Some(file_response::Union::Error(err)) => {
                        hbb_common::bail!("parallel receiver error: {}", err.error)
                    }
                    _ => {}
                },
                _ => {}
            }
        }
    }
}

async fn run_parallel_download_worker<T: InvokeUiSession>(
    handler: Session<T>,
    key: String,
    token: String,
    worker: u32,
    transfer_id: String,
    auth_token: String,
    args: ParallelDownloadArgs,
    chunks: Arc<Mutex<VecDeque<(u64, u64)>>>,
    queued_chunks: Arc<AtomicUsize>,
    open_connections: Arc<AtomicUsize>,
    completed: Arc<Mutex<Vec<(u64, u64)>>>,
    received: Arc<AtomicU64>,
    cancelled: Arc<AtomicBool>,
    telemetry: Option<(Arc<ParallelWorkerTelemetry>, Arc<AtomicUsize>)>,
) -> ResultType<()> {
    use hbb_common::tokio::io::{AsyncSeekExt, AsyncWriteExt};

    let mut connection =
        connect_parallel_worker(handler, &key, &token, worker, &transfer_id, &auth_token).await?;
    open_connections.fetch_add(1, Ordering::Relaxed);
    let open_connections_on_drop = open_connections.clone();
    let _open_connection_guard = crate::SimpleCallOnReturn {
        b: true,
        f: Box::new(move || {
            open_connections_on_drop.fetch_sub(1, Ordering::Relaxed);
        }),
    };
    let target = args.target_path()?;
    let download = PathBuf::from(format!("{}.download", get_string(&target)));
    let mut output = tokio::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .open(&download)
        .await?;

    loop {
        if cancelled.load(Ordering::Relaxed) {
            hbb_common::bail!("parallel download cancelled");
        }
        let next = match chunks.lock() {
            Ok(mut chunks) => chunks.pop_front(),
            Err(_) => hbb_common::bail!("parallel download queue lock is poisoned"),
        };
        let Some((range_start, range_len)) = next else {
            output.sync_all().await?;
            if let Some((worker_stats, _)) = &telemetry {
                worker_stats
                    .state
                    .store(PARALLEL_WORKER_COMPLETE, Ordering::Relaxed);
            }
            return Ok(());
        };
        queued_chunks.fetch_sub(1, Ordering::Relaxed);
        let range_end = range_start.saturating_add(range_len);
        if let Some((worker_stats, phase)) = &telemetry {
            worker_stats
                .range_start
                .store(range_start, Ordering::Relaxed);
            worker_stats.range_end.store(range_end, Ordering::Relaxed);
            worker_stats
                .state
                .store(PARALLEL_WORKER_TRANSFERRING, Ordering::Relaxed);
            phase.store(PARALLEL_PHASE_TRANSFERRING, Ordering::Relaxed);
        }

        let mut action = FileAction::new();
        action.set_send(FileTransferSendRequest {
            id: args.id,
            path: args.remote_path.clone(),
            include_hidden: false,
            file_num: 0,
            file_type: file_transfer_send_request::FileType::Generic.into(),
            parallel_transfer_id: transfer_id.clone(),
            range_start,
            range_len,
            parallel_worker: worker,
            ..Default::default()
        });
        let mut request = Message::new();
        request.set_file_action(action);
        connection.peer.send(&request).await?;

        let mut expected_offset = range_start;
        loop {
            let bytes = match time::timeout(Duration::from_secs(1), connection.peer.next()).await {
                Ok(Some(bytes)) => bytes?,
                Ok(None) => hbb_common::bail!("parallel download connection closed"),
                Err(_) if cancelled.load(Ordering::Relaxed) => {
                    hbb_common::bail!("parallel download cancelled")
                }
                Err(_) => continue,
            };
            if bytes.is_empty() {
                connection.peer.send_bytes(bytes::Bytes::new()).await?;
                continue;
            }
            let message = Message::parse_from_bytes(&bytes)?;
            match message.union {
                Some(message::Union::FileResponse(response)) => match response.union {
                    Some(file_response::Union::Dir(_)) => {}
                    Some(file_response::Union::Block(block)) => {
                        if block.parallel_transfer_id != transfer_id
                            || block.parallel_worker != worker
                            || block.offset != expected_offset
                            || block.offset.saturating_add(block.data.len() as u64) > range_end
                        {
                            hbb_common::bail!("invalid parallel download block");
                        }
                        output.seek(std::io::SeekFrom::Start(block.offset)).await?;
                        output.write_all(&block.data).await?;
                        expected_offset = expected_offset.saturating_add(block.data.len() as u64);
                        received.fetch_add(block.data.len() as u64, Ordering::Relaxed);
                        if let Some((worker_stats, _)) = &telemetry {
                            worker_stats
                                .bytes_transferred
                                .fetch_add(block.data.len() as u64, Ordering::Relaxed);
                        }
                    }
                    Some(file_response::Union::Done(done)) => {
                        if done.worker_ack
                            && done.parallel_transfer_id == transfer_id
                            && done.parallel_worker == worker
                        {
                            if expected_offset != range_end {
                                hbb_common::bail!("parallel download range ended early");
                            }
                            if let Ok(mut ranges) = completed.lock() {
                                ranges.push((range_start, range_end));
                            }
                            if let Some((worker_stats, _)) = &telemetry {
                                worker_stats
                                    .chunks_completed
                                    .fetch_add(1, Ordering::Relaxed);
                                worker_stats.jobs_completed.fetch_add(1, Ordering::Relaxed);
                                worker_stats
                                    .state
                                    .store(PARALLEL_WORKER_AWAITING_ACK, Ordering::Relaxed);
                            }
                            break;
                        }
                    }
                    Some(file_response::Union::Error(err)) => {
                        hbb_common::bail!("parallel sender error: {}", err.error)
                    }
                    _ => {}
                },
                _ => {}
            }
        }
    }
}

async fn run_parallel_download<T: InvokeUiSession>(
    handler: Session<T>,
    key: String,
    token: String,
    transfer_id: String,
    auth_token: String,
    args: ParallelDownloadArgs,
    mode: ParallelMode,
    resume_offset: u64,
    received: Arc<AtomicU64>,
    cancelled: Arc<AtomicBool>,
) -> ResultType<()> {
    let target = args.target_path()?;
    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let download = PathBuf::from(format!("{}.download", get_string(&target)));
    let digest = PathBuf::from(format!("{}.digest", get_string(&target)));
    let output = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .open(&download)?;
    output.set_len(resume_offset)?;
    drop(output);
    std::fs::write(
        &digest,
        serde_json::json!({"size": args.file.size, "modified": args.file.modified_time})
            .to_string(),
    )?;

    let streams = match mode {
        ParallelMode::Fixed(streams) => streams,
        ParallelMode::Auto => 8,
    }
    .max(1)
    .min(8);
    let chunks = Arc::new(Mutex::new(split_parallel_chunks(
        resume_offset,
        args.file.size.saturating_sub(resume_offset),
        streams,
    )));
    let queued_chunks = Arc::new(AtomicUsize::new(
        chunks.lock().map(|chunks| chunks.len()).unwrap_or_default(),
    ));
    let open_connections = Arc::new(AtomicUsize::new(0));
    begin_parallel_telemetry_stage(
        &transfer_id,
        streams,
        queued_chunks.clone(),
        open_connections.clone(),
    );
    let completed = Arc::new(Mutex::new(Vec::<(u64, u64)>::new()));
    let mut tasks = Vec::with_capacity(streams);
    for index in 0..streams {
        let worker = index as u32 + 1;
        let telemetry = register_parallel_worker(&transfer_id, worker, resume_offset, 0);
        tasks.push(tokio::spawn(run_parallel_download_worker(
            handler.clone(),
            key.clone(),
            token.clone(),
            worker,
            transfer_id.clone(),
            auth_token.clone(),
            args.clone(),
            chunks.clone(),
            queued_chunks.clone(),
            open_connections.clone(),
            completed.clone(),
            received.clone(),
            cancelled.clone(),
            telemetry,
        )));
    }

    let mut first_error = None;
    for task in tasks {
        match task.await {
            Ok(Ok(())) => {}
            Ok(Err(err)) => {
                cancelled.store(true, Ordering::Relaxed);
                first_error.get_or_insert_with(|| err.to_string());
            }
            Err(err) => {
                cancelled.store(true, Ordering::Relaxed);
                first_error.get_or_insert_with(|| err.to_string());
            }
        }
    }
    if let Some(err) = first_error {
        let ranges = completed
            .lock()
            .map(|ranges| ranges.clone())
            .unwrap_or_default();
        let prefix = contiguous_completed_prefix(resume_offset, ranges);
        std::fs::OpenOptions::new()
            .write(true)
            .open(&download)?
            .set_len(prefix)?;
        hbb_common::bail!("{err}");
    }

    std::fs::OpenOptions::new()
        .write(true)
        .open(&download)?
        .set_len(args.file.size)?;
    if target.exists() {
        std::fs::remove_file(&target)?;
    }
    std::fs::rename(&download, &target)?;
    std::fs::remove_file(&digest).ok();
    fs::set_transfer_file_modified_time(&target, args.file.modified_time)?;
    Ok(())
}

fn contiguous_completed_prefix(initial: u64, mut ranges: Vec<(u64, u64)>) -> u64 {
    let mut prefix = initial;
    ranges.sort_unstable_by_key(|range| range.0);
    for (start, end) in ranges {
        if start > prefix {
            break;
        }
        prefix = prefix.max(end);
    }
    prefix
}

pub struct Remote<T: InvokeUiSession> {
    handler: Session<T>,
    audio_sender: MediaSender,
    receiver: mpsc::UnboundedReceiver<Data>,
    sender: mpsc::UnboundedSender<Data>,
    // Stop sending local audio to remote client.
    stop_voice_call_sender: Option<std::sync::mpsc::Sender<()>>,
    voice_call_request_timestamp: Option<NonZeroI64>,
    read_jobs: Vec<fs::TransferJob>,
    write_jobs: Vec<fs::TransferJob>,
    remove_jobs: HashMap<i32, RemoveJob>,
    timer: crate::RustDeskInterval,
    last_update_jobs_status: (Instant, HashMap<i32, u64>),
    is_connected: bool,
    first_frame: bool,
    #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
    client_conn_id: i32, // used for file clipboard
    data_count: Arc<AtomicUsize>,
    video_format: CodecFormat,
    elevation_requested: bool,
    peer_info: ParsedPeerInfo,
    video_threads: HashMap<usize, VideoThread>,
    chroma: Arc<RwLock<Option<Chroma>>>,
    last_record_state: bool,
    sent_close_reason: bool,
    parallel_send_jobs: HashMap<i32, ParallelSendJob>,
    parallel_receive_jobs: HashMap<i32, ParallelReceiveJob>,
    parallel_worker_pool: Option<ParallelWorkerPool>,
    connection_key: String,
    connection_token: String,
    #[cfg(target_os = "windows")]
    local_parallel_clipboard_generation_expected: bool,
}

#[derive(Default)]
struct ParsedPeerInfo {
    platform: String,
    is_installed: bool,
    idd_impl: String,
    support_view_camera: bool,
    support_terminal: bool,
    support_parallel_clipboard_cache: bool,
}

impl ParsedPeerInfo {
    fn is_support_virtual_display(&self) -> bool {
        self.is_installed
            && self.platform == "Windows"
            && (self.idd_impl == "rustdesk_idd" || self.idd_impl == "amyuni_idd")
    }
}

impl<T: InvokeUiSession> Remote<T> {
    pub fn new(
        handler: Session<T>,
        receiver: mpsc::UnboundedReceiver<Data>,
        sender: mpsc::UnboundedSender<Data>,
    ) -> Self {
        Self {
            handler,
            audio_sender: crate::client::start_audio_thread(),
            receiver,
            sender,
            read_jobs: Vec::new(),
            write_jobs: Vec::new(),
            remove_jobs: Default::default(),
            timer: crate::rustdesk_interval(time::interval(SEC30)),
            last_update_jobs_status: (Instant::now(), Default::default()),
            is_connected: false,
            first_frame: false,
            #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
            client_conn_id: 0,
            data_count: Arc::new(AtomicUsize::new(0)),
            video_format: CodecFormat::Unknown,
            stop_voice_call_sender: None,
            voice_call_request_timestamp: None,
            elevation_requested: false,
            peer_info: Default::default(),
            video_threads: Default::default(),
            chroma: Default::default(),
            last_record_state: false,
            sent_close_reason: false,
            parallel_send_jobs: HashMap::new(),
            parallel_receive_jobs: HashMap::new(),
            parallel_worker_pool: None,
            connection_key: String::new(),
            connection_token: String::new(),
            #[cfg(target_os = "windows")]
            local_parallel_clipboard_generation_expected: false,
        }
    }

    pub async fn io_loop(&mut self, key: &str, token: &str, round: u32) {
        self.connection_key = key.to_owned();
        self.connection_token = token.to_owned();
        #[cfg(target_os = "windows")]
        let _file_clip_context_holder = {
            // `is_port_forward()` will not reach here, but we still check it for clarity.
            if self.handler.is_default() {
                // It is ok to call this function multiple times.
                ContextSend::enable(true);
                Some(crate::SimpleCallOnReturn {
                    b: true,
                    f: Box::new(|| {
                        // No need to call `enable(false)` for sciter version, because each client of sciter version is a new process.
                        // It's better to check if the peers are windows(support file copy&paste), but it's not necessary.
                        #[cfg(feature = "flutter")]
                        if !crate::flutter::sessions::has_sessions_running(ConnType::DEFAULT_CONN) {
                            ContextSend::enable(false);
                        };
                    }),
                })
            } else {
                None
            }
        };

        let mut received = false;
        let conn_type = if self.handler.is_file_transfer() {
            ConnType::FILE_TRANSFER
        } else if self.handler.is_view_camera() {
            ConnType::VIEW_CAMERA
        } else if self.handler.is_terminal() {
            ConnType::TERMINAL
        } else {
            ConnType::default()
        };

        match Client::start(
            &self.handler.get_id(),
            key,
            token,
            conn_type,
            self.handler.clone(),
        )
        .await
        {
            Ok(((mut peer, direct, pk, kcp, stream_type), (feedback, rendezvous_server))) => {
                self.handler
                    .connection_round_state
                    .lock()
                    .unwrap()
                    .set_connected();
                let is_secured = peer.is_secured();
                self.handler
                    .set_connection_type(is_secured, direct, stream_type); // flutter -> connection_ready
                if !is_secured
                    && !crate::common::is_direct_ip_access(&self.handler.get_id())
                    && !client::confirm_insecure_connection(&self.handler, &mut self.receiver).await
                {
                    self.send_close_reason(&mut peer, "").await;
                    if kcp.is_some() {
                        tokio::time::sleep(KCP_CLOSE_REASON_FLUSH_DELAY).await;
                    }
                    self.handle_disconnected(round);
                    return;
                }
                self.handler.update_direct(Some(direct));
                if conn_type == ConnType::DEFAULT_CONN || conn_type == ConnType::VIEW_CAMERA {
                    self.handler
                        .set_fingerprint(crate::common::pk_to_fingerprint(pk.unwrap_or_default()));
                }

                // just build for now
                #[cfg(not(any(target_os = "windows", feature = "unix-file-copy-paste")))]
                let (_tx_holder, mut rx_clip_client) = mpsc::unbounded_channel::<i32>();

                #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
                let (_tx_holder, rx) = mpsc::unbounded_channel();
                #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
                let mut rx_clip_client_holder = (Arc::new(TokioMutex::new(rx)), None);
                #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
                {
                    if self.handler.is_default() {
                        (self.client_conn_id, rx_clip_client_holder.0) =
                            clipboard::get_rx_cliprdr_client(&self.handler.get_id());
                        log::debug!("get cliprdr client for conn_id {}", self.client_conn_id);
                        let client_conn_id = self.client_conn_id;
                        rx_clip_client_holder.1 = Some(crate::SimpleCallOnReturn {
                            b: true,
                            f: Box::new(move || {
                                clipboard::remove_channel_by_conn_id(client_conn_id);
                            }),
                        });
                    };
                }
                #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
                let mut rx_clip_client = rx_clip_client_holder.0.lock().await;

                let mut status_timer =
                    crate::rustdesk_interval(time::interval(TRANSFER_TELEMETRY_INTERVAL));
                let mut fps_instant = Instant::now();

                let _keep_it = client::hc_connection(feedback, rendezvous_server, token).await;
                let mut last_recv_time = Instant::now();

                loop {
                    tokio::select! {
                        res = peer.next() => {
                            if let Some(res) = res {
                                match res {
                                    Err(err) => {
                                        self.handler.on_establish_connection_error(err.to_string());
                                        break;
                                    }
                                    Ok(ref bytes) => {
                                        last_recv_time = Instant::now();
                                        if !received {
                                            received = true;
                                            self.handler.update_received(true);
                                        }
                                        self.data_count.fetch_add(bytes.len(), Ordering::Relaxed);
                                        if !self.handle_msg_from_peer(bytes, &mut peer).await {
                                            break
                                        }
                                    }
                                }
                            } else {
                                if self.handler.is_restarting_remote_device() {
                                    log::info!("Restart remote device");
                                    self.handler.msgbox("restarting", "Restarting remote device", "Connection in progress. Please wait.", "");
                                } else {
                                    log::info!("Reset by the peer");
                                    self.handler.msgbox("error", "Connection Error", "Reset by the peer", "");
                                }
                                break;
                            }
                        }
                        d = self.receiver.recv() => {
                            if let Some(d) = d {
                                if !self.handle_msg_from_ui(d, &mut peer).await {
                                    break;
                                }
                            }
                        }
                        _msg = rx_clip_client.recv() => {
                            #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
                            self.handle_local_clipboard_msg(&mut peer, _msg).await;
                        }
                        _ = self.timer.tick() => {
                            if last_recv_time.elapsed() >= SEC30 {
                                self.handler.msgbox("error", "Connection Error", "Timeout", "");
                                break;
                            }
                            if !self.read_jobs.is_empty() {
                                if let Err(err) = fs::handle_read_jobs(&mut self.read_jobs, &mut peer).await {
                                    self.handler.msgbox("error", "Connection Error", &err.to_string(), "");
                                    break;
                                }
                                self.update_jobs_status();
                            } else {
                                self.timer = crate::rustdesk_interval(time::interval_at(Instant::now() + SEC30, SEC30));
                            }
                        }
                        _ = status_timer.tick() => {
                            if !self.parallel_send_jobs.is_empty()
                                || !self.parallel_receive_jobs.is_empty()
                            {
                                self.update_jobs_status();
                            }
                            if self.handler.is_restarting_remote_device()
                                && last_recv_time.elapsed() >= RESTART_REMOTE_DEVICE_NO_DATA_TIMEOUT
                            {
                                self.handler.msgbox("restarting-show", "Restarting remote device", "Connection in progress. Please wait.", "");
                                break;
                            }
                            let elapsed = fps_instant.elapsed().as_millis();
                            if elapsed < 1000 {
                                continue;
                            }
                            fps_instant = Instant::now();
                            let mut speed = self.data_count.swap(0, Ordering::Relaxed);
                            speed = speed * 1000 / elapsed as usize;
                            let speed = format!("{:.2}kB/s", speed as f32 / 1024 as f32);

                            let fps = self.video_threads.iter().map(|(k, v)| {
                                // Correcting the inaccuracy of status_timer
                                (k.clone(), (*v.frame_count.read().unwrap() as i32) * 1000 / elapsed as i32)
                            }).collect::<HashMap<usize, i32>>();
                            self.video_threads.iter().for_each(|(_, v)| {
                                *v.frame_count.write().unwrap() = 0;
                            });
                            self.fps_control(direct, fps.clone());
                            let chroma = self.chroma.read().unwrap().clone();
                            let chroma = match chroma {
                                Some(Chroma::I444) => "4:4:4",
                                Some(Chroma::I420) => "4:2:0",
                                None => "-",
                            };
                            let chroma = Some(chroma.to_string());
                            let codec_format = if self.video_format == CodecFormat::Unknown {
                                None
                            } else {
                                Some(self.video_format.clone())
                            };
                            self.handler.update_quality_status(QualityStatus {
                                speed: Some(speed),
                                fps,
                                chroma,
                                codec_format,
                                ..Default::default()
                            });
                        }
                    }
                }
                log::debug!("Exit io_loop of id={}", self.handler.get_id());
                // Stop client audio server.
                if let Some(s) = self.stop_voice_call_sender.take() {
                    s.send(()).ok();
                }
                if kcp.is_some() {
                    // Send the close reason if it hasn't been sent yet, as KCP cannot detect the socket close event.
                    self.send_close_reason(&mut peer, "kcp").await;
                    // KCP does not send messages immediately, so wait to ensure the last message is sent.
                    // 1ms works in my test, but 30ms is more reliable.
                    tokio::time::sleep(KCP_CLOSE_REASON_FLUSH_DELAY).await;
                }
            }
            Err(err) => {
                self.handler.on_establish_connection_error(err.to_string());
            }
        }
        for job in self.parallel_receive_jobs.values() {
            job.cancelled.store(true, Ordering::Relaxed);
        }
        let completions = self
            .parallel_receive_jobs
            .values_mut()
            .filter_map(|job| job.completion.take())
            .collect::<Vec<_>>();
        for completion in completions {
            let _ = time::timeout(Duration::from_secs(5), completion).await;
        }
        let _ = self.sync_jobs_status_to_local().await;
        self.is_connected = false;
        self.handle_disconnected(round);
    }

    fn handle_disconnected(&self, round: u32) {
        // set_disconnected_ok is used to check if new connection round is started.
        let _set_disconnected_ok = self
            .handler
            .connection_round_state
            .lock()
            .unwrap()
            .set_disconnected(round);

        #[cfg(not(target_os = "ios"))]
        if self.handler.is_default() && _set_disconnected_ok {
            Client::try_stop_clipboard();
        }

        #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
        if self.handler.is_default() && _set_disconnected_ok {
            // Linux client cleanup runs synchronously in try_stop_clipboard() before FUSE is
            // unmounted. Keep this async path for other file-clipboard platforms.
            crate::clipboard::try_empty_clipboard_files(ClipboardSide::Client, self.client_conn_id);
        }
    }

    #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
    async fn handle_local_clipboard_msg(
        &mut self,
        peer: &mut Stream,
        msg: Option<clipboard::ClipboardFile>,
    ) {
        match msg {
            Some(clip) => {
                #[cfg(target_os = "windows")]
                if let clipboard::ClipboardFile::FormatList { format_list } = &clip {
                    self.local_parallel_clipboard_generation_expected = format_list
                        .iter()
                        .any(|(_, name)| name == "MasterDeskParallelFileCacheV1");
                    let enabled = self.peer_info.support_parallel_clipboard_cache
                        && self.peer_info.platform == "Windows"
                        && !matches!(configured_parallel_mode(), ParallelMode::Fixed(1));
                    let _ = ContextSend::proc(|context| -> ResultType<()> {
                        context
                            .set_parallel_file_cache_enabled(enabled)
                            .map_err(|err| err.into())
                    });
                }
                match clip {
                    clipboard::ClipboardFile::NotifyCallback {
                        r#type,
                        title,
                        text,
                    } => {
                        self.handler.msgbox(&r#type, &title, &text, "");
                    }
                    clipboard::ClipboardFile::Files { files } => {
                        let audit =
                            crate::clipboard_file::clip_2_msg(clipboard::ClipboardFile::Files {
                                files: files.clone(),
                            });
                        allow_err!(peer.send(&audit).await);
                        if self.local_parallel_clipboard_generation_expected
                            && self.peer_info.support_parallel_clipboard_cache
                            && self.peer_info.platform == "Windows"
                        {
                            self.start_parallel_clipboard_cache(files, peer).await;
                        }
                    }
                    _ => {
                        let is_stopping_allowed = clip.is_stopping_allowed();
                        let server_file_transfer_enabled =
                            *self.handler.server_file_transfer_enabled.read().unwrap();
                        let file_transfer_enabled =
                            self.handler.lc.read().unwrap().enable_file_copy_paste.v;
                        let view_only = self.handler.lc.read().unwrap().view_only.v;
                        let stop = is_stopping_allowed
                            && (view_only
                                || !self.is_connected
                                || !(server_file_transfer_enabled && file_transfer_enabled));
                        log::debug!(
                        "Process clipboard message from system, stop: {}, is_stopping_allowed: {}, view_only: {}, server_file_transfer_enabled: {}, file_transfer_enabled: {}",
                        stop, is_stopping_allowed, view_only, server_file_transfer_enabled, file_transfer_enabled
                    );
                        if stop {
                            #[cfg(target_os = "windows")]
                            {
                                ContextSend::set_is_stopped();
                            }
                        } else {
                            #[cfg(target_os = "windows")]
                            if let Err(e) = ContextSend::make_sure_enabled() {
                                log::error!("failed to restart clipboard context: {}", e);
                                // to-do: Show msgbox with "Don't show again" option
                            };
                            log::debug!("Send system clipboard message to remote");
                            let msg = crate::clipboard_file::clip_2_msg(clip);
                            allow_err!(peer.send(&msg).await);
                        }
                    }
                }
            }
            None => {
                // unreachable!()
            }
        }
    }

    fn handle_job_status(&mut self, id: i32, file_num: i32, err: Option<String>) {
        if let Some(job) = self.remove_jobs.get_mut(&id) {
            if job.no_confirm {
                let file_num = (file_num + 1) as usize;
                if file_num < job.files.len() {
                    let path = format!("{}{}{}", job.path, job.sep, job.files[file_num].name);
                    self.sender
                        .send(Data::RemoveFile((id, path, file_num as i32, job.is_remote)))
                        .ok();
                    let elapsed = job.last_update_job_status.elapsed().as_millis() as i32;
                    if elapsed >= 1000 {
                        job.last_update_job_status = Instant::now();
                    } else {
                        return;
                    }
                } else {
                    self.remove_jobs.remove(&id);
                }
            }
        }
        if let Some(err) = err {
            self.handler.job_error(id, err, file_num);
        } else {
            self.handler.job_done(id, file_num);
        }
    }

    fn stop_voice_call(&mut self) {
        let voice_call_sender = std::mem::replace(&mut self.stop_voice_call_sender, None);
        if let Some(stopper) = voice_call_sender {
            let _ = stopper.send(());
        }
    }

    fn parallel_upload_supported(&self, job: &fs::TransferJob) -> bool {
        let lc = self.handler.lc.read().unwrap();
        let supported = lc
            .features
            .as_ref()
            .map(|features| features.parallel_file_transfer_v1)
            .unwrap_or(false);
        supported
            && self.peer_info.platform == "Windows"
            && job.r#type == fs::JobType::Generic
            && !job.files().is_empty()
            && (job.files().len() > 1 || job.total_size() >= PARALLEL_FILE_MIN_SIZE)
            && !matches!(configured_parallel_mode(), ParallelMode::Fixed(1))
    }

    fn parallel_download_supported(&self, job_type: fs::JobType) -> bool {
        let lc = self.handler.lc.read().unwrap();
        lc.features
            .as_ref()
            .map(|features| features.parallel_file_download_v1)
            .unwrap_or(false)
            && self.peer_info.platform == "Windows"
            && job_type == fs::JobType::Generic
            && !matches!(configured_parallel_mode(), ParallelMode::Fixed(1))
    }

    fn parallel_download_request(
        id: i32,
        path: String,
        file_num: i32,
        include_hidden: bool,
        transfer_id: String,
        auth_token: String,
    ) -> Message {
        let mut action = FileAction::new();
        action.set_send(FileTransferSendRequest {
            id,
            path,
            include_hidden,
            file_num,
            file_type: file_transfer_send_request::FileType::Generic.into(),
            parallel_transfer_id: transfer_id,
            parallel_initialize: true,
            parallel_auth_token: auth_token,
            ..Default::default()
        });
        let mut message = Message::new();
        message.set_file_action(action);
        message
    }

    async fn cancel_pending_parallel_download(&mut self, id: i32, peer: &mut Stream) {
        let Some(job) = self.parallel_receive_jobs.remove(&id) else {
            return;
        };
        job.cancelled.store(true, Ordering::Relaxed);
        let mut action = FileAction::new();
        action.set_cancel(FileTransferCancel {
            id,
            parallel_transfer_id: job.transfer_id,
            keep_partial: true,
            ..Default::default()
        });
        let mut message = Message::new();
        message.set_file_action(action);
        allow_err!(peer.send(&message).await);
    }

    async fn try_start_parallel_download(
        &mut self,
        digest: &FileTransferDigest,
        peer: &mut Stream,
    ) -> bool {
        let Some(pending) = self.parallel_receive_jobs.get(&digest.id) else {
            return false;
        };
        if pending.started {
            return true;
        }
        let Some(file) = pending.file.clone() else {
            return false;
        };
        if file.size < PARALLEL_FILE_MIN_SIZE {
            self.cancel_pending_parallel_download(digest.id, peer).await;
            return false;
        }

        let Some(job) = fs::get_job(digest.id, &mut self.write_jobs) else {
            self.cancel_pending_parallel_download(digest.id, peer).await;
            return false;
        };
        let destination = match &job.data_source {
            fs::DataSource::FilePath(path) => path.clone(),
            fs::DataSource::MemoryCursor(_) => {
                self.cancel_pending_parallel_download(digest.id, peer).await;
                return false;
            }
        };
        let target = match fs::resolve_transfer_path(&destination, &file.name) {
            Ok(path) => path,
            Err(err) => {
                self.handle_job_status(digest.id, digest.file_num, Some(err.to_string()));
                self.cancel_pending_parallel_download(digest.id, peer).await;
                return true;
            }
        };
        let target_string = get_string(&target);
        let resume_offset =
            match fs::is_write_need_confirmation(job.is_resume, &target_string, digest) {
                Ok(DigestCheckResult::NoSuchFile) => 0,
                Ok(DigestCheckResult::NeedConfirm(existing))
                    if job.is_resume && existing.is_identical =>
                {
                    existing.transferred_size.min(file.size)
                }
                _ => {
                    self.cancel_pending_parallel_download(digest.id, peer).await;
                    return false;
                }
            };
        job.is_last_job = false;
        job.set_finished_size_on_resume();

        let Some(pending) = self.parallel_receive_jobs.get_mut(&digest.id) else {
            return false;
        };
        pending.started = true;
        pending.received.store(resume_offset, Ordering::Relaxed);
        let transfer_id = pending.transfer_id.clone();
        let auth_token = pending.auth_token.clone();
        let remote_path = pending.remote_path.clone();
        let mode = pending.mode;
        let received = pending.received.clone();
        let cancelled = pending.cancelled.clone();
        register_parallel_transfer(
            digest.id,
            &transfer_id,
            mode,
            &file.name,
            file.size,
            1,
            received.clone(),
        );

        let mut cancel_action = FileAction::new();
        cancel_action.set_cancel(FileTransferCancel {
            id: digest.id,
            keep_partial: true,
            ..Default::default()
        });
        let mut cancel = Message::new();
        cancel.set_file_action(cancel_action);
        allow_err!(peer.send(&cancel).await);

        let sender = self.sender.clone();
        let handler = self.handler.clone();
        let key = self.connection_key.clone();
        let token = self.connection_token.clone();
        let args = ParallelDownloadArgs {
            id: digest.id,
            file_num: digest.file_num,
            remote_path,
            destination,
            file,
        };
        let id = digest.id;
        let completion = tokio::spawn(async move {
            let file_num = args.file_num;
            let result = run_parallel_download(
                handler,
                key,
                token,
                transfer_id.clone(),
                auth_token,
                args,
                mode,
                resume_offset,
                received,
                cancelled,
            )
            .await;
            sender
                .send(Data::ParallelDownloadFinished((
                    id,
                    file_num,
                    transfer_id,
                    result.err().map(|err| err.to_string()),
                )))
                .ok();
        });
        if let Some(pending) = self.parallel_receive_jobs.get_mut(&id) {
            pending.completion = Some(completion);
        }
        true
    }

    async fn start_parallel_clipboard_cache(
        &mut self,
        files: Vec<(String, u64)>,
        peer: &mut Stream,
    ) {
        if files.is_empty() {
            return;
        }
        let mut source_paths = Vec::with_capacity(files.len());
        let mut entries = Vec::with_capacity(files.len());
        for (index, (source, reported_size)) in files.into_iter().enumerate() {
            let path = PathBuf::from(source);
            let Ok(metadata) = std::fs::metadata(&path) else {
                log::warn!(
                    "parallel Explorer clipboard cache skipped missing source {}",
                    path.display()
                );
                #[cfg(target_os = "windows")]
                crate::platform::fail_pending_viewer_drop_cache();
                return;
            };
            if !path.is_absolute() || !metadata.is_file() || metadata.len() != reported_size {
                log::warn!(
                    "parallel Explorer clipboard cache rejected changed source {}",
                    path.display()
                );
                #[cfg(target_os = "windows")]
                crate::platform::fail_pending_viewer_drop_cache();
                return;
            }
            let modified_time = metadata
                .modified()
                .ok()
                .and_then(|time| time.duration_since(std::time::SystemTime::UNIX_EPOCH).ok())
                .map(|duration| duration.as_secs())
                .unwrap_or_default();
            source_paths.push(path);
            entries.push(FileEntry {
                entry_type: FileType::File.into(),
                name: format!("{index:08}.mdclip"),
                size: reported_size,
                modified_time,
                ..Default::default()
            });
        }

        let id = NEXT_PARALLEL_CLIPBOARD_JOB_ID.fetch_sub(1, Ordering::Relaxed);
        let transfer_id = uuid::Uuid::new_v4().to_string();
        #[cfg(target_os = "windows")]
        crate::platform::begin_viewer_drop_cache(&transfer_id);
        let auth_token = uuid::Uuid::new_v4().to_string();
        let mode = configured_parallel_mode();
        let args = ParallelUploadArgs {
            id,
            file_num: 0,
            source_selection: PathBuf::new(),
            destination: String::new(),
            files: entries,
            include_hidden: false,
            source_paths: Some(source_paths),
            clipboard_cache: true,
        };
        let mut action = FileAction::new();
        action.set_receive(FileTransferReceiveRequest {
            id,
            files: args.files.clone(),
            file_num: args.file_num,
            total_size: args.total_size(),
            parallel_transfer_id: transfer_id.clone(),
            parallel_initialize: true,
            parallel_auth_token: auth_token.clone(),
            parallel_clipboard_cache: true,
            ..Default::default()
        });
        let mut message = Message::new();
        message.set_file_action(action);
        self.parallel_send_jobs.insert(
            id,
            ParallelSendJob {
                transfer_id: transfer_id.clone(),
                auth_token,
                args,
                mode,
                sent: Arc::new(AtomicU64::new(0)),
                cancelled: Arc::new(AtomicBool::new(false)),
                started: false,
            },
        );
        log::info!(
            "parallel Explorer clipboard cache {} negotiated initialization, mode={:?}",
            transfer_id,
            mode
        );
        allow_err!(peer.send(&message).await);
    }

    async fn start_legacy_upload(&mut self, args: ParallelUploadArgs, peer: &mut Stream) {
        if args.clipboard_cache {
            log::warn!("Explorer clipboard cache cannot fall back to a destination upload");
            return;
        }
        let od = can_enable_overwrite_detection(self.handler.lc.read().unwrap().version);
        let path = args.source_selection.to_string_lossy().to_string();
        match fs::TransferJob::new_read(
            args.id,
            fs::JobType::Generic,
            args.destination.clone(),
            fs::DataSource::FilePath(args.source_selection.clone()),
            args.file_num,
            args.include_hidden,
            false,
            od,
        ) {
            Ok(job) => {
                self.handler
                    .update_folder_files(job.id(), job.files(), path, true, true);
                #[cfg(not(windows))]
                let files = job.files().clone();
                #[cfg(windows)]
                let mut files = job.files().clone();
                #[cfg(windows)]
                if self.handler.peer_platform() != "Windows" {
                    fs::transform_windows_path(&mut files);
                }
                let total_size = job.total_size();
                self.read_jobs.push(job);
                self.timer = crate::rustdesk_interval(time::interval(MILLI1));
                allow_err!(
                    peer.send(&fs::new_receive(
                        args.id,
                        args.destination,
                        args.file_num,
                        files,
                        total_size,
                    ))
                    .await
                );
            }
            Err(err) => self.handle_job_status(args.id, -1, Some(err.to_string())),
        }
    }

    fn start_parallel_workers(&mut self, transfer_id: &str, resume_offset: u64) {
        if self.parallel_worker_pool.is_none() {
            self.parallel_worker_pool = Some(ParallelWorkerPool::new(
                self.handler.clone(),
                self.connection_key.clone(),
                self.connection_token.clone(),
            ));
        }
        let Some(pool) = self.parallel_worker_pool.clone() else {
            return;
        };
        let Some(job) = self
            .parallel_send_jobs
            .values_mut()
            .find(|job| job.transfer_id == transfer_id)
        else {
            return;
        };
        if job.started {
            return;
        }
        job.started = true;
        job.sent.store(resume_offset, Ordering::Relaxed);
        register_parallel_transfer(
            job.args.id,
            &job.transfer_id,
            job.mode,
            &job.args.label(),
            job.args.total_size(),
            job.args.files.len(),
            job.sent.clone(),
        );
        let sender = self.sender.clone();
        let transfer_id = job.transfer_id.clone();
        let auth_token = job.auth_token.clone();
        let args = job.args.clone();
        let mode = job.mode;
        let sent = job.sent.clone();
        let cancelled = job.cancelled.clone();
        tokio::spawn(async move {
            let result = run_parallel_upload(
                pool,
                &transfer_id,
                &auth_token,
                &args,
                mode,
                resume_offset,
                sent,
                cancelled,
            )
            .await;
            match result {
                Ok(streams) => {
                    mark_parallel_transfer_phase(&transfer_id, PARALLEL_PHASE_COMPLETE);
                    log::info!(
                        "parallel file transfer {} finished sending with {} stream(s)",
                        transfer_id,
                        streams
                    );
                    sender
                        .send(Data::ParallelFinalize((
                            args.id,
                            args.last_file_num(),
                            transfer_id,
                        )))
                        .ok();
                }
                Err(err) => {
                    sender
                        .send(Data::ParallelFailed((
                            args.id,
                            transfer_id,
                            err.to_string(),
                        )))
                        .ok();
                }
            }
        });
    }

    // Start a voice call recorder, records audio and send to remote
    fn start_voice_call(&mut self) -> Option<std::sync::mpsc::Sender<()>> {
        if self.handler.is_file_transfer()
            || self.handler.is_port_forward()
            || self.handler.is_terminal()
        {
            return None;
        }
        // iOS does not have this server.
        #[cfg(not(any(target_os = "ios")))]
        {
            // NOTE:
            // The client server and --server both use the same sound input device.
            // It's better to distinguish the server side and client side.
            // But it' not necessary for now, because it's not a common case.
            // And it is immediately known when the input device is changed.
            crate::audio_service::set_voice_call_input_device(get_default_sound_input(), false);
            // Create a channel to receive error or closed message
            let (tx, rx) = std::sync::mpsc::channel();
            let (tx_audio_data, mut rx_audio_data) =
                hbb_common::tokio::sync::mpsc::unbounded_channel();
            // Create a stand-alone inner, add subscribe to audio service
            let conn_id = CLIENT_SERVER.write().unwrap().get_new_id();
            let client_conn_inner = ConnInner::new(conn_id.clone(), Some(tx_audio_data), None);
            // now we subscribe
            CLIENT_SERVER.write().unwrap().subscribe(
                audio_service::NAME,
                client_conn_inner.clone(),
                true,
            );
            let tx_audio = self.sender.clone();
            std::thread::spawn(move || {
                loop {
                    // check if client is closed
                    match rx.try_recv() {
                        Ok(_) | Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                            log::debug!("Exit voice call audio service of client");
                            // unsubscribe
                            CLIENT_SERVER.write().unwrap().subscribe(
                                audio_service::NAME,
                                client_conn_inner,
                                false,
                            );
                            crate::audio_service::set_voice_call_input_device(None, true);
                            break;
                        }
                        _ => {}
                    }
                    match rx_audio_data.try_recv() {
                        Ok((_instant, msg)) => match &msg.union {
                            Some(message::Union::AudioFrame(frame)) => {
                                let mut msg = Message::new();
                                msg.set_audio_frame(frame.clone());
                                tx_audio.send(Data::Message(msg)).ok();
                            }
                            Some(message::Union::Misc(misc)) => {
                                let mut msg = Message::new();
                                msg.set_misc(misc.clone());
                                tx_audio.send(Data::Message(msg)).ok();
                            }
                            _ => {}
                        },
                        Err(err) => {
                            if err == TryRecvError::Empty {
                                // ignore
                            } else {
                                log::debug!("Failed to record local audio channel: {}", err);
                            }
                        }
                    }
                }
            });
            return Some(tx);
        }
        #[cfg(target_os = "ios")]
        {
            None
        }
    }

    async fn send_close_reason(&mut self, peer: &mut Stream, reason: &str) {
        if self.sent_close_reason {
            return;
        }
        let mut misc = Misc::new();
        misc.set_close_reason(reason.to_owned());
        let mut msg = Message::new();
        msg.set_misc(misc);
        allow_err!(peer.send(&msg).await);
        self.sent_close_reason = true;
    }

    async fn handle_msg_from_ui(&mut self, data: Data, peer: &mut Stream) -> bool {
        match data {
            Data::Close => {
                let parallel_jobs = self
                    .parallel_send_jobs
                    .values()
                    .map(|job| (job.args.id, job.transfer_id.clone(), job.cancelled.clone()))
                    .collect::<Vec<_>>();
                for (id, transfer_id, cancelled) in parallel_jobs {
                    cancelled.store(true, Ordering::Relaxed);
                    mark_parallel_transfer_phase(&transfer_id, PARALLEL_PHASE_FALLBACK);
                    let mut action = FileAction::new();
                    action.set_cancel(FileTransferCancel {
                        id,
                        parallel_transfer_id: transfer_id,
                        keep_partial: true,
                        ..Default::default()
                    });
                    let mut message = Message::new();
                    message.set_file_action(action);
                    allow_err!(peer.send(&message).await);
                }
                for job in self.parallel_receive_jobs.values() {
                    job.cancelled.store(true, Ordering::Relaxed);
                }
                self.send_close_reason(peer, "").await;
                return false;
            }
            Data::Login((os_username, os_password, password, remember)) => {
                self.handler
                    .handle_login_from_ui(os_username, os_password, password, remember, peer)
                    .await;
            }
            #[cfg(all(target_os = "windows", not(feature = "flutter")))]
            Data::ToggleClipboardFile => {
                self.check_clipboard_file_context();
            }
            Data::Message(msg) => {
                match &msg.union {
                    Some(message::Union::Misc(misc)) => match misc.union {
                        Some(misc::Union::RefreshVideo(_)) => {
                            self.video_threads.iter().for_each(|(_, v)| {
                                *v.discard_queue.write().unwrap() = true;
                            });
                        }
                        Some(misc::Union::RefreshVideoDisplay(display)) => {
                            if let Some(v) = self.video_threads.get_mut(&(display as usize)) {
                                *v.discard_queue.write().unwrap() = true;
                            }
                        }
                        _ => {}
                    },
                    _ => {}
                }
                allow_err!(peer.send(&msg).await);
            }
            Data::SendFiles((id, r#type, path, to, file_num, include_hidden, is_remote)) => {
                log::info!("send files, is remote {}", is_remote);
                let od = can_enable_overwrite_detection(self.handler.lc.read().unwrap().version);
                if is_remote {
                    log::debug!("New job {}, write to {} from remote {}", id, to, path);
                    let parallel_download = self.parallel_download_supported(r#type);
                    let destination = PathBuf::from(&to);
                    let to = match r#type {
                        fs::JobType::Generic => fs::DataSource::FilePath(destination),
                        fs::JobType::Printer => {
                            fs::DataSource::MemoryCursor(std::io::Cursor::new(Vec::new()))
                        }
                    };
                    self.write_jobs.push(fs::TransferJob::new_write(
                        id,
                        r#type,
                        path.clone(),
                        to,
                        file_num,
                        include_hidden,
                        is_remote,
                        od,
                    ));
                    if parallel_download {
                        let transfer_id = uuid::Uuid::new_v4().to_string();
                        let auth_token = uuid::Uuid::new_v4().to_string();
                        let message = Self::parallel_download_request(
                            id,
                            path.clone(),
                            file_num,
                            include_hidden,
                            transfer_id.clone(),
                            auth_token.clone(),
                        );
                        self.parallel_receive_jobs.insert(
                            id,
                            ParallelReceiveJob {
                                transfer_id,
                                auth_token,
                                remote_path: path,
                                mode: configured_parallel_mode(),
                                received: Arc::new(AtomicU64::new(0)),
                                cancelled: Arc::new(AtomicBool::new(false)),
                                file: None,
                                started: false,
                                completion: None,
                            },
                        );
                        allow_err!(peer.send(&message).await);
                    } else {
                        allow_err!(
                            peer.send(&fs::new_send(id, r#type, path, file_num, include_hidden))
                                .await
                        );
                    }
                } else {
                    match fs::TransferJob::new_read(
                        id,
                        r#type,
                        to.clone(),
                        fs::DataSource::FilePath(PathBuf::from(&path)),
                        file_num,
                        include_hidden,
                        is_remote,
                        od,
                    ) {
                        Err(err) => {
                            self.handle_job_status(id, -1, Some(err.to_string()));
                        }
                        Ok(job) => {
                            log::debug!(
                                "New job {}, read {} to remote {}, {} files",
                                id,
                                path.clone(),
                                to,
                                job.files().len()
                            );
                            self.handler.update_folder_files(
                                job.id(),
                                job.files(),
                                path.clone(),
                                !is_remote,
                                true,
                            );
                            if self.parallel_upload_supported(&job) {
                                let file = job.files()[0].clone();
                                let source_selection = PathBuf::from(&path);
                                let source = fs::TransferJob::join(&source_selection, &file.name);
                                if source.is_file() {
                                    let transfer_id = uuid::Uuid::new_v4().to_string();
                                    let auth_token = uuid::Uuid::new_v4().to_string();
                                    let mode = configured_parallel_mode();
                                    let args = ParallelUploadArgs {
                                        id,
                                        file_num,
                                        source_selection,
                                        destination: to.clone(),
                                        files: job.files().clone(),
                                        include_hidden,
                                        source_paths: None,
                                        clipboard_cache: false,
                                    };
                                    let mut action = FileAction::new();
                                    action.set_receive(FileTransferReceiveRequest {
                                        id,
                                        path: to,
                                        files: job.files().clone(),
                                        file_num,
                                        total_size: job.total_size(),
                                        parallel_transfer_id: transfer_id.clone(),
                                        parallel_initialize: true,
                                        parallel_auth_token: auth_token.clone(),
                                        ..Default::default()
                                    });
                                    let mut message = Message::new();
                                    message.set_file_action(action);
                                    self.parallel_send_jobs.insert(
                                        id,
                                        ParallelSendJob {
                                            transfer_id: transfer_id.clone(),
                                            auth_token,
                                            args,
                                            mode,
                                            sent: Arc::new(AtomicU64::new(0)),
                                            cancelled: Arc::new(AtomicBool::new(false)),
                                            started: false,
                                        },
                                    );
                                    log::info!(
                                        "parallel file transfer {} negotiated initialization, mode={:?}, size={}",
                                        transfer_id,
                                        mode,
                                        job.total_size()
                                    );
                                    allow_err!(peer.send(&message).await);
                                    return true;
                                }
                            }
                            #[cfg(not(windows))]
                            let files = job.files().clone();
                            #[cfg(windows)]
                            let mut files = job.files().clone();
                            #[cfg(windows)]
                            if self.handler.peer_platform() != "Windows" {
                                // peer is not windows, need transform \ to /
                                fs::transform_windows_path(&mut files);
                            }
                            let total_size = job.total_size();
                            self.read_jobs.push(job);
                            self.timer = crate::rustdesk_interval(time::interval(MILLI1));
                            allow_err!(
                                peer.send(&fs::new_receive(id, to, file_num, files, total_size))
                                    .await
                            );
                        }
                    }
                }
            }
            Data::AddJob((id, r#type, path, to, file_num, include_hidden, is_remote)) => {
                let od = can_enable_overwrite_detection(self.handler.lc.read().unwrap().version);
                if is_remote {
                    log::debug!(
                        "new write waiting job {}, write to {} from remote {}",
                        id,
                        to,
                        path
                    );
                    let mut job = fs::TransferJob::new_write(
                        id,
                        r#type,
                        path.clone(),
                        fs::DataSource::FilePath(PathBuf::from(&to)),
                        file_num,
                        include_hidden,
                        is_remote,
                        od,
                    );
                    job.is_last_job = true;
                    self.write_jobs.push(job);
                } else {
                    match fs::TransferJob::new_read(
                        id,
                        r#type,
                        to.clone(),
                        fs::DataSource::FilePath(PathBuf::from(&path)),
                        file_num,
                        include_hidden,
                        is_remote,
                        od,
                    ) {
                        Err(err) => {
                            self.handle_job_status(id, -1, Some(err.to_string()));
                        }
                        Ok(mut job) => {
                            log::debug!(
                                "new read waiting job {}, read {} to remote {}, {} files",
                                id,
                                path,
                                to,
                                job.files().len()
                            );
                            self.handler.update_folder_files(
                                job.id(),
                                job.files(),
                                path,
                                !is_remote,
                                true,
                            );
                            job.is_last_job = true;
                            self.read_jobs.push(job);
                            self.timer = crate::rustdesk_interval(time::interval(MILLI1));
                        }
                    }
                }
            }
            Data::ResumeJob((id, is_remote)) => {
                if is_remote {
                    let parallel_download = self.parallel_download_supported(fs::JobType::Generic);
                    if let Some(job) = get_job(id, &mut self.write_jobs) {
                        job.is_last_job = false;
                        job.is_resume = true;
                        if parallel_download {
                            let transfer_id = uuid::Uuid::new_v4().to_string();
                            let auth_token = uuid::Uuid::new_v4().to_string();
                            let message = Self::parallel_download_request(
                                id,
                                job.remote.clone(),
                                job.file_num,
                                job.show_hidden,
                                transfer_id.clone(),
                                auth_token.clone(),
                            );
                            self.parallel_receive_jobs.insert(
                                id,
                                ParallelReceiveJob {
                                    transfer_id,
                                    auth_token,
                                    remote_path: job.remote.clone(),
                                    mode: configured_parallel_mode(),
                                    received: Arc::new(AtomicU64::new(0)),
                                    cancelled: Arc::new(AtomicBool::new(false)),
                                    file: None,
                                    started: false,
                                    completion: None,
                                },
                            );
                            allow_err!(peer.send(&message).await);
                        } else {
                            allow_err!(
                                peer.send(&fs::new_send(
                                    id,
                                    fs::JobType::Generic,
                                    job.remote.clone(),
                                    job.file_num,
                                    job.show_hidden
                                ))
                                .await
                            );
                        }
                    }
                } else {
                    let parallel_index = self.read_jobs.iter().position(|job| {
                        job.id() == id
                            && self.parallel_upload_supported(job)
                            && job.files().len() == 1
                            && matches!(&job.data_source, fs::DataSource::FilePath(path)
                                if fs::TransferJob::join(path, &job.files()[0].name).is_file())
                    });
                    if let Some(index) = parallel_index {
                        let job = self.read_jobs.remove(index);
                        let source_selection = match &job.data_source {
                            fs::DataSource::FilePath(path) => path.clone(),
                            fs::DataSource::MemoryCursor(_) => return true,
                        };
                        let transfer_id = uuid::Uuid::new_v4().to_string();
                        let auth_token = uuid::Uuid::new_v4().to_string();
                        let mode = configured_parallel_mode();
                        let args = ParallelUploadArgs {
                            id,
                            file_num: job.file_num,
                            source_selection,
                            destination: job.remote.clone(),
                            files: job.files().clone(),
                            include_hidden: job.show_hidden,
                            source_paths: None,
                            clipboard_cache: false,
                        };
                        let mut action = FileAction::new();
                        action.set_receive(FileTransferReceiveRequest {
                            id,
                            path: args.destination.clone(),
                            files: args.files.clone(),
                            file_num: args.file_num,
                            total_size: args.total_size(),
                            parallel_transfer_id: transfer_id.clone(),
                            parallel_initialize: true,
                            parallel_auth_token: auth_token.clone(),
                            parallel_resume: true,
                            ..Default::default()
                        });
                        let mut message = Message::new();
                        message.set_file_action(action);
                        self.parallel_send_jobs.insert(
                            id,
                            ParallelSendJob {
                                transfer_id: transfer_id.clone(),
                                auth_token,
                                args,
                                mode,
                                sent: Arc::new(AtomicU64::new(0)),
                                cancelled: Arc::new(AtomicBool::new(false)),
                                started: false,
                            },
                        );
                        log::info!(
                            "parallel file transfer {} negotiated resume, mode={:?}",
                            transfer_id,
                            mode
                        );
                        allow_err!(peer.send(&message).await);
                    } else if let Some(job) = get_job(id, &mut self.read_jobs) {
                        match &job.data_source {
                            fs::DataSource::FilePath(_p) => {
                                job.is_last_job = false;
                                job.is_resume = true;
                                job.set_finished_size_on_resume();
                                #[cfg(not(windows))]
                                let files = job.files().clone();
                                #[cfg(windows)]
                                let mut files = job.files().clone();
                                #[cfg(windows)]
                                if self.handler.peer_platform() != "Windows" {
                                    // peer is not windows, need transform \ to /
                                    fs::transform_windows_path(&mut files);
                                }
                                allow_err!(
                                    peer.send(&fs::new_receive(
                                        id,
                                        job.remote.clone(),
                                        job.file_num,
                                        files,
                                        job.total_size(),
                                    ))
                                    .await
                                );
                            }
                            fs::DataSource::MemoryCursor(_) => {
                                // unreachable!()
                                log::error!("Resume job with memory cursor");
                            }
                        }
                    }
                }
            }
            Data::SetNoConfirm(id) => {
                if let Some(job) = self.remove_jobs.get_mut(&id) {
                    job.no_confirm = true;
                }
            }
            Data::ConfirmDeleteFiles((id, file_num)) => {
                if let Some(job) = self.remove_jobs.get_mut(&id) {
                    let i = file_num as usize;
                    if i < job.files.len() {
                        self.handler.ui_handler.confirm_delete_files(
                            id,
                            file_num,
                            job.files[i].name.clone(),
                        );
                    }
                }
            }
            Data::SetConfirmOverrideFile((id, file_num, need_override, remember, is_upload)) => {
                if is_upload {
                    if let Some(job) = fs::get_job(id, &mut self.read_jobs) {
                        if remember {
                            job.set_overwrite_strategy(Some(need_override));
                        }
                        job.confirm(&FileTransferSendConfirmRequest {
                            id,
                            file_num,
                            union: if need_override {
                                Some(file_transfer_send_confirm_request::Union::OffsetBlk(0))
                            } else {
                                Some(file_transfer_send_confirm_request::Union::Skip(true))
                            },
                            ..Default::default()
                        })
                        .await;
                    }
                } else {
                    if let Some(job) = fs::get_job(id, &mut self.write_jobs) {
                        if remember {
                            job.set_overwrite_strategy(Some(need_override));
                        }
                        let mut msg = Message::new();
                        let mut file_action = FileAction::new();
                        let req = FileTransferSendConfirmRequest {
                            id,
                            file_num,
                            union: if need_override {
                                Some(file_transfer_send_confirm_request::Union::OffsetBlk(0))
                            } else {
                                Some(file_transfer_send_confirm_request::Union::Skip(true))
                            },
                            ..Default::default()
                        };
                        job.confirm(&req).await;
                        file_action.set_send_confirm(req);
                        msg.set_file_action(file_action);
                        allow_err!(peer.send(&msg).await);
                    }
                }
            }
            Data::RemoveDirAll((id, path, is_remote, include_hidden)) => {
                let sep = self.handler.get_path_sep(is_remote);
                if is_remote {
                    let mut msg_out = Message::new();
                    let mut file_action = FileAction::new();
                    file_action.set_all_files(ReadAllFiles {
                        id,
                        path: path.clone(),
                        include_hidden,
                        ..Default::default()
                    });
                    msg_out.set_file_action(file_action);
                    allow_err!(peer.send(&msg_out).await);
                    self.remove_jobs
                        .insert(id, RemoveJob::new(Vec::new(), path, sep, is_remote));
                } else {
                    match fs::get_recursive_files(&path, include_hidden) {
                        Ok(entries) => {
                            self.handler.update_folder_files(
                                id,
                                &entries,
                                path.clone(),
                                !is_remote,
                                false,
                            );
                            self.remove_jobs
                                .insert(id, RemoveJob::new(entries, path, sep, is_remote));
                        }
                        Err(err) => {
                            self.handle_job_status(id, -1, Some(err.to_string()));
                        }
                    }
                }
            }
            Data::CancelJob(id) => {
                if let Some(job) = self.parallel_send_jobs.remove(&id) {
                    job.cancelled.store(true, Ordering::Relaxed);
                    mark_parallel_transfer_phase(&job.transfer_id, PARALLEL_PHASE_FALLBACK);
                    if job.args.clipboard_cache {
                        #[cfg(target_os = "windows")]
                        crate::platform::complete_viewer_drop_cache(&job.transfer_id, false);
                    }
                    let mut action = FileAction::new();
                    action.set_cancel(FileTransferCancel {
                        id,
                        parallel_transfer_id: job.transfer_id,
                        ..Default::default()
                    });
                    let mut message = Message::new();
                    message.set_file_action(action);
                    allow_err!(peer.send(&message).await);
                    return true;
                }
                if let Some(mut job) = self.parallel_receive_jobs.remove(&id) {
                    job.cancelled.store(true, Ordering::Relaxed);
                    mark_parallel_transfer_phase(&job.transfer_id, PARALLEL_PHASE_FALLBACK);
                    let mut action = FileAction::new();
                    action.set_cancel(FileTransferCancel {
                        id,
                        parallel_transfer_id: job.transfer_id,
                        ..Default::default()
                    });
                    let mut message = Message::new();
                    message.set_file_action(action);
                    allow_err!(peer.send(&message).await);
                    if let Some(completion) = job.completion.take() {
                        let _ = time::timeout(Duration::from_secs(5), completion).await;
                    }
                    if let Some(job) = fs::remove_job(id, &mut self.write_jobs) {
                        job.remove_download_file();
                    }
                    return true;
                }
                self.cancel_transfer_job(id, peer).await;
            }
            Data::RemoveDir((id, path)) => {
                let mut msg_out = Message::new();
                let mut file_action = FileAction::new();
                file_action.set_remove_dir(FileRemoveDir {
                    id,
                    path,
                    recursive: true,
                    ..Default::default()
                });
                msg_out.set_file_action(file_action);
                allow_err!(peer.send(&msg_out).await);
            }
            Data::RemoveFile((id, path, file_num, is_remote)) => {
                if is_remote {
                    let mut msg_out = Message::new();
                    let mut file_action = FileAction::new();
                    file_action.set_remove_file(FileRemoveFile {
                        id,
                        path,
                        file_num,
                        ..Default::default()
                    });
                    msg_out.set_file_action(file_action);
                    allow_err!(peer.send(&msg_out).await);
                } else {
                    match fs::remove_file(&path) {
                        Err(err) => {
                            self.handle_job_status(id, file_num, Some(err.to_string()));
                        }
                        Ok(()) => {
                            self.handle_job_status(id, file_num, None);
                        }
                    }
                }
            }
            Data::CreateDir((id, path, is_remote)) => {
                if is_remote {
                    let mut msg_out = Message::new();
                    let mut file_action = FileAction::new();
                    file_action.set_create(FileDirCreate {
                        id,
                        path,
                        ..Default::default()
                    });
                    msg_out.set_file_action(file_action);
                    allow_err!(peer.send(&msg_out).await);
                } else {
                    match fs::create_dir(&path) {
                        Err(err) => {
                            self.handle_job_status(id, -1, Some(err.to_string()));
                        }
                        Ok(()) => {
                            self.handle_job_status(id, -1, None);
                        }
                    }
                }
            }
            Data::RenameFile((id, path, new_name, is_remote)) => {
                if is_remote {
                    let mut msg_out = Message::new();
                    let mut file_action = FileAction::new();
                    file_action.set_rename(FileRename {
                        id,
                        path,
                        new_name,
                        ..Default::default()
                    });
                    msg_out.set_file_action(file_action);
                    allow_err!(peer.send(&msg_out).await);
                } else {
                    let err = fs::rename_file(&path, &new_name)
                        .err()
                        .map(|e| e.to_string());
                    self.handle_job_status(id, -1, err);
                }
            }
            Data::RecordScreen(start) => {
                self.handler.lc.write().unwrap().record_state = start;
                self.update_record_state();
            }
            Data::ElevateDirect => {
                let mut request = ElevationRequest::new();
                request.set_direct(true);
                let mut misc = Misc::new();
                misc.set_elevation_request(request);
                let mut msg = Message::new();
                msg.set_misc(misc);
                allow_err!(peer.send(&msg).await);
                self.elevation_requested = true;
            }
            Data::ElevateWithLogon(username, password) => {
                let mut request = ElevationRequest::new();
                request.set_logon(ElevationRequestWithLogon {
                    username,
                    password,
                    ..Default::default()
                });
                let mut misc = Misc::new();
                misc.set_elevation_request(request);
                let mut msg = Message::new();
                msg.set_misc(misc);
                allow_err!(peer.send(&msg).await);
                self.elevation_requested = true;
            }
            Data::NewVoiceCall => {
                let msg = new_voice_call_request(true);
                // Save the voice call request timestamp for the further validation.
                self.voice_call_request_timestamp = Some(
                    NonZeroI64::new(msg.voice_call_request().req_timestamp)
                        .unwrap_or(NonZeroI64::new(get_time()).unwrap()),
                );
                allow_err!(peer.send(&msg).await);
                self.handler.on_voice_call_waiting();
            }
            Data::CloseVoiceCall => {
                self.stop_voice_call();
                let msg = new_voice_call_request(false);
                self.handler
                    .on_voice_call_closed("Closed manually by the peer");
                allow_err!(peer.send(&msg).await);
            }
            Data::ResetDecoder(display) => match display {
                Some(display) => {
                    if let Some(v) = self.video_threads.get_mut(&display) {
                        v.video_sender.send(MediaData::Reset).ok();
                    }
                }
                None => {
                    for (_, v) in self.video_threads.iter_mut() {
                        v.video_sender.send(MediaData::Reset).ok();
                    }
                }
            },
            Data::TakeScreenshot((display, sid)) => {
                let mut msg = Message::new();
                msg.set_screenshot_request(ScreenshotRequest {
                    display,
                    sid,
                    ..Default::default()
                });
                allow_err!(peer.send(&msg).await);
            }
            Data::ParallelFinalize((id, file_num, transfer_id)) => {
                if self
                    .parallel_send_jobs
                    .get(&id)
                    .map(|job| job.transfer_id.as_str())
                    == Some(transfer_id.as_str())
                {
                    let mut response = FileResponse::new();
                    response.set_done(FileTransferDone {
                        id,
                        file_num,
                        parallel_transfer_id: transfer_id,
                        finalize: true,
                        ..Default::default()
                    });
                    let mut message = Message::new();
                    message.set_file_response(response);
                    allow_err!(peer.send(&message).await);
                }
            }
            Data::ParallelFailed((id, transfer_id, err)) => {
                let matches = self
                    .parallel_send_jobs
                    .get(&id)
                    .map(|job| job.transfer_id.as_str())
                    == Some(transfer_id.as_str());
                if matches {
                    if let Some(job) = self.parallel_send_jobs.remove(&id) {
                        job.cancelled.store(true, Ordering::Relaxed);
                        mark_parallel_transfer_phase(&job.transfer_id, PARALLEL_PHASE_FALLBACK);
                        let mut action = FileAction::new();
                        action.set_cancel(FileTransferCancel {
                            id,
                            parallel_transfer_id: transfer_id.clone(),
                            ..Default::default()
                        });
                        let mut message = Message::new();
                        message.set_file_action(action);
                        allow_err!(peer.send(&message).await);
                        log::warn!(
                            "parallel file transfer {} fallback=worker-failure: {}",
                            transfer_id,
                            err
                        );
                        if job.args.clipboard_cache {
                            #[cfg(target_os = "windows")]
                            crate::platform::complete_viewer_drop_cache(&transfer_id, false);
                            self.handler.job_error(id, err.clone(), job.args.file_num);
                            log::warn!(
                                "parallel Explorer clipboard cache {} failed: {}",
                                transfer_id,
                                err
                            );
                        } else {
                            self.start_legacy_upload(job.args, peer).await;
                        }
                    }
                }
            }
            Data::ParallelDownloadFinished((id, file_num, transfer_id, error)) => {
                let matches = self
                    .parallel_receive_jobs
                    .get(&id)
                    .map(|job| job.transfer_id.as_str())
                    == Some(transfer_id.as_str());
                if matches {
                    let completed_job = self.parallel_receive_jobs.remove(&id);
                    let mut action = FileAction::new();
                    action.set_cancel(FileTransferCancel {
                        id,
                        parallel_transfer_id: transfer_id.clone(),
                        keep_partial: error.is_some(),
                        ..Default::default()
                    });
                    let mut message = Message::new();
                    message.set_file_action(action);
                    allow_err!(peer.send(&message).await);
                    match error {
                        Some(err) => {
                            mark_parallel_transfer_phase(&transfer_id, PARALLEL_PHASE_FALLBACK);
                            self.handle_job_status(id, file_num, Some(err));
                        }
                        None => {
                            mark_parallel_transfer_phase(&transfer_id, PARALLEL_PHASE_COMPLETE);
                            fs::remove_job(id, &mut self.write_jobs);
                            let total = completed_job
                                .and_then(|job| job.file.map(|file| file.size))
                                .unwrap_or_default();
                            self.handler.job_progress(id, file_num, 0.0, total as f64);
                            self.handle_job_status(id, file_num, None);
                        }
                    }
                }
            }
            _ => {}
        }
        true
    }

    #[inline]
    fn update_job_status(
        job: &fs::TransferJob,
        elapsed: i32,
        last_update_jobs_status: &mut (Instant, HashMap<i32, u64>),
        handler: &Session<T>,
    ) {
        if elapsed <= 0 {
            return;
        }
        let transferred = job.transferred();
        let last_transferred = {
            if let Some(v) = last_update_jobs_status.1.get(&job.id()) {
                v.to_owned()
            } else {
                0
            }
        };
        last_update_jobs_status.1.insert(job.id(), transferred);
        let speed = (transferred - last_transferred) as f64 / (elapsed as f64 / 1000.);
        let file_num = job.file_num() - 1;
        handler.job_progress(job.id(), file_num, speed, job.finished_size() as f64);
    }

    fn update_jobs_status(&mut self) {
        let elapsed = self.last_update_jobs_status.0.elapsed().as_millis() as i32;
        if elapsed >= TRANSFER_TELEMETRY_INTERVAL.as_millis() as i32 {
            for job in self.read_jobs.iter() {
                Self::update_job_status(
                    job,
                    elapsed,
                    &mut self.last_update_jobs_status,
                    &self.handler,
                );
            }
            for job in self.write_jobs.iter() {
                Self::update_job_status(
                    job,
                    elapsed,
                    &mut self.last_update_jobs_status,
                    &mut self.handler,
                );
            }
            for job in self.parallel_send_jobs.values() {
                let transferred = job.sent.load(Ordering::Relaxed);
                let last_transferred = self
                    .last_update_jobs_status
                    .1
                    .insert(job.args.id, transferred)
                    .unwrap_or_default();
                let speed =
                    transferred.saturating_sub(last_transferred) as f64 / (elapsed as f64 / 1000.0);
                self.handler.job_progress(
                    job.args.id,
                    job.args.file_num,
                    speed,
                    transferred as f64,
                );
            }
            for (id, job) in self.parallel_receive_jobs.iter() {
                if !job.started {
                    continue;
                }
                let transferred = job.received.load(Ordering::Relaxed);
                let last_transferred = self
                    .last_update_jobs_status
                    .1
                    .insert(*id, transferred)
                    .unwrap_or_default();
                let speed =
                    transferred.saturating_sub(last_transferred) as f64 / (elapsed as f64 / 1000.0);
                self.handler.job_progress(*id, 0, speed, transferred as f64);
            }
            self.last_update_jobs_status.0 = Instant::now();
        }
    }

    async fn cancel_transfer_job(&mut self, id: i32, peer: &mut Stream) {
        let mut msg_out = Message::new();
        let mut file_action = FileAction::new();
        file_action.set_cancel(FileTransferCancel {
            id,
            ..Default::default()
        });
        msg_out.set_file_action(file_action);
        allow_err!(peer.send(&msg_out).await);
        if let Some(job) = fs::remove_job(id, &mut self.write_jobs) {
            job.remove_download_file();
        }
        if let Some(job) = self.parallel_receive_jobs.remove(&id) {
            job.cancelled.store(true, Ordering::Relaxed);
        }
        let _ = fs::remove_job(id, &mut self.read_jobs);
        self.remove_jobs.remove(&id);
    }

    pub async fn sync_jobs_status_to_local(&mut self) -> bool {
        if !self.is_connected {
            return false;
        }
        let mut config: PeerConfig = self.handler.load_config();
        let mut transfer_metas = TransferSerde::default();
        for job in self.read_jobs.iter() {
            let json_str = serde_json::to_string(&job.gen_meta()).unwrap_or_default();
            transfer_metas.read_jobs.push(json_str);
        }
        for job in self.parallel_send_jobs.values() {
            let meta = fs::TransferJobMeta {
                id: job.args.id,
                remote: job.args.destination.clone(),
                to: job.args.source_selection.to_string_lossy().to_string(),
                file_num: job.args.file_num,
                show_hidden: job.args.include_hidden,
                is_remote: false,
            };
            let json_str = serde_json::to_string(&meta).unwrap_or_default();
            transfer_metas.read_jobs.push(json_str);
        }
        for job in self.write_jobs.iter() {
            let json_str = serde_json::to_string(&job.gen_meta()).unwrap_or_default();
            transfer_metas.write_jobs.push(json_str);
        }
        log::info!("meta: {:?}", transfer_metas);
        if config.transfer != transfer_metas {
            config.transfer = transfer_metas;
            self.handler.save_config(config);
        }
        true
    }

    async fn send_toggle_virtual_display_msg(&self, peer: &mut Stream) {
        if self.handler.is_view_camera() {
            return;
        }
        if !self.peer_info.is_support_virtual_display() {
            return;
        }
        let lc = self.handler.lc.read().unwrap();
        let displays = lc.get_option("virtual-display");
        for d in displays.split(',') {
            if let Ok(index) = d.parse::<i32>() {
                let mut misc = Misc::new();
                misc.set_toggle_virtual_display(ToggleVirtualDisplay {
                    display: index,
                    on: true,
                    ..Default::default()
                });
                let mut msg_out = Message::new();
                msg_out.set_misc(misc);
                allow_err!(peer.send(&msg_out).await);
            }
        }
    }

    async fn send_toggle_privacy_mode_msg(&self, peer: &mut Stream) {
        if self.handler.is_view_camera() {
            return;
        }
        let lc = self.handler.lc.read().unwrap();
        if lc.version >= hbb_common::get_version_number("1.2.4")
            && lc.get_toggle_option("privacy-mode")
        {
            let impl_key = lc.get_option("privacy-mode-impl-key");
            if impl_key == crate::privacy_mode::PRIVACY_MODE_IMPL_WIN_VIRTUAL_DISPLAY
                && !self.peer_info.is_support_virtual_display()
            {
                return;
            }
            let mut misc = Misc::new();
            misc.set_toggle_privacy_mode(TogglePrivacyMode {
                impl_key,
                on: true,
                ..Default::default()
            });
            let mut msg_out = Message::new();
            msg_out.set_misc(misc);
            allow_err!(peer.send(&msg_out).await);
        }
    }

    fn contains_key_frame(vf: &VideoFrame) -> bool {
        use video_frame::Union::*;
        match &vf.union {
            Some(vf) => match vf {
                Vp8s(f) | Vp9s(f) | Av1s(f) | H264s(f) | H265s(f) => f.frames.iter().any(|e| e.key),
                _ => false,
            },
            None => false,
        }
    }

    // Currently, this function only considers decoding speed and queue length, not network delay.
    // The controlled end can consider auto fps as the maximum decoding fps.
    #[inline]
    fn fps_control(&mut self, direct: bool, real_fps_map: HashMap<usize, i32>) {
        self.video_threads.iter_mut().for_each(|(k, v)| {
            let real_fps = real_fps_map.get(k).cloned().unwrap_or_default();
            if real_fps == 0 {
                v.fps_control.inactive_counter += 1;
            } else {
                v.fps_control.inactive_counter = 0;
            }
        });
        let custom_fps = self.handler.lc.read().unwrap().custom_fps.clone();
        let custom_fps = custom_fps.lock().unwrap().clone();
        let mut custom_fps = custom_fps.unwrap_or(30);
        if custom_fps < 5 || custom_fps > 120 {
            custom_fps = 30;
        }
        let inactive_threshold = 15;
        let max_queue_len = self
            .video_threads
            .iter()
            .map(|v| v.1.video_queue.read().unwrap().len())
            .max()
            .unwrap_or_default();
        let min_decode_fps = self
            .video_threads
            .iter()
            .filter(|v| v.1.fps_control.inactive_counter < inactive_threshold)
            .map(|v| *v.1.decode_fps.read().unwrap())
            .min()
            .flatten();
        let Some(min_decode_fps) = min_decode_fps else {
            return;
        };
        let mut limited_fps = if direct {
            min_decode_fps * 9 / 10 // 30 got 27
        } else {
            min_decode_fps * 4 / 5 // 30 got 24
        };
        if limited_fps > custom_fps {
            limited_fps = custom_fps;
        }
        let last_auto_fps = self.handler.lc.read().unwrap().last_auto_fps.clone();
        let displays = self.video_threads.keys().cloned().collect::<Vec<_>>();
        let mut fps_trending = |display: usize| {
            let thread = self.video_threads.get_mut(&display)?;
            let ctl = &mut thread.fps_control;
            let len = thread.video_queue.read().unwrap().len();
            let decode_fps = thread.decode_fps.read().unwrap().clone()?;
            let last_auto_fps = last_auto_fps.clone().unwrap_or(custom_fps as _);
            if ctl.inactive_counter > inactive_threshold {
                return None;
            }
            if len > 1 && last_auto_fps > limited_fps || len > std::cmp::max(1, decode_fps / 2) {
                ctl.idle_counter = 0;
                return Some(false);
            }
            if len <= 1 {
                ctl.idle_counter += 1;
                if ctl.idle_counter > 3 && last_auto_fps + 3 <= limited_fps {
                    return Some(true);
                }
            }
            if len > 1 {
                ctl.idle_counter = 0;
            }
            None
        };
        let trendings: Vec<_> = displays.iter().map(|k| fps_trending(*k)).collect();
        let should_decrease = trendings.iter().any(|v| *v == Some(false));
        let should_increase = !should_decrease && trendings.iter().any(|v| *v == Some(true));
        if last_auto_fps.is_none() || should_decrease || should_increase {
            // limited_fps to ensure decoding is faster than encoding
            let mut auto_fps = limited_fps;
            if should_decrease && limited_fps < max_queue_len {
                auto_fps = limited_fps / 2;
            }
            if auto_fps < 1 {
                auto_fps = 1;
            }
            if Some(auto_fps) != last_auto_fps {
                let mut misc = Misc::new();
                misc.set_option(OptionMessage {
                    custom_fps: auto_fps as _,
                    ..Default::default()
                });
                let mut msg = Message::new();
                msg.set_misc(misc);
                self.sender.send(Data::Message(msg)).ok();
                log::info!("Set fps to {}", auto_fps);
                self.handler.lc.write().unwrap().last_auto_fps = Some(auto_fps);
            }
        }
        // send refresh
        for (display, thread) in self.video_threads.iter_mut() {
            let ctl = &mut thread.fps_control;
            let video_queue = thread.video_queue.read().unwrap();
            let tolerable = std::cmp::min(min_decode_fps, video_queue.capacity() / 2);
            if ctl.refresh_times < 20 // enough
                    && (video_queue.len() > tolerable
                            && (ctl.refresh_times == 0 || ctl.last_refresh_instant.map(|t|t.elapsed().as_secs() > 10).unwrap_or(false)))
            {
                // Refresh causes client set_display, left frames cause flickering.
                drop(video_queue);
                self.handler.refresh_video(*display as _);
                log::info!("Refresh display {} to reduce delay", display);
                ctl.refresh_times += 1;
                ctl.last_refresh_instant = Some(Instant::now());
            }
        }
    }

    fn check_view_camera_support(&self, peer_version: &str, peer_platform: &str) -> bool {
        if self.peer_info.support_view_camera {
            return true;
        }
        if hbb_common::get_version_number(&peer_version) < hbb_common::get_version_number("1.3.9")
            && (peer_platform == "Windows" || peer_platform == "Linux")
        {
            self.handler.msgbox(
                "error",
                "Download new version",
                "upgrade_remote_rustdesk_client_to_{1.3.9}_tip",
                "",
            );
        } else {
            self.handler.on_error("view_camera_unsupported_tip");
        }
        return false;
    }

    fn check_terminal_support(&self, peer_version: &str) -> bool {
        if self.peer_info.support_terminal {
            return true;
        }
        if hbb_common::get_version_number(&peer_version) < hbb_common::get_version_number("1.4.1") {
            self.handler.msgbox(
                "error",
                "Remote terminal not supported",
                "Remote terminal is not supported by the remote side. Please upgrade to version 1.4.1 or higher.",
                "",
            );
        } else {
            self.handler
                .on_error("Remote terminal is not supported by the remote side");
        }
        return false;
    }

    async fn handle_msg_from_peer(&mut self, data: &[u8], peer: &mut Stream) -> bool {
        if let Ok(msg_in) = Message::parse_from_bytes(&data) {
            match msg_in.union {
                Some(message::Union::VideoFrame(vf)) => {
                    if !self.first_frame {
                        self.first_frame = true;
                        self.handler.close_success();
                        self.handler.adapt_size();
                        self.send_toggle_virtual_display_msg(peer).await;
                        self.send_toggle_privacy_mode_msg(peer).await;
                    }
                    self.video_format = CodecFormat::from(&vf);

                    let display = vf.display as usize;
                    if !self.video_threads.contains_key(&display) {
                        self.new_video_thread(display);
                    }
                    let Some(thread) = self.video_threads.get_mut(&display) else {
                        return true;
                    };
                    if Self::contains_key_frame(&vf) {
                        thread
                            .video_sender
                            .send(MediaData::VideoFrame(Box::new(vf)))
                            .ok();
                    } else {
                        let video_queue = thread.video_queue.read().unwrap();
                        if video_queue.force_push(vf).is_some() {
                            drop(video_queue);
                            self.handler.refresh_video(display as _);
                        } else {
                            thread.video_sender.send(MediaData::VideoQueue).ok();
                        }
                    }
                }
                Some(message::Union::Hash(hash)) => {
                    self.handler
                        .handle_hash(&self.handler.password.clone(), hash, peer)
                        .await;
                }
                Some(message::Union::LoginResponse(lr)) => match lr.union {
                    Some(login_response::Union::Error(err)) => {
                        if err == client::REQUIRE_2FA {
                            self.handler.lc.write().unwrap().enable_trusted_devices =
                                lr.enable_trusted_devices;
                        }
                        if !self.handler.handle_login_error(&err) {
                            return false;
                        }
                    }
                    Some(login_response::Union::PeerInfo(pi)) => {
                        let peer_version = pi.version.clone();
                        let peer_platform = pi.platform.clone();
                        self.set_peer_info(&pi);
                        #[cfg(target_os = "windows")]
                        {
                            let enabled = self.peer_info.support_parallel_clipboard_cache
                                && self.peer_info.platform == "Windows"
                                && !matches!(configured_parallel_mode(), ParallelMode::Fixed(1));
                            let _ = ContextSend::proc(|context| -> ResultType<()> {
                                context
                                    .set_parallel_file_cache_enabled(enabled)
                                    .map_err(|err| err.into())
                            });
                        }
                        if self.handler.is_view_camera() {
                            if !self.check_view_camera_support(&peer_version, &peer_platform) {
                                self.handler.lc.write().unwrap().handle_peer_info(&pi);
                                return false;
                            }
                        }
                        if self.handler.is_terminal() {
                            if !self.check_terminal_support(&peer_version) {
                                self.handler.lc.write().unwrap().handle_peer_info(&pi);
                                return false;
                            }
                        }
                        self.handler.handle_peer_info(pi);
                        #[cfg(all(target_os = "windows", not(feature = "flutter")))]
                        self.check_clipboard_file_context();
                        if self.handler.is_default() {
                            #[cfg(feature = "flutter")]
                            #[cfg(not(target_os = "ios"))]
                            let rx = Client::try_start_clipboard(None);
                            #[cfg(not(feature = "flutter"))]
                            #[cfg(not(any(target_os = "android", target_os = "ios")))]
                            let rx = Client::try_start_clipboard(Some(
                                crate::client::ClientClipboardContext {
                                    cfg: self.handler.get_permission_config(),
                                    tx: self.sender.clone(),
                                    #[cfg(feature = "unix-file-copy-paste")]
                                    is_file_supported: crate::is_support_file_copy_paste(
                                        &peer_version,
                                    ),
                                },
                            ));
                            // To make sure current text clipboard data is updated.
                            #[cfg(not(target_os = "ios"))]
                            if let Some(mut rx) = rx {
                                timeout(CLIPBOARD_INTERVAL, rx.recv()).await.ok();
                            }

                            #[cfg(not(any(target_os = "android", target_os = "ios")))]
                            if self.handler.lc.read().unwrap().sync_init_clipboard.v {
                                if let Some(msg_out) = crate::clipboard::get_current_clipboard_msg(
                                    &peer_version,
                                    &peer_platform,
                                    crate::clipboard::ClipboardSide::Client,
                                ) {
                                    let sender = self.sender.clone();
                                    let permission_config = self.handler.get_permission_config();
                                    tokio::spawn(async move {
                                        if permission_config.is_text_clipboard_required() {
                                            sender.send(Data::Message(msg_out)).ok();
                                        }
                                    });
                                }
                            }
                            // to-do: Android, is `sync_init_clipboard` really needed?
                            // https://github.com/rustdesk/rustdesk/discussions/9010

                            #[cfg(feature = "flutter")]
                            #[cfg(not(target_os = "ios"))]
                            crate::flutter::update_text_clipboard_required();

                            #[cfg(all(feature = "flutter", feature = "unix-file-copy-paste"))]
                            crate::flutter::update_file_clipboard_required();

                            // on connection established client
                            #[cfg(all(feature = "flutter", feature = "plugin_framework"))]
                            #[cfg(not(any(target_os = "android", target_os = "ios")))]
                            crate::plugin::handle_listen_event(
                                crate::plugin::EVENT_ON_CONN_CLIENT.to_owned(),
                                self.handler.get_id(),
                            );
                        }

                        if self.handler.is_file_transfer() {
                            self.handler.load_last_jobs();
                        }

                        self.is_connected = true;
                    }
                    _ => {}
                },
                Some(message::Union::CursorData(cd)) => {
                    self.handler.set_cursor_data(cd);
                }
                Some(message::Union::CursorId(id)) => {
                    self.handler.set_cursor_id(id.to_string());
                }
                Some(message::Union::CursorPosition(cp)) => {
                    self.handler.set_cursor_position(cp);
                }
                Some(message::Union::Clipboard(cb)) => {
                    let clipboard_allowed = {
                        let lc = self.handler.lc.read().unwrap();
                        !lc.disable_clipboard.v && !lc.view_only.v
                    };
                    if clipboard_allowed {
                        #[cfg(not(any(target_os = "android", target_os = "ios")))]
                        update_clipboard(vec![cb], ClipboardSide::Client);
                        #[cfg(target_os = "ios")]
                        {
                            let content = if cb.compress {
                                hbb_common::compress::decompress(&cb.content)
                            } else {
                                cb.content.into()
                            };
                            if let Ok(content) = String::from_utf8(content) {
                                self.handler.clipboard(content);
                            }
                        }
                        #[cfg(target_os = "android")]
                        crate::clipboard::handle_msg_clipboard(cb);
                    }
                }
                Some(message::Union::MultiClipboards(_mcb)) => {
                    let clipboard_allowed = {
                        let lc = self.handler.lc.read().unwrap();
                        !lc.disable_clipboard.v && !lc.view_only.v
                    };
                    if clipboard_allowed {
                        #[cfg(not(any(target_os = "android", target_os = "ios")))]
                        update_clipboard(_mcb.clipboards, ClipboardSide::Client);
                        #[cfg(target_os = "ios")]
                        {
                            if let Some(cb) = _mcb
                                .clipboards
                                .iter()
                                .find(|c| c.format.enum_value() == Ok(ClipboardFormat::Text))
                            {
                                let content = if cb.compress {
                                    hbb_common::compress::decompress(&cb.content)
                                } else {
                                    cb.content.to_vec()
                                };
                                if let Ok(content) = String::from_utf8(content) {
                                    self.handler.clipboard(content);
                                }
                            }
                        }
                        #[cfg(target_os = "android")]
                        crate::clipboard::handle_msg_multi_clipboards(_mcb);
                    }
                }
                #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
                Some(message::Union::Cliprdr(clip)) => {
                    self.handle_cliprdr_msg(clip, peer).await;
                }
                Some(message::Union::FileResponse(fr)) => {
                    match fr.union {
                        Some(file_response::Union::EmptyDirs(res)) => {
                            self.handler.update_empty_dirs(res);
                        }
                        Some(file_response::Union::Dir(fd)) => {
                            #[cfg(windows)]
                            let entries = fd.entries.to_vec();
                            #[cfg(not(windows))]
                            let mut entries = fd.entries.to_vec();
                            #[cfg(not(windows))]
                            {
                                if self.handler.peer_platform() == "Windows" {
                                    fs::transform_windows_path(&mut entries);
                                }
                            }
                            // We cannot call cancel_transfer_job/handle_job_status while holding
                            // a mutable borrow from fs::get_job(&mut self.write_jobs), so defer
                            // the error handling until after the borrow scope ends.
                            let mut set_files_err = None;
                            if let Some(pending) = self.parallel_receive_jobs.get_mut(&fd.id) {
                                pending.file = if entries.len() == 1 {
                                    entries.first().cloned()
                                } else {
                                    None
                                };
                            }
                            if entries.len() != 1 {
                                self.cancel_pending_parallel_download(fd.id, peer).await;
                            }
                            if let Some(job) = fs::get_job(fd.id, &mut self.write_jobs) {
                                log::info!("job set_files: {:?}", entries);
                                if let Err(err) = job.set_files(entries.clone()) {
                                    set_files_err = Some(err.to_string());
                                } else {
                                    job.set_finished_size_on_resume();
                                    self.handler.update_folder_files(
                                        fd.id,
                                        job.files(),
                                        fd.path,
                                        false,
                                        false,
                                    );
                                }
                            } else if let Some(job) = self.remove_jobs.get_mut(&fd.id) {
                                // Intentionally keep raw entries here:
                                // - remote remove flow executes deletions on peer side;
                                // - local remove flow is populated from local get_recursive_files().
                                job.files = entries;
                                self.handler
                                    .update_folder_files(fd.id, &job.files, fd.path, false, false);
                            } else {
                                self.handler
                                    .update_folder_files(fd.id, &entries, fd.path, false, false);
                            }
                            if let Some(err) = set_files_err {
                                log::warn!(
                                    "Rejected unsafe file list from remote peer for job {}: {}",
                                    fd.id,
                                    err
                                );
                                self.cancel_transfer_job(fd.id, peer).await;
                                self.handle_job_status(fd.id, -1, Some(err));
                            }
                        }
                        Some(file_response::Union::Digest(digest)) => {
                            if self.parallel_receive_jobs.contains_key(&digest.id)
                                && self.try_start_parallel_download(&digest, peer).await
                            {
                                return true;
                            }
                            if !digest.parallel_transfer_id.is_empty() {
                                if let Some(id) =
                                    self.parallel_send_jobs.iter().find_map(|(id, job)| {
                                        (job.transfer_id == digest.parallel_transfer_id)
                                            .then_some(*id)
                                    })
                                {
                                    if let Some(job) = self.parallel_send_jobs.remove(&id) {
                                        job.cancelled.store(true, Ordering::Relaxed);
                                        mark_parallel_transfer_phase(
                                            &job.transfer_id,
                                            PARALLEL_PHASE_FALLBACK,
                                        );
                                        let mut action = FileAction::new();
                                        action.set_cancel(FileTransferCancel {
                                            id,
                                            parallel_transfer_id: job.transfer_id.clone(),
                                            ..Default::default()
                                        });
                                        let mut message = Message::new();
                                        message.set_file_action(action);
                                        allow_err!(peer.send(&message).await);
                                        log::info!(
                                                "parallel file transfer {} fallback=destination-conflict",
                                                job.transfer_id
                                            );
                                        if job.args.clipboard_cache {
                                            #[cfg(target_os = "windows")]
                                            crate::platform::complete_viewer_drop_cache(
                                                &job.transfer_id,
                                                false,
                                            );
                                            self.handler.job_error(
                                                id,
                                                "destination conflict".to_owned(),
                                                job.args.file_num,
                                            );
                                            log::warn!(
                                                "parallel Explorer clipboard cache {} rejected by destination",
                                                job.transfer_id
                                            );
                                        } else {
                                            self.start_legacy_upload(job.args, peer).await;
                                        }
                                    }
                                }
                                return true;
                            }
                            if digest.is_upload {
                                if let Some(job) = fs::get_job(digest.id, &mut self.read_jobs) {
                                    if let Some(file) = job.files().get(digest.file_num as usize) {
                                        if let fs::DataSource::FilePath(p) = &job.data_source {
                                            let read_path =
                                                get_string(&fs::TransferJob::join(p, &file.name));
                                            let mut overwrite_strategy =
                                                job.default_overwrite_strategy();
                                            let mut offset = 0u64;
                                            if digest.is_identical && job.is_resume {
                                                if digest.transferred_size > 0 {
                                                    overwrite_strategy = Some(true);
                                                    offset = digest.transferred_size;
                                                }
                                            }
                                            if let Some(overwrite) = overwrite_strategy {
                                                let req = FileTransferSendConfirmRequest {
                                                    id: digest.id,
                                                    file_num: digest.file_num,
                                                    union: Some(if overwrite {
                                                        file_transfer_send_confirm_request::Union::OffsetBlk(
                                                            offset.min(u32::MAX as u64) as u32,
                                                        )
                                                    } else {
                                                        file_transfer_send_confirm_request::Union::Skip(
                                                            true,
                                                        )
                                                    }),
                                                    parallel_resume_offset: offset,
                                                    ..Default::default()
                                                };
                                                job.confirm(&req).await;
                                                let msg = new_send_confirm(req);
                                                allow_err!(peer.send(&msg).await);
                                            } else {
                                                self.handler.override_file_confirm(
                                                    digest.id,
                                                    digest.file_num,
                                                    read_path,
                                                    true,
                                                    digest.is_identical,
                                                );
                                            }
                                        }
                                    }
                                }
                            } else {
                                if let Some(job) = fs::get_job(digest.id, &mut self.write_jobs) {
                                    if let Some(file) = job.files().get(digest.file_num as usize) {
                                        if let fs::DataSource::FilePath(p) = &job.data_source {
                                            let write_path =
                                                get_string(&fs::TransferJob::join(p, &file.name));
                                            job.set_digest(digest.file_size, digest.last_modified);
                                            let peer_ver = self.handler.lc.read().unwrap().version;
                                            let is_support_resume =
                                                crate::is_support_file_transfer_resume_num(
                                                    peer_ver,
                                                );
                                            match fs::is_write_need_confirmation(
                                                is_support_resume && job.is_resume,
                                                &write_path,
                                                &digest,
                                            ) {
                                                Ok(res) => match res {
                                                    DigestCheckResult::IsSame => {
                                                        let req = FileTransferSendConfirmRequest {
                                                            id: digest.id,
                                                            file_num: digest.file_num,
                                                            union: Some(file_transfer_send_confirm_request::Union::Skip(true)),
                                                            ..Default::default()
                                                        };
                                                        job.confirm(&req).await;
                                                        let msg = new_send_confirm(req);
                                                        allow_err!(peer.send(&msg).await);
                                                    }
                                                    DigestCheckResult::NeedConfirm(digest) => {
                                                        let mut overwrite_strategy =
                                                            job.default_overwrite_strategy();
                                                        let mut offset = 0u64;
                                                        if digest.is_identical
                                                            && job.is_resume
                                                            && digest.transferred_size > 0
                                                        {
                                                            overwrite_strategy = Some(true);
                                                            offset = digest.transferred_size;
                                                        }
                                                        if let Some(overwrite) = overwrite_strategy
                                                        {
                                                            let req =
                                                                FileTransferSendConfirmRequest {
                                                                    id: digest.id,
                                                                    file_num: digest.file_num,
                                                                    union: Some(if overwrite {
                                                                        file_transfer_send_confirm_request::Union::OffsetBlk(
                                                                            offset.min(u32::MAX as u64) as u32,
                                                                        )
                                                                    } else {
                                                                        file_transfer_send_confirm_request::Union::Skip(true)
                                                                    }),
                                                                    parallel_resume_offset: offset,
                                                                    ..Default::default()
                                                                };
                                                            job.confirm(&req).await;
                                                            let msg = new_send_confirm(req);
                                                            allow_err!(peer.send(&msg).await);
                                                        } else {
                                                            self.handler.override_file_confirm(
                                                                digest.id,
                                                                digest.file_num,
                                                                write_path,
                                                                false,
                                                                digest.is_identical,
                                                            );
                                                        }
                                                    }
                                                    DigestCheckResult::NoSuchFile => {
                                                        let req = FileTransferSendConfirmRequest {
                                                        id: digest.id,
                                                        file_num: digest.file_num,
                                                        union: Some(file_transfer_send_confirm_request::Union::OffsetBlk(0)),
                                                        ..Default::default()
                                                    };
                                                        job.confirm(&req).await;
                                                        let msg = new_send_confirm(req);
                                                        allow_err!(peer.send(&msg).await);
                                                    }
                                                },
                                                Err(err) => {
                                                    println!("error receiving digest: {}", err);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        Some(file_response::Union::Block(block)) => {
                            if let Some(job) = fs::get_job(block.id, &mut self.write_jobs) {
                                if let Err(_err) = job.write(block).await {
                                    // to-do: add "skip" for writing job
                                }
                                if job.r#type == fs::JobType::Generic {
                                    self.update_jobs_status();
                                }
                            }
                        }
                        Some(file_response::Union::Done(d)) => {
                            if d.transfer_complete && !d.parallel_transfer_id.is_empty() {
                                if let Some(job) = self.parallel_send_jobs.remove(&d.id) {
                                    job.cancelled.store(true, Ordering::Relaxed);
                                    if job.args.clipboard_cache {
                                        #[cfg(target_os = "windows")]
                                        crate::platform::complete_viewer_drop_cache(
                                            &d.parallel_transfer_id,
                                            true,
                                        );
                                        self.handler.job_progress(
                                            d.id,
                                            d.file_num,
                                            0.0,
                                            job.args.total_size() as f64,
                                        );
                                        self.handler.job_done(d.id, d.file_num);
                                        log::info!(
                                            "parallel Explorer clipboard cache {} is ready",
                                            d.parallel_transfer_id
                                        );
                                    } else {
                                        self.handler.job_progress(
                                            d.id,
                                            d.file_num,
                                            0.0,
                                            job.args.total_size() as f64,
                                        );
                                        self.handle_job_status(d.id, d.file_num, None);
                                    }
                                }
                                return true;
                            }
                            let mut err: Option<String> = None;
                            let mut job_type = fs::JobType::Generic;
                            let mut printer_data = None;
                            if let Some(job) = fs::remove_job(d.id, &mut self.write_jobs) {
                                job.modify_time();
                                err = job.job_error();
                                job_type = job.r#type;
                                printer_data = match job.get_buf_data().await {
                                    Ok(d) => d,
                                    Err(e) => {
                                        log::error!("Failed to get the printer data: {}", e);
                                        None
                                    }
                                };
                            }
                            match job_type {
                                fs::JobType::Generic => {
                                    self.handle_job_status(d.id, d.file_num, err);
                                }
                                fs::JobType::Printer => {
                                    if let Some(err) = err {
                                        log::error!("Receive print job failed, error {err}");
                                    } else {
                                        log::info!(
                                            "Receive print job done, data len: {:?}",
                                            printer_data.as_ref().map(|d| d.len()).unwrap_or(0)
                                        );
                                        #[cfg(target_os = "windows")]
                                        if let Some(data) = printer_data {
                                            let printer_name = self
                                                .handler
                                                .printer_names
                                                .write()
                                                .unwrap()
                                                .remove(&d.id);
                                            // Spawn a new thread to handle the print job.
                                            // Or print job will block the ui thread.
                                            std::thread::spawn(move || {
                                                if let Err(e) =
                                                    crate::platform::send_raw_data_to_printer(
                                                        printer_name,
                                                        data,
                                                    )
                                                {
                                                    log::error!("Print job error: {}", e);
                                                }
                                            });
                                        }
                                    }
                                }
                            }
                        }
                        Some(file_response::Union::Error(e)) => {
                            if !e.parallel_transfer_id.is_empty() {
                                if let Some(job) = self.parallel_send_jobs.remove(&e.id) {
                                    job.cancelled.store(true, Ordering::Relaxed);
                                    mark_parallel_transfer_phase(
                                        &job.transfer_id,
                                        PARALLEL_PHASE_FALLBACK,
                                    );
                                    log::warn!(
                                        "parallel file transfer {} receiver fallback: {}",
                                        job.transfer_id,
                                        e.error
                                    );
                                    if job.args.clipboard_cache {
                                        self.handler.job_error(
                                            e.id,
                                            e.error.clone(),
                                            job.args.file_num,
                                        );
                                        let mut action = FileAction::new();
                                        action.set_cancel(FileTransferCancel {
                                            id: e.id,
                                            parallel_transfer_id: job.transfer_id,
                                            ..Default::default()
                                        });
                                        let mut message = Message::new();
                                        message.set_file_action(action);
                                        allow_err!(peer.send(&message).await);
                                    } else {
                                        self.start_legacy_upload(job.args, peer).await;
                                    }
                                }
                                return true;
                            }
                            let job_type = fs::remove_job(e.id, &mut self.write_jobs)
                                .or_else(|| fs::remove_job(e.id, &mut self.read_jobs))
                                .map(|j| j.r#type)
                                .unwrap_or(fs::JobType::Generic);
                            match job_type {
                                fs::JobType::Generic => {
                                    self.handle_job_status(e.id, e.file_num, Some(e.error));
                                }
                                fs::JobType::Printer => {
                                    log::error!("Printer job error: {}", e.error);
                                }
                            }
                        }
                        _ => {}
                    }
                }
                Some(message::Union::Misc(misc)) => match misc.union {
                    Some(misc::Union::AudioFormat(f)) => {
                        self.audio_sender.send(MediaData::AudioFormat(f)).ok();
                    }
                    Some(misc::Union::ChatMessage(c)) => {
                        self.handler.new_message(c.text);
                    }
                    Some(misc::Union::PermissionInfo(p)) => {
                        log::info!("Change permission {:?} -> {}", p.permission, p.enabled);
                        // https://github.com/rustdesk/rustdesk/issues/3703#issuecomment-1474734754
                        match p.permission.enum_value() {
                            Ok(Permission::Keyboard) => {
                                *self.handler.server_keyboard_enabled.write().unwrap() = p.enabled;
                                #[cfg(feature = "flutter")]
                                #[cfg(not(target_os = "ios"))]
                                crate::flutter::update_text_clipboard_required();
                                #[cfg(all(feature = "flutter", feature = "unix-file-copy-paste"))]
                                crate::flutter::update_file_clipboard_required();
                                self.handler.set_permission("keyboard", p.enabled);
                            }
                            Ok(Permission::Clipboard) => {
                                *self.handler.server_clipboard_enabled.write().unwrap() = p.enabled;
                                #[cfg(feature = "flutter")]
                                #[cfg(not(target_os = "ios"))]
                                crate::flutter::update_text_clipboard_required();
                                self.handler.set_permission("clipboard", p.enabled);
                            }
                            Ok(Permission::Audio) => {
                                self.handler.set_permission("audio", p.enabled);
                            }
                            Ok(Permission::File) => {
                                *self.handler.server_file_transfer_enabled.write().unwrap() =
                                    p.enabled;
                                if !p.enabled && self.handler.is_file_transfer() {
                                    return true;
                                }
                                #[cfg(all(feature = "flutter", feature = "unix-file-copy-paste"))]
                                crate::flutter::update_file_clipboard_required();
                                self.handler.set_permission("file", p.enabled);
                                #[cfg(feature = "unix-file-copy-paste")]
                                if !p.enabled {
                                    try_empty_clipboard_files(
                                        ClipboardSide::Client,
                                        self.client_conn_id,
                                    );
                                }
                            }
                            Ok(Permission::Restart) => {
                                self.handler.set_permission("restart", p.enabled);
                            }
                            Ok(Permission::Recording) => {
                                self.handler.lc.write().unwrap().record_permission = p.enabled;
                                self.update_record_state();
                                self.handler.set_permission("recording", p.enabled);
                            }
                            Ok(Permission::BlockInput) => {
                                self.handler.set_permission("block_input", p.enabled);
                            }
                            Ok(Permission::PrivacyMode) => {
                                self.handler.set_permission("privacy_mode", p.enabled);
                            }
                            _ => {}
                        }
                    }
                    Some(misc::Union::KeyboardLayout(layout)) => {
                        // Older candidates reported the peer KLID after a fixed
                        // delay. That value can be stale and undo the local
                        // Windows shortcut. The controller OS is authoritative.
                        log::debug!(
                            "Ignored peer keyboard layout {}; local platform owns modifier shortcuts",
                            layout.klid
                        );
                    }
                    Some(misc::Union::SwitchDisplay(s)) => {
                        self.handler.handle_peer_switch_display(&s);
                        if let Some(thread) = self.video_threads.get_mut(&(s.display as usize)) {
                            thread.video_sender.send(MediaData::Reset).ok();
                        }

                        let mut scale = 1.0;
                        if let Some(pi) = &self.handler.lc.read().unwrap().peer_info {
                            if let Some(d) = pi.displays.get(s.display as usize) {
                                scale = d.scale;
                            }
                        }

                        if s.width > 0 && s.height > 0 {
                            self.handler.set_display(
                                s.x,
                                s.y,
                                s.width,
                                s.height,
                                s.cursor_embedded,
                                scale,
                            );
                        }
                    }
                    Some(misc::Union::CloseReason(c)) => {
                        self.sent_close_reason = true; // The controlled end will close, no need to send close reason
                        self.handler.msgbox("error", "Connection Error", &c, "");
                        return false;
                    }
                    Some(misc::Union::RestartRemoteDeviceError(error)) => {
                        self.handler
                            .get_lch()
                            .write()
                            .unwrap()
                            .clear_restarting_remote_device();
                        self.handler
                            .msgbox("error", "Restart remote device", &error, "");
                    }
                    Some(misc::Union::BackNotification(notification)) => {
                        if !self.handle_back_notification(notification).await {
                            return false;
                        }
                    }
                    Some(misc::Union::Uac(uac)) => {
                        let keyboard = self.handler.server_keyboard_enabled.read().unwrap().clone();
                        #[cfg(feature = "flutter")]
                        {
                            if uac && keyboard {
                                self.handler.msgbox(
                                    "on-uac",
                                    "Prompt",
                                    "Please wait for confirmation of UAC...",
                                    "",
                                );
                            } else {
                                self.handler.cancel_msgbox("on-uac");
                                self.handler.cancel_msgbox("wait-uac");
                                self.handler.cancel_msgbox("elevation-error");
                            }
                        }
                        #[cfg(not(feature = "flutter"))]
                        {
                            let msgtype = "custom-uac-nocancel";
                            let title = "Prompt";
                            let text = "Please wait for confirmation of UAC...";
                            let link = "";
                            if uac && keyboard {
                                self.handler.msgbox(msgtype, title, text, link);
                            } else {
                                self.handler.cancel_msgbox(&format!(
                                    "{}-{}-{}-{}",
                                    msgtype, title, text, link,
                                ));
                            }
                        }
                    }
                    Some(misc::Union::ForegroundWindowElevated(elevated)) => {
                        let keyboard = self.handler.server_keyboard_enabled.read().unwrap().clone();
                        #[cfg(feature = "flutter")]
                        {
                            if elevated && keyboard {
                                self.handler.msgbox(
                                    "on-foreground-elevated",
                                    "Prompt",
                                    "elevated_foreground_window_tip",
                                    "",
                                );
                            } else {
                                self.handler.cancel_msgbox("on-foreground-elevated");
                                self.handler.cancel_msgbox("wait-uac");
                                self.handler.cancel_msgbox("elevation-error");
                            }
                        }
                        #[cfg(not(feature = "flutter"))]
                        {
                            let msgtype = "custom-elevated-foreground-nocancel";
                            let title = "Prompt";
                            let text = "elevated_foreground_window_tip";
                            let link = "";
                            if elevated && keyboard {
                                self.handler.msgbox(msgtype, title, text, link);
                            } else {
                                self.handler.cancel_msgbox(&format!(
                                    "{}-{}-{}-{}",
                                    msgtype, title, text, link,
                                ));
                            }
                        }
                    }
                    Some(misc::Union::ElevationResponse(err)) => {
                        if err.is_empty() {
                            self.handler.msgbox("wait-uac", "", "", "");
                        } else {
                            self.handler.cancel_msgbox("wait-uac");
                            self.handler
                                .msgbox("elevation-error", "Elevation Error", &err, "");
                        }
                    }
                    Some(misc::Union::PortableServiceRunning(b)) => {
                        self.handler.portable_service_running(b);
                        if self.elevation_requested && b {
                            self.handler.msgbox(
                                "custom-nocancel-success",
                                "Successful",
                                "Elevate successfully",
                                "",
                            );
                        }
                    }
                    #[cfg(feature = "flutter")]
                    #[cfg(not(any(target_os = "android", target_os = "ios")))]
                    Some(misc::Union::SwitchBack(_)) => {
                        let allow_switch_back = self
                            .handler
                            .lc
                            .write()
                            .unwrap()
                            .consume_switch_back_permission();
                        if allow_switch_back {
                            self.handler.switch_back(&self.handler.get_id());
                        } else {
                            log::warn!(
                                "Ignored unsolicited SwitchBack from {}",
                                self.handler.get_id()
                            );
                        }
                    }
                    #[cfg(all(feature = "flutter", feature = "plugin_framework"))]
                    #[cfg(not(any(target_os = "android", target_os = "ios")))]
                    Some(misc::Union::PluginRequest(p)) => {
                        allow_err!(crate::plugin::handle_server_event(
                            &p.id,
                            &self.handler.get_id(),
                            &p.content
                        ));
                        // to-do: show message box on UI when error occurs?
                    }
                    #[cfg(all(feature = "flutter", feature = "plugin_framework"))]
                    #[cfg(not(any(target_os = "android", target_os = "ios")))]
                    Some(misc::Union::PluginFailure(p)) => {
                        let name = if p.name.is_empty() {
                            "plugin".to_string()
                        } else {
                            p.name
                        };
                        self.handler.msgbox("custom-nocancel", &name, &p.msg, "");
                    }
                    Some(misc::Union::SupportedEncoding(e)) => {
                        log::info!("update supported encoding:{:?}", e);
                        self.handler.lc.write().unwrap().supported_encoding = e;
                    }
                    Some(misc::Union::FollowCurrentDisplay(d_idx)) => {
                        self.handler.set_current_display(d_idx);
                    }
                    _ => {}
                },
                Some(message::Union::TestDelay(t)) => {
                    self.handler.handle_test_delay(t, peer).await;
                }
                Some(message::Union::AudioFrame(frame)) => {
                    if !self.handler.lc.read().unwrap().disable_audio.v {
                        self.audio_sender
                            .send(MediaData::AudioFrame(Box::new(frame)))
                            .ok();
                    }
                }
                Some(message::Union::FileAction(action)) => match action.union {
                    Some(file_action::Union::Send(_s)) => match _s.file_type.enum_value() {
                        #[cfg(target_os = "windows")]
                        Ok(file_transfer_send_request::FileType::Printer) => {
                            #[cfg(feature = "flutter")]
                            let action = LocalConfig::get_option(
                                config::keys::OPTION_PRINTER_INCOMING_JOB_ACTION,
                            );
                            #[cfg(not(feature = "flutter"))]
                            let action = "";
                            if action == "dismiss" {
                                // Just ignore the incoming print job.
                            } else {
                                let id = fs::get_next_job_id();
                                #[cfg(feature = "flutter")]
                                let allow_auto_print = LocalConfig::get_bool_option(
                                    config::keys::OPTION_PRINTER_ALLOW_AUTO_PRINT,
                                );
                                #[cfg(not(feature = "flutter"))]
                                let allow_auto_print = false;
                                if allow_auto_print {
                                    let printer_name = if action == "" {
                                        "".to_string()
                                    } else {
                                        LocalConfig::get_option(
                                            config::keys::OPTION_PRINTER_SELECTED_NAME,
                                        )
                                    };
                                    self.handler.printer_response(id, _s.path, printer_name);
                                } else {
                                    self.handler.printer_request(id, _s.path);
                                }
                            }
                        }
                        _ => {}
                    },
                    Some(file_action::Union::SendConfirm(c)) => {
                        if !c.parallel_transfer_id.is_empty() {
                            if !c.skip() {
                                self.start_parallel_workers(
                                    &c.parallel_transfer_id,
                                    c.parallel_resume_offset,
                                );
                            }
                            return true;
                        }
                        if let Some(job) = fs::get_job(c.id, &mut self.read_jobs) {
                            job.confirm(&c).await;
                        }
                    }
                    _ => {}
                },
                Some(message::Union::MessageBox(msgbox)) => {
                    let mut link = msgbox.link;
                    if let Some(v) = config::HELPER_URL.get(&link as &str) {
                        link = v.to_string();
                    } else {
                        log::warn!("Message box ignore link {} for security", &link);
                        link = "".to_string();
                    }
                    self.handler
                        .msgbox(&msgbox.msgtype, &msgbox.title, &msgbox.text, &link);
                }
                Some(message::Union::VoiceCallRequest(request)) => {
                    if request.is_connect {
                        // TODO: maybe we will do a voice call from the peer in the future.
                    } else {
                        log::debug!("The remote has requested to close the voice call");
                        if let Some(sender) = self.stop_voice_call_sender.take() {
                            allow_err!(sender.send(()));
                            self.handler.on_voice_call_closed("");
                        }
                    }
                }
                Some(message::Union::VoiceCallResponse(response)) => {
                    let ts = std::mem::replace(&mut self.voice_call_request_timestamp, None);
                    if let Some(ts) = ts {
                        if response.req_timestamp != ts.get() {
                            log::debug!("Possible encountering a voice call attack.");
                        } else {
                            if response.accepted {
                                // The peer accepted the voice call.
                                self.handler.on_voice_call_started();
                                self.stop_voice_call_sender = self.start_voice_call();
                            } else {
                                // The peer refused the voice call.
                                self.handler.on_voice_call_closed("");
                            }
                        }
                    }
                }
                Some(message::Union::PeerInfo(pi)) => {
                    self.handler.set_displays(&pi.displays);
                    self.handler.set_platform_additions(&pi.platform_additions);
                }
                Some(message::Union::ScreenshotResponse(response)) => {
                    crate::client::screenshot::set_screenshot(response.data);
                    self.handler
                        .handle_screenshot_resp(response.sid, response.msg);
                }
                Some(message::Union::TerminalResponse(response)) => {
                    use hbb_common::message_proto::terminal_response::Union;
                    if let Some(Union::Opened(opened)) = &response.union {
                        if opened.success && !opened.service_id.is_empty() {
                            let mut lc = self.handler.lc.write().unwrap();
                            let key = lc.get_key_terminal_service_id().to_owned();
                            lc.set_option(key, opened.service_id.clone());
                        }
                    }
                    self.handler.handle_terminal_response(response);
                }
                _ => {}
            }
        }
        true
    }

    fn set_peer_info(&mut self, pi: &PeerInfo) {
        self.peer_info.platform = pi.platform.clone();

        // Check features field for terminal support
        if let Some(features) = pi.features.as_ref() {
            self.peer_info.support_terminal = features.terminal;
            self.peer_info.support_parallel_clipboard_cache = features.parallel_clipboard_cache_v1;
        }

        #[cfg(target_os = "windows")]
        if self.handler.is_default() {
            PARALLEL_CLIPBOARD_CACHE_SUPPORTED.store(
                self.peer_info.support_parallel_clipboard_cache && pi.platform == "Windows",
                Ordering::Release,
            );
            refresh_parallel_clipboard_cache_mode();
        }

        if let Ok(platform_additions) =
            serde_json::from_str::<HashMap<String, serde_json::Value>>(&pi.platform_additions)
        {
            self.peer_info.is_installed = platform_additions
                .get("is_installed")
                .map(|v| v.as_bool())
                .flatten()
                .unwrap_or(false);
            self.peer_info.idd_impl = platform_additions
                .get("idd_impl")
                .map(|v| v.as_str())
                .flatten()
                .unwrap_or_default()
                .to_string();
            self.peer_info.support_view_camera = platform_additions
                .get("support_view_camera")
                .map(|v| v.as_bool())
                .flatten()
                .unwrap_or(false);
        }
    }

    async fn handle_back_notification(&mut self, notification: BackNotification) -> bool {
        match notification.union {
            Some(back_notification::Union::BlockInputState(state)) => {
                self.handle_back_msg_block_input(
                    state.enum_value_or(back_notification::BlockInputState::BlkStateUnknown),
                    notification.details,
                )
                .await;
            }
            Some(back_notification::Union::PrivacyModeState(state)) => {
                if !self
                    .handle_back_msg_privacy_mode(
                        state.enum_value_or(back_notification::PrivacyModeState::PrvStateUnknown),
                        notification.details,
                        notification.impl_key,
                    )
                    .await
                {
                    return false;
                }
            }
            _ => {}
        }
        true
    }

    #[inline(always)]
    fn update_block_input_state(&mut self, on: bool) {
        self.handler.update_block_input_state(on);
    }

    async fn handle_back_msg_block_input(
        &mut self,
        state: back_notification::BlockInputState,
        details: String,
    ) {
        match state {
            back_notification::BlockInputState::BlkOnSucceeded => {
                self.update_block_input_state(true);
            }
            back_notification::BlockInputState::BlkOnFailed => {
                self.handler.msgbox(
                    "custom-error",
                    "Block user input",
                    if details.is_empty() {
                        "Failed"
                    } else {
                        &details
                    },
                    "",
                );
                self.update_block_input_state(false);
            }
            back_notification::BlockInputState::BlkOffSucceeded => {
                self.update_block_input_state(false);
            }
            back_notification::BlockInputState::BlkOffFailed => {
                self.handler.msgbox(
                    "custom-error",
                    "Unblock user input",
                    if details.is_empty() {
                        "Failed"
                    } else {
                        &details
                    },
                    "",
                );
            }
            _ => {}
        }
    }

    #[inline(always)]
    fn update_privacy_mode(&mut self, impl_key: String, on: bool) {
        let mut config = self.handler.load_config();
        config.privacy_mode.v = on;
        if on {
            // For compatibility, version < 1.2.4, the default value is 'privacy_mode_impl_mag'.
            let impl_key = if impl_key.is_empty() {
                "privacy_mode_impl_mag".to_string()
            } else {
                impl_key
            };
            config
                .options
                .insert("privacy-mode-impl-key".to_string(), impl_key);
        }
        self.handler.save_config(config);

        self.handler.update_privacy_mode();
    }

    async fn handle_back_msg_privacy_mode(
        &mut self,
        state: back_notification::PrivacyModeState,
        details: String,
        impl_key: String,
    ) -> bool {
        match state {
            back_notification::PrivacyModeState::PrvOnByOther => {
                self.handler.msgbox(
                    "error",
                    "Connecting...",
                    "Someone turns on privacy mode, exit",
                    "",
                );
                return false;
            }
            back_notification::PrivacyModeState::PrvNotSupported => {
                self.handler
                    .msgbox("custom-error", "Privacy mode", "Unsupported", "");
                self.update_privacy_mode(impl_key, false);
            }
            back_notification::PrivacyModeState::PrvOnSucceeded => {
                self.handler
                    .msgbox("custom-nocancel", "Privacy mode", "Enter privacy mode", "");
                self.update_privacy_mode(impl_key, true);
            }
            back_notification::PrivacyModeState::PrvOnFailedDenied => {
                self.handler
                    .msgbox("custom-error", "Privacy mode", "Peer denied", "");
                self.update_privacy_mode(impl_key, false);
            }
            back_notification::PrivacyModeState::PrvOnFailedPlugin => {
                self.handler
                    .msgbox("custom-error", "Privacy mode", "Please install plugins", "");
                self.update_privacy_mode(impl_key, false);
            }
            back_notification::PrivacyModeState::PrvOnFailed => {
                self.handler.msgbox(
                    "custom-error",
                    "Privacy mode",
                    if details.is_empty() {
                        "Failed"
                    } else {
                        &details
                    },
                    "",
                );
                self.update_privacy_mode(impl_key, false);
            }
            back_notification::PrivacyModeState::PrvOffSucceeded => {
                self.handler
                    .msgbox("custom-nocancel", "Privacy mode", "Exit privacy mode", "");
                self.update_privacy_mode(impl_key, false);
            }
            back_notification::PrivacyModeState::PrvOffByPeer => {
                self.handler
                    .msgbox("custom-error", "Privacy mode", "Peer exit", "");
                self.update_privacy_mode(impl_key, false);
            }
            back_notification::PrivacyModeState::PrvOffFailed => {
                self.handler.msgbox(
                    "custom-error",
                    "Privacy mode",
                    if details.is_empty() {
                        "Failed to turn off"
                    } else {
                        &details
                    },
                    "",
                );
            }
            back_notification::PrivacyModeState::PrvOffUnknown => {
                self.handler
                    .msgbox("custom-error", "Privacy mode", "Turned off", "");
                // log::error!("Privacy mode is turned off with unknown reason");
                self.update_privacy_mode(impl_key, false);
            }
            _ => {}
        }
        true
    }

    #[cfg(all(target_os = "windows", not(feature = "flutter")))]
    fn check_clipboard_file_context(&self) {
        let enabled = *self.handler.server_file_transfer_enabled.read().unwrap()
            && self.handler.lc.read().unwrap().enable_file_copy_paste.v;
        ContextSend::enable(enabled);
    }

    #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
    async fn handle_cliprdr_msg(
        &mut self,
        clip: hbb_common::message_proto::Cliprdr,
        _peer: &mut Stream,
    ) {
        log::debug!("handling cliprdr msg from server peer");
        #[cfg(feature = "flutter")]
        if let Some(hbb_common::message_proto::cliprdr::Union::FormatList(_)) = &clip.union {
            if self.client_conn_id
                != clipboard::get_client_conn_id(&crate::flutter::get_cur_peer_id()).unwrap_or(0)
            {
                return;
            }
        }

        let Some(clip) = crate::clipboard_file::msg_2_clip(clip) else {
            log::warn!("failed to decode cliprdr msg from server peer");
            return;
        };

        let is_stopping_allowed = clip.is_beginning_message();
        let file_transfer_enabled = self.handler.is_file_clipboard_required();
        let stop = is_stopping_allowed && !file_transfer_enabled;
        log::debug!(
                "Process clipboard message from server peer, stop: {}, is_stopping_allowed: {}, file_transfer_enabled: {}",
                stop, is_stopping_allowed, file_transfer_enabled);
        if !stop {
            #[cfg(any(
                target_os = "windows",
                all(target_os = "macos", feature = "unix-file-copy-paste")
            ))]
            if let Err(e) = ContextSend::make_sure_enabled() {
                log::error!("failed to restart clipboard context: {}", e);
            };
            #[cfg(target_os = "windows")]
            {
                let _ = ContextSend::proc(|context| -> ResultType<()> {
                    context
                        .server_clip_file(self.client_conn_id, clip)
                        .map_err(|e| e.into())
                });
            }
            #[cfg(feature = "unix-file-copy-paste")]
            if crate::is_support_file_copy_paste_num(self.handler.lc.read().unwrap().version) {
                let mut out_msgs = vec![];

                #[cfg(target_os = "macos")]
                if clipboard::platform::unix::macos::should_handle_msg(&clip) {
                    if let Err(e) = ContextSend::proc(|context| -> ResultType<()> {
                        context
                            .server_clip_file(self.client_conn_id, clip)
                            .map_err(|e| e.into())
                    }) {
                        log::error!("failed to handle cliprdr msg: {}", e);
                    }
                } else {
                    out_msgs = unix_file_clip::serve_clip_messages(
                        ClipboardSide::Client,
                        clip,
                        self.client_conn_id,
                    );
                }

                #[cfg(not(target_os = "macos"))]
                {
                    out_msgs = unix_file_clip::serve_clip_messages(
                        ClipboardSide::Client,
                        clip,
                        self.client_conn_id,
                    );
                }

                for msg in out_msgs.into_iter() {
                    allow_err!(_peer.send(&msg).await);
                }
            }
        }
    }

    fn new_video_thread(&mut self, display: usize) {
        let video_queue = Arc::new(RwLock::new(ArrayQueue::new(client::VIDEO_QUEUE_SIZE)));
        let (video_sender, video_receiver) = std::sync::mpsc::channel::<MediaData>();
        let decode_fps = Arc::new(RwLock::new(None));
        let frame_count = Arc::new(RwLock::new(0));
        let discard_queue = Arc::new(RwLock::new(false));
        let video_thread = VideoThread {
            video_queue: video_queue.clone(),
            video_sender,
            decode_fps: decode_fps.clone(),
            frame_count: frame_count.clone(),
            fps_control: Default::default(),
            discard_queue: discard_queue.clone(),
        };
        let handler = self.handler.ui_handler.clone();
        crate::client::start_video_thread(
            self.handler.clone(),
            display,
            video_receiver,
            video_queue,
            decode_fps,
            self.chroma.clone(),
            discard_queue,
            move |display: usize,
                  data: &mut scrap::ImageRgb,
                  _texture: *mut c_void,
                  pixelbuffer: bool| {
                *frame_count.write().unwrap() += 1;
                if pixelbuffer {
                    handler.on_rgba(display, data);
                } else {
                    #[cfg(all(feature = "vram", feature = "flutter"))]
                    handler.on_texture(display, _texture);
                }
            },
        );
        self.video_threads.insert(display, video_thread);
        if self.video_threads.len() == 1 {
            let auto_record =
                LocalConfig::get_bool_option(config::keys::OPTION_ALLOW_AUTO_RECORD_OUTGOING);
            self.handler.lc.write().unwrap().record_state = auto_record;
            self.update_record_state();
        }
    }

    fn update_record_state(&mut self) {
        // state
        let permission = self.handler.lc.read().unwrap().record_permission;
        if !permission {
            self.handler.lc.write().unwrap().record_state = false;
        }
        let state = self.handler.lc.read().unwrap().record_state;
        let start = state && permission;
        if self.last_record_state == start {
            return;
        }
        self.last_record_state = start;
        log::info!("record screen start: {start}");
        // update local
        for (_, v) in self.video_threads.iter_mut() {
            v.video_sender.send(MediaData::RecordScreen(start)).ok();
        }
        self.handler.update_record_status(start);
        // update remote
        let mut misc = Misc::new();
        misc.set_client_record_status(start);
        let mut msg = Message::new();
        msg.set_misc(misc);
        self.sender.send(Data::Message(msg)).ok();
    }
}

struct RemoveJob {
    files: Vec<FileEntry>,
    path: String,
    sep: &'static str,
    is_remote: bool,
    no_confirm: bool,
    last_update_job_status: Instant,
}

impl RemoveJob {
    fn new(files: Vec<FileEntry>, path: String, sep: &'static str, is_remote: bool) -> Self {
        Self {
            files,
            path,
            sep,
            is_remote,
            no_confirm: false,
            last_update_job_status: Instant::now(),
        }
    }

    pub fn _gen_meta(&self) -> RemoveJobMeta {
        RemoveJobMeta {
            path: self.path.clone(),
            is_remote: self.is_remote,
            no_confirm: self.no_confirm,
        }
    }
}

#[derive(Debug, Default)]
struct FpsControl {
    refresh_times: usize,
    last_refresh_instant: Option<Instant>,
    idle_counter: usize,
    inactive_counter: usize,
}

struct VideoThread {
    video_queue: Arc<RwLock<ArrayQueue<VideoFrame>>>,
    video_sender: MediaSender,
    decode_fps: Arc<RwLock<Option<usize>>>,
    frame_count: Arc<RwLock<usize>>,
    discard_queue: Arc<RwLock<bool>>,
    fps_control: FpsControl,
}

impl Drop for VideoThread {
    fn drop(&mut self) {
        // since channels are buffered, messages sent before the disconnect will still be properly received.
        *self.discard_queue.write().unwrap() = true;
    }
}

#[cfg(test)]
mod parallel_file_transfer_tests {
    use super::*;

    #[test]
    fn parallel_file_transfer_ranges_cover_file_without_overlap() {
        let total = 2 * 1024 * 1024 * 1024u64 + 17;
        let ranges = split_parallel_chunks(0, total, 8);
        assert!(ranges.len() > 8);
        let mut cursor = 0;
        for (start, len) in ranges {
            assert_eq!(start, cursor);
            assert!(len > 0);
            assert!(len <= PARALLEL_DYNAMIC_CHUNK_SIZE);
            cursor += len;
        }
        assert_eq!(cursor, total);
    }

    #[test]
    fn parallel_file_transfer_range_split_caps_worker_count() {
        let ranges = split_parallel_chunks(11, 3, 8);
        assert_eq!(ranges, VecDeque::from([(11, 1), (12, 1), (13, 1)]));
    }

    #[test]
    fn parallel_file_transfer_large_file_has_dynamic_tail_work() {
        let total = 965 * 1024 * 1024u64;
        let ranges = split_parallel_chunks(0, total, 8);
        assert!(ranges.len() > 8);
        assert!(ranges
            .iter()
            .all(|(_, len)| *len <= PARALLEL_DYNAMIC_CHUNK_SIZE));
    }

    #[test]
    fn parallel_resume_starts_exactly_at_saved_offset() {
        let file_size = 128 * 1024 * 1024u64;
        let resume_offset = 37 * 1024 * 1024u64 + 19;
        let args = ParallelUploadArgs {
            id: 9,
            file_num: 0,
            source_selection: PathBuf::from("resume.bin"),
            destination: "target".to_owned(),
            files: vec![FileEntry {
                name: "resume.bin".to_owned(),
                size: file_size,
                ..Default::default()
            }],
            include_hidden: false,
            source_paths: None,
            clipboard_cache: false,
        };
        let work = split_parallel_work_items(&args, resume_offset, file_size - resume_offset, 8);
        assert_eq!(
            work.front().map(|item| item.range_start),
            Some(resume_offset)
        );
        assert_eq!(
            work.iter().map(|item| item.range_len).sum::<u64>(),
            file_size - resume_offset
        );
    }

    #[test]
    fn interrupted_parallel_download_keeps_only_contiguous_ranges() {
        let mib = 1024 * 1024u64;
        let ranges = vec![
            (24 * mib, 32 * mib),
            (8 * mib, 16 * mib),
            (16 * mib, 24 * mib),
        ];
        assert_eq!(contiguous_completed_prefix(8 * mib, ranges), 32 * mib);
        assert_eq!(
            contiguous_completed_prefix(8 * mib, vec![(24 * mib, 32 * mib)]),
            8 * mib
        );
    }

    #[test]
    fn parallel_file_transfer_folder_uses_one_dynamic_queue() {
        let files = (0..452)
            .map(|index| FileEntry {
                name: format!("file-{index:04}.bin"),
                size: 1024 * 1024,
                ..Default::default()
            })
            .collect::<Vec<_>>();
        let args = ParallelUploadArgs {
            id: 7,
            file_num: 10,
            source_selection: PathBuf::from("folder452"),
            destination: "target".to_owned(),
            files,
            include_hidden: false,
            source_paths: None,
            clipboard_cache: false,
        };
        let total = args.total_size();
        let work = split_parallel_work_items(&args, 0, total, 8);
        assert_eq!(work.len(), 452);
        assert_eq!(work.front().map(|item| item.file_num), Some(10));
        assert_eq!(work.back().map(|item| item.file_num), Some(461));
        assert_eq!(work.iter().map(|item| item.range_len).sum::<u64>(), total);
        assert!(work.iter().all(|item| item.range_start == 0));
    }

    #[test]
    fn parallel_clipboard_cache_uses_immutable_explicit_sources() {
        let sources = vec![
            PathBuf::from(r"C:\source\large.bin"),
            PathBuf::from(r"C:\source\small.bin"),
        ];
        let files = vec![
            FileEntry {
                name: "00000000.mdclip".to_owned(),
                size: 80 * 1024 * 1024,
                ..Default::default()
            },
            FileEntry {
                name: "00000001.mdclip".to_owned(),
                size: 1024,
                ..Default::default()
            },
        ];
        let args = ParallelUploadArgs {
            id: -1_000_000,
            file_num: 0,
            source_selection: PathBuf::new(),
            destination: String::new(),
            files,
            include_hidden: false,
            source_paths: Some(sources.clone()),
            clipboard_cache: true,
        };
        let work = split_parallel_work_items(&args, 0, args.total_size(), 8);
        assert_eq!(work.front().map(|item| &item.source), Some(&sources[0]));
        assert_eq!(work.back().map(|item| &item.source), Some(&sources[1]));
        assert!(work.len() > 2);
    }

    #[test]
    fn parallel_file_transfer_mode_supports_ui_values_and_safe_fallback() {
        assert_eq!(parallel_mode_from_value("off"), ParallelMode::Fixed(1));
        assert_eq!(parallel_mode_from_value("2"), ParallelMode::Fixed(2));
        assert_eq!(parallel_mode_from_value("4"), ParallelMode::Fixed(4));
        assert_eq!(parallel_mode_from_value("8"), ParallelMode::Fixed(8));
        assert_eq!(parallel_mode_from_value("auto"), ParallelMode::Auto);
        assert_eq!(parallel_mode_from_value("16"), ParallelMode::Auto);
    }

    #[test]
    fn parallel_auxiliary_security_matches_main_direct_ip_policy() {
        assert!(parallel_auxiliary_connection_is_allowed(
            "192.168.7.14",
            false
        ));
        assert!(parallel_auxiliary_connection_is_allowed(
            "192.168.7.14",
            true
        ));
        assert!(parallel_auxiliary_connection_is_allowed("123456789", true));
        assert!(!parallel_auxiliary_connection_is_allowed(
            "123456789",
            false
        ));
    }

    #[test]
    fn parallel_worker_login_is_file_transfer_with_auxiliary_identity() {
        let login = configure_parallel_worker_login(
            client::LoginConfigHandler::default(),
            3,
            "transfer-identity",
            "transfer-auth",
        );
        assert_eq!(login.conn_type, ConnType::FILE_TRANSFER);

        let message = login.create_login_msg(String::new(), String::new(), Vec::new());
        let Some(message::Union::LoginRequest(request)) = message.union else {
            panic!("expected login request");
        };
        let Some(login_request::Union::FileTransfer(file_transfer)) = request.union else {
            panic!("expected file transfer login");
        };
        assert!(file_transfer.parallel_auxiliary);
        assert_eq!(file_transfer.parallel_transfer_id, "transfer-identity");
        assert_eq!(file_transfer.parallel_worker, 3);
        assert_eq!(file_transfer.parallel_auth_token, "transfer-auth");
    }

    #[test]
    fn parallel_auto_uses_short_probes_and_keeps_measuring() {
        assert_eq!(parallel_auto_stage_len(1, u64::MAX), 2 * 1024 * 1024);
        assert_eq!(parallel_auto_stage_len(8, u64::MAX), 16 * 1024 * 1024);
        assert_eq!(parallel_auto_stage_len(8, 123), 123);
        assert!(parallel_auto_stage_is_better(0.0, 1.0));
        assert!(parallel_auto_stage_is_better(100.0, 105.0));
        assert!(!parallel_auto_stage_is_better(100.0, 104.9));
    }

    #[test]
    fn parallel_file_transfer_telemetry_reports_real_worker_state() {
        let job_id = i32::MAX - 100;
        let sent = Arc::new(AtomicU64::new(0));
        register_parallel_transfer(
            job_id,
            "telemetry-test",
            ParallelMode::Fixed(4),
            "sample.bin",
            1024,
            1,
            sent.clone(),
        );
        let queued_chunks = Arc::new(AtomicUsize::new(7));
        let open_connections = Arc::new(AtomicUsize::new(4));
        begin_parallel_telemetry_stage("telemetry-test", 4, queued_chunks, open_connections);
        let (worker, phase) = register_parallel_worker("telemetry-test", 1, 0, 256).unwrap();
        worker
            .state
            .store(PARALLEL_WORKER_TRANSFERRING, Ordering::Relaxed);
        worker.bytes_transferred.store(128, Ordering::Relaxed);
        worker.chunks_completed.store(2, Ordering::Relaxed);
        worker.jobs_completed.store(2, Ordering::Relaxed);
        phase.store(PARALLEL_PHASE_TRANSFERRING, Ordering::Relaxed);
        sent.store(128, Ordering::Relaxed);

        let json = parallel_transfer_stats_json(job_id).unwrap();
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(value["mode"], "FIXED 4x");
        assert_eq!(value["phase"], "TRANSFERRING");
        assert_eq!(value["active_workers"], 1);
        assert_eq!(value["busy_workers"], 1);
        assert_eq!(value["open_connections"], 4);
        assert_eq!(value["target_workers"], 4);
        assert_eq!(value["queued_chunks"], 7);
        assert_eq!(value["completed_chunks"], 2);
        assert_eq!(value["file_count"], 1);
        assert_eq!(value["completed_jobs"], 2);
        assert_eq!(value["workers"][0]["bytes_transferred"], 128);
        assert_eq!(value["workers"][0]["jobs_completed"], 2);

        PARALLEL_TRANSFER_TELEMETRY.lock().unwrap().remove(&job_id);
    }
}
