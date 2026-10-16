//! Remote (stand-alone) CPU mining endpoint for hegemon-cpuminer.
//!
//! External miners on other machines mine against this node WITHOUT running a
//! node. The node keeps full authority: it builds every block template itself
//! (pending actions, roots, PoW bits and a coinbase paying the worker-supplied
//! shielded address), hands out only the 32-byte `pre_hash` plus compact
//! target, and runs the normal `import_mined_block` path (full PoW,
//! commitment and replay verification) on every submitted nonce.
//!
//! Enable with:
//!   HEGEMON_REMOTE_MINING_LISTEN=0.0.0.0:9944
//!   HEGEMON_REMOTE_MINING_TOKEN=<secret, >= 16 chars>
//!
//! JSON-RPC 2.0 over HTTP, params[0] is an object containing "token":
//!   mining_getWork {token, address, worker, hashrate?} -> job
//!   mining_submit  {token, job_id, nonce, worker}      -> {accepted, ...}
//!   mining_stats   {token}                             -> node + per-worker stats
//!
//! PoW is unchanged: sha256d(pre_hash || nonce32) <= target(pow_bits).

use super::*;

const REMOTE_JOB_TTL: Duration = Duration::from_secs(300);
const REMOTE_MAX_JOBS: usize = 1024;
const REMOTE_MAX_ADDRESSES: usize = 64;
/// Template reused for this long unless the tip changes (refreshes the
/// timestamp and picks up new mempool transactions).
const REMOTE_TEMPLATE_REFRESH: Duration = Duration::from_secs(30);
const REMOTE_MAX_BODY_BYTES: usize = 64 * 1024;
const REMOTE_MAX_CONCURRENCY: usize = 128;

#[derive(Clone)]
struct RemoteJob {
    work: NativeWork,
    created: Instant,
    address_key: [u8; 32],
}

#[derive(Clone, Default, Serialize)]
struct RemoteWorkerStats {
    address_prefix: String,
    last_seen_unix: u64,
    reported_hashrate: f64,
    get_work: u64,
    blocks: u64,
    stale: u64,
    rejected: u64,
    last_block_height: u64,
    last_error: Option<String>,
}

#[derive(Default)]
struct RemoteMiningInner {
    jobs: BTreeMap<String, RemoteJob>,
    order: std::collections::VecDeque<String>,
    /// address_key -> (job_id, parent hash) of the newest template
    current: BTreeMap<[u8; 32], (String, [u8; 32])>,
    addresses: BTreeSet<[u8; 32]>,
    workers: BTreeMap<String, RemoteWorkerStats>,
    seq: u64,
}

pub(crate) struct RemoteMining {
    token: String,
    inner: Mutex<RemoteMiningInner>,
    build_lock: Mutex<()>,
    blocks_found: AtomicU64,
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn address_key(address: &str) -> [u8; 32] {
    *blake3::hash(address.as_bytes()).as_bytes()
}

/// Constant-time comparison (hash both sides, compare digests).
fn token_matches(expected: &str, provided: &str) -> bool {
    let a = blake3::hash(expected.as_bytes());
    let b = blake3::hash(provided.as_bytes());
    let mut diff = 0u8;
    for (x, y) in a.as_bytes().iter().zip(b.as_bytes()) {
        diff |= x ^ y;
    }
    diff == 0 && !expected.is_empty()
}

fn sanitize_worker(raw: Option<&str>) -> String {
    let cleaned: String = raw
        .unwrap_or("worker")
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
        .take(48)
        .collect();
    if cleaned.is_empty() {
        "worker".into()
    } else {
        cleaned
    }
}

impl RemoteMiningInner {
    fn prune(&mut self) {
        let now = Instant::now();
        while let Some(front) = self.order.front().cloned() {
            let expired = self
                .jobs
                .get(&front)
                .map(|j| now.duration_since(j.created) > REMOTE_JOB_TTL)
                .unwrap_or(true);
            if expired || self.jobs.len() > REMOTE_MAX_JOBS {
                self.order.pop_front();
                self.jobs.remove(&front);
            } else {
                break;
            }
        }
        let jobs = &self.jobs;
        self.current.retain(|_, (id, _)| jobs.contains_key(id));
    }

