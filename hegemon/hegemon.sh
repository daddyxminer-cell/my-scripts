#!/usr/bin/env bash
# =============================================================================
#  hegemon.sh — automated download / install / build / wallet / node / miner
#               for Hegemon (HGN)  https://github.com/Pauli-Group/Hegemon
#
#  Follows the upstream README.md, runbooks/miner_wallet_quickstart.md and the
#  release TESTNET-README.txt:
#    * release mode : download the official release ZIP for your platform,
#                     verify its SHA-256, extract (default, fast)
#    * source mode  : git clone at the release tag, `make setup`, `make node`,
#                     `cargo build --release -p walletd -p wallet`
#    * wallet       : walletd --mode create / open  (store ~/.hegemon-wallet)
#    * node         : same env/flags as the official testnet-start.sh launcher
#                     (--dev --rpc-methods safe + approved seeds = public testnet)
#    * miner        : relay first -> verify genesis + sync -> restart mining
#                     with HEGEMON_MINER_ADDRESS = your shielded address
#
#  Usage:  bash hegemon.sh help
# =============================================================================
set -euo pipefail

# ----------------------------- configuration --------------------------------
REPO="Pauli-Group/Hegemon"
REPO_URL="https://github.com/${REPO}.git"

HEGEMON_HOME="${HEGEMON_HOME:-$HOME/.hegemon-auto}"          # binaries/logs/pids
DATA_DIR="${HEGEMON_DATA_DIR:-$HOME/.hegemon-testnet}"        # node state (same as launcher)
WALLET_STORE="${HEGEMON_WALLET_STORE:-$HOME/.hegemon-wallet}" # wallet store (same as docs)
RPC_PORT="${HEGEMON_RPC_PORT:-$(cat "${HEGEMON_HOME:-$HOME/.hegemon-auto}/rpc-port" 2>/dev/null || echo 9944)}"
P2P_PORT="${HEGEMON_P2P_PORT:-30333}"
NODE_NAME="${HEGEMON_NODE_NAME:-HegemonTestnet}"
SEEDS="${HEGEMON_SEEDS_OVERRIDE:-hegemon.pauli.group:30333,devnet.hegemonprotocol.com:30333}"
EXPECTED_GENESIS="${HEGEMON_EXPECTED_GENESIS:-0x506fc2cd5ed367cc68d6d23a987fe6e4a7916fde02a249105ab91884a1e6fa59}"
RELEASE_TAG="${HEGEMON_VERSION:-latest}"                      # e.g. v0.10.3
INSTALL_MODE="${HEGEMON_INSTALL_MODE:-release}"               # release | source
SYNC_TIMEOUT="${HEGEMON_SYNC_TIMEOUT:-0}"                     # seconds, 0 = wait forever
# A synced node reloads + re-verifies its sled DB before binding RPC; on a full
# testnet chain this takes minutes, so the RPC wait must be long.
STARTUP_TIMEOUT="${HEGEMON_STARTUP_TIMEOUT:-1800}"             # seconds to wait for RPC
STOP_TIMEOUT="${HEGEMON_STOP_TIMEOUT:-300}"                    # seconds before SIGKILL

_default_threads() {
  local n
  n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
  (( n > 1 )) && echo $((n - 1)) || echo 1
}
MINE_THREADS="${HEGEMON_MINE_THREADS:-$(_default_threads)}"

BIN_DIR="$HEGEMON_HOME/bin"
SRC_DIR="$HEGEMON_HOME/src/Hegemon"
LOG_DIR="$HEGEMON_HOME/logs"
RUN_DIR="$HEGEMON_HOME/run"
NODE_LOG="$LOG_DIR/node.log"
NODE_PID="$RUN_DIR/node.pid"
NODE_MODE_FILE="$RUN_DIR/node.mode"
ADDR_FILE="$HEGEMON_HOME/miner-address.txt"
RPC_URL="http://127.0.0.1:${RPC_PORT}"

