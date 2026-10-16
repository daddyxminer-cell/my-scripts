//! hegemon-cpuminer — standalone CPU miner for Hegemon v0.10.3.
//!
//! Connects to a Hegemon node that runs the remote-mining endpoint
//! (node built with hegemon/node-patch, env HEGEMON_REMOTE_MINING_LISTEN),
//! fetches block templates whose coinbase pays YOUR shielded address, grinds
//! nonces on every core and submits solutions. No local node, no chain sync.
//!
//! PoW (identical to hegemon-node v0.10.3):
//!   work_hash = SHA256(SHA256(pre_hash[32] || nonce[32]))
//!   valid if work_hash (big-endian bytes) <= compact_to_target(pow_bits)
//!
//! Per hash: 3 SHA-256 compressions, zero allocation.

use sha2::compress256;
use sha2::digest::generic_array::GenericArray;
use std::io::{self, BufRead, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const VERSION: &str = env!("CARGO_PKG_VERSION");
const H0: [u32; 8] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];
/// Hashes per thread between job-generation checks (~50-100 ms of work).
const BATCH: u64 = 1 << 16;

// ---------------------------------------------------------------------------
// PoW
// ---------------------------------------------------------------------------

#[inline(always)]
fn compress(state: &mut [u32; 8], block: &[u8; 64]) {
    compress256(state, std::slice::from_ref(GenericArray::from_slice(block)));
}

/// Second SHA-256 block for a 64-byte message (pure padding, length 512 bits).
const PAD64: [u8; 64] = {
    let mut b = [0u8; 64];
    b[0] = 0x80;
    b[62] = 0x02;
    b
};

#[inline(always)]
fn sha256d_64(msg: &[u8; 64]) -> [u8; 32] {
    let mut st = H0;
    compress(&mut st, msg);
    compress(&mut st, &PAD64);
    let mut b2 = [0u8; 64];
    for i in 0..8 {
        b2[i * 4..i * 4 + 4].copy_from_slice(&st[i].to_be_bytes());
    }
    b2[32] = 0x80;
    b2[62] = 0x01; // 256 bits
    let mut st2 = H0;
    compress(&mut st2, &b2);
    let mut out = [0u8; 32];
    for i in 0..8 {
        out[i * 4..i * 4 + 4].copy_from_slice(&st2[i].to_be_bytes());
    }
    out
}

/// Bitcoin-style compact target — byte-identical to consensus-light-client.
fn compact_to_target(bits: u32) -> Option<[u8; 32]> {
    let exponent = bits >> 24;
    let mantissa = bits & 0x00ff_ffff;
    if mantissa == 0 || exponent > 32 {
        return None;
    }
    let mut target = [0u8; 32];
    let mb = [(mantissa >> 16) as u8, (mantissa >> 8) as u8, mantissa as u8];
    if exponent <= 3 {
        let value = mantissa >> (8 * (3 - exponent));
        target[28..32].copy_from_slice(&value.to_be_bytes());
    } else {
        let start = 32usize.checked_sub(exponent as usize)?;
        for (o, byte) in mb.iter().enumerate() {
            let i = start + o;
            if i >= 32 {
                if *byte != 0 {
                    return None;
                }
                continue;
            }
            target[i] = *byte;
        }
    }
    Some(target)
}

fn expected_hashes(target: &[u8; 32]) -> f64 {
    let t = target.iter().fold(0f64, |acc, b| acc * 256.0 + *b as f64);
    2f64.powi(256) / (t + 1.0)
}

// ---------------------------------------------------------------------------
// Shared state
// ---------------------------------------------------------------------------

struct Job {
    id: String,
    height: u64,
    pre_hash: [u8; 32],
    target: [u8; 32],
    pow_bits: u32,
    tx_count: u64,
}

struct Shared {
    job: RwLock<Option<Arc<Job>>>,
    generation: AtomicU64,
    hashes: AtomicU64,
    stop: AtomicBool,
    found: Mutex<Vec<(Arc<Job>, [u8; 32])>>,
}

