#!/usr/bin/env bash
# =============================================================================
#  hegemon-install.sh — install Hegemon v0.10.3 (node + built-in miner + wallet)
#
#  Release : https://github.com/Pauli-Group/Hegemon/releases/tag/v0.10.3
#  Commit  : e5d971838f123d55a56abb482c66c42ad3aeacb1
#  Genesis : 0x506fc2cd5ed367cc68d6d23a987fe6e4a7916fde02a249105ab91884a1e6fa59
#
#  NOTHING is stored in /root or $HOME. Everything lives under one base dir:
#
#     /opt/hegemon/hegemon.conf   <- config (put your payout address here)
#     /opt/hegemon/data/          <- chain data
#     /opt/hegemon/wallet/        <- wallet store
#     /opt/hegemon/src/ cargo/ rustup/ release/   <- build files / toolchain
#     /usr/local/bin/hegemon-*    <- commands
#
#  Quick start:
#     bash hegemon-install.sh --prebuilt --address <YOUR_ADDRESS>
#     hegemon-miner
#
#  Re-running the script is safe: if v0.10.3 binaries are already installed it
#  does NOT rebuild, it only rewrites the config/helper commands (use --rebuild
#  to force a rebuild).
#
#  Options:
#     --address ADDR   write payout address into the config
#     --prebuilt       use official release binaries (Linux x86_64 / macOS)
#     --source         build from source (default)
#     --rebuild        rebuild / redownload even if binaries are installed
#     --helpers-only   never build/download; only config + helper commands
#     --base DIR       base directory              (default: /opt/hegemon)
#     --bin-dir DIR    command directory           (default: /usr/local/bin)
#     --threads N      mining threads written to config
#     --jobs N         cargo build jobs (1-2 on low-RAM VPS)
#     --skip-deps      do not install system packages
#     --systemd        install systemd service hegemon-node.service
#     -h, --help
# =============================================================================
set -euo pipefail

VERSION="0.10.3"
TAG="v${VERSION}"
REPO_URL="https://github.com/Pauli-Group/Hegemon.git"
DL_BASE="https://github.com/Pauli-Group/Hegemon/releases/download/${TAG}"
EXPECTED_COMMIT="e5d971838f123d55a56abb482c66c42ad3aeacb1"
EXPECTED_GENESIS="0x506fc2cd5ed367cc68d6d23a987fe6e4a7916fde02a249105ab91884a1e6fa59"
DEFAULT_SEEDS="hegemon.pauli.group:30333,devnet.hegemonprotocol.com:30333"

pinned_sha256() {
  case "$1" in
    hegemon-node-linux-x86_64) echo 10138d3ba57752a782b229e068decca9729358c375b01f4660895be519643789 ;;
    wallet-linux-x86_64)       echo 24200cdd56144890e35914769eb3746aff2dfcbf2e45b167faa21d0c41d807b1 ;;
    walletd-linux-x86_64)      echo c26b7d7c88057fa72fd45d3751b43fc0d7cecb92591566a66a0fdc6f7196fff6 ;;
    hegemon-node-macos-arm64)  echo 71ad42d0bc3a8973833909fc1e06e5594a41e59d2f21bca929dbd23b20e2b938 ;;
    wallet-macos-arm64)        echo d66a9c68b7b463108c4d11f9e514f4349ac0600d3d8346d556d55176f6659346 ;;
    walletd-macos-arm64)       echo 3aa8a58f12e4637fe22f704041fd06bcdb9c7d978a397aeae3d45f0c09f5fd0f ;;
    hegemon-node-macos-x86_64) echo a586a37908f1504229c2afa125c774cafcef42225921f139e461a0a294fff2bd ;;
    wallet-macos-x86_64)       echo 7315821ebcfa15265971eaf36f6c6b28896cc60f36173ead00ff41fc01b16b97 ;;
    walletd-macos-x86_64)      echo 7a2e3ff7df564d35eb089fbe68c1e383f43c7268b7a117dd28a4932c110bba38 ;;
    *) return 1 ;;
  esac
}

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
MODE="${HEGEMON_INSTALL_MODE:-source}"
BASE="${HEGEMON_BASE:-/opt/hegemon}"
BIN_DIR="${HEGEMON_BIN_DIR:-/usr/local/bin}"
ADDRESS=""
THREADS=""
BUILD_JOBS="${HEGEMON_BUILD_JOBS:-}"
SKIP_DEPS=0
INSTALL_SYSTEMD=0
REBUILD=0
HELPERS_ONLY=0