# ------------------------------- helpers ------------------------------------
if [[ -t 1 ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""
fi
log()  { printf '%s[hegemon]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[  ok  ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[ warn ]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[error ]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

sha256_of() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

need_root_cmd() {   # prints "sudo" when not root and sudo exists
  if [[ ${EUID:-$(id -u)} -ne 0 ]] && have sudo; then echo sudo; fi
}

ensure_base_tools() {
  local missing=()
  for t in curl jq unzip; do have "$t" || missing+=("$t"); done
  [[ "$INSTALL_MODE" == "source" ]] && { have git || missing+=(git); have make || missing+=(make); }
  ((${#missing[@]} == 0)) && return 0
  log "Installing missing tools: ${missing[*]}"
  local SUDO; SUDO="$(need_root_cmd)"
  if have apt-get; then
    $SUDO apt-get update -y && $SUDO apt-get install -y "${missing[@]}" ca-certificates
  elif have dnf; then $SUDO dnf install -y "${missing[@]}"
  elif have yum; then $SUDO yum install -y "${missing[@]}"
  elif have pacman; then $SUDO pacman -Sy --noconfirm "${missing[@]}"
  elif have brew; then brew install "${missing[@]}"
  else die "Please install manually: ${missing[*]}"; fi
}

detect_platform() {
  case "$(uname -s):$(uname -m)" in
    Linux:x86_64|Linux:amd64)       PLATFORM="linux-x86_64" ;;
    Darwin:x86_64)                  PLATFORM="macos-x86_64" ;;
    Darwin:arm64|Darwin:aarch64)    PLATFORM="macos-arm64" ;;
    Linux:aarch64|Linux:arm64)      PLATFORM="linux-arm64" ;;   # no prebuilt -> source
    *) die "Unsupported platform $(uname -s) $(uname -m)" ;;
  esac
}

NODE_BIN()    { echo "$BIN_DIR/hegemon-node"; }
WALLET_BIN()  { echo "$BIN_DIR/wallet"; }
WALLETD_BIN() { echo "$BIN_DIR/walletd"; }

require_bins() {
  [[ -x "$(NODE_BIN)" && -x "$(WALLETD_BIN)" && -x "$(WALLET_BIN)" ]] \
    || die "Binaries not installed. Run: bash $0 install"
}

rpc() {   # rpc <method> [params-json]
  local method="$1" params="${2:-[]}"
  curl --fail --silent --show-error --connect-timeout 3 --max-time 20 \
    -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":${params}}" \
    "$RPC_URL/"
}

node_running() {
  [[ -f "$NODE_PID" ]] && kill -0 "$(cat "$NODE_PID")" 2>/dev/null
}

# ---------------------------- passphrase handling ---------------------------
# Priority: HEGEMON_WALLET_PASSPHRASE env > HEGEMON_WALLET_PASSPHRASE_FILE > prompt.
# The passphrase is only ever piped to walletd's stdin (printf is a shell builtin,
# so it never appears in the process list).
PASSPHRASE=""
get_passphrase() {
  local confirm="${1:-0}"
  [[ -n "$PASSPHRASE" ]] && return 0
  if [[ -n "${HEGEMON_WALLET_PASSPHRASE:-}" ]]; then
    PASSPHRASE="$HEGEMON_WALLET_PASSPHRASE"; return 0
  fi
  if [[ -n "${HEGEMON_WALLET_PASSPHRASE_FILE:-}" ]]; then
    [[ -r "$HEGEMON_WALLET_PASSPHRASE_FILE" ]] || die "Cannot read $HEGEMON_WALLET_PASSPHRASE_FILE"
    PASSPHRASE="$(head -n1 "$HEGEMON_WALLET_PASSPHRASE_FILE")"; return 0
  fi
  [[ -t 0 ]] || die "No TTY: set HEGEMON_WALLET_PASSPHRASE or HEGEMON_WALLET_PASSPHRASE_FILE"
  local p2
  read -r -s -p "Wallet passphrase: " PASSPHRASE; echo
  if [[ "$confirm" == 1 ]]; then
    read -r -s -p "Confirm passphrase: " p2; echo
    [[ "$PASSPHRASE" == "$p2" ]] || die "Passphrases do not match"
  fi
  [[ -n "$PASSPHRASE" ]] || die "Passphrase cannot be empty"
}

walletd_call() {   # walletd_call <mode open|create> <json-request>
  local mode="$1" req="$2"
  printf '%s\n%s\n' "$PASSPHRASE" "$req" | "$(WALLETD_BIN)" --store "$WALLET_STORE" --mode "$mode"
}

# =============================================================================
#  INSTALL
# =============================================================================
resolve_tag() {
  if [[ "$RELEASE_TAG" == "latest" ]]; then
    RELEASE_TAG="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | jq -r .tag_name)"
    [[ -n "$RELEASE_TAG" && "$RELEASE_TAG" != "null" ]] || die "Could not resolve latest release tag"
  fi
  VERSION="${RELEASE_TAG#v}"
  # Public testnet passed block 120,000: the difficulty-retarget correction
  # (v0.10.2+) is mandatory, older binaries fork off the canonical chain.
  local min="0.10.2" base="${VERSION%%-*}"
  if [[ "$(printf '%s\n%s\n' "$base" "$min" | sort -V | head -n1)" != "$min" ]]; then
    die "Release $RELEASE_TAG is older than v$min and is incompatible with the public testnet (activation at block 120,000)."
  fi
}

install_release() {
  local dl="https://github.com/${REPO}/releases/download/${RELEASE_TAG}"
  local zip="hegemon-testnet-${VERSION}-${PLATFORM}.zip"
  local dest="$HEGEMON_HOME/releases/${RELEASE_TAG}"
  mkdir -p "$dest"
  log "Downloading ${zip} (${RELEASE_TAG})"
  curl -fL --retry 3 --progress-bar -o "$dest/$zip" "$dl/$zip" \
    || die "Download failed. No prebuilt bundle for ${PLATFORM}? Try: --source"
  curl -fsSL --retry 3 -o "$dest/$zip.sha256" "$dl/$zip.sha256"

  local expected actual
  expected="$(awk '{print $1}' "$dest/$zip.sha256")"
  actual="$(sha256_of "$dest/$zip")"
  [[ "$expected" == "$actual" ]] || die "SHA-256 mismatch for $zip (expected $expected, got $actual)"
  ok "ZIP checksum verified: $actual"

  unzip -o -q "$dest/$zip" -d "$dest"
  # verify every binary inside the bundle against its own .sha256 sidecar
  local b
  for b in hegemon-node wallet walletd; do
    local f="$dest/${b}-${PLATFORM}"
    [[ -f "$f" ]] || die "Bundle is missing ${b}-${PLATFORM}"
    if [[ -f "$f.sha256" ]]; then
      [[ "$(awk '{print $1}' "$f.sha256")" == "$(sha256_of "$f")" ]] || die "Checksum mismatch: $f"
    fi
    chmod +x "$f"
    ln -sfn "$f" "$BIN_DIR/$b"
  done
  # macOS: clear quarantine flag on downloaded binaries
  if [[ "$(uname -s)" == "Darwin" ]] && have xattr; then
    xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
  fi
  ok "Installed release binaries ${RELEASE_TAG} -> $BIN_DIR"
}

install_source() {
  # README "Building the Native Node": make setup -> make node (+ walletd/wallet per runbook)
  if [[ -d "$SRC_DIR/.git" ]]; then
    log "Updating source checkout in $SRC_DIR"
    git -C "$SRC_DIR" fetch --tags --force origin
  else
    log "Cloning $REPO_URL"
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone "$REPO_URL" "$SRC_DIR"
  fi
  git -C "$SRC_DIR" checkout --force "$RELEASE_TAG"
  ok "Source at $(git -C "$SRC_DIR" rev-parse --short HEAD) (${RELEASE_TAG})"

  log "make setup  (installs Rust/Go/Node/jq/clang-format via scripts/dev-setup.sh)"
  ( cd "$SRC_DIR" && make setup )
  # shellcheck disable=SC1091
  [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
  export PATH="$HOME/.local/go/bin:$HOME/.local/node/bin:/usr/local/go/bin:$PATH"

  log "make node  (cargo build -p hegemon-node --release) — this takes a while"
  ( cd "$SRC_DIR" && make node )
  log "cargo build --release -p walletd -p wallet"
  ( cd "$SRC_DIR" && cargo build --release -p walletd -p wallet )

  local b
  for b in hegemon-node wallet walletd; do
    [[ -x "$SRC_DIR/target/release/$b" ]] || die "Build did not produce $b"
    ln -sfn "$SRC_DIR/target/release/$b" "$BIN_DIR/$b"
  done
  ok "Built from source -> $BIN_DIR"
}

cmd_install() {
  detect_platform
  ensure_base_tools
  mkdir -p "$BIN_DIR" "$LOG_DIR" "$RUN_DIR"
  resolve_tag
  if [[ "$INSTALL_MODE" == "release" && "$PLATFORM" == "linux-arm64" ]]; then
    warn "No prebuilt linux-arm64 bundle upstream; switching to source build"
    INSTALL_MODE="source"; ensure_base_tools
  fi
  log "Install mode: $INSTALL_MODE   version: $RELEASE_TAG   platform: $PLATFORM"
  if [[ "$INSTALL_MODE" == "source" ]]; then install_source; else install_release; fi
  echo "$RELEASE_TAG" > "$HEGEMON_HOME/installed-version"
  "$(NODE_BIN)" --help >/dev/null || die "hegemon-node does not execute on this machine"
  ok "hegemon-node, wallet, walletd ready ($("$(WALLET_BIN)" --version 2>/dev/null || echo "$RELEASE_TAG"))"
}

# =============================================================================
#  WALLET
# =============================================================================
cmd_wallet_create() {
  require_bins
  local mode="create"
  if [[ -e "$WALLET_STORE" ]]; then
    log "Existing wallet store found at $WALLET_STORE — opening it (never overwritten)"
    mode="open"; get_passphrase 0
  else
    log "Creating new wallet store at $WALLET_STORE"
    get_passphrase 1
  fi
  local out addr
  out="$(walletd_call "$mode" '{"id":1,"method":"status.get","params":{}}')" \
    || die "walletd failed (wrong passphrase?)"
  addr="$(jq -r '.result.primaryAddress // empty' <<<"$out")"
  [[ -n "$addr" ]] || die "Could not read primaryAddress: $(head -c 300 <<<"$out")"
  printf '%s\n' "$addr" > "$ADDR_FILE"; chmod 600 "$ADDR_FILE"; rm -f "$HEGEMON_HOME/external-address"
  ok "Shielded address saved to $ADDR_FILE"
  echo "  ${addr:0:60}...  (${#addr} chars)"
  if [[ "$mode" == "create" ]]; then
    warn "BACK UP the store file ($WALLET_STORE) AND your passphrase. walletd emits no mnemonic."
  fi
}

validate_address() {
  local a="$1"
  [[ "$a" == shca1* ]] || { echo "must start with 'shca1'"; return 1; }
  (( ${#a} > 1000 ))   || { echo "too short (${#a} chars) - copy the whole ~2600-char line"; return 1; }
  [[ "$a" =~ ^shca1[02-9ac-hj-np-z]+$ ]] || { echo "invalid bech32m characters"; return 1; }
}

# --address / --address-file / HEGEMON_MINER_ADDRESS: mine to an address you
# already own instead of creating a wallet on this VPS.
use_external_address() {
  local a=""
  if [[ -n "${ADDRESS_ARG:-}" ]]; then a="$ADDRESS_ARG"
  elif [[ -n "${ADDRESS_FILE_ARG:-}" ]]; then
    [[ -r "$ADDRESS_FILE_ARG" ]] || die "Cannot read $ADDRESS_FILE_ARG"; a="$(cat "$ADDRESS_FILE_ARG")"
  elif [[ -n "${HEGEMON_MINER_ADDRESS:-}" ]]; then a="$HEGEMON_MINER_ADDRESS"
  else return 1; fi
  a="$(tr -d '[:space:]' <<<"$a")"
  local why; why="$(validate_address "$a")" || die "Invalid payout address: $why"
  mkdir -p "$HEGEMON_HOME"; printf '%s\n' "$a" > "$ADDR_FILE"; chmod 600 "$ADDR_FILE"
  touch "$HEGEMON_HOME/external-address"
  ok "Mining to the given payout address (${#a} chars): ${a:0:24}...${a: -12}"
  log "No wallet is created on this VPS; check rewards in the wallet that owns this address."
  return 0
}

# Interactive choice on first run: create/open a local wallet, or paste an address.
choose_payout() {
  use_external_address && return 0
  if [[ -s "$ADDR_FILE" && -f "$HEGEMON_HOME/external-address" ]]; then
    ok "Using saved external payout address: $(cut -c1-24 "$ADDR_FILE")..."; return 0
  fi
  if [[ -e "$WALLET_STORE" || ! -t 0 ]]; then cmd_wallet_create; return 0; fi
  echo
  echo "Where should mining rewards go?"
  echo "  1) Create a new wallet on this VPS (default)"
  echo "  2) I already have an address - paste it (shca1..., ~2600 chars)"
  local c; read -r -p "Choose [1/2]: " c
  if [[ "$c" == 2 ]]; then
    local a why t
    for t in 1 2 3; do
      read -r -e -p "Payout address: " a || true
      a="$(tr -d '[:space:]' <<<"$a")"
      if why="$(validate_address "$a")"; then ADDRESS_ARG="$a" use_external_address; return 0; fi
      warn "Invalid address: $why"
    done
    die "No valid address entered"
  fi
  cmd_wallet_create
}

cmd_address() {
  if [[ -s "$ADDR_FILE" ]]; then cat "$ADDR_FILE"; else cmd_wallet_create >/dev/null; cat "$ADDR_FILE"; fi
}

cmd_balance() {
  require_bins
  [[ -e "$WALLET_STORE" ]] || die "No wallet at $WALLET_STORE. Run: bash $0 wallet"
  get_passphrase 0
  if [[ "${BALANCE_CACHED:-0}" == 1 ]]; then
    log "Cached balance (no sync) — may be behind the chain:"
    print_wallet_status; return 0
  fi
  local leaves
  leaves="$(rpc hegemon_walletNotes 2>/dev/null | jq -r '.result.leaf_count // empty' 2>/dev/null || true)"
  [[ -n "$leaves" ]] || die "Node RPC $RPC_URL not reachable — start the node first (bash $0 status)"

  log "Syncing wallet against $RPC_URL: $leaves commitments on chain."
  log "First scan of a full chain is slow (often 30-90 min on a small VPS); later syncs only fetch new blocks."
  log "Ctrl+C is safe: progress is saved after every page and the next run resumes."

  local out; out="$(mktemp "${TMPDIR:-/tmp}/hegemon-sync.XXXXXX")"
  ( walletd_call open "{\"id\":1,\"method\":\"sync.once\",\"params\":{\"ws_url\":\"${RPC_URL}\",\"force_rescan\":false}}" \
      > "$out" 2>&1 ) &
  local pid=$! start; start=$(date +%s)
  # Ctrl+C: stop walletd cleanly (progress already written is kept and resumed).
  trap 'echo; warn "Interrupted - stopping wallet scan (progress saved, re-run to resume)"; pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -f "$out"; exit 130' INT TERM
  while kill -0 "$pid" 2>/dev/null; do
    local size el cpu
    size="$(wc -c < "$WALLET_STORE" 2>/dev/null | tr -d ' ')"
    el=$(( $(date +%s) - start ))
    cpu="$(ps -o %cpu= -p "$(pgrep -f -- "--store $WALLET_STORE" | tr '\n' ',' | sed 's/,$//')" 2>/dev/null | awk '{s+=$1} END{printf "%d", s}')"
    printf '\r  %02d:%02d:%02d elapsed  scanning %s commitments   wallet file %s KB   walletd CPU %s%%   ' \
      $((el/3600)) $((el%3600/60)) $((el%60)) "$leaves" $((size/1024)) "${cpu:-?}"
    sleep 5
  done
  wait "$pid" || true
  trap - INT TERM
  echo
  local s; s="$(cat "$out")"; rm -f "$out"
  if jq -e '.ok == true' <<<"$s" >/dev/null 2>&1; then
    ok "Wallet sync complete in $(( $(date +%s) - start ))s: $(jq -c '.result' <<<"$s")"
  else
    warn "Wallet sync failed: $(head -c 400 <<<"$s")"
    warn "Cached balance below may be stale (a failed sync does NOT mean zero balance)."
  fi
  print_wallet_status
}

print_wallet_status() {
  walletd_call open '{"id":1,"method":"status.get","params":{}}' | jq '
    .result | {
      lastSyncedHeight,
      balance_HGM: ((([.balances[]? | select(.assetId == 0) | .total] | add) // 0) / 100000000),
      spendable_HGM: ((([.balances[]? | select(.assetId == 0) | .spendable] | add) // 0) / 100000000),
      spendableNotes: .notes.spendableCount,
      pending: (.pending | length)
    }'
}

# =============================================================================
#  NODE / MINER
# =============================================================================
check_time_sync() {
  if have timedatectl; then
    if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qi yes; then
      ok "System clock is NTP-synchronized"
    else
      warn "System clock not reported as NTP-synchronized. PoW blocks >90s in the future are rejected."
      warn "Enable it:  sudo timedatectl set-ntp true   (or install chrony)"
    fi
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    log "macOS: make sure 'Set time and date automatically' is enabled"
  fi
}

start_node() {   # start_node <relay|mine|dev>
  local mode="$1"
  require_bins
  if node_running; then
    log "Node already running (pid $(cat "$NODE_PID"), mode $(cat "$NODE_MODE_FILE" 2>/dev/null))"
    NODE_LOG_START_LINE=1
    wait_for_rpc
    return 0
  fi
  mkdir -p "$LOG_DIR" "$RUN_DIR"
  local -a args env_vars
  case "$mode" in
    relay|mine)
      env_vars=(HEGEMON_SEEDS="$SEEDS" HEGEMON_BOOTSTRAP_AUTHORING=0)
      args=(--dev --base-path "$DATA_DIR" --rpc-methods safe
            --rpc-port "$RPC_PORT" --port "$P2P_PORT" --name "$NODE_NAME")
      if [[ "$mode" == "mine" ]]; then
        local addr; addr="$(cat "$ADDR_FILE" 2>/dev/null || true)"
        [[ -n "${addr//[[:space:]]/}" ]] || die "No miner address. Run: bash $0 wallet"
        env_vars+=(HEGEMON_MINE=1 HEGEMON_MINER_ADDRESS="$addr" HEGEMON_MINE_THREADS="$MINE_THREADS")
      else
        env_vars+=(HEGEMON_MINE=0)
      fi
      ;;
    dev)  # isolated private dev chain (README step 3), temp DB, solo mining
      local addr; addr="$(cat "$ADDR_FILE" 2>/dev/null || true)"
      [[ -n "$addr" ]] || die "No miner address. Run: bash $0 wallet"
      env_vars=(HEGEMON_SEEDS="" HEGEMON_MINE=1 HEGEMON_BOOTSTRAP_AUTHORING=1
                HEGEMON_MINER_ADDRESS="$addr" HEGEMON_MINE_THREADS="$MINE_THREADS")
      args=(--dev --tmp --rpc-port "$RPC_PORT" --port "$P2P_PORT")
      ;;
    *) die "unknown node mode $mode" ;;
  esac
  env_vars+=(NO_COLOR=1 RUST_LOG="${RUST_LOG:-hegemon_node=info,consensus=info,network=info}")

  log "Starting node in ${mode} mode  (log: $NODE_LOG)"
  [[ "$mode" != "dev" ]] && log "Seeds: $SEEDS   data: $DATA_DIR"
  [[ "$mode" != "relay" ]] && log "Mining threads: $MINE_THREADS"
  {
    echo "===== $(date -u '+%F %T UTC') start mode=$mode ====="
  } >> "$NODE_LOG"
  [[ "$mode" != "dev" ]] && check_disk_space "$DATA_DIR"
  check_port_free "$RPC_PORT" RPC
  check_port_free "$P2P_PORT" P2P
  NODE_LOG_START_LINE=$(( $(wc -l < "$NODE_LOG" 2>/dev/null || echo 0) + 1 ))
  nohup env "${env_vars[@]}" "$(NODE_BIN)" "${args[@]}" >> "$NODE_LOG" 2>&1 &
  echo $! > "$NODE_PID"
  echo "$mode" > "$NODE_MODE_FILE"
  wait_for_rpc
}

check_disk_space() {   # warn/abort when the data filesystem is nearly full
  local dir="$1" need_mb="${HEGEMON_MIN_FREE_MB:-2048}" avail
  mkdir -p "$dir"
  avail="$(df -Pm "$dir" 2>/dev/null | awk 'NR==2{print $4}')"
  [[ -n "$avail" ]] || return 0
  if (( avail < 256 )); then
    die "Only ${avail} MB free on the filesystem holding $dir — node would fail with 'No space left on device'. Free space or use --data-dir."
  elif (( avail < need_mb )); then
    warn "Only ${avail} MB free for $dir (recommended >= ${need_mb} MB; the testnet chain keeps growing)"
  fi
}

check_port_free() {   # check_port_free <port> <label> — fail early if someone else holds it
  local port="$1" label="$2"
  if have ss && ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}\$"; then
    die "$label port $port is already in use (another hegemon-node?). Check: ss -ltnp | grep $port   — stop it, or use --rpc-port/--port"
  fi
}

# Report the node's current startup phase from its own log lines.
startup_phase() {
  local line
  line="$(tail -n +"${NODE_LOG_START_LINE:-1}" "$NODE_LOG" 2>/dev/null \
    | grep -E 'opening native Hegemon node storage|sled database opened|storage reload completed|block_proof_verification_metrics|starting native Hegemon node' \
    | tail -n1 || true)"
  case "$line" in
    *"starting native Hegemon node"*)      echo "binding RPC" ;;
    *block_proof_verification_metrics*)    echo "re-verifying stored blocks" ;;
    *"storage reload completed"*)          echo "storage loaded, starting services" ;;
    *"sled database opened"*)              echo "reloading chain state from disk" ;;
    *"opening native Hegemon node storage"*) echo "opening database" ;;
    *)                                      echo "launching" ;;
  esac
}

