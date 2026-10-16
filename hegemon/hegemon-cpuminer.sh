#!/usr/bin/env bash
# =============================================================================
#  hegemon-cpuminer.sh — STANDALONE CPU miner for Hegemon v0.10.3
#
#  Runs on any mining VPS. No node, no chain sync, no wallet: it connects to
#  your node's remote-mining endpoint (set up with hegemon-pool-node.sh),
#  gets block templates paying YOUR shielded address and hashes on all cores.
#
#  Usage:
#    bash hegemon-cpuminer.sh            # asks node URL, token, address; builds; starts
#    bash hegemon-cpuminer.sh --url http://161.97.92.49:9944 --token TOKEN --address shca1...
#    bash hegemon-cpuminer.sh status|logs|stop|start|restart|benchmark|config|check|update
#  Options: --threads N  --worker NAME  --address-file FILE
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${HEGEMON_CPUMINER_SRC:-$SCRIPT_DIR/cpuminer}"
SRC_REPO="${HEGEMON_CPUMINER_REPO:-https://github.com/daddyxminer-cell/my-scripts.git}"
SRC_BRANCH="${HEGEMON_CPUMINER_BRANCH:-main}"
HOME_DIR="${HEGEMON_CPUMINER_HOME:-$HOME/.hegemon-cpuminer}"
BIN="$HOME_DIR/bin/hegemon-cpuminer"
CONF="$HOME_DIR/miner.conf"
LOG="$HOME_DIR/miner.log"
UNIT="hegemon-cpuminer"
DEFAULT_URL="http://161.97.92.49:9944"

C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[36m'; C_0=$'\e[0m'
[[ -t 1 ]] || { C_G=""; C_Y=""; C_R=""; C_B=""; C_0=""; }
log()  { printf '%s[cpuminer]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[  ok  ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[ warn ]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[ fail ]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
SUDO=""; [[ ${EUID:-$(id -u)} -ne 0 ]] && SUDO="sudo"

URL=""; TOKEN=""; ADDRESS=""; THREADS=""; WORKER=""; CMD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --address) ADDRESS="$2"; shift 2 ;;
    --address-file) ADDRESS="$(cat "$2")"; shift 2 ;;
    --threads) THREADS="$2"; shift 2 ;;
    --worker) WORKER="$2"; shift 2 ;;
    -h|--help) sed -n 2,15p "$0"; exit 0 ;;
    *) CMD="$1"; shift ;;
  esac
done

# HG_URL HG_TOKEN HG_ADDRESS HG_THREADS HG_WORKER
load_conf() { if [[ -f "$CONF" ]]; then source "$CONF"; fi; }

have_systemd() {
  have systemctl || return 1
  local st; st="$(systemctl is-system-running 2>/dev/null || true)"
  [[ "$st" =~ ^(running|degraded|starting|initializing)$ ]]
}

miner_pids() { pgrep -f -- "$BIN --threads" 2>/dev/null || true; }