HELPERS=(hegemon-start hegemon-miner hegemon-status hegemon-set-address hegemon-config
         hegemon-wallet-create hegemon-wallet-address hegemon-wallet-balance)

if [[ -t 1 ]]; then
  C_B=$'\e[1m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_C=$'\e[36m'; C_0=$'\e[0m'
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_C=""; C_0=""
fi
log()  { printf '%s==>%s %s\n' "$C_C$C_B" "$C_0" "$*"; }
ok()   { printf '%s ✔ %s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s ! %s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s ✘ %s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; }

SUDO=""
if [[ ${EUID:-$(id -u)} -ne 0 ]] && have sudo; then SUDO="sudo"; fi

sha256_of() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# -----------------------------------------------------------------------------
# Arguments
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --address)   ADDRESS="${2:?--address needs a value}"; shift 2 ;;
    --address=*) ADDRESS="${1#--address=}"; shift ;;
    --prebuilt)  MODE=prebuilt; shift ;;
    --source)    MODE=source; shift ;;
    --rebuild)   REBUILD=1; shift ;;
    --base)      BASE="${2:?--base needs a value}"; shift 2 ;;
    --bin-dir)   BIN_DIR="${2:?--bin-dir needs a value}"; shift 2 ;;
    --threads)   THREADS="${2:?--threads needs a value}"; shift 2 ;;
    --jobs)      BUILD_JOBS="${2:?--jobs needs a value}"; shift 2 ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    --systemd)   INSTALL_SYSTEMD=1; shift ;;
    --helpers-only) HELPERS_ONLY=1; shift ;;   # only config + helper commands
    -h|--help)   usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
done
[[ "$MODE" == source || "$MODE" == prebuilt ]] || die "invalid mode: $MODE"
ADDRESS="${ADDRESS//[[:space:]]/}"
if [[ -n "$ADDRESS" && ! "$ADDRESS" =~ ^[A-Za-z0-9._:-]+$ ]]; then
  die "Address contains invalid characters"
fi

CONF_FILE="$BASE/hegemon.conf"
DATA_DIR="$BASE/data"
WALLET_DIR="$BASE/wallet"
WALLET_STORE="$WALLET_DIR/wallet.store"
SRC_DIR="$BASE/src/Hegemon-${VERSION}"
# Keep the Rust toolchain out of $HOME as well.
export CARGO_HOME="${CARGO_HOME_OVERRIDE:-$BASE/cargo}"
export RUSTUP_HOME="${RUSTUP_HOME_OVERRIDE:-$BASE/rustup}"
export PATH="$CARGO_HOME/bin:$PATH"

OS="$(uname -s)"; ARCH="$(uname -m)"
case "$OS:$ARCH" in
  Linux:x86_64|Linux:amd64)    PLAT="linux-x86_64" ;;
  Linux:aarch64|Linux:arm64)   PLAT="linux-aarch64" ;;
  Darwin:x86_64)               PLAT="macos-x86_64" ;;
  Darwin:arm64|Darwin:aarch64) PLAT="macos-arm64" ;;
  *) die "Unsupported platform: $OS $ARCH" ;;
esac
if [[ "$MODE" == prebuilt && "$PLAT" == linux-aarch64 ]]; then
  die "No prebuilt binaries for Linux aarch64 — run without --prebuilt."
fi

# -----------------------------------------------------------------------------
# Directories (created with sudo if needed, then owned by the current user)
# -----------------------------------------------------------------------------
prepare_dirs() {
  local d
  for d in "$BASE" "$BIN_DIR"; do
    if ! mkdir -p "$d" 2>/dev/null; then
      [[ -n "$SUDO" ]] || die "Cannot create $d (run as root or choose --base/--bin-dir)"
      $SUDO mkdir -p "$d"
    fi
  done
  if [[ ! -w "$BASE" ]]; then
    $SUDO chown "$(id -u):$(id -g)" "$BASE" || die "$BASE is not writable"
  fi
  mkdir -p "$DATA_DIR" "$WALLET_DIR" "$BASE/src"
  chmod 700 "$WALLET_DIR"
}