# Wait (long) until the node answers JSON-RPC. Fails hard if the process dies
# or the timeout expires, so callers never act on an unreachable node.
wait_for_rpc() {
  local start; start=$(date +%s)
  log "Waiting for node RPC on $RPC_URL (a synced chain can take several minutes to reload)..."
  while true; do
    if rpc system_health >/dev/null 2>&1; then
      [[ -t 1 ]] && printf '\n'
      ok "Node up, RPC $RPC_URL (pid $(cat "$NODE_PID" 2>/dev/null)) after $(( $(date +%s) - start ))s"
      return 0
    fi
    if ! node_running; then
      [[ -t 1 ]] && printf '\n'
      warn "hegemon-node exited during startup. Last log lines:"
      tail -n 40 "$NODE_LOG" >&2
      if have dmesg && dmesg 2>/dev/null | tail -n 50 | grep -qiE 'out of memory|oom-kill|killed process.*hegemon'; then
        warn "Kernel OOM-killer terminated the node: add RAM or swap (see README)."
      fi
      rm -f "$NODE_PID" "$NODE_MODE_FILE"
      die "Node failed to start (full log: $NODE_LOG)"
    fi
    local el=$(( $(date +%s) - start ))
    if (( el > STARTUP_TIMEOUT )); then
      [[ -t 1 ]] && printf '\n'
      die "RPC still not answering after ${STARTUP_TIMEOUT}s (node still running, phase: $(startup_phase)). Re-run later or raise HEGEMON_STARTUP_TIMEOUT. Logs: bash $0 logs"
    fi
    if [[ -t 1 ]]; then
      printf '\r  starting... %4ss  phase: %-40s' "$el" "$(startup_phase)"
    elif (( el % 30 == 0 )); then
      log "  still starting (${el}s, phase: $(startup_phase))"
    fi
    sleep 2
  done
}