    fn insert(&mut self, job: RemoteJob) -> String {
        self.seq = self.seq.wrapping_add(1);
        let mut h = blake3::Hasher::new();
        h.update(b"hegemon-remote-job-v1");
        h.update(&self.seq.to_le_bytes());
        h.update(&job.work.pre_hash);
        let id = hex::encode(&h.finalize().as_bytes()[..16]);
        self.current
            .insert(job.address_key, (id.clone(), job.work.parent_hash));
        self.order.push_back(id.clone());
        self.jobs.insert(id.clone(), job);
        self.prune();
        id
    }

    fn fresh_job_for(&self, key: &[u8; 32], tip: &[u8; 32]) -> Option<(String, NativeWork)> {
        let (id, parent) = self.current.get(key)?;
        if parent != tip {
            return None;
        }
        let job = self.jobs.get(id)?;
        (job.created.elapsed() < REMOTE_TEMPLATE_REFRESH).then(|| (id.clone(), job.work.clone()))
    }

    fn worker(&mut self, name: &str) -> &mut RemoteWorkerStats {
        self.workers.entry(name.to_string()).or_default()
    }
}

fn job_json(id: &str, work: &NativeWork) -> Value {
    json!({
        "available": true,
        "job_id": id,
        "height": work.height,
        "parent_hash": hex32(&work.parent_hash),
        "pre_hash": hex32(&work.pre_hash),
        "pow_bits": work.pow_bits,
        "timestamp_ms": work.timestamp_ms,
        "tx_count": work.tx_count,
        "algorithm": "sha256d(pre_hash||nonce32)",
        "ttl_seconds": REMOTE_JOB_TTL.as_secs(),
    })
}

impl NativeNode {
    fn remote_get_work(&self, rm: &RemoteMining, params: &Value) -> Result<Value> {
        let address = params
            .get("address")
            .and_then(Value::as_str)
            .map(str::trim)
            .ok_or_else(|| anyhow!("missing payout address"))?;
        let worker = sanitize_worker(params.get("worker").and_then(Value::as_str));
        let key = address_key(address);
        {
            let mut inner = rm.inner.lock();
            if !inner.addresses.contains(&key) {
                ShieldedAddress::decode(address)
                    .map_err(|_| anyhow!("invalid shielded payout address"))?;
                if inner.addresses.len() >= REMOTE_MAX_ADDRESSES {
                    return Err(anyhow!("too many distinct payout addresses on this node"));
                }
                inner.addresses.insert(key);
            }
            let hr = params.get("hashrate").and_then(Value::as_f64).unwrap_or(0.0);
            let w = inner.worker(&worker);
            w.address_prefix = address.chars().take(20).collect();
            w.last_seen_unix = now_unix();
            w.get_work += 1;
            if hr.is_finite() && hr >= 0.0 {
                w.reported_hashrate = hr;
            }
        }

        self.refresh_mining_sync_gate();
        if !self.mining_sync_gate_allows_work() {
            return Ok(json!({
                "available": false,
                "reason": "node is syncing (mining sync gate closed); retry shortly",
                "height": self.state.read().best.height,
            }));
        }

        let tip = self.state.read().best.hash;
        if let Some((id, work)) = rm.inner.lock().fresh_job_for(&key, &tip) {
            return Ok(job_json(&id, &work));
        }
        let _guard = rm.build_lock.lock();
        let tip = self.state.read().best.hash;
        if let Some((id, work)) = rm.inner.lock().fresh_job_for(&key, &tip) {
            return Ok(job_json(&id, &work));
        }
        let work = self.prepare_work_for(Some(address))?;
        let id = rm.inner.lock().insert(RemoteJob {
            work: work.clone(),
            created: Instant::now(),
            address_key: key,
        });
        Ok(job_json(&id, &work))
    }