# Writes a file into BIN_DIR (sudo if not writable).
put_bin() {  # put_bin SRC NAME
  if [[ -w "$BIN_DIR" ]]; then install -m 0755 "$1" "$BIN_DIR/$2"
  else $SUDO install -m 0755 "$1" "$BIN_DIR/$2"; fi
}

# -----------------------------------------------------------------------------
# 1. Dependencies
# -----------------------------------------------------------------------------
install_system_deps() {
  log "Installing system dependencies"
  local extra=""
  [[ "$MODE" == source ]] && extra="yes"
  if have apt-get; then
    $SUDO apt-get update -y
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      curl ca-certificates git ${extra:+build-essential pkg-config libssl-dev clang libclang-dev lld cmake protobuf-compiler}
  elif have dnf; then
    $SUDO dnf install -y curl git ${extra:+gcc gcc-c++ make pkgconf-pkg-config openssl-devel clang clang-devel lld cmake protobuf-compiler}
  elif have yum; then
    $SUDO yum install -y curl git ${extra:+gcc gcc-c++ make pkgconfig openssl-devel clang clang-devel cmake protobuf-compiler}
  elif have pacman; then
    $SUDO pacman -Sy --needed --noconfirm curl git ${extra:+base-devel pkgconf openssl clang lld cmake protobuf}
  elif have brew; then
    brew install git curl ${extra:+protobuf cmake}
  else
    warn "Unknown package manager — install curl, git (and a C toolchain, clang, cmake, protobuf for source builds)."
  fi
  ok "System dependencies ready"
}

install_rust() {
  if ! have rustup; then
    log "Installing Rust into $CARGO_HOME / $RUSTUP_HOME"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --default-toolchain none --no-modify-path
  fi
  ok "rustup $(rustup --version 2>/dev/null | head -1 | awk '{print $2}')"
}

# -----------------------------------------------------------------------------
# 2. Get binaries
# -----------------------------------------------------------------------------
build_from_source() {
  log "Fetching Hegemon ${TAG} source into $SRC_DIR"
  if [[ -d "$SRC_DIR/.git" ]]; then
    git -C "$SRC_DIR" fetch --depth 1 origin "refs/tags/${TAG}:refs/tags/${TAG}" --force
    git -C "$SRC_DIR" checkout --force "${TAG}"
  else
    git clone --depth 1 --branch "${TAG}" "$REPO_URL" "$SRC_DIR"
  fi
  local head; head="$(git -C "$SRC_DIR" rev-parse HEAD)"
  [[ "$head" == "$EXPECTED_COMMIT" ]] || die "Source commit mismatch: $head"
  ok "Source verified at $head"

  ( cd "$SRC_DIR"
    rustup toolchain install 2>/dev/null \
      || rustup toolchain install 1.91.1 --profile minimal \
           --component rustfmt,clippy,rust-src --target wasm32-unknown-unknown
    rustc --version )

  local mem_gb=0
  [[ -r /proc/meminfo ]] && mem_gb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
  if [[ -z "$BUILD_JOBS" && $mem_gb -gt 0 && $mem_gb -lt 8 ]]; then
    BUILD_JOBS=2; warn "Only ${mem_gb} GB RAM — using $BUILD_JOBS build jobs."
  fi
  local j=(); [[ -n "$BUILD_JOBS" ]] && j=(-j "$BUILD_JOBS")

  log "Building (15-60 min)..."
  ( cd "$SRC_DIR"
    export CARGO_INCREMENTAL=0 CARGO_TARGET_DIR="$SRC_DIR/target"
    cargo build --locked --release ${j[@]+"${j[@]}"} -p hegemon-node --bin hegemon-node --no-default-features
    cargo build --locked --release ${j[@]+"${j[@]}"} -p wallet  --bin wallet
    cargo build --locked --release ${j[@]+"${j[@]}"} -p walletd --bin walletd )
  NODE_SRC="$SRC_DIR/target/release/hegemon-node"
  WALLET_SRC="$SRC_DIR/target/release/wallet"
  WALLETD_SRC="$SRC_DIR/target/release/walletd"
}