cmd_stop() {
  if node_running; then
    local pid; pid="$(cat "$NODE_PID")"
    log "Stopping node (pid $pid) with SIGTERM (clean DB flush)..."
    kill -TERM "$pid" 2>/dev/null || true
    local i
    for (( i = 0; i < STOP_TIMEOUT; i++ )); do
      kill -0 "$pid" 2>/dev/null || break
      (( i > 0 && i % 15 == 0 )) && log "  waiting for clean database flush (${i}s)..."
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then warn "Still alive after ${STOP_TIMEOUT}s, sending SIGKILL"; kill -KILL "$pid" || true; sleep 2; fi
    ok "Node stopped"
  else
    log "Node not running"
  fi
  rm -f "$NODE_PID" "$NODE_MODE_FILE"
}

# Returns 0 = genesis matches, 1 = DIFFERENT chain, 2 = could not query RPC.
verify_genesis() {
  local g="" i
  for i in 1 2 3 4 5 6; do
    g="$(rpc chain_getBlockHash '[0]' 2>/dev/null | jq -r '.result // empty' 2>/dev/null || true)"
    [[ -n "$g" ]] && break
    sleep 5
  done
  if [[ -z "$g" ]]; then
    warn "Could not query genesis hash from $RPC_URL (RPC unreachable) — this is NOT a chain mismatch"
    return 2
  fi
  if [[ "$g" == "$EXPECTED_GENESIS" ]]; then ok "Genesis matches public testnet: $g"; return 0; fi
  warn "Genesis mismatch! got=$g expected=$EXPECTED_GENESIS"; return 1
}