    fn remote_submit(&self, rm: &RemoteMining, params: &Value) -> Result<Value> {
        let id = params
            .get("job_id")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("missing job_id"))?
            .to_string();
        let worker = sanitize_worker(params.get("worker").and_then(Value::as_str));
        let raw = params
            .get("nonce")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("missing nonce"))?;
        let bytes = hex::decode(raw.trim_start_matches("0x"))
            .map_err(|_| anyhow!("nonce must be hex"))?;
        let nonce: [u8; 32] = bytes
            .try_into()
            .map_err(|_| anyhow!("nonce must be exactly 32 bytes"))?;

        let job = {
            let mut inner = rm.inner.lock();
            inner.prune();
            inner.worker(&worker).last_seen_unix = now_unix();
            inner.jobs.get(&id).cloned()
        };
        let Some(job) = job else {
            rm.inner.lock().worker(&worker).stale += 1;
            return Ok(json!({"accepted": false, "stale": true, "reason": "unknown or expired job"}));
        };
        let work_hash = native_pow_work_hash(&job.work.pre_hash, nonce);
        if !native_seal_meets_target(&work_hash, job.work.pow_bits) {
            let mut inner = rm.inner.lock();
            let w = inner.worker(&worker);
            w.rejected += 1;
            w.last_error = Some("hash above target".into());
            return Ok(json!({"accepted": false, "reason": "hash does not meet target"}));
        }
        if self.state.read().best.hash != job.work.parent_hash {
            rm.inner.lock().worker(&worker).stale += 1;
            return Ok(json!({"accepted": false, "stale": true, "reason": "chain tip moved before submit"}));
        }
        match self.import_mined_block(&job.work, NativeSeal { nonce, work_hash }) {
            Ok(Some(meta)) => {
                rm.blocks_found.fetch_add(1, Ordering::Relaxed);
                let mut inner = rm.inner.lock();
                inner.current.clear(); // every outstanding template is stale now
                let w = inner.worker(&worker);
                w.blocks += 1;
                w.last_block_height = meta.height;
                w.last_error = None;
                drop(inner);
                info!(height = meta.height, hash = %hex32(&meta.hash), worker = %worker,
                      "remote-mined native PoW block imported");
                Ok(json!({"accepted": true, "height": meta.height, "hash": hex32(&meta.hash)}))
            }
            Ok(None) => {
                rm.inner.lock().worker(&worker).stale += 1;
                Ok(json!({"accepted": false, "stale": true, "reason": "template no longer valid for the chain tip"}))
            }
            Err(err) => {
                let msg = err.to_string();
                warn!(error = %msg, worker = %worker, "remote-mined block rejected");
                let mut inner = rm.inner.lock();
                let w = inner.worker(&worker);
                w.rejected += 1;
                w.last_error = Some(msg.chars().take(200).collect());
                Ok(json!({"accepted": false, "reason": msg}))
            }
        }
    }

    fn remote_stats(&self, rm: &RemoteMining) -> Value {
        let mut inner = rm.inner.lock();
        inner.prune();
        let now = now_unix();
        let total: f64 = inner
            .workers
            .values()
            .filter(|w| now.saturating_sub(w.last_seen_unix) < 120)
            .map(|w| w.reported_hashrate)
            .sum();
        let state = self.state.read();
        json!({
            "height": state.best.height,
            "best_hash": hex32(&state.best.hash),
            "pow_bits": state.best.pow_bits,
            "mining_sync_gate_open": self.mining_sync_gate_allows_work(),
            "peers": self.network_peer_count(),
            "remote_blocks_found": rm.blocks_found.load(Ordering::Relaxed),
            "remote_hashrate_reported": total,
            "active_jobs": inner.jobs.len(),
            "workers": inner.workers,
        })
    }
}

