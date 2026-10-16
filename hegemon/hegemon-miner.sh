#!/usr/bin/env bash
# =============================================================================
#  hegemon-miner.sh — mining-only worker for extra VPSes
#
#  Hegemon v0.10.x has NO remote-work / pool RPC (hegemon_poolWork and
#  hegemon_compactJob return "not enabled in milestone 1"), so a VPS cannot
#  "mine to" another node's RPC. The supported way is: run a mining
#  hegemon-node on every VPS, peer it with your main node over P2P (30333),
#  and pay every worker to the SAME shielded address. All rewards then show up
#  in the one wallet on your main VPS.
#
#  No wallet, no passphrase and no private key on the worker — only the public
#  payout address.
#
#  Quick start (on the extra VPS):
#    bash hegemon-miner.sh                      # asks for the payout address first
#    bash hegemon-miner.sh --address shca1...   # or: --address-file addr.txt
#  Get the address on the MAIN VPS with:  bash hegemon.sh address
# =============================================================================
set -euo pipefail

REPO="Pauli-Group/Hegemon"
MAIN_NODE="${HEGEMON_MAIN_NODE:-161.97.92.49:30333}"           # your node (P2P port)
OFFICIAL_SEEDS="hegemon.pauli.group:30333,devnet.hegemonprotocol.com:30333"
EXPECTED_GENESIS="0x506fc2cd5ed367cc68d6d23a987fe6e4a7916fde02a249105ab91884a1e6fa59"

MINER_HOME="${HEGEMON_MINER_HOME:-$HOME/.hegemon-miner}"
DATA_DIR="${HEGEMON_DATA_DIR:-$MINER_HOME/data}"
RPC_PORT="${HEGEMON_RPC_PORT:-9944}"          # loopback only
P2P_PORT="${HEGEMON_P2P_PORT:-30333}"
RELEASE_TAG="${HEGEMON_VERSION:-latest}"
WORKER_NAME="${HEGEMON_WORKER_NAME:-miner-$(hostname -s 2>/dev/null || echo vps)}"
STARTUP_TIMEOUT="${HEGEMON_STARTUP_TIMEOUT:-1800}"
STOP_TIMEOUT="${HEGEMON_STOP_TIMEOUT:-300}"
UNCAP_THREADS=0

_cores() { getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 2; }
MINE_THREADS="${HEGEMON_MINE_THREADS:-$(_cores)}"

BIN_DIR="$MINER_HOME/bin"; LOG_DIR="$MINER_HOME/logs"; RUN_DIR="$MINER_HOME/run"
NODE_BIN="$BIN_DIR/hegemon-node"; NODE_LOG="$LOG_DIR/node.log"; NODE_PID="$RUN_DIR/node.pid"
ADDR_FILE="$MINER_HOME/payout-address.txt"
RPC_URL="http://127.0.0.1:${RPC_PORT}"
UNIT_NAME="hegemon-worker"