wait_for_sync() {
  log "Waiting for canonical catch-up (peers > 0, height = network tip, node sync gate open)..."
  local start; start=$(date +%s)
  local stable=0
  while true; do
    node_running || { tail -n 30 "$NODE_LOG" >&2; die "Node died while syncing"; }
    local h ms peers syncing height target gate
    h="$(rpc system_health 2>/dev/null || true)"
    ms="$(rpc hegemon_miningStatus 2>/dev/null || true)"
    peers="$(jq -r '.result.peers // 0' <<<"$h" 2>/dev/null || echo 0)"
    syncing="$(jq -r '.result.isSyncing // true' <<<"$h" 2>/dev/null || echo true)"
    height="$(jq -r '.result.block_height // 0' <<<"$ms" 2>/dev/null || echo 0)"
    target="$(jq -r '.result.sync_target_height // 0' <<<"$ms" 2>/dev/null || echo 0)"
    gate="$(jq -r '.result.mining_sync_gate_open // false' <<<"$ms" 2>/dev/null || echo false)"
    printf '\r  peers=%s syncing=%s height=%s target=%s gate=%s   ' "$peers" "$syncing" "$height" "$target" "$gate"
    # The node's own mining gate (mining_sync_gate_open) is the authoritative
    # "caught up" signal. isSyncing flickers to true at the live tip whenever a
    # peer announces a new, not-yet-verified block, so it is only a fallback.
    # Allow being 2 blocks behind the announced target (new blocks keep arriving).
    if [[ "$peers" != "0" && "$height" -gt 0 && $(( height + 2 )) -ge "$target" ]] \
       && [[ "$gate" == "true" || "$syncing" == "false" ]]; then
      stable=$((stable + 1))
    else
      stable=0
    fi
    if (( stable >= 3 )); then echo; ok "Synced at height $height with $peers peer(s)"; return 0; fi
    if (( SYNC_TIMEOUT > 0 && $(date +%s) - start > SYNC_TIMEOUT )); then
      echo; warn "Sync wait timed out after ${SYNC_TIMEOUT}s"; return 1
    fi
    sleep 10
  done
}