impl Shared {
    fn new(job: Option<Job>) -> Arc<Self> {
        Arc::new(Self {
            generation: AtomicU64::new(job.is_some() as u64),
            job: RwLock::new(job.map(Arc::new)),
            hashes: AtomicU64::new(0),
            stop: AtomicBool::new(false),
            found: Mutex::new(Vec::new()),
        })
    }
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

struct Config {
    url: String,
    token: String,
    address: String,
    worker: String,
    threads: usize,
    affinity: bool,
    poll: Duration,
    benchmark: bool,
}

fn usage() -> ! {
    eprintln!(
        "hegemon-cpuminer {VERSION} - standalone CPU miner for Hegemon v0.10.3

USAGE:
  hegemon-cpuminer --url http://HOST:PORT --token TOKEN --address shca1... [options]
  hegemon-cpuminer --benchmark [--threads N]

OPTIONS:
  --url URL            node remote-mining endpoint      (env HEGEMON_POOL_URL)
  --token TOKEN        mining token set on the node     (env HEGEMON_MINING_TOKEN)
  --address ADDR       shielded payout address shca1... (env HEGEMON_MINER_ADDRESS)
  --address-file FILE  read the payout address from a file
  --worker NAME        worker name in node stats (default: hostname)
  --threads N          hashing threads (default: all logical CPUs)
  --no-affinity        do not pin threads to cores
  --poll-ms MS         template poll interval (default 1500)
  --benchmark          measure local hash rate and exit
  -V, --version"
    );
    std::process::exit(2)
}

fn hostname() -> String {
    std::fs::read_to_string("/etc/hostname")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "cpuminer".into())
}

fn parse_args() -> Config {
    let mut args = std::env::args().skip(1);
    let mut cfg = Config {
        url: std::env::var("HEGEMON_POOL_URL").unwrap_or_default(),
        token: std::env::var("HEGEMON_MINING_TOKEN").unwrap_or_default(),
        address: std::env::var("HEGEMON_MINER_ADDRESS").unwrap_or_default(),
        worker: hostname(),
        threads: thread::available_parallelism().map(|n| n.get()).unwrap_or(1),
        affinity: true,
        poll: Duration::from_millis(1500),
        benchmark: false,
    };
    while let Some(a) = args.next() {
        let mut val = || args.next().unwrap_or_else(|| usage());
        match a.as_str() {
            "--url" => cfg.url = val(),
            "--token" => cfg.token = val(),
            "--address" => cfg.address = val(),
            "--address-file" => {
                let f = val();
                cfg.address = std::fs::read_to_string(&f).unwrap_or_else(|e| {
                    eprintln!("cannot read {f}: {e}");
                    std::process::exit(2)
                })
            }
            "--worker" => cfg.worker = val(),
            "--threads" => cfg.threads = val().parse().unwrap_or_else(|_| usage()),
            "--no-affinity" => cfg.affinity = false,
            "--poll-ms" => cfg.poll = Duration::from_millis(val().parse().unwrap_or_else(|_| usage())),
            "--benchmark" => cfg.benchmark = true,
            "-V" | "--version" => {
                println!("hegemon-cpuminer {VERSION}");
                std::process::exit(0)
            }
            "-h" | "--help" => usage(),
            other => {
                eprintln!("unknown option {other}");
                usage()
            }
        }
    }
    cfg.address.retain(|c| !c.is_whitespace());
    cfg.token = cfg.token.trim().to_string();
    cfg.url = cfg.url.trim().trim_end_matches('/').to_string();
    if !cfg.url.is_empty() && !cfg.url.starts_with("http") {
        cfg.url = format!("http://{}", cfg.url);
    }
    cfg.threads = cfg.threads.max(1);
    cfg
}

// ---------------------------------------------------------------------------
// Logging / RPC
// ---------------------------------------------------------------------------

fn ts() -> String {
    let s = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    format!("{:02}:{:02}:{:02}", (s / 3600) % 24, (s / 60) % 60, s % 60)
}
macro_rules! log {
    ($($t:tt)*) => {{ println!("[{}] {}", ts(), format!($($t)*)); let _ = io::stdout().flush(); }};
}

fn fmt_rate(h: f64) -> String {
    match h {
        h if h >= 1e9 => format!("{:.2} GH/s", h / 1e9),
        h if h >= 1e6 => format!("{:.2} MH/s", h / 1e6),
        h if h >= 1e3 => format!("{:.2} kH/s", h / 1e3),
        h => format!("{h:.0} H/s"),
    }
}

