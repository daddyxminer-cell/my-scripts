#!/usr/bin/env bash
# =============================================================================
#  hegemon-pool-node.sh — run ON YOUR NODE VPS (e.g. 161.97.92.49)
#
#  Builds hegemon-node v0.10.3 from source with the remote-mining patch
#  (hegemon/node-patch) and restarts your node with a token-protected
#  remote-mining endpoint, so standalone `hegemon-cpuminer` rigs on other
#  VPSes can mine to your wallet WITHOUT running their own node.
#
#  Your existing chain data (~/.hegemon-testnet) and wallet are kept.
#  Consensus is unchanged: the node builds and fully validates every block.
#
#  Usage:
#    bash hegemon-pool-node.sh install      # build patched node, create token, start
#    bash hegemon-pool-node.sh status       # node + per-worker mining stats
#    bash hegemon-pool-node.sh token        # print the miner connect info
#    bash hegemon-pool-node.sh new-token    # rotate the token (miners must update)
#    bash hegemon-pool-node.sh stop|start|restart|rebuild|logs
# =============================================================================
set -euo pipefail

REPO="Pauli-Group/Hegemon"
TAG="${HEGEMON_VERSION:-v0.10.3}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="${HEGEMON_PATCH_DIR:-$SCRIPT_DIR/node-patch}"
PATCH_REPO="${HEGEMON_PATCH_REPO:-https://github.com/daddyxminer-cell/my-scripts.git}"
PATCH_BRANCH="${HEGEMON_PATCH_BRANCH:-main}"
POOL_HOME="${HEGEMON_POOL_HOME:-$HOME/.hegemon-pool}"
SRC="$POOL_HOME/src/Hegemon"
BIN="$POOL_HOME/bin/hegemon-node"
DATA_DIR="${HEGEMON_DATA_DIR:-$HOME/.hegemon-testnet}"     # same as hegemon.sh / launcher
MINING_PORT="${HEGEMON_MINING_PORT:-9944}"                 # public remote-mining port
RPC_PORT="${HEGEMON_RPC_PORT:-9945}"                       # node JSON-RPC (loopback only)
P2P_PORT="${HEGEMON_P2P_PORT:-30333}"
SEEDS="hegemon.pauli.group:30333,devnet.hegemonprotocol.com:30333"
TOKEN_FILE="$POOL_HOME/mining-token"
ENV_FILE="$POOL_HOME/node.env"
UNIT="hegemon-pool-node"
LOG="$POOL_HOME/node.log"