download_prebuilt() {
  local dir="$BASE/release-${VERSION}" name expected actual
  mkdir -p "$dir"
  log "Downloading official ${TAG} binaries for $PLAT"
  for b in hegemon-node wallet walletd; do
    name="${b}-${PLAT}"
    curl -fL --silent --show-error -o "$dir/$name" "$DL_BASE/$name"
    expected="$(pinned_sha256 "$name")" || die "no pinned hash for $name"
    actual="$(sha256_of "$dir/$name")"
    [[ "$actual" == "$expected" ]] || die "Checksum mismatch for $name"
    chmod +x "$dir/$name"; ok "$name sha256 OK"
  done
  [[ "$OS" == Darwin ]] && { xattr -d com.apple.quarantine "$dir"/* 2>/dev/null || true; }
  NODE_SRC="$dir/hegemon-node-${PLAT}"
  WALLET_SRC="$dir/wallet-${PLAT}"
  WALLETD_SRC="$dir/walletd-${PLAT}"
}

binaries_installed() {
  [[ -x "$BIN_DIR/hegemon-node" && -x "$BIN_DIR/hegemon-wallet" && -x "$BIN_DIR/hegemon-walletd" ]] || return 1
  "$BIN_DIR/hegemon-node" --version 2>/dev/null | grep -q "$VERSION"
}

install_binaries() {
  put_bin "$NODE_SRC"    hegemon-node
  put_bin "$WALLET_SRC"  hegemon-wallet
  put_bin "$WALLETD_SRC" hegemon-walletd
  ok "hegemon-node, hegemon-wallet, hegemon-walletd -> $BIN_DIR"
}

# -----------------------------------------------------------------------------
# 3. Config
# -----------------------------------------------------------------------------
# Read KEY from a config file without sourcing it (tolerates quotes/spaces/export).
conf_get() {  # conf_get FILE KEY
  [[ -f "$1" ]] || return 0
  sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?$2[[:space:]]*=[[:space:]]*//p" "$1" \
    | tail -1 | sed -E "s/[[:space:]]+#.*$//; s/^[\"']//; s/[\"'][[:space:]]*$//" | tr -d '[:space:]'
}
conf_set() {  # conf_set FILE KEY VALUE
  local tmp; tmp="$(mktemp "$1.XXXXXX")"
  grep -v -E "^[[:space:]]*(export[[:space:]]+)?$2[[:space:]]*=" "$1" > "$tmp" || true
  printf '%s="%s"\n' "$2" "$3" >> "$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$1"
}

write_config() {
  if [[ ! -f "$CONF_FILE" ]]; then
    cat > "$CONF_FILE" <<EOF
# =====================================================================
#  Hegemon ${VERSION} config — read by hegemon-miner / hegemon-start
# =====================================================================

# >>> YOUR MINING PAYOUT ADDRESS — paste it between the quotes <<<
HEGEMON_MINER_ADDRESS=""

# Mining threads (empty = node default), e.g. HEGEMON_MINE_THREADS="8"
HEGEMON_MINE_THREADS=""

HEGEMON_DATA_DIR="$DATA_DIR"
HEGEMON_WALLET_STORE="$WALLET_STORE"
HEGEMON_SEEDS="$DEFAULT_SEEDS"
HEGEMON_RPC_PORT="9944"
HEGEMON_P2P_PORT="30333"
HEGEMON_NODE_NAME="HegemonNode"
EOF
    chmod 600 "$CONF_FILE"
    ok "Config written: $CONF_FILE"
  else
    ok "Keeping existing config: $CONF_FILE"
    grep -qE '^[[:space:]]*HEGEMON_MINER_ADDRESS[[:space:]]*=' "$CONF_FILE" \
      || conf_set "$CONF_FILE" HEGEMON_MINER_ADDRESS ""
  fi

  # Pick up an address from an older install (read only — nothing is written there).
  if [[ -z "$ADDRESS" && -z "$(conf_get "$CONF_FILE" HEGEMON_MINER_ADDRESS)" ]]; then
    local old a
    for old in "$HOME/.hegemon/hegemon.conf" /root/.hegemon/hegemon.conf; do
      a="$(conf_get "$old" HEGEMON_MINER_ADDRESS 2>/dev/null || true)"
      [[ -n "$a" ]] && { ADDRESS="$a"; break; }
    done
    for old in "$HOME/.hegemon/miner-address" /root/.hegemon/miner-address; do
      [[ -z "$ADDRESS" && -s "$old" ]] && ADDRESS="$(tr -d '[:space:]' < "$old" 2>/dev/null || true)"
    done
    [[ -n "$ADDRESS" ]] && ok "Imported payout address from old install"
  fi

  [[ -n "$ADDRESS" ]] && { conf_set "$CONF_FILE" HEGEMON_MINER_ADDRESS "$ADDRESS"; ok "Payout address saved in $CONF_FILE"; }
  [[ -n "$THREADS" ]] && { conf_set "$CONF_FILE" HEGEMON_MINE_THREADS "$THREADS"; ok "Mining threads: $THREADS"; }
  return 0
}

# -----------------------------------------------------------------------------
# 4. Helper commands
#    Each helper = small generated header (paths) + a literal body.
# -----------------------------------------------------------------------------
helper_header() {
  cat <<EOF
#!/usr/bin/env bash
# Generated by hegemon-install.sh (Hegemon ${VERSION})
set -euo pipefail
CONF="\${HEGEMON_CONF:-$CONF_FILE}"
BIN_DIR="$BIN_DIR"
VERSION="$VERSION"
EXPECTED_GENESIS="$EXPECTED_GENESIS"
DEFAULT_SEEDS="$DEFAULT_SEEDS"
DEFAULT_DATA="$DATA_DIR"
DEFAULT_WALLET="$WALLET_STORE"
EOF
  cat <<'EOF'
conf_get() {
  [[ -f "$CONF" ]] || return 0
  sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?$1[[:space:]]*=[[:space:]]*//p" "$CONF" \
    | tail -1 | sed -E "s/[[:space:]]+#.*$//; s/^[\"']//; s/[\"'][[:space:]]*$//" | tr -d '[:space:]'
}
conf_set() {
  touch "$CONF"
  local tmp; tmp="$(mktemp "$CONF.XXXXXX")"
  grep -v -E "^[[:space:]]*(export[[:space:]]+)?$1[[:space:]]*=" "$CONF" > "$tmp" || true
  printf '%s="%s"\n' "$1" "$2" >> "$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$CONF"
}
DATA_DIR="$(conf_get HEGEMON_DATA_DIR)";        DATA_DIR="${DATA_DIR:-$DEFAULT_DATA}"
WALLET_STORE="$(conf_get HEGEMON_WALLET_STORE)"; WALLET_STORE="${WALLET_STORE:-$DEFAULT_WALLET}"
RPC_PORT="$(conf_get HEGEMON_RPC_PORT)";         RPC_PORT="${RPC_PORT:-9944}"
P2P_PORT="$(conf_get HEGEMON_P2P_PORT)";         P2P_PORT="${P2P_PORT:-30333}"
SEEDS="$(conf_get HEGEMON_SEEDS)";               SEEDS="${SEEDS:-$DEFAULT_SEEDS}"
NODE_NAME="$(conf_get HEGEMON_NODE_NAME)";       NODE_NAME="${NODE_NAME:-HegemonNode}"
json_field() { grep -o "\"$1\" *: *\"[^\"]*\"" | head -1 | sed -E 's/.*: *"(.*)"/\1/'; }
EOF
}

write_helper() {  # write_helper NAME  (body on stdin)
  local tmp; tmp="$(mktemp)"
  { helper_header; cat; } > "$tmp"
  put_bin "$tmp" "$1"; rm -f "$tmp"
}

write_helpers() {
  log "Writing helper commands into $BIN_DIR"

  # ---- hegemon-start : relay (default) or --mine -----------------------------
  write_helper hegemon-start <<'EOF'
mine=0; cli_addr=""; extra=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mine) mine=1; shift ;;
    --address) cli_addr="${2:?--address needs a value}"; shift 2 ;;
    --address=*) cli_addr="${1#--address=}"; shift ;;
    *) extra+=("$1"); shift ;;
  esac