fn rpc_err(id: Value, code: i64, msg: impl Into<String>) -> Value {
    json!({"jsonrpc": "2.0", "error": {"code": code, "message": msg.into()}, "id": id})
}

#[derive(Clone)]
struct RemoteCtx {
    node: Arc<NativeNode>,
    rm: Arc<RemoteMining>,
}

async fn remote_rpc_handler(State(ctx): State<RemoteCtx>, Json(request): Json<Value>) -> Response {
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let method = request
        .get("method")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let params = match request.get("params") {
        Some(Value::Array(items)) => items.first().cloned().unwrap_or(Value::Null),
        Some(other) => other.clone(),
        None => Value::Null,
    };
    let token = params.get("token").and_then(Value::as_str).unwrap_or_default();
    if !token_matches(&ctx.rm.token, token) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(rpc_err(id, -32001, "invalid mining token")),
        )
            .into_response();
    }
    let (node, rm) = (Arc::clone(&ctx.node), Arc::clone(&ctx.rm));
    let result = tokio::task::spawn_blocking(move || match method.as_str() {
        "mining_getWork" => node.remote_get_work(&rm, &params),
        "mining_submit" => node.remote_submit(&rm, &params),
        "mining_stats" => Ok(node.remote_stats(&rm)),
        other => Err(anyhow!("unknown method {other}")),
    })
    .await
    .map_err(|e| anyhow!("remote mining task failed: {e}"))
    .and_then(|r| r);
    let body = match result {
        Ok(r) => json!({"jsonrpc": "2.0", "result": r, "id": id}),
        Err(e) => rpc_err(id, -32000, e.to_string()),
    };
    (StatusCode::OK, Json(body)).into_response()
}

async fn remote_health() -> Response {
    (
        StatusCode::OK,
        Json(json!({"ok": true, "service": "hegemon-remote-mining", "version": env!("CARGO_PKG_VERSION")})),
    )
        .into_response()
}

/// Start the remote-mining listener when HEGEMON_REMOTE_MINING_LISTEN is set.
pub(crate) async fn start_remote_mining(node: Arc<NativeNode>) -> Result<()> {
    let listen = std::env::var("HEGEMON_REMOTE_MINING_LISTEN").unwrap_or_default();
    let listen = listen.trim();
    if listen.is_empty() {
        return Ok(());
    }
    let token = std::env::var("HEGEMON_REMOTE_MINING_TOKEN").unwrap_or_default();
    let token = token.trim().to_string();
    if token.len() < 16 {
        return Err(anyhow!(
            "HEGEMON_REMOTE_MINING_TOKEN must be set (>= 16 chars) when HEGEMON_REMOTE_MINING_LISTEN is used"
        ));
    }
    let addr: SocketAddr = listen
        .parse()
        .with_context(|| format!("invalid HEGEMON_REMOTE_MINING_LISTEN {listen}"))?;
    let ctx = RemoteCtx {
        node,
        rm: Arc::new(RemoteMining {
            token,
            inner: Mutex::new(RemoteMiningInner::default()),
            build_lock: Mutex::new(()),
            blocks_found: AtomicU64::new(0),
        }),
    };
    let app = Router::new()
        .route("/", post(remote_rpc_handler).get(remote_health))
        .route("/health", get(remote_health))
        .layer(DefaultBodyLimit::max(REMOTE_MAX_BODY_BYTES))
        .layer(ConcurrencyLimitLayer::new(REMOTE_MAX_CONCURRENCY))
        .with_state(ctx);
    let listener = TcpListener::bind(addr)
        .await
        .with_context(|| format!("bind remote mining listener {addr}"))?;
    info!(listen = %addr, "remote CPU-mining endpoint enabled");
    tokio::spawn(async move {
        if let Err(err) = axum::serve(listener, app).await {
            warn!(error = %err, "remote mining listener stopped");
        }
    });
    Ok(())
}