fn fmt_dur(s: f64) -> String {
    if !s.is_finite() {
        return "inf".into();
    }
    let s = s as u64;
    match s {
        s if s >= 86400 => format!("{}d{}h", s / 86400, (s % 86400) / 3600),
        s if s >= 3600 => format!("{}h{}m", s / 3600, (s % 3600) / 60),
        s if s >= 60 => format!("{}m{}s", s / 60, s % 60),
        s => format!("{s}s"),
    }
}

struct Rpc {
    agent: ureq::Agent,
    url: String,
    token: String,
}

impl Rpc {
    fn call(&self, method: &str, mut params: serde_json::Value) -> Result<serde_json::Value, String> {
        params["token"] = serde_json::Value::String(self.token.clone());
        let body = serde_json::json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": [params]});
        let v: serde_json::Value = match self.agent.post(&self.url).send_json(body) {
            Ok(r) => r.into_json().map_err(|e| format!("bad response: {e}"))?,
            Err(ureq::Error::Status(401, _)) => return Err("401: node rejected the mining token".into()),
            Err(ureq::Error::Status(c, r)) => {
                return Err(format!("HTTP {c}: {}", r.into_string().unwrap_or_default()))
            }
            Err(e) => return Err(format!("connection failed: {e}")),
        };
        if let Some(err) = v.get("error") {
            return Err(err.get("message").and_then(|m| m.as_str()).unwrap_or("rpc error").to_string());
        }
        Ok(v.get("result").cloned().unwrap_or(serde_json::Value::Null))
    }
}

fn parse_job(v: &serde_json::Value) -> Result<Option<Job>, String> {
    if v.get("available").and_then(|a| a.as_bool()) == Some(false) {
        return Ok(None);
    }
    let pre = v.get("pre_hash").and_then(|x| x.as_str()).ok_or("missing pre_hash")?;
    let pre_hash: [u8; 32] = hex::decode(pre.trim_start_matches("0x"))
        .map_err(|_| "bad pre_hash hex")?
        .try_into()
        .map_err(|_| "pre_hash must be 32 bytes")?;
    let pow_bits = v.get("pow_bits").and_then(|x| x.as_u64()).ok_or("missing pow_bits")? as u32;
    Ok(Some(Job {
        id: v.get("job_id").and_then(|x| x.as_str()).ok_or("missing job_id")?.to_string(),
        height: v.get("height").and_then(|x| x.as_u64()).unwrap_or(0),
        target: compact_to_target(pow_bits).ok_or("invalid pow_bits")?,
        pre_hash,
        pow_bits,
        tx_count: v.get("tx_count").and_then(|x| x.as_u64()).unwrap_or(0),
    }))
}

// ---------------------------------------------------------------------------
// Hashing threads
// ---------------------------------------------------------------------------

/// Nonce layout (32 bytes): [0..8] counter, [8..16] per-thread salt, rest 0.
/// The salt mixes time, pid and thread index so threads, restarts and
/// multiple rigs on the same address never search overlapping ranges.
fn worker_loop(idx: usize, shared: Arc<Shared>) {
    let salt = {
        let t = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0) as u64;
        (t ^ ((std::process::id() as u64) << 40)).wrapping_add((idx as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15))
    };
    let mut seen = u64::MAX;
    let mut job: Option<Arc<Job>> = None;
    let mut msg = [0u8; 64];
    let mut counter = 0u64;
    let mut local = 0u64;
    while !shared.stop.load(Ordering::Relaxed) {
        let gen = shared.generation.load(Ordering::Acquire);
        if gen != seen {
            seen = gen;
            job = shared.job.read().unwrap().clone();
            if let Some(j) = &job {
                msg[..32].copy_from_slice(&j.pre_hash);
                msg[32..].fill(0);
                msg[40..48].copy_from_slice(&salt.to_le_bytes());
                counter = 0;
            }
        }
        let Some(j) = job.as_ref() else {
            thread::sleep(Duration::from_millis(50));
            continue;
        };
        let t0 = j.target[0];
        for _ in 0..BATCH {
            msg[32..40].copy_from_slice(&counter.to_le_bytes());
            let h = sha256d_64(&msg);
            if h[0] <= t0 && h <= j.target {
                let mut nonce = [0u8; 32];
                nonce.copy_from_slice(&msg[32..]);
                shared.found.lock().unwrap().push((Arc::clone(j), nonce));
            }
            counter = counter.wrapping_add(1);
        }
        local += BATCH;
        if local >= BATCH * 4 {
            shared.hashes.fetch_add(local, Ordering::Relaxed);
            local = 0;
        }
    }
}