if [[ -t 1 ]]; then C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
else C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""; fi
log()  { printf '%s[miner]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[ ok  ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[warn ]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[error]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
sha256_of() { if have sha256sum; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
SUDO=""; [[ ${EUID:-$(id -u)} -ne 0 ]] && have sudo && SUDO="sudo"

seeds() {   # main node first, then the approved list (avoids partitions if main is down)
  local s="$MAIN_NODE"
  [[ -n "${HEGEMON_EXTRA_SEEDS:-}" ]] && s="$s,$HEGEMON_EXTRA_SEEDS"
  echo "$s,$OFFICIAL_SEEDS"
}

rpc() {
  curl --fail --silent --show-error --connect-timeout 3 --max-time 20 -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":${2:-[]}}" "$RPC_URL/"
}
node_running() {
  if have systemctl && systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null; then return 0; fi
  [[ -f "$NODE_PID" ]] && kill -0 "$(cat "$NODE_PID")" 2>/dev/null
}

ensure_tools() {
  local m=(); for t in curl jq unzip; do have "$t" || m+=("$t"); done
  (( UNCAP_THREADS )) && { have git || m+=(git); have make || m+=(make); }
  ((${#m[@]})) || return 0
  log "Installing: ${m[*]}"
  if have apt-get; then $SUDO apt-get update -y && $SUDO apt-get install -y "${m[@]}" ca-certificates
  elif have dnf; then $SUDO dnf install -y "${m[@]}"
  elif have yum; then $SUDO yum install -y "${m[@]}"
  else die "Install manually: ${m[*]}"; fi
}

# ------------------------------ payout address ------------------------------
validate_address() {   # validate_address <addr>  -> prints reason on failure
  local a="$1"
  [[ -n "$a" ]]          || { echo "empty"; return 1; }
  [[ "$a" == shca1* ]]   || { echo "must start with 'shca1' (got '${a:0:12}...')"; return 1; }
  (( ${#a} > 1000 ))     || { echo "too short (${#a} chars) - Hegemon addresses are ~2.6 KB, copy the whole line"; return 1; }
  [[ "$a" =~ ^shca1[02-9ac-hj-np-z]+$ ]] || { echo "contains invalid bech32m characters"; return 1; }
}

save_address() {
  local a="$1"
  mkdir -p "$MINER_HOME"; printf '%s\n' "$a" > "$ADDR_FILE"; chmod 600 "$ADDR_FILE"
  ok "Payout address saved (${#a} chars): ${a:0:24}...${a: -12}"
  ok "Stored in $ADDR_FILE"
}

# Sources, in priority order: --address, --address-file, $HEGEMON_MINER_ADDRESS,
# interactive prompt (offers to keep an already-saved address).
set_address() {
  local a="" why
  if [[ -n "${ADDRESS_ARG:-}" ]]; then a="$ADDRESS_ARG"
  elif [[ -n "${ADDRESS_FILE_ARG:-}" ]]; then
    [[ -r "$ADDRESS_FILE_ARG" ]] || die "Cannot read $ADDRESS_FILE_ARG"
    a="$(cat "$ADDRESS_FILE_ARG")"
  elif [[ -n "${HEGEMON_MINER_ADDRESS:-}" ]]; then a="$HEGEMON_MINER_ADDRESS"
  fi
  if [[ -n "$a" ]]; then
    a="$(tr -d '[:space:]' <<<"$a")"
    why="$(validate_address "$a")" || die "Invalid payout address: $why"
    save_address "$a"; return 0
  fi

  [[ -t 0 ]] || { [[ -s "$ADDR_FILE" ]] && return 0
                  die "No payout address. Use --address shca1... , --address-file FILE or HEGEMON_MINER_ADDRESS"; }

  if [[ -s "$ADDR_FILE" && "${FORCE_ADDRESS_PROMPT:-0}" != 1 ]]; then
    local cur; cur="$(cat "$ADDR_FILE")"
    echo
    echo "Saved payout address: ${cur:0:24}...${cur: -12}"
    local yn; read -r -p "Keep this address? [Y/n] " yn
    [[ "$yn" =~ ^[Nn] ]] || { ok "Keeping saved payout address"; return 0; }
  fi

  echo
  echo "=================================================================="
  echo " Enter the shielded payout address for this miner."
  echo " Mining rewards go to this address (your MAIN VPS wallet)."
  echo " On the main VPS get it with:   bash hegemon.sh address"
  echo " It is one long line (~2600 chars) starting with shca1"
  echo "=================================================================="
  local tries
  for tries in 1 2 3; do
    # read -e avoids the 4096-byte canonical-mode line limit on long pastes
    read -r -e -p "Payout address: " a || true
    a="$(tr -d '[:space:]' <<<"$a")"
    if why="$(validate_address "$a")"; then save_address "$a"; return 0; fi
    warn "Invalid address: $why"
  done
  die "No valid payout address entered"
}

# --------------------------------- install ----------------------------------
platform() {
  case "$(uname -s):$(uname -m)" in
    Linux:x86_64|Linux:amd64) echo linux-x86_64 ;;
    Darwin:x86_64) echo macos-x86_64 ;;
    Darwin:arm64|Darwin:aarch64) echo macos-arm64 ;;
    *) echo unsupported ;;
  esac
}

resolve_tag() {
  if [[ "$RELEASE_TAG" == latest ]]; then
    RELEASE_TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | jq -r .tag_name)"
    [[ -n "$RELEASE_TAG" && "$RELEASE_TAG" != null ]] || die "Cannot resolve latest release"
  fi
  local v="${RELEASE_TAG#v}"; v="${v%%-*}"
  [[ "$(printf '%s\n0.10.2\n' "$v" | sort -V | head -n1)" == 0.10.2 ]] \
    || die "$RELEASE_TAG < v0.10.2 forks off the public testnet after block 120,000"
}

install_release() {
  local plat; plat="$(platform)"
  [[ "$plat" != unsupported ]] || die "No prebuilt binary for $(uname -sm); use --uncap-threads (source build)"
  local url="https://github.com/$REPO/releases/download/$RELEASE_TAG/hegemon-node-$plat"
  local dest="$MINER_HOME/releases/$RELEASE_TAG"; mkdir -p "$dest" "$BIN_DIR"
  log "Downloading hegemon-node-$plat ($RELEASE_TAG)"
  curl -fL --retry 3 --progress-bar -o "$dest/hegemon-node" "$url"
  curl -fsSL --retry 3 -o "$dest/hegemon-node.sha256" "$url.sha256"
  [[ "$(awk '{print $1}' "$dest/hegemon-node.sha256")" == "$(sha256_of "$dest/hegemon-node")" ]] \
    || die "SHA-256 mismatch for hegemon-node"
  ok "Checksum verified"
  chmod +x "$dest/hegemon-node"; ln -sfn "$dest/hegemon-node" "$NODE_BIN"
}

# Optional: build from source with the node's local mining-thread cap raised.
# Upstream caps mining at min(2, cores-3) threads to keep sync/RPC responsive.
# That cap is a local liveness setting, not a consensus rule. On a dedicated
# miner we reserve 1 core for networking/sync instead of 3 and remove the 2-thread
# ceiling. Needs a lot of RAM/disk for the Rust build (~4 GB RAM recommended).
install_uncapped() {
  local src="$MINER_HOME/src/Hegemon"
  if [[ -d "$src/.git" ]]; then git -C "$src" fetch --tags --force -q origin
  else mkdir -p "$(dirname "$src")"; git clone -q "https://github.com/$REPO.git" "$src"; fi
  git -C "$src" checkout -q --force "$RELEASE_TAG"
  local mod="$src/node/src/native/mod.rs"
  grep -q 'NATIVE_MINING_BACKGROUND_THREAD_CAP: u32 = ' "$mod" || die "Thread-cap constant not found in $RELEASE_TAG; cannot patch"
  sed -i.bak -E \
    -e 's/(NATIVE_MINING_BACKGROUND_THREAD_CAP: u32 = )[0-9]+;/\1256;/' \
    -e 's/(NATIVE_MINING_RESERVED_SERVICE_THREADS: u32 = )[0-9]+;/\11;/' "$mod"
  grep -nE 'NATIVE_MINING_(BACKGROUND_THREAD_CAP|RESERVED_SERVICE_THREADS): u32' "$mod"
  local mem; mem="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
  (( mem == 0 || mem >= 3500 )) || warn "Only ${mem} MB RAM: the Rust build may be OOM-killed (add swap: fallocate -l 4G /swapfile ...)"
  log "Installing Rust + build deps and building hegemon-node — this can take 30+ min"
  if have apt-get; then $SUDO apt-get install -y build-essential pkg-config libssl-dev clang git >/dev/null; fi
  if ! have cargo && [[ ! -f "$HOME/.cargo/env" ]]; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none
  fi
  # shellcheck disable=SC1091
  [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"   # rust-toolchain.toml pins the exact version
  ( cd "$src" && cargo build -p hegemon-node --bin hegemon-node --no-default-features --release )
  mkdir -p "$BIN_DIR"; ln -sfn "$src/target/release/hegemon-node" "$NODE_BIN"
  ok "Built uncapped hegemon-node from $RELEASE_TAG"
}

cmd_install() {
  ensure_tools; resolve_tag
  if (( UNCAP_THREADS )); then install_uncapped; else install_release; fi
  "$NODE_BIN" --help >/dev/null || die "hegemon-node does not run on this machine"
  echo "$RELEASE_TAG$( (( UNCAP_THREADS )) && echo ' (uncapped)')" > "$MINER_HOME/installed-version"
  ok "hegemon-node $RELEASE_TAG installed -> $NODE_BIN"
}

# ------------------------------- run / stop ---------------------------------
preflight() {
  [[ -x "$NODE_BIN" ]] || die "Not installed. Run: bash $0 install"
  [[ -s "$ADDR_FILE" ]] || set_address
  mkdir -p "$DATA_DIR" "$LOG_DIR" "$RUN_DIR"
  local avail; avail="$(df -Pm "$DATA_DIR" | awk 'NR==2{print $4}')"
  (( avail > 256 )) || die "Only ${avail} MB free for $DATA_DIR"
  (( avail > 2048 )) || warn "Only ${avail} MB free; the chain keeps growing"
  if have timedatectl && ! timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qi yes; then
    warn "Clock not NTP-synced: blocks >90s in the future are rejected. Fix: sudo timedatectl set-ntp true"
  fi
  if have ss && ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]($RPC_PORT|$P2P_PORT)\$"; then
    die "Port $RPC_PORT or $P2P_PORT already in use (another node?). Use --rpc-port/--port or stop it."
  fi
  local host="${MAIN_NODE%:*}" port="${MAIN_NODE##*:}"
  if timeout 6 bash -c "</dev/tcp/$host/$port" 2>/dev/null; then ok "Main node $MAIN_NODE reachable (P2P)"
  else warn "Main node $MAIN_NODE not reachable — check its firewall allows TCP $port. Falling back to official seeds."; fi
}

node_env() {
  cat <<EOF
HEGEMON_SEEDS=$(seeds)
HEGEMON_MINE=1
HEGEMON_MINE_THREADS=$MINE_THREADS
HEGEMON_MINER_ADDRESS=$(cat "$ADDR_FILE")
HEGEMON_BOOTSTRAP_AUTHORING=0
NO_COLOR=1
RUST_LOG=hegemon_node=info,consensus=info,network=info
EOF
}
node_args() { echo "--dev --base-path $DATA_DIR --rpc-methods safe --rpc-port $RPC_PORT --port $P2P_PORT --name $WORKER_NAME"; }

wait_for_rpc() {
  local start; start=$(date +%s)
  log "Waiting for node RPC (a synced chain takes minutes to reload)..."
  while ! rpc system_health >/dev/null 2>&1; do
    node_running || { tail -n 30 "$NODE_LOG" >&2 2>/dev/null; die "Node exited during startup (log: $NODE_LOG)"; }
    (( $(date +%s) - start < STARTUP_TIMEOUT )) || die "RPC not up after ${STARTUP_TIMEOUT}s; re-run 'bash $0 status' later"
    [[ -t 1 ]] && printf '\r  starting... %ss ' "$(( $(date +%s) - start ))"
    sleep 3
  done
  [[ -t 1 ]] && echo
  local g; g="$(rpc chain_getBlockHash '[0]' | jq -r '.result // empty')"
  if [[ "$g" != "$EXPECTED_GENESIS" ]]; then cmd_stop; die "Unexpected genesis $g — stopped"; fi
  ok "Node up, genesis OK"
}

cmd_start() {
  preflight
  if node_running; then log "Worker already running"; wait_for_rpc; return; fi
  log "Starting mining worker '$WORKER_NAME' (threads requested: $MINE_THREADS)"
  log "Seeds: $(seeds)"
  echo "===== $(date -u '+%F %T UTC') start =====" >> "$NODE_LOG"
  # shellcheck disable=SC2046
  nohup env $(node_env | tr '\n' ' ') "$NODE_BIN" $(node_args) >> "$NODE_LOG" 2>&1 &
  echo $! > "$NODE_PID"
  wait_for_rpc
  ok "Mining is enabled. The node's sync gate starts hashing once the chain is caught up."
  log "First sync of the chain can take a while. Watch: bash $0 status   |   bash $0 logs"
}

cmd_stop() {
  if have systemctl && systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null; then
    $SUDO systemctl stop "$UNIT_NAME"; ok "Service stopped"; return
  fi
  if [[ -f "$NODE_PID" ]] && kill -0 "$(cat "$NODE_PID")" 2>/dev/null; then
    local pid; pid="$(cat "$NODE_PID")"; log "Stopping worker (pid $pid)..."
    kill -TERM "$pid"; local i
    for (( i = 0; i < STOP_TIMEOUT; i++ )); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -0 "$pid" 2>/dev/null && { warn "Forcing kill"; kill -KILL "$pid"; }
    ok "Stopped"
  else log "Not running"; fi
  rm -f "$NODE_PID"
}

cmd_status() {
  local out
  out="$(curl --fail --silent --connect-timeout 3 --max-time 15 -H 'Content-Type: application/json' \
    --data '[{"jsonrpc":"2.0","id":1,"method":"system_health","params":[]},{"jsonrpc":"2.0","id":2,"method":"hegemon_miningStatus","params":[]},{"jsonrpc":"2.0","id":3,"method":"chain_getBlockHash","params":[0]},{"jsonrpc":"2.0","id":4,"method":"system_version","params":[]}]' \
    "$RPC_URL/")" || die "Worker RPC not reachable on $RPC_URL (is it running? bash $0 start)"
  jq -r '(map({(.id|tostring): .result}) | add) as $r |
    "  worker       : '"$WORKER_NAME"'  (\($r["4"]))",
    "  peers        : \($r["1"].peers)   syncing: \($r["1"].isSyncing)",
    "  height       : \($r["2"].block_height) / \($r["2"].sync_target_height)",
    "  mining       : \($r["2"].is_mining)   threads: \($r["2"].threads)   gate_open: \($r["2"].mining_sync_gate_open)",
    "  hash rate    : \(($r["2"].hash_rate // 0) / 1000000 * 100 | floor / 100) MH/s",
    "  blocks found : \($r["2"].blocks_found)",
    "  genesis      : \(if $r["3"] == "'"$EXPECTED_GENESIS"'" then "OK" else "MISMATCH \($r["3"])" end)"' <<<"$out"
  local host="${MAIN_NODE%:*}"
  if grep -q "peer connected: $host" "$NODE_LOG" 2>/dev/null; then ok "Has connected to main node $host"
  else warn "No connection to main node $host seen in the log yet"; fi
  log "Payout: $(cut -c1-24 "$ADDR_FILE")...  (rewards appear in the MAIN VPS wallet: bash hegemon.sh balance)"
  grep -m1 -o 'requested_threads=[0-9]* effective_threads=[0-9]*' "$NODE_LOG" 2>/dev/null | tail -1 \
    | sed 's/^/  thread cap   : /' || true
}

cmd_systemd() {
  have systemctl || die "systemd not available"
  preflight
  [[ -f "$NODE_PID" ]] && kill -0 "$(cat "$NODE_PID")" 2>/dev/null && cmd_stop
  local envf="$MINER_HOME/worker.env" unit="/etc/systemd/system/$UNIT_NAME.service"
  node_env > "$envf"; chmod 600 "$envf"
  $SUDO tee "$unit" >/dev/null <<EOF
[Unit]
Description=Hegemon mining worker ($WORKER_NAME -> $MAIN_NODE)
After=network-online.target time-sync.target
Wants=network-online.target

[Service]
User=$(id -un)
EnvironmentFile=$envf
ExecStart=$NODE_BIN $(node_args)
StandardOutput=append:$NODE_LOG
StandardError=append:$NODE_LOG
KillSignal=SIGTERM
TimeoutStopSec=$STOP_TIMEOUT
Restart=always
RestartSec=20
Nice=5

[Install]
WantedBy=multi-user.target
EOF
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now "$UNIT_NAME"
  ok "Service '$UNIT_NAME' enabled (starts at boot, restarts on crash)"
  wait_for_rpc
}

cmd_uninstall_service() {
  have systemctl || return 0
  $SUDO systemctl disable --now "$UNIT_NAME" 2>/dev/null || true
  $SUDO rm -f "/etc/systemd/system/$UNIT_NAME.service"; $SUDO systemctl daemon-reload
  ok "Service removed (data kept in $DATA_DIR)"
}

apply_address_change() {
  if have systemctl && systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null; then
    node_env > "$MINER_HOME/worker.env"; chmod 600 "$MINER_HOME/worker.env"
    log "Restarting service to use the new address..."; $SUDO systemctl restart "$UNIT_NAME"; wait_for_rpc
  elif [[ -f "$NODE_PID" ]] && kill -0 "$(cat "$NODE_PID")" 2>/dev/null; then
    log "Restarting worker to use the new address..."; cmd_stop; cmd_start
  else
    log "Address saved. Start mining with: bash $0 start"
  fi
}

cmd_update() {
  local svc=0; have systemctl && systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null && svc=1
  cmd_stop; cmd_install
  if (( svc )); then $SUDO systemctl start "$UNIT_NAME"; wait_for_rpc; else cmd_start; fi
}

usage() {
  cat <<EOF
Hegemon mining-only worker (no wallet on this VPS).

Usage: bash $0 [options] [command]

Commands:
  all (default)  install + set payout address + start mining (background)
  install        download the verified hegemon-node release binary
  address        change the payout address (prompts; restarts the miner)
  show-address   print the saved payout address
  start          start the mining node        stop      stop it cleanly
  status         height, peers, hash rate, blocks found
  logs           follow the log               update    upgrade + restart
  systemd        run as a system service (auto-start at boot, auto-restart)
  remove-service remove the systemd service

Options:
  --address shca1...      payout address (from main VPS: bash hegemon.sh address)
  --address-file FILE     read the address from a file
  --main HOST:PORT        main node P2P address (default $MAIN_NODE)
  --threads N             requested mining threads (default: all cores)
  --uncap-threads         build from source with the node's thread cap lifted
                          (upstream release caps mining at min(2, cores-3))
  --name NAME             worker name (default $WORKER_NAME)
  --version vX.Y.Z        release tag (default latest, >= v0.10.2)
  --data-dir PATH         --rpc-port PORT   --port PORT
EOF
}

CMD=""; ADDRESS_ARG=""; ADDRESS_FILE_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --address) ADDRESS_ARG="$2"; shift 2 ;;
    --address-file) ADDRESS_FILE_ARG="$2"; shift 2 ;;
    --main) MAIN_NODE="$2"; shift 2 ;;
    --threads) MINE_THREADS="$2"; shift 2 ;;
    --uncap-threads) UNCAP_THREADS=1; shift ;;
    --name) WORKER_NAME="$2"; shift 2 ;;
    --version) RELEASE_TAG="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    --rpc-port) RPC_PORT="$2"; RPC_URL="http://127.0.0.1:$2"; shift 2 ;;
    --port) P2P_PORT="$2"; shift 2 ;;
    -h|--help|help) usage; exit 0 ;;
    -*) die "Unknown option $1" ;;
    *) CMD="$1"; shift ;;
  esac
done
[[ "$MAIN_NODE" == *:* ]] || MAIN_NODE="$MAIN_NODE:30333"
[[ "$MINE_THREADS" =~ ^[0-9]+$ && "$MINE_THREADS" -ge 1 ]] || die "--threads must be >= 1"
# --address/--address-file given with start/systemd/update: save it first
case "${CMD:-all}" in
  start|systemd|update) [[ -n "$ADDRESS_ARG$ADDRESS_FILE_ARG" ]] && set_address ;;
esac

case "${CMD:-all}" in
  all)     set_address; [[ -x "$NODE_BIN" ]] || cmd_install; cmd_start ;;
  install) set_address; cmd_install ;;
  address) FORCE_ADDRESS_PROMPT=1 set_address; apply_address_change ;;
  show-address) [[ -s "$ADDR_FILE" ]] && cat "$ADDR_FILE" || die "No payout address saved" ;;
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  status)  cmd_status ;;
  logs)    tail -n 100 -f "$NODE_LOG" ;;
  update)  cmd_update ;;
  systemd) cmd_systemd ;;
  remove-service) cmd_uninstall_service ;;
  *) usage; exit 2 ;;
esac