cmd_relay() { check_time_sync; start_node relay; }

cmd_mine() {
  require_bins
  [[ -s "$ADDR_FILE" ]] || choose_payout
  check_time_sync
  if node_running && [[ "$(cat "$NODE_MODE_FILE" 2>/dev/null)" == "mine" ]]; then
    log "Miner already running"; return 0
  fi
  if [[ "${SKIP_SYNC_WAIT:-0}" != 1 ]]; then
    # Upstream guidance: start a relay first, verify genesis + catch-up, then mine.
    start_node relay          # starts, or attaches to an already-running node, and waits for RPC
    local rc=0; verify_genesis || rc=$?
    case "$rc" in
      0) ;;
      1) die "Refusing to mine: node is on a different chain than the public testnet. Inspect: bash $0 status" ;;
      *) die "Node RPC is not reachable, cannot verify the chain. Check: bash $0 logs" ;;
    esac
    wait_for_sync || die "Not synced; refusing to mine (use --skip-sync-wait to override)"
    cmd_stop
  else
    node_running && cmd_stop
  fi
  start_node mine
  # Re-check the chain on the mining process too (RPC is up at this point).
  local rc2=0; verify_genesis || rc2=$?
  if [[ "$rc2" == 1 ]]; then cmd_stop; die "Mining node reports an unexpected genesis — stopped."; fi
  ok "Mining started. Rewards are shielded notes paid to your wallet address."
  log "Monitor:  bash $0 status    |  bash $0 logs    |  bash $0 balance"
}