C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[36m'; C_0=$'\e[0m'
[[ -t 1 ]] || { C_G=""; C_Y=""; C_R=""; C_B=""; C_0=""; }
log()  { printf '%s[pool]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
SUDO=""; [[ ${EUID:-$(id -u)} -ne 0 ]] && SUDO="sudo"

[[ "$MINING_PORT" != "$RPC_PORT" ]] || die "mining port and node RPC port must differ"

public_ip() { curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}'; }

have_systemd() {
  have systemctl || return 1
  local st; st="$(systemctl is-system-running 2>/dev/null || true)"
  [[ "$st" =~ ^(running|degraded|starting|initializing)$ ]]
}

ensure_swap_for_build() {
  local mem swap
  mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  swap=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)
  if (( mem + swap < 6000 )); then
    log "Only ${mem} MB RAM + ${swap} MB swap: adding a 6 GB swapfile for the Rust build"
    if [[ ! -f /swapfile-hegemon ]]; then
      $SUDO fallocate -l 6G /swapfile-hegemon 2>/dev/null || $SUDO dd if=/dev/zero of=/swapfile-hegemon bs=1M count=6144 status=none
      $SUDO chmod 600 /swapfile-hegemon && $SUDO mkswap /swapfile-hegemon >/dev/null
    fi
    $SUDO swapon /swapfile-hegemon 2>/dev/null || true
  fi
}

install_deps() {
  log "Installing build dependencies"
  if have apt-get; then
    $SUDO apt-get update -qq
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq build-essential pkg-config libssl-dev clang git curl jq python3 openssl >/dev/null
  elif have dnf; then
    $SUDO dnf install -y gcc gcc-c++ make pkgconf openssl-devel clang git curl jq python3 openssl
  else
    die "Unsupported distro: install build-essential, clang, libssl-dev, git, curl, jq, python3, openssl"
  fi
  if ! have cargo; then
    [[ -f "$HOME/.cargo/env" ]] || curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none
  fi
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
}

fetch_patch() {
  [[ -f "$PATCH_DIR/apply_patch.py" && -f "$PATCH_DIR/remote_mining.rs" ]] && return 0
  log "Patch files not next to this script; fetching them from $PATCH_REPO"
  local tmp="$POOL_HOME/patch-repo"
  rm -rf "$tmp"; git clone -q --depth 1 --branch "$PATCH_BRANCH" "$PATCH_REPO" "$tmp"
  PATCH_DIR="$tmp/hegemon/node-patch"
  [[ -f "$PATCH_DIR/apply_patch.py" ]] || die "node-patch not found in $PATCH_REPO"
}

build_node() {
  fetch_patch
  mkdir -p "$POOL_HOME/bin" "$(dirname "$SRC")"
  if [[ -d "$SRC/.git" ]]; then
    git -C "$SRC" fetch -q --depth 1 origin "refs/tags/$TAG:refs/tags/$TAG" 2>/dev/null || true
    git -C "$SRC" checkout -q --force "$TAG"
    git -C "$SRC" reset -q --hard "$TAG"
    git -C "$SRC" clean -qfd -e target
  else
    log "Cloning $REPO @ $TAG"
    git clone -q --depth 1 --branch "$TAG" "https://github.com/$REPO.git" "$SRC"
  fi
  python3 "$PATCH_DIR/apply_patch.py" "$SRC"
  ensure_swap_for_build
  log "Building hegemon-node (release). First build takes 5-40 min depending on CPU/RAM"
  local jobs; jobs=$(nproc); (( jobs > 4 )) && jobs=4
  ( cd "$SRC" && CARGO_BUILD_JOBS=$jobs cargo build -p hegemon-node --bin hegemon-node --no-default-features --release )
  install -m 755 "$SRC/target/release/hegemon-node" "$BIN"
  ok "Built patched node: $BIN"
}

write_config() {
  mkdir -p "$POOL_HOME"
  if [[ ! -s "$TOKEN_FILE" ]]; then
    ( umask 077; openssl rand -hex 24 > "$TOKEN_FILE" )
    ok "Generated mining token"
  fi
  ( umask 077; cat > "$ENV_FILE" <<EOF
HEGEMON_SEEDS=$SEEDS
HEGEMON_MINE=0
HEGEMON_BOOTSTRAP_AUTHORING=0
HEGEMON_REMOTE_MINING_LISTEN=0.0.0.0:$MINING_PORT
HEGEMON_REMOTE_MINING_TOKEN=$(cat "$TOKEN_FILE")
NO_COLOR=1
RUST_LOG=hegemon_node=info,consensus=info,network=info
EOF
  )
}

kill_wait() {   # kill_wait <pid>  — clean SIGTERM, wait up to 5 min for DB flush
  local p="$1" i
  kill -TERM "$p" 2>/dev/null || return 0
  for i in $(seq 1 300); do kill -0 "$p" 2>/dev/null || return 0; sleep 1; done
  warn "pid $p did not exit after 300s; sending SIGKILL"; kill -KILL "$p" 2>/dev/null || true
}

stop_other_nodes() {
  # Stop the node started by hegemon.sh / official launcher (same data dir / ports).
  local pidf="$HOME/.hegemon-auto/run/node.pid"
  if [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
    log "Stopping node started by hegemon.sh (clean shutdown, may take a minute)"
    kill_wait "$(cat "$pidf")"
    rm -f "$pidf" "$HOME/.hegemon-auto/run/node.mode"
  fi
  if have_systemd; then
    systemctl --user stop hegemon-miner 2>/dev/null || true
    $SUDO systemctl stop hegemon-miner hegemon-worker 2>/dev/null || true
  fi
  local p exe
  for p in $(pgrep -f -- "--base-path $DATA_DIR" 2>/dev/null || true); do
    exe="$(readlink -f "/proc/$p/exe" 2>/dev/null || true)"
    [[ "$exe" == *hegemon-node* ]] || continue
    [[ "$exe" == "$(readlink -f "$BIN")" ]] && continue
    log "Stopping other hegemon-node (pid $p) using $DATA_DIR"
    kill_wait "$p"
  done
}

node_cmd() { echo "$BIN --dev --base-path $DATA_DIR --rpc-methods safe --rpc-port $RPC_PORT --port $P2P_PORT --name HegemonPool"; }

start_node() {
  if have_systemd; then
    $SUDO tee "/etc/systemd/system/$UNIT.service" >/dev/null <<EOF
[Unit]
Description=Hegemon v0.10.3 node with remote CPU-mining endpoint (:$MINING_PORT)
After=network-online.target time-sync.target
Wants=network-online.target

[Service]
User=$(id -un)
EnvironmentFile=$ENV_FILE
ExecStart=$(node_cmd)
StandardOutput=append:$LOG
StandardError=append:$LOG
KillSignal=SIGTERM
TimeoutStopSec=300
Restart=always
RestartSec=15
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable "$UNIT" >/dev/null 2>&1 || true
    $SUDO systemctl restart "$UNIT"
  else
    stop_bg
    ( set -a; source "$ENV_FILE"; set +a
      # shellcheck disable=SC2046
      nohup $(node_cmd) >> "$LOG" 2>&1 & echo $! > "$POOL_HOME/node.pid" )
    warn "No systemd: node started in background (pid $(cat "$POOL_HOME/node.pid")); add '@reboot bash $0 start' to crontab"
  fi
}

stop_bg() { [[ -f "$POOL_HOME/node.pid" ]] && kill_wait "$(cat "$POOL_HOME/node.pid")"; rm -f "$POOL_HOME/node.pid"; }

node_alive() {
  if have_systemd; then systemctl is-active --quiet "$UNIT"
  else [[ -f "$POOL_HOME/node.pid" ]] && kill -0 "$(cat "$POOL_HOME/node.pid")" 2>/dev/null; fi
}

open_firewall() {
  if have ufw && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
    $SUDO ufw allow "$MINING_PORT/tcp" >/dev/null && ok "ufw: opened $MINING_PORT/tcp"
    $SUDO ufw allow "$P2P_PORT/tcp" >/dev/null || true
  elif have firewall-cmd && $SUDO firewall-cmd --state >/dev/null 2>&1; then
    $SUDO firewall-cmd -q --permanent --add-port="$MINING_PORT/tcp" && $SUDO firewall-cmd -q --reload && ok "firewalld: opened $MINING_PORT/tcp"
  fi
  warn "If your VPS provider has a cloud firewall, allow TCP $MINING_PORT there too."
}

wait_up() {
  log "Waiting for the node to reload its chain and open the mining endpoint (can take several minutes)..."
  local i
  for i in $(seq 1 900); do
    if curl -fsS --max-time 3 "http://127.0.0.1:$MINING_PORT/health" >/dev/null 2>&1; then
      ok "Remote-mining endpoint is up on port $MINING_PORT"; return 0
    fi
    node_alive || { tail -n 40 "$LOG" >&2; die "node exited; see $LOG"; }
    sleep 2
  done
  warn "Endpoint not up yet; check: bash $0 logs"
}

note_rpc_port() {
  # hegemon.sh status/balance read this to find the node RPC.
  mkdir -p "$HOME/.hegemon-auto"
  echo "$RPC_PORT" > "$HOME/.hegemon-auto/rpc-port"
  log "Node JSON-RPC moved to 127.0.0.1:$RPC_PORT (hegemon.sh status/balance use it automatically)"
}

print_connect() {
  [[ -s "$TOKEN_FILE" ]] || die "not installed yet: bash $0 install"
  local ip; ip="$(public_ip)"
  echo
  echo "==================== MINER CONNECT INFO ===================="
  echo "  URL   : http://${ip:-YOUR_NODE_IP}:$MINING_PORT"
  echo "  TOKEN : $(cat "$TOKEN_FILE")"
  echo
  echo "On each mining VPS run:   bash hegemon-cpuminer.sh"
  echo "and enter URL, TOKEN and your shca1... payout address."
  echo "Keep the token secret: anyone with it can use your node to mine."
  echo "============================================================"
}

cmd_status() {
  local tok; tok="$(cat "$TOKEN_FILE" 2>/dev/null)" || die "not installed: bash $0 install"
  node_alive && ok "node running" || warn "node not running"
  curl -fsS --max-time 10 -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"mining_stats\",\"params\":[{\"token\":\"$tok\"}]}" \
    "http://127.0.0.1:$MINING_PORT/" | jq -r '.result |
      "  height         : \(.height)   peers: \(.peers)   sync gate open: \(.mining_sync_gate_open)",
      "  remote blocks  : \(.remote_blocks_found)   active jobs: \(.active_jobs)",
      "  total hashrate : \((.remote_hashrate_reported/1e6*100|floor)/100) MH/s (reported by active workers)",
      "  workers:",
      (.workers | to_entries[] |
        "    \(.key): \((.value.reported_hashrate/1e6*100|floor)/100) MH/s  blocks \(.value.blocks)  stale \(.value.stale)  rejected \(.value.rejected)  last seen \((now - .value.last_seen_unix)|floor)s ago\(if .value.last_error then "  err: " + .value.last_error else "" end)")' \
    || die "mining endpoint not reachable on 127.0.0.1:$MINING_PORT (still starting? bash $0 logs)"
}

case "${1:-install}" in
  install)
    install_deps; build_node; write_config; stop_other_nodes; open_firewall
    start_node; wait_up; note_rpc_port; print_connect ;;
  rebuild)   install_deps; build_node; start_node; wait_up ;;
  start)     start_node; wait_up ;;
  stop)      if have_systemd; then $SUDO systemctl stop "$UNIT"; else stop_bg; fi; ok "stopped" ;;
  restart)   start_node; wait_up ;;
  status)    cmd_status ;;
  token)     print_connect ;;
  new-token) rm -f "$TOKEN_FILE"; write_config; start_node; wait_up; print_connect ;;
  logs)      tail -n 100 -f "$LOG" ;;
  *) echo "usage: bash $0 [install|status|token|new-token|start|stop|restart|rebuild|logs]"; exit 2 ;;
esac