validate_address() {
  local a="$1"
  [[ "$a" == shca1* ]] || { echo "must start with shca1"; return 1; }
  (( ${#a} > 1000 )) || { echo "too short (${#a} chars) - paste the WHOLE ~2600-char line"; return 1; }
  [[ "$a" =~ ^shca1[02-9ac-hj-np-z]+$ ]] || { echo "invalid characters"; return 1; }
}

ask_config() {
  load_conf
  URL="${URL:-${HG_URL:-}}"; TOKEN="${TOKEN:-${HG_TOKEN:-}}"; ADDRESS="${ADDRESS:-${HG_ADDRESS:-}}"
  THREADS="${THREADS:-${HG_THREADS:-$(nproc)}}"; WORKER="${WORKER:-${HG_WORKER:-$(hostname -s)}}"
  if [[ -t 0 ]]; then
    if [[ -z "$URL" ]]; then
      read -r -p "Node mining URL [$DEFAULT_URL]: " URL; URL="${URL:-$DEFAULT_URL}"
    fi
    if [[ -z "$TOKEN" ]]; then
      echo "Mining token (on the node VPS run: bash hegemon-pool-node.sh token)"
      read -r -p "Token: " TOKEN
    fi
    local why t
    for t in 1 2 3; do
      if [[ -n "$ADDRESS" ]]; then
        ADDRESS="$(tr -d '[:space:]' <<<"$ADDRESS")"
        if why="$(validate_address "$ADDRESS")"; then break; fi
        warn "Invalid address: $why"; ADDRESS=""
      fi
      echo "Paste your shielded payout address (one line, starts with shca1, ~2600 chars):"
      read -r -e -p "Address: " ADDRESS || true
    done
  fi
  URL="${URL:-$DEFAULT_URL}"; URL="${URL%/}"
  [[ "$URL" == http* ]] || URL="http://$URL"
  TOKEN="$(tr -d '[:space:]' <<<"$TOKEN")"
  [[ -n "$TOKEN" ]] || die "Mining token required (--token)"
  ADDRESS="$(tr -d '[:space:]' <<<"$ADDRESS")"
  local why; why="$(validate_address "$ADDRESS")" || die "Invalid payout address: $why"
  [[ "$THREADS" =~ ^[0-9]+$ && "$THREADS" -ge 1 ]] || die "--threads must be >= 1"
  [[ "$WORKER" =~ ^[A-Za-z0-9._-]+$ ]] || WORKER="worker"
  mkdir -p "$HOME_DIR"
  ( umask 077; cat > "$CONF" <<EOF
HG_URL='$URL'
HG_TOKEN='$TOKEN'
HG_ADDRESS='$ADDRESS'
HG_THREADS='$THREADS'
HG_WORKER='$WORKER'
EOF
    printf '%s\n' "$ADDRESS" > "$HOME_DIR/address.txt" )
  ok "Config saved: $CONF (url $URL, threads $THREADS, worker $WORKER)"
}

check_node() {
  load_conf
  local health r
  health="$(curl -fsS --max-time 8 "$HG_URL/health" 2>/dev/null)" \
    || die "Cannot reach $HG_URL/health - is hegemon-pool-node.sh installed on the node and is the TCP port open (VPS + provider firewall)?"
  ok "Node mining endpoint reachable: $health"
  r="$(curl -sS --max-time 15 -H 'Content-Type: application/json' \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"mining_stats\",\"params\":[{\"token\":\"$HG_TOKEN\"}]}" "$HG_URL/")"
  if jq -e '.result.height' >/dev/null 2>&1 <<<"$r"; then
    ok "Token accepted. Node height $(jq -r .result.height <<<"$r"), sync gate open: $(jq -r .result.mining_sync_gate_open <<<"$r")"
  else
    die "Node rejected the token: $(jq -r '.error.message // .' <<<"$r" 2>/dev/null || echo "$r")"
  fi
}

install_deps() {
  if have apt-get; then
    $SUDO apt-get update -qq
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq build-essential pkg-config git curl jq ca-certificates >/dev/null
  elif have dnf; then $SUDO dnf install -y gcc make git curl jq
  fi
  if ! have cargo; then
    [[ -f "$HOME/.cargo/env" ]] || curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
  fi
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
  # rustup may exist without a default toolchain (e.g. installed by hegemon-pool-node.sh)
  if ! cargo --version >/dev/null 2>&1; then
    log "Installing stable Rust toolchain"
    rustup toolchain install stable --profile minimal >/dev/null
    rustup default stable >/dev/null
  fi
}

build_miner() {
  if [[ ! -f "$SRC_DIR/Cargo.toml" ]]; then
    log "Miner source not next to this script; fetching it from $SRC_REPO"
    local tmp="$HOME_DIR/src-repo"
    rm -rf "$tmp"; git clone -q --depth 1 --branch "$SRC_BRANCH" "$SRC_REPO" "$tmp"
    SRC_DIR="$tmp/hegemon/cpuminer"
    [[ -f "$SRC_DIR/Cargo.toml" ]] || die "cpuminer source not found in $SRC_REPO"
  fi
  log "Building hegemon-cpuminer optimised for THIS CPU (target-cpu=native)"
  if grep -qw sha_ni /proc/cpuinfo; then ok "CPU has SHA extensions (SHA-NI): fastest hashing path"
  else warn "CPU has no SHA-NI; using AVX2/SSE SHA-256 (slower per core)"; fi
  ( cd "$SRC_DIR" && RUSTFLAGS="-C target-cpu=native" cargo build --release --quiet )
  mkdir -p "$HOME_DIR/bin"
  install -m 755 "$SRC_DIR/target/release/hegemon-cpuminer" "$BIN"
  ok "Installed $BIN ($("$BIN" --version))"
}

stop_bg() {
  [[ -f "$HOME_DIR/miner.pid" ]] && kill "$(cat "$HOME_DIR/miner.pid")" 2>/dev/null || true
  rm -f "$HOME_DIR/miner.pid"
  local p; for p in $(miner_pids); do kill "$p" 2>/dev/null || true; done
}

start_miner() {
  load_conf
  [[ -x "$BIN" ]] || die "miner not built yet: bash $0"
  ( umask 077; cat > "$HOME_DIR/miner.env" <<EOF
HEGEMON_POOL_URL=$HG_URL
HEGEMON_MINING_TOKEN=$HG_TOKEN
HEGEMON_MINER_ADDRESS=$HG_ADDRESS
EOF
  )
  touch "$LOG" 2>/dev/null || $SUDO chown "$(id -un)" "$LOG"
  if have_systemd; then
    $SUDO tee "/etc/systemd/system/$UNIT.service" >/dev/null <<EOF
[Unit]
Description=Hegemon standalone CPU miner -> $HG_URL
After=network-online.target
Wants=network-online.target

[Service]
User=$(id -un)
EnvironmentFile=$HOME_DIR/miner.env
ExecStart=$BIN --threads $HG_THREADS --worker $HG_WORKER
StandardOutput=append:$LOG
StandardError=append:$LOG
Restart=always
RestartSec=10
Nice=10
CPUSchedulingPolicy=batch

[Install]
WantedBy=multi-user.target
EOF
    stop_bg
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable "$UNIT" >/dev/null 2>&1 || true
    $SUDO systemctl restart "$UNIT" || true
    sleep 3
    if systemctl is-active --quiet "$UNIT"; then
      ok "Miner running as service '$UNIT' (starts at boot, restarts on crash)"; return 0
    fi
    warn "systemd service did not start; falling back to a background process"
  fi
  stop_bg
  ( set -a; source "$HOME_DIR/miner.env"; set +a
    nohup nice -n 10 "$BIN" --threads "$HG_THREADS" --worker "$HG_WORKER" >> "$LOG" 2>&1 &
    echo $! > "$HOME_DIR/miner.pid" )
  sleep 2
  kill -0 "$(cat "$HOME_DIR/miner.pid")" 2>/dev/null || { tail -n 20 "$LOG" >&2; die "miner exited; see $LOG"; }
  ok "Miner started in background (pid $(cat "$HOME_DIR/miner.pid"))"
  warn "No systemd: for auto-start after reboot add to crontab:  @reboot bash $SCRIPT_DIR/$(basename "$0") start"
}

stop_miner() {
  if have_systemd && systemctl is-active --quiet "$UNIT" 2>/dev/null; then $SUDO systemctl stop "$UNIT" || true; fi
  stop_bg
  ok "stopped"
}

cmd_status() {
  local pids; pids="$(miner_pids | tr '\n' ' ')"
  if [[ -n "${pids// /}" ]]; then ok "miner running (pid ${pids% })"
  else warn "miner not running (start: bash $0 start)"; fi
  echo "--- recent miner output ---"
  grep -E "H/s|ACCEPTED|stale|rejected|error|not ready|fatal" "$LOG" 2>/dev/null | tail -n 8 || true
}

case "${CMD:-install}" in
  install)   ask_config; install_deps; check_node; build_miner; start_miner; sleep 3; cmd_status
             echo; log "Live output: bash $0 logs    |    status: bash $0 status" ;;
  config)    ask_config; check_node; start_miner ;;
  update)    install_deps; build_miner; start_miner ;;
  start)     start_miner ;;
  stop)      stop_miner ;;
  restart)   stop_miner; start_miner ;;
  status)    cmd_status ;;
  logs)      tail -n 50 -f "$LOG" ;;
  check)     check_node ;;
  benchmark) [[ -x "$BIN" ]] || { install_deps; build_miner; }
             load_conf; "$BIN" --benchmark --threads "${THREADS:-${HG_THREADS:-$(nproc)}}" ;;
  *) echo "usage: bash $0 [install|config|status|logs|start|stop|restart|benchmark|check|update]"; exit 2 ;;
esac