cmd_dev() {
  require_bins
  [[ -s "$ADDR_FILE" ]] || cmd_wallet_create
  node_running && cmd_stop
  start_node dev
  ok "Private dev chain mining (temporary DB, isolated from the testnet)"
}

cmd_status() {
  log "RPC $RPC_URL   expected genesis $EXPECTED_GENESIS"
  if node_running; then ok "Node process running (pid $(cat "$NODE_PID"), mode $(cat "$NODE_MODE_FILE" 2>/dev/null))"
  else warn "Node process not managed/running by this script"; fi
  local out
  out="$(curl --fail --silent --show-error --connect-timeout 3 --max-time 15 -H 'Content-Type: application/json' \
    --data '[{"jsonrpc":"2.0","id":1,"method":"system_health","params":[]},{"jsonrpc":"2.0","id":2,"method":"chain_getHeader","params":[]},{"jsonrpc":"2.0","id":3,"method":"chain_getBlockHash","params":[0]},{"jsonrpc":"2.0","id":4,"method":"hegemon_miningStatus","params":[]},{"jsonrpc":"2.0","id":5,"method":"system_version","params":[]}]' \
    "$RPC_URL/")" || die "Node RPC not reachable on $RPC_URL"
  jq -r '
    (map({(.id|tostring): .result}) | add) as $r |
    "  version        : \($r["5"])",
    "  peers          : \($r["1"].peers)   syncing: \($r["1"].isSyncing)",
    "  tip            : \($r["2"].number) (hex)  -> \(($r["2"].number // "0x0") )",
    "  genesis        : \($r["3"])",
    "  mining         : \($r["4"].is_mining)  threads: \($r["4"].threads)  gate_open: \($r["4"].mining_sync_gate_open)",
    "  height/target  : \($r["4"].block_height) / \($r["4"].sync_target_height)",
    "  blocks found   : \($r["4"].blocks_found)   hash_rate: \($r["4"].hash_rate)"
  ' <<<"$out"
  local g; g="$(jq -r '.[] | select(.id==3) | .result' <<<"$out")"
  [[ "$(cat "$NODE_MODE_FILE" 2>/dev/null)" == "dev" ]] || {
    [[ "$g" == "$EXPECTED_GENESIS" ]] && ok "Genesis OK" || warn "Genesis differs from public testnet"; }
}

cmd_logs() { [[ -f "$NODE_LOG" ]] || die "No log yet"; tail -n "${LINES_N:-100}" -f "$NODE_LOG"; }

cmd_all() {
  choose_payout
  cmd_install
  cmd_mine
  echo
  ok "All done. Node + miner running in the background."
  cat <<EOF
  Status  : bash $0 status
  Logs    : bash $0 logs
  Balance : bash $0 balance
  Stop    : bash $0 stop
EOF
}

cmd_update() {
  local was_mode=""
  node_running && was_mode="$(cat "$NODE_MODE_FILE" 2>/dev/null)"
  [[ -n "$was_mode" ]] && cmd_stop
  cmd_install
  case "$was_mode" in
    mine)  SKIP_SYNC_WAIT=1 cmd_mine ;;
    relay) cmd_relay ;;
    dev)   cmd_dev ;;
  esac
}