done
export HEGEMON_SEEDS="$SEEDS" HEGEMON_BOOTSTRAP_AUTHORING=0
export NO_COLOR="${NO_COLOR:-1}"
export RUST_LOG="${RUST_LOG:-hegemon_node=info,consensus=info,network=info}"

if [[ "$mine" == 1 ]]; then
  # Priority: --address  >  exported HEGEMON_MINER_ADDRESS  >  config file
  addr="${cli_addr:-${HEGEMON_MINER_ADDRESS:-$(conf_get HEGEMON_MINER_ADDRESS)}}"
  addr="${addr//[[:space:]]/}"
  if [[ -z "$addr" ]]; then
    cat >&2 <<MSG
No payout address found in $CONF

Fix it with ONE of these:
  hegemon-set-address <YOUR_ADDRESS>
  nano $CONF            ->  HEGEMON_MINER_ADDRESS="<YOUR_ADDRESS>"
  hegemon-miner --address <YOUR_ADDRESS>
MSG
    exit 2
  fi
  threads="$(conf_get HEGEMON_MINE_THREADS)"
  if [[ -n "$threads" ]]; then export HEGEMON_MINE_THREADS="$threads"; else unset HEGEMON_MINE_THREADS || true; fi
  if command -v timedatectl >/dev/null 2>&1 && \
     [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" != yes ]]; then
    echo "WARNING: clock not NTP-synchronized (blocks >90s in the future are rejected)." >&2
  fi
  export HEGEMON_MINE=1 HEGEMON_MINER_ADDRESS="$addr"
  echo "Hegemon $VERSION: MINING to ${addr:0:20}...${addr: -10}  threads: ${threads:-default}"
else
  export HEGEMON_MINE=0; unset HEGEMON_MINER_ADDRESS || true
  echo "Hegemon $VERSION: relay mode (no mining)"
fi
echo "Config: $CONF   Data: $DATA_DIR   RPC: 127.0.0.1:$RPC_PORT"
mkdir -p "$DATA_DIR"
exec "$BIN_DIR/hegemon-node" --dev --base-path "$DATA_DIR" --rpc-methods safe \
  --rpc-port "$RPC_PORT" --port "$P2P_PORT" --name "$NODE_NAME" ${extra[@]+"${extra[@]}"}
EOF

  # ---- hegemon-miner ---------------------------------------------------------
  write_helper hegemon-miner <<'EOF'
# hegemon-miner [--address ADDR] [node args...]
exec "$BIN_DIR/hegemon-start" --mine "$@"
EOF

  # ---- hegemon-set-address ---------------------------------------------------
  write_helper hegemon-set-address <<'EOF'
addr="${1:-}"
[[ -n "$addr" ]] || read -r -p "Paste payout address: " addr
addr="${addr//[[:space:]]/}"
[[ -n "$addr" ]] || { echo "Address cannot be empty" >&2; exit 1; }
[[ "$addr" =~ ^[A-Za-z0-9._:-]+$ ]] || { echo "Address contains invalid characters" >&2; exit 1; }
conf_set HEGEMON_MINER_ADDRESS "$addr"
echo "Payout address saved in $CONF"
echo "  ${addr:0:20}...${addr: -10}"
echo "Start mining: hegemon-miner"
EOF

  # ---- hegemon-config --------------------------------------------------------
  write_helper hegemon-config <<'EOF'
a="$(conf_get HEGEMON_MINER_ADDRESS)"
echo "Config file : $CONF"
echo "Payout addr : ${a:-<NOT SET>}"
echo "Threads     : $(t="$(conf_get HEGEMON_MINE_THREADS)"; echo "${t:-default}")"
echo "Data dir    : $DATA_DIR"
echo "Wallet store: $WALLET_STORE"
echo "Edit with   : nano $CONF"
EOF

  # ---- hegemon-status --------------------------------------------------------
  write_helper hegemon-status <<'EOF'
URL="http://127.0.0.1:${1:-$RPC_PORT}/"
rpc() { curl -fsS --connect-timeout 3 --max-time 15 -H 'Content-Type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":${2:-[]}}" "$URL"; }
health="$(rpc system_health)" || { echo "Node not reachable at $URL (is hegemon-miner running?)" >&2; exit 1; }
genesis="$(rpc chain_getBlockHash '[0]' | json_field result)"
num="$(rpc chain_getHeader | json_field number)"
echo "Version : $(rpc system_version | json_field result)"
echo "Health  : $health"
echo "Height  : $(( ${num:-0x0} ))"
if [[ "$genesis" == "$EXPECTED_GENESIS" ]]; then echo "Genesis : OK"; else echo "Genesis : MISMATCH ($genesis)"; fi
echo "Mining  : $(rpc hegemon_miningStatus 2>/dev/null || echo n/a)"
EOF

  # ---- hegemon-wallet-create -------------------------------------------------
  write_helper hegemon-wallet-create <<'EOF'
STORE="${1:-$WALLET_STORE}"
if [[ -e "$STORE" ]]; then echo "Wallet already exists at $STORE — not touching it." >&2; exit 1; fi
mkdir -p "$(dirname "$STORE")"; chmod 700 "$(dirname "$STORE")" 2>/dev/null || true
read -r -s -p "New wallet passphrase: " P1; echo >&2
read -r -s -p "Confirm passphrase:    " P2; echo >&2
[[ -n "$P1" ]] || { echo "Passphrase cannot be empty" >&2; exit 1; }
[[ "$P1" == "$P2" ]] || { echo "Passphrases do not match" >&2; exit 1; }
out="$(printf '%s\n{"id":1,"method":"status.get","params":{}}\n' "$P1" \
  | "$BIN_DIR/hegemon-walletd" --store "$STORE" --mode create 2>&1 || true)"
unset P1 P2
addr="$(json_field primaryAddress <<<"$out" || true)"
[[ -n "$addr" ]] || { echo "Wallet creation failed: $out" >&2; exit 1; }
chmod -R go-rwx "$STORE" 2>/dev/null || true
conf_set HEGEMON_MINER_ADDRESS "$addr"
echo "Wallet created : $STORE"
echo "Address        : $addr"
echo "Saved as payout address in $CONF"
echo "BACK UP the wallet store AND your passphrase (no mnemonic is shown)."
echo "Start mining   : hegemon-miner"
EOF

  # ---- hegemon-wallet-address ------------------------------------------------
  write_helper hegemon-wallet-address <<'EOF'
save=0; [[ "${1:-}" == "--save" ]] && { save=1; shift; }
STORE="${1:-$WALLET_STORE}"
[[ -e "$STORE" ]] || { echo "No wallet at $STORE. Create one (hegemon-wallet-create) or set an address: hegemon-set-address <addr>" >&2; exit 1; }
read -r -s -p "Wallet passphrase: " P; echo >&2
out="$(printf '%s\n{"id":1,"method":"status.get","params":{}}\n' "$P" \
  | "$BIN_DIR/hegemon-walletd" --store "$STORE" --mode open 2>&1 || true)"
unset P
addr="$(json_field primaryAddress <<<"$out" || true)"
[[ -n "$addr" ]] || { echo "Could not read address: $out" >&2; exit 1; }
[[ "$save" == 1 ]] && { conf_set HEGEMON_MINER_ADDRESS "$addr"; echo "Saved in $CONF" >&2; }
printf '%s\n' "$addr"
EOF

  # ---- hegemon-wallet-balance ------------------------------------------------
  write_helper hegemon-wallet-balance <<'EOF'
exec "$BIN_DIR/hegemon-wallet" status --store "${1:-$WALLET_STORE}" --ws-url "http://127.0.0.1:$RPC_PORT"
EOF

  ok "Helpers: ${HELPERS[*]}"
}

# Replace OLD copies of the helpers (e.g. ~/.local/bin, /root/.local/bin) that
# would otherwise be found first in PATH and still use the old /root config.
remove_stale_helpers() {
  local name p dirs=("$HOME/.local/bin" /root/.local/bin /usr/bin /usr/local/sbin)
  IFS=: read -r -a path_dirs <<<"$PATH"
  dirs+=("${path_dirs[@]}")
  for name in "${HELPERS[@]}" hegemon-node hegemon-wallet hegemon-walletd; do
    for p in "${dirs[@]}"; do
      [[ -n "$p" && "$p" != "$BIN_DIR" && -e "$p/$name" ]] || continue
      [[ "$p/$name" -ef "$BIN_DIR/$name" ]] && continue
      warn "Removing old $p/$name"
      rm -f "$p/$name" 2>/dev/null || $SUDO rm -f "$p/$name" 2>/dev/null || true
    done
  done
  hash -r 2>/dev/null || true
  case ":$PATH:" in *":$BIN_DIR:"*) ;; *)
    warn "$BIN_DIR is not in PATH — run:  export PATH=\"$BIN_DIR:\$PATH\"" ;;
  esac
}