fn spawn_workers(cfg: &Config, shared: &Arc<Shared>) -> Vec<thread::JoinHandle<()>> {
    let cores = if cfg.affinity { core_affinity::get_core_ids().unwrap_or_default() } else { vec![] };
    (0..cfg.threads)
        .map(|i| {
            let s = Arc::clone(shared);
            let core = cores.get(i % cores.len().max(1)).copied();
            thread::Builder::new()
                .name(format!("hash-{i}"))
                .spawn(move || {
                    if let Some(c) = core {
                        core_affinity::set_for_current(c);
                    }
                    worker_loop(i, s)
                })
                .expect("spawn hashing thread")
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Self test + benchmark
// ---------------------------------------------------------------------------

fn self_test() {
    use sha2::{Digest, Sha256};
    let mut msg = [0u8; 64];
    for (i, b) in msg.iter_mut().enumerate() {
        *b = (i as u8).wrapping_mul(37).wrapping_add(11);
    }
    let reference: [u8; 32] = Sha256::digest(Sha256::digest(msg)).into();
    assert_eq!(sha256d_64(&msg), reference, "SHA-256d fast path mismatch");
    let t = compact_to_target(0x1d00ffff).unwrap();
    assert_eq!(&t[..6], &[0, 0, 0, 0, 0xff, 0xff]);
    assert!(t[6..].iter().all(|b| *b == 0));
    assert!(compact_to_target(0).is_none());
}

fn benchmark(cfg: &Config) {
    let shared = Shared::new(Some(Job {
        id: "bench".into(),
        height: 0,
        pre_hash: [7u8; 32],
        target: [0u8; 32],
        pow_bits: 0,
        tx_count: 0,
    }));
    log!("benchmark: {} threads, 15 s ...", cfg.threads);
    let handles = spawn_workers(cfg, &shared);
    thread::sleep(Duration::from_secs(3));
    let (h0, t0) = (shared.hashes.load(Ordering::Relaxed), Instant::now());
    thread::sleep(Duration::from_secs(12));
    let rate = (shared.hashes.load(Ordering::Relaxed) - h0) as f64 / t0.elapsed().as_secs_f64();
    shared.stop.store(true, Ordering::Relaxed);
    handles.into_iter().for_each(|h| drop(h.join()));
    log!("benchmark: {}  ({} per thread)", fmt_rate(rate), fmt_rate(rate / cfg.threads as f64));
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

fn main() {
    let mut cfg = parse_args();
    self_test();
    if cfg.benchmark {
        benchmark(&cfg);
        return;
    }
    if cfg.address.is_empty() {
        print!("Payout address (shca1...): ");
        let _ = io::stdout().flush();
        let mut line = String::new();
        let _ = io::stdin().lock().read_line(&mut line);
        cfg.address = line.chars().filter(|c| !c.is_whitespace()).collect();
    }
    if !cfg.address.starts_with("shca1") || cfg.address.len() < 1000 {
        eprintln!(
            "invalid payout address: need the full shca1... line (~2600 chars), got {} chars",
            cfg.address.len()
        );
        std::process::exit(2);
    }
    if cfg.url.is_empty() || cfg.token.is_empty() {
        eprintln!("--url and --token are required (see --help)");
        std::process::exit(2);
    }
    let rpc = Rpc {
        agent: ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(5))
            .timeout(Duration::from_secs(60))
            .build(),
        url: cfg.url.clone(),
        token: cfg.token.clone(),
    };
    log!("hegemon-cpuminer {VERSION} | threads {} | node {} | worker {}", cfg.threads, cfg.url, cfg.worker);
    log!("payout {}...{}", &cfg.address[..24], &cfg.address[cfg.address.len() - 12..]);

    let shared = Shared::new(None);
    let _handles = spawn_workers(&cfg, &shared);

    let start = Instant::now();
    let (mut rep_t, mut rep_h) = (Instant::now(), 0u64);
    let mut poll_t = Instant::now() - cfg.poll;
    let mut rate = 0f64;
    let (mut accepted, mut stale, mut rejected) = (0u64, 0u64, 0u64);
    let mut backoff = Duration::from_secs(1);
    let mut cur_id = String::new();
    let mut cur_height = 0u64;
    let mut waiting = false;

    loop {
        // 1) submit solutions immediately
        let found = std::mem::take(&mut *shared.found.lock().unwrap());
        for (job, nonce) in found {
            if job.id != cur_id {
                stale += 1;
                continue; // job already replaced; skip a pointless submit
            }
            log!("solution for height {} - submitting", job.height);
            let res = rpc.call(
                "mining_submit",
                serde_json::json!({"job_id": job.id, "nonce": hex::encode(nonce), "worker": cfg.worker}),
            );
            match res {
                Ok(r) if r["accepted"].as_bool() == Some(true) => {
                    accepted += 1;
                    log!(
                        "\x1b[32mBLOCK ACCEPTED\x1b[0m height {} hash {} (total {accepted})",
                        r["height"].as_u64().unwrap_or(job.height),
                        r["hash"].as_str().unwrap_or("?")
                    );
                }
                Ok(r) => {
                    let why = r["reason"].as_str().unwrap_or("rejected");
                    if r["stale"].as_bool() == Some(true) {
                        stale += 1;
                        log!("\x1b[33mstale\x1b[0m: {why}");
                    } else {
                        rejected += 1;
                        log!("\x1b[31mrejected\x1b[0m: {why}");
                    }
                }
                Err(e) => {
                    rejected += 1;
                    log!("\x1b[31msubmit failed\x1b[0m: {e}");
                }
            }
            poll_t = Instant::now() - cfg.poll; // fetch next template now
        }

        // 2) refresh template
        if poll_t.elapsed() >= cfg.poll {
            poll_t = Instant::now();
            let req = serde_json::json!({"address": cfg.address, "worker": cfg.worker, "hashrate": rate});
            match rpc.call("mining_getWork", req) {
                Ok(v) => {
                    backoff = Duration::from_secs(1);
                    match parse_job(&v) {
                        Ok(Some(job)) if job.id != cur_id => {
                            waiting = false;
                            if job.height != cur_height {
                                log!(
                                    "new job: height {} bits 0x{:08x} txs {} | ~{:.2e} hashes/block",
                                    job.height,
                                    job.pow_bits,
                                    job.tx_count,
                                    expected_hashes(&job.target)
                                );
                                cur_height = job.height;
                            }
                            cur_id = job.id.clone();
                            *shared.job.write().unwrap() = Some(Arc::new(job));
                            shared.generation.fetch_add(1, Ordering::Release);
                        }
                        Ok(Some(_)) => {}
                        Ok(None) => {
                            if !waiting {
                                log!("node not ready: {} - waiting", v["reason"].as_str().unwrap_or("unavailable"));
                                waiting = true;
                            }
                            *shared.job.write().unwrap() = None;
                            shared.generation.fetch_add(1, Ordering::Release);
                            cur_id.clear();
                        }
                        Err(e) => log!("bad job from node: {e}"),
                    }
                }
                Err(e) => {
                    if e.starts_with("401") || e.contains("invalid shielded payout address") {
                        eprintln!("fatal: {e}");
                        std::process::exit(1);
                    }
                    log!("\x1b[31mnode error\x1b[0m: {e} - retry in {}s", backoff.as_secs());
                    thread::sleep(backoff);
                    backoff = (backoff * 2).min(Duration::from_secs(30));
                }
            }
        }

        // 3) stats every 30 s
        if rep_t.elapsed() >= Duration::from_secs(30) {
            let h = shared.hashes.load(Ordering::Relaxed);
            let r = (h - rep_h) as f64 / rep_t.elapsed().as_secs_f64();
            rate = if rate == 0.0 { r } else { rate * 0.6 + r * 0.4 };
            (rep_h, rep_t) = (h, Instant::now());
            let eta = shared
                .job
                .read()
                .unwrap()
                .as_ref()
                .map(|j| expected_hashes(&j.target) / rate.max(1.0))
                .unwrap_or(f64::INFINITY);
            log!(
                "{} | height {} | accepted {accepted} stale {stale} rejected {rejected} | ~{} per block | up {}",
                fmt_rate(rate),
                cur_height,
                fmt_dur(eta),
                fmt_dur(start.elapsed().as_secs_f64())
            );
        }
        thread::sleep(Duration::from_millis(50));
    }
}