cmd_systemd() {   # install a systemd --user unit that runs the miner at boot
  have systemctl || die "systemd not available"
  require_bins
  [[ -s "$ADDR_FILE" ]] || die "Run 'bash $0 wallet' first"
  local unit="$HOME/.config/systemd/user/hegemon-miner.service"
  mkdir -p "$(dirname "$unit")"
  cat > "$unit" <<EOF
[Unit]
Description=Hegemon testnet node + miner
After=network-online.target time-sync.target
Wants=network-online.target

[Service]
Environment=HEGEMON_SEEDS=$SEEDS
Environment=HEGEMON_BOOTSTRAP_AUTHORING=0
Environment=HEGEMON_MINE=1
Environment=HEGEMON_MINE_THREADS=$MINE_THREADS
Environment=NO_COLOR=1
Environment=RUST_LOG=hegemon_node=info,consensus=info,network=info
EnvironmentFile=$HEGEMON_HOME/miner.env
ExecStart=$(NODE_BIN) --dev --base-path $DATA_DIR --rpc-methods safe --rpc-port $RPC_PORT --port $P2P_PORT --name $NODE_NAME
KillSignal=SIGTERM
TimeoutStopSec=90
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
EOF
  printf 'HEGEMON_MINER_ADDRESS=%s\n' "$(cat "$ADDR_FILE")" > "$HEGEMON_HOME/miner.env"
  chmod 600 "$HEGEMON_HOME/miner.env"
  node_running && cmd_stop
  systemctl --user daemon-reload
  systemctl --user enable --now hegemon-miner.service
  have loginctl && loginctl enable-linger "$USER" 2>/dev/null || true
  ok "systemd user service 'hegemon-miner' enabled. Logs: journalctl --user -u hegemon-miner -f"
}

usage() {
  cat <<EOF
Hegemon automation script — download, install, build, wallet, node, miner.

Usage: bash $0 [global options] <command>

Commands:
  all          install + create/open wallet + start relay, wait for sync, start miner  (default)
  install      download verified release bundle (or build from source with --source)
  wallet       create the wallet (or open existing) and save the shielded mining address
  address      print the shielded address
  relay        start a non-mining node on the public testnet (background)
  mine         relay -> verify genesis -> wait for sync -> restart with mining
  dev          solo-mine an isolated private dev chain (temp DB; README step 3)
  status       node health, tip, genesis, mining stats
  balance      sync the wallet with the local node (shows progress) and show the balance
  balance-cached  show the last synced balance instantly (no sync)
  logs         follow the node log
  stop         stop the node cleanly (SIGTERM)
  update       install the latest release and restart in the previous mode
  systemd      install a systemd --user service that runs the miner at boot

Global options:
  --source              build from source (git clone + make setup + make node + cargo build)
  --release             use official prebuilt release bundle (default)
  --version vX.Y.Z      pick a release tag (default: latest)
  --threads N           mining threads (default: CPU cores - 1 = $MINE_THREADS)
  --data-dir PATH       node data dir (default: $DATA_DIR)
  --wallet PATH         wallet store (default: $WALLET_STORE)
  --address shca1...    mine to an existing payout address (no wallet created here)
  --address-file FILE   same, read the address from a file
  --rpc-port PORT       (default 9944)      --port PORT   P2P (default 30333)
  --sync-timeout SEC    max seconds to wait for sync before mining (0 = forever)
  --skip-sync-wait      start mining immediately (node's sync gate still applies)

Environment:
  HEGEMON_WALLET_PASSPHRASE / HEGEMON_WALLET_PASSPHRASE_FILE  for unattended runs
  HEGEMON_HOME (default ~/.hegemon-auto)
EOF
}

# ------------------------------- arg parsing --------------------------------
CMD=""; ADDRESS_ARG=""; ADDRESS_FILE_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)        INSTALL_MODE=source; shift ;;
    --release)       INSTALL_MODE=release; shift ;;
    --version)       RELEASE_TAG="$2"; shift 2 ;;
    --threads)       MINE_THREADS="$2"; shift 2 ;;
    --data-dir)      DATA_DIR="$2"; shift 2 ;;
    --wallet)        WALLET_STORE="$2"; shift 2 ;;
    --address)       ADDRESS_ARG="$2"; shift 2 ;;
    --address-file)  ADDRESS_FILE_ARG="$2"; shift 2 ;;
    --rpc-port)      RPC_PORT="$2"; RPC_URL="http://127.0.0.1:${RPC_PORT}"; shift 2 ;;
    --port)          P2P_PORT="$2"; shift 2 ;;
    --sync-timeout)  SYNC_TIMEOUT="$2"; shift 2 ;;
    --skip-sync-wait) SKIP_SYNC_WAIT=1; shift ;;
    -h|--help|help)  usage; exit 0 ;;
    -*)              die "Unknown option $1 (see: bash $0 help)" ;;
    *)               [[ -z "$CMD" ]] && CMD="$1" || die "Unexpected argument $1"; shift ;;
  esac
done
[[ "$MINE_THREADS" =~ ^[0-9]+$ && "$MINE_THREADS" -ge 1 ]] || die "--threads must be >= 1"

case "${CMD:-all}" in
  mine|miner|systemd|dev) [[ -n "$ADDRESS_ARG$ADDRESS_FILE_ARG" ]] && use_external_address ;;
esac

case "${CMD:-all}" in
  all)            cmd_all ;;
  install)        cmd_install ;;
  wallet|wallet-create) cmd_wallet_create ;;
  address)        cmd_address ;;
  relay|start)    cmd_relay ;;
  mine|miner)     cmd_mine ;;
  dev)            cmd_dev ;;
  status)         cmd_status ;;
  balance)        cmd_balance ;;
  balance-cached) BALANCE_CACHED=1 cmd_balance ;;
  logs)           cmd_logs ;;
  stop)           cmd_stop ;;
  update)         cmd_update ;;
  systemd)        cmd_systemd ;;
  *)              usage; exit 2 ;;
esac