# -----------------------------------------------------------------------------
# 5. Optional systemd service
# -----------------------------------------------------------------------------
install_systemd() {
  [[ "$OS" == Linux ]] && have systemctl || { warn "systemd not available; skipping."; return 0; }
  [[ -f "$BASE/service.env" ]] || printf '# empty = relay mode, --mine = mining\nHEGEMON_SERVICE_ARGS=--mine\n' > "$BASE/service.env"
  $SUDO tee /etc/systemd/system/hegemon-node.service >/dev/null <<EOF
[Unit]
Description=Hegemon ${VERSION} node/miner (config: $CONF_FILE)
After=network-online.target time-sync.target
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
Environment=HEGEMON_CONF=$CONF_FILE
EnvironmentFile=-$BASE/service.env
ExecStart=/usr/bin/env bash -c 'exec $BIN_DIR/hegemon-start \$HEGEMON_SERVICE_ARGS'
Restart=on-failure
RestartSec=10
TimeoutStopSec=120
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  $SUDO systemctl daemon-reload
  ok "Service installed: sudo systemctl enable --now hegemon-node ; journalctl -u hegemon-node -f"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  printf '%s\n' "${C_B}Hegemon ${VERSION} installer — base: $BASE, mode: $MODE, platform: $PLAT${C_0}"
  prepare_dirs

  if [[ "$HELPERS_ONLY" == 1 ]]; then
    [[ -x "$BIN_DIR/hegemon-node" ]] || warn "$BIN_DIR/hegemon-node missing — run without --helpers-only."
  elif [[ "$REBUILD" == 0 ]] && binaries_installed; then
    ok "Hegemon $VERSION binaries already in $BIN_DIR — skipping build (use --rebuild to force)"
  else
    [[ "$SKIP_DEPS" == 0 ]] && install_system_deps
    have curl || die "curl is required"
    if [[ "$MODE" == source ]]; then
      have git || die "git is required"
      [[ "$SKIP_DEPS" == 0 ]] && install_rust
      have cargo || die "cargo not found"
      build_from_source
    else
      download_prebuilt
    fi
    install_binaries
  fi

  write_config
  write_helpers
  remove_stale_helpers
  [[ "$INSTALL_SYSTEMD" == 1 ]] && install_systemd

  # Ask for the address if still missing and we are interactive.
  if [[ -z "$(conf_get "$CONF_FILE" HEGEMON_MINER_ADDRESS)" && -t 0 ]]; then
    local a=""
    read -r -p "Paste your mining payout address (Enter to skip): " a || true
    a="${a//[[:space:]]/}"
    if [[ -n "$a" && "$a" =~ ^[A-Za-z0-9._:-]+$ ]]; then
      conf_set "$CONF_FILE" HEGEMON_MINER_ADDRESS "$a"; ok "Payout address saved in $CONF_FILE"
    fi
  fi

  local cur; cur="$(conf_get "$CONF_FILE" HEGEMON_MINER_ADDRESS)"
  cat <<EOF

${C_G}${C_B}Hegemon ${VERSION} ready.${C_0}
 Config        : $CONF_FILE
 Payout address: ${cur:-${C_Y}NOT SET${C_0}}

 Set / change address : ${C_B}hegemon-set-address <ADDRESS>${C_0}   (or: nano $CONF_FILE)
 Show settings        : ${C_B}hegemon-config${C_0}
 Start mining         : ${C_B}hegemon-miner${C_0}
 Node status          : ${C_B}hegemon-status${C_0}     (other terminal)
 New wallet (optional): ${C_B}hegemon-wallet-create${C_0}   (auto-saves its address)

 Data: $DATA_DIR   Wallet: $WALLET_STORE   P2P 30333/tcp   RPC 127.0.0.1:9944
EOF
}

main "$@"
