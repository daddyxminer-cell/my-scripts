#!/usr/bin/env bash
# =============================================================================
#  hegemon-install.sh — download, build and install Hegemon v0.10.3
#                       (node + built-in miner, wallet CLI, walletd)
#
#  Release : https://github.com/Pauli-Group/Hegemon/releases/tag/v0.10.3
#  Commit  : e5d971838f123d55a56abb482c66c42ad3aeacb1
#  Network : existing public v0.10 testnet
#  Genesis : 0x506fc2cd5ed367cc68d6d23a987fe6e4a7916fde02a249105ab91884a1e6fa59
#
#  In Hegemon the miner is NOT a separate program: it is built into
#  `hegemon-node` and switched on with HEGEMON_MINE=1 + HEGEMON_MINER_ADDRESS.
#  This script installs the node and wraps the mining mode in `hegemon-miner`.
#
#  Usage:
#    bash hegemon-install.sh                 # build from source (default)
#    bash hegemon-install.sh --prebuilt      # use official release binaries
#    bash hegemon-install.sh --systemd       # also install systemd service
#    bash hegemon-install.sh --helpers-only  # only (re)write config + helper
#                                            # commands (no deps, no build)
#    bash hegemon-install.sh --help
#
#  Mining payout address (pick ONE):
#    a) edit ~/.hegemon/hegemon.conf and set  HEGEMON_MINER_ADDRESS="<addr>"
#    b) hegemon-set-address <addr>
#    c) hegemon-miner --address <addr>
#    d) hegemon-wallet-create  (saves the new wallet's address automatically)
#
#  Supported: Linux x86_64/aarch64 (source), Linux x86_64 (prebuilt),
#             macOS Intel / Apple Silicon (source + prebuilt).
# =============================================================================
set -euo pipefail

# ----------------------------------------------------------------------------- 
# Release constants
# -----------------------------------------------------------------------------
VERSION="0.10.3"
TAG="v${VERSION}"
REPO_URL="https://github.com/Pauli-Group/Hegemon.git"
DL_BASE="https://github.com/Pauli-Group/Hegemon/releases/download/${TAG}"
EXPECTED_COMMIT="e5d971838f123d55a56abb482c66c42ad3aeacb1"
EXPECTED_GENESIS="0x506fc2cd5ed367cc68d6d23a987fe6e4a7916fde02a249105ab91884a1e6fa59"
DEFAULT_SEEDS="hegemon.pauli.group:30333,devnet.hegemonprotocol.com:30333"

# Pinned SHA-256 of the official v0.10.3 release binaries (from the GitHub
# release asset digests). Used in --prebuilt mode.
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
# Defaults (override with flags or environment variables)
# -----------------------------------------------------------------------------
MODE="${HEGEMON_INSTALL_MODE:-source}"            # source | prebuilt
HEGEMON_HOME="${HEGEMON_HOME:-$HOME/.hegemon}"     # sources, build, config
SRC_DIR="${HEGEMON_SRC_DIR:-$HEGEMON_HOME/src/Hegemon-${VERSION}}"
# Where commands are installed: /usr/local/bin for root (always in PATH),
# ~/.local/bin otherwise (added to PATH via shell rc files if needed).
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  BIN_DIR="${HEGEMON_BIN_DIR:-/usr/local/bin}"
else
  BIN_DIR="${HEGEMON_BIN_DIR:-$HOME/.local/bin}"
fi
PATH_WAS_MISSING=0
DATA_DIR="${HEGEMON_DATA_DIR:-$HOME/.hegemon-testnet}"   # node chain data
WALLET_STORE="${HEGEMON_WALLET_STORE:-$HOME/.hegemon-wallet}"
CONF_FILE="$HEGEMON_HOME/hegemon.conf"
BUILD_JOBS="${HEGEMON_BUILD_JOBS:-}"               # empty = cargo default
SKIP_DEPS=0
INSTALL_SYSTEMD=0
HELPERS_ONLY=0

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
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

SUDO=""
if [[ ${EUID:-$(id -u)} -ne 0 ]] && have sudo; then SUDO="sudo"; fi

sha256_of() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

usage() {
  cat <<EOF
${C_B}Hegemon ${VERSION} installer${C_0} — node + miner + wallet

Usage: bash hegemon-install.sh [options]

Options:
  --source            Build from the tagged source (default)
  --prebuilt          Download official release binaries (SHA-256 pinned)
  --bin-dir DIR       Install commands into DIR (default: /usr/local/bin as root,
                      ~/.local/bin otherwise; added to PATH automatically)
  --data-dir DIR      Node data directory             (default: ~/.hegemon-testnet)
  --wallet FILE       Wallet store file               (default: ~/.hegemon-wallet)
  --jobs N            Parallel cargo build jobs (use 1-2 on low-RAM machines)
  --skip-deps         Do not install system packages / Rust toolchain
  --systemd           Install a systemd service (hegemon-node.service, Linux)
  --helpers-only      Only (re)write config + helper commands; keeps the already
                      installed binaries (fast fix, no rebuild)
  -h, --help          Show this help

After installation these commands are available:
  hegemon-node             raw node binary (relay or miner)
  hegemon-wallet           wallet CLI   (init, node-sync, status, node-send ...)
  hegemon-walletd          wallet JSON daemon (used by helper scripts)
  hegemon-start            start the node in relay (non-mining) mode
  hegemon-miner            start the node in mining mode  (--address ADDR optional)
  hegemon-set-address      write a payout address into the config manually
  hegemon-status           query the running node (peers, height, genesis)
  hegemon-wallet-create    create a new wallet store
  hegemon-wallet-address   print / save your shielded mining address
  hegemon-wallet-balance   sync wallet with the local node and show balance
EOF
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)    MODE=source; shift ;;
    --prebuilt)  MODE=prebuilt; shift ;;
    --bin-dir)   BIN_DIR="${2:?--bin-dir needs a value}"; shift 2 ;;
    --data-dir)  DATA_DIR="${2:?--data-dir needs a value}"; shift 2 ;;
    --wallet)    WALLET_STORE="${2:?--wallet needs a value}"; shift 2 ;;
    --jobs)      BUILD_JOBS="${2:?--jobs needs a value}"; shift 2 ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    --systemd)   INSTALL_SYSTEMD=1; shift ;;
    --helpers-only) HELPERS_ONLY=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
done
[[ "$MODE" == source || "$MODE" == prebuilt ]] || die "invalid mode: $MODE"

# -----------------------------------------------------------------------------
# Platform detection
# -----------------------------------------------------------------------------
OS="$(uname -s)"; ARCH="$(uname -m)"
case "$OS:$ARCH" in
  Linux:x86_64|Linux:amd64)   PLAT="linux-x86_64" ;;
  Linux:aarch64|Linux:arm64)  PLAT="linux-aarch64" ;;
  Darwin:x86_64)              PLAT="macos-x86_64" ;;
  Darwin:arm64|Darwin:aarch64) PLAT="macos-arm64" ;;
  *) die "Unsupported platform: $OS $ARCH (use Windows release ZIP on Windows)" ;;
esac
if [[ "$MODE" == prebuilt && "$PLAT" == "linux-aarch64" ]]; then
  die "No official prebuilt binaries for Linux aarch64 — rerun without --prebuilt to build from source."
fi

# -----------------------------------------------------------------------------
# 1. System dependencies
# -----------------------------------------------------------------------------
install_system_deps() {
  log "Installing system dependencies"
  if have apt-get; then
    $SUDO apt-get update -y
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential pkg-config libssl-dev clang libclang-dev lld cmake \
      protobuf-compiler git curl ca-certificates unzip jq python3
  elif have dnf; then
    $SUDO dnf install -y gcc gcc-c++ make pkgconf-pkg-config openssl-devel clang \
      clang-devel lld cmake protobuf-compiler git curl unzip jq python3
  elif have yum; then
    $SUDO yum install -y gcc gcc-c++ make pkgconfig openssl-devel clang clang-devel \
      cmake protobuf-compiler git curl unzip jq python3
  elif have pacman; then
    $SUDO pacman -Sy --needed --noconfirm base-devel pkgconf openssl clang lld cmake \
      protobuf git curl unzip jq python
  elif have zypper; then
    $SUDO zypper --non-interactive install -t pattern devel_basis || true
    $SUDO zypper --non-interactive install pkg-config libopenssl-devel clang llvm-devel \
      cmake protobuf-devel git curl unzip jq python3
  elif have brew; then
    xcode-select -p >/dev/null 2>&1 || warn "Run 'xcode-select --install' if the build fails."
    brew install protobuf cmake jq git curl
  else
    warn "Unknown package manager. Make sure these are installed: C/C++ toolchain,"
    warn "pkg-config, OpenSSL headers, clang/libclang, cmake, protobuf-compiler, git, curl, jq."
  fi
  ok "System dependencies ready"
}

install_rust() {
  # rust-toolchain.toml in the repo pins Rust 1.91.1; rustup fetches it automatically.
  if [[ -f "$HOME/.cargo/env" ]]; then # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
  fi
  if ! have rustup; then
    log "Installing Rust (rustup)"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --default-toolchain none
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
  fi
  ok "rustup $(rustup --version 2>/dev/null | head -1 | awk '{print $2}')"
}

# -----------------------------------------------------------------------------
# 2a. Build from source
# -----------------------------------------------------------------------------
build_from_source() {
  log "Fetching Hegemon ${TAG} source into $SRC_DIR"
  mkdir -p "$(dirname "$SRC_DIR")"
  if [[ -d "$SRC_DIR/.git" ]]; then
    git -C "$SRC_DIR" fetch --depth 1 origin "refs/tags/${TAG}:refs/tags/${TAG}" --force
    git -C "$SRC_DIR" checkout --force "${TAG}"
  else
    git clone --depth 1 --branch "${TAG}" "$REPO_URL" "$SRC_DIR"
  fi
  local head; head="$(git -C "$SRC_DIR" rev-parse HEAD)"
  [[ "$head" == "$EXPECTED_COMMIT" ]] \
    || die "Source commit mismatch: got $head, expected $EXPECTED_COMMIT"
  ok "Source verified at commit $head"

  log "Installing pinned Rust toolchain from rust-toolchain.toml"
  (
    cd "$SRC_DIR"
    rustup toolchain install 2>/dev/null \
      || rustup toolchain install 1.91.1 --profile minimal \
           --component rustfmt,clippy,rust-src --target wasm32-unknown-unknown
    rustc --version
  )

  local mem_gb=0
  if [[ -r /proc/meminfo ]]; then
    mem_gb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
  fi
  if [[ -z "$BUILD_JOBS" && $mem_gb -gt 0 && $mem_gb -lt 8 ]]; then
    BUILD_JOBS=2
    warn "Only ${mem_gb} GB RAM detected — limiting build to $BUILD_JOBS jobs (override with --jobs)."
  fi
  local jobs_arg=()
  [[ -n "$BUILD_JOBS" ]] && jobs_arg=(-j "$BUILD_JOBS")

  log "Building hegemon-node, wallet and walletd (release). This can take 15-60 min..."
  (
    cd "$SRC_DIR"
    export CARGO_INCREMENTAL=0
    # Same commands as scripts/build_release_artifacts.sh in the release.
    cargo build --locked --release ${jobs_arg[@]+"${jobs_arg[@]}"} -p hegemon-node --bin hegemon-node --no-default-features
    cargo build --locked --release ${jobs_arg[@]+"${jobs_arg[@]}"} -p wallet  --bin wallet
    cargo build --locked --release ${jobs_arg[@]+"${jobs_arg[@]}"} -p walletd --bin walletd
  )
  NODE_SRC="$SRC_DIR/target/release/hegemon-node"
  WALLET_SRC="$SRC_DIR/target/release/wallet"
  WALLETD_SRC="$SRC_DIR/target/release/walletd"
  ok "Build complete"
}

# -----------------------------------------------------------------------------
# 2b. Download prebuilt release binaries (pinned SHA-256)
# -----------------------------------------------------------------------------
download_prebuilt() {
  local dir="$HEGEMON_HOME/release-${VERSION}"
  mkdir -p "$dir"
  log "Downloading official ${TAG} binaries for $PLAT"
  local name expected actual sidecar
  for base in hegemon-node wallet walletd; do
    name="${base}-${PLAT}"
    curl --fail --location --silent --show-error -o "$dir/$name"        "$DL_BASE/$name"
    curl --fail --location --silent --show-error -o "$dir/$name.sha256" "$DL_BASE/$name.sha256"
    expected="$(pinned_sha256 "$name")" || die "no pinned hash for $name"
    sidecar="$(awk '{print $1}' "$dir/$name.sha256")"
    actual="$(sha256_of "$dir/$name")"
    [[ "$actual" == "$expected" && "$sidecar" == "$expected" ]] \
      || die "Checksum mismatch for $name (got $actual, expected $expected)"
    chmod +x "$dir/$name"
    ok "$name  sha256 OK"
  done
  if [[ "$OS" == Darwin ]]; then
    xattr -d com.apple.quarantine "$dir"/* 2>/dev/null || true
  fi
  NODE_SRC="$dir/hegemon-node-${PLAT}"
  WALLET_SRC="$dir/wallet-${PLAT}"
  WALLETD_SRC="$dir/walletd-${PLAT}"
}

# -----------------------------------------------------------------------------
# 3. Install binaries + helper commands
# -----------------------------------------------------------------------------
install_binaries() {
  log "Installing binaries into $BIN_DIR"
  mkdir -p "$BIN_DIR" "$HEGEMON_HOME" "$DATA_DIR"
  install -m 0755 "$NODE_SRC"    "$BIN_DIR/hegemon-node"
  install -m 0755 "$WALLET_SRC"  "$BIN_DIR/hegemon-wallet"
  install -m 0755 "$WALLETD_SRC" "$BIN_DIR/hegemon-walletd"
  ok "hegemon-node, hegemon-wallet, hegemon-walletd installed"
}

write_config() {
  if [[ -f "$CONF_FILE" ]]; then
    ok "Keeping existing config $CONF_FILE"
    # Migrate older configs: make sure the manual address setting exists.
    if ! grep -q '^HEGEMON_MINER_ADDRESS=' "$CONF_FILE"; then
      cat >> "$CONF_FILE" <<'EOF'

# Mining payout address. Paste your shielded address between the quotes,
# or run: hegemon-set-address <address>. Takes priority over the address file.
HEGEMON_MINER_ADDRESS=""
EOF
      ok "Added HEGEMON_MINER_ADDRESS setting to $CONF_FILE"
    fi
    grep -q '^HEGEMON_MINER_ADDRESS_FILE=' "$CONF_FILE" \
      || printf 'HEGEMON_MINER_ADDRESS_FILE="%s"\n' "$HEGEMON_HOME/miner-address" >> "$CONF_FILE"
    return
  fi
  cat > "$CONF_FILE" <<EOF
# Hegemon ${VERSION} settings — sourced by hegemon-start / hegemon-miner / systemd.
HEGEMON_DATA_DIR="$DATA_DIR"
HEGEMON_WALLET_STORE="$WALLET_STORE"
HEGEMON_SEEDS="$DEFAULT_SEEDS"
HEGEMON_RPC_PORT=9944
HEGEMON_P2P_PORT=30333
HEGEMON_NODE_NAME="HegemonNode"
# Mining threads (empty = node default). Example: HEGEMON_MINE_THREADS=4
HEGEMON_MINE_THREADS=""
# Payout address file written by 'hegemon-wallet-address --save'
HEGEMON_MINER_ADDRESS_FILE="$HEGEMON_HOME/miner-address"

# Mining payout address. Paste your shielded address between the quotes,
# or run: hegemon-set-address <address>. Takes priority over the address file.
HEGEMON_MINER_ADDRESS=""
EOF
  chmod 600 "$CONF_FILE"
  ok "Config written: $CONF_FILE"
}

write_helpers() {
  log "Writing helper commands"

  # ---- common runner (relay or mine) ---------------------------------------
  cat > "$BIN_DIR/hegemon-start" <<EOF
#!/usr/bin/env bash
# Start the Hegemon ${VERSION} node. Relay mode by default; 'hegemon-start --mine' mines.
set -euo pipefail
# An address exported in the environment wins over the config file.
env_addr="\${HEGEMON_MINER_ADDRESS:-}"
CONF="\${HEGEMON_CONF:-$CONF_FILE}"
[[ -f "\$CONF" ]] && source "\$CONF"
BIN_DIR="$BIN_DIR"
mine=0
cli_addr=""
extra=()
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --mine) mine=1; shift ;;
    --address) cli_addr="\${2:?--address needs a value}"; shift 2 ;;
    --address=*) cli_addr="\${1#--address=}"; shift ;;
    *) extra+=("\$1"); shift ;;
  esac
done

export HEGEMON_SEEDS="\${HEGEMON_SEEDS:-$DEFAULT_SEEDS}"
export HEGEMON_BOOTSTRAP_AUTHORING=0
export NO_COLOR="\${NO_COLOR:-1}"
export RUST_LOG="\${RUST_LOG:-hegemon_node=info,consensus=info,network=info}"

if [[ "\$mine" == 1 ]]; then
  # Priority: --address > environment > config HEGEMON_MINER_ADDRESS > address file
  addr="\${cli_addr:-\${env_addr:-\${HEGEMON_MINER_ADDRESS:-}}}"
  addr="\${addr//[[:space:]]/}"
  if [[ -z "\$addr" && -n "\${HEGEMON_MINER_ADDRESS_FILE:-}" && -s "\$HEGEMON_MINER_ADDRESS_FILE" ]]; then
    addr="\$(tr -d '[:space:]' < "\$HEGEMON_MINER_ADDRESS_FILE")"
  fi
  if [[ -z "\$addr" ]]; then
    cat >&2 <<MSG
No payout address configured. Do ONE of these:
  1) Edit \$CONF and set:  HEGEMON_MINER_ADDRESS="<your address>"
  2) hegemon-set-address <your address>
  3) hegemon-miner --address <your address>
MSG
    exit 2
  fi
  # Time sync is required: blocks >90s in the future are rejected.
  if command -v timedatectl >/dev/null 2>&1; then
    [[ "\$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == yes ]] \
      || echo "WARNING: system clock not reported as NTP-synchronized. Enable NTP/chrony." >&2
  fi
  export HEGEMON_MINE=1
  export HEGEMON_MINER_ADDRESS="\$addr"
  if [[ -n "\${HEGEMON_MINE_THREADS:-}" ]]; then export HEGEMON_MINE_THREADS; else unset HEGEMON_MINE_THREADS || true; fi
  echo "Hegemon ${VERSION}: MINING to \${addr:0:24}...\${addr: -12}"
else
  export HEGEMON_MINE=0
  unset HEGEMON_MINER_ADDRESS || true
  echo "Hegemon ${VERSION}: relay mode (no mining)"
fi
echo "Data: \${HEGEMON_DATA_DIR}   RPC: http://127.0.0.1:\${HEGEMON_RPC_PORT}   Seeds: \$HEGEMON_SEEDS"
echo "Expected genesis: $EXPECTED_GENESIS"
mkdir -p "\$HEGEMON_DATA_DIR"
# --dev is the documented public-testnet launch profile for 0.10.x when used with the seeds.
exec "\$BIN_DIR/hegemon-node" --dev --base-path "\$HEGEMON_DATA_DIR" --rpc-methods safe \\
  --rpc-port "\$HEGEMON_RPC_PORT" --port "\$HEGEMON_P2P_PORT" --name "\${HEGEMON_NODE_NAME:-HegemonNode}" \\
  \${extra[@]+"\${extra[@]}"}
EOF

  # ---- miner -----------------------------------------------------------------
  cat > "$BIN_DIR/hegemon-miner" <<EOF
#!/usr/bin/env bash
# Start the Hegemon node with the built-in miner enabled.
# Mines only after the node's sync gate opens (synced to the canonical chain).
#   hegemon-miner                      # address from config
#   hegemon-miner --address <addr>     # one-off address override
exec "$BIN_DIR/hegemon-start" --mine "\$@"
EOF

  # ---- set payout address manually -----------------------------------------
  cat > "$BIN_DIR/hegemon-set-address" <<EOF
#!/usr/bin/env bash
# Write a mining payout address into the config (HEGEMON_MINER_ADDRESS) and
# into the address file. Usage: hegemon-set-address <address>
set -euo pipefail
CONF="\${HEGEMON_CONF:-$CONF_FILE}"; [[ -f "\$CONF" ]] && source "\$CONF"
addr="\${1:-}"
if [[ -z "\$addr" ]]; then
  read -r -p "Paste payout address: " addr
fi
addr="\${addr//[[:space:]]/}"
[[ -n "\$addr" ]] || { echo "Address cannot be empty" >&2; exit 1; }
[[ "\$addr" =~ ^[A-Za-z0-9._:-]+\$ ]] || { echo "Address contains invalid characters" >&2; exit 1; }
mkdir -p "\$(dirname "\$CONF")"
touch "\$CONF"
tmp="\$(mktemp "\$CONF.XXXXXX")"
grep -v '^HEGEMON_MINER_ADDRESS=' "\$CONF" > "\$tmp" || true
printf 'HEGEMON_MINER_ADDRESS="%s"\n' "\$addr" >> "\$tmp"
chmod 600 "\$tmp"; mv "\$tmp" "\$CONF"
ADDR_FILE="\${HEGEMON_MINER_ADDRESS_FILE:-$HEGEMON_HOME/miner-address}"
mkdir -p "\$(dirname "\$ADDR_FILE")"
( umask 077; printf '%s\n' "\$addr" > "\$ADDR_FILE" )
echo "Payout address set in \$CONF"
echo "  \${addr:0:24}...\${addr: -12}"
echo "Now run: hegemon-miner"
EOF

  # ---- status ---------------------------------------------------------------
  cat > "$BIN_DIR/hegemon-status" <<EOF
#!/usr/bin/env bash
# Query a running local node: peers, tip height, genesis, mining gate, version.
set -euo pipefail
CONF="\${HEGEMON_CONF:-$CONF_FILE}"; [[ -f "\$CONF" ]] && source "\$CONF"
PORT="\${1:-\${HEGEMON_RPC_PORT:-9944}}"
URL="http://127.0.0.1:\$PORT/"
rpc() { curl --fail --silent --show-error --connect-timeout 3 --max-time 15 \\
  -H 'Content-Type: application/json' --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"\$1\",\"params\":\${2:-[]}}" "\$URL"; }
if ! command -v jq >/dev/null 2>&1; then
  for m in system_health chain_getHeader hegemon_miningStatus system_version; do rpc "\$m"; echo; done
  rpc chain_getBlockHash "[0]"; echo; exit 0
fi
health="\$(rpc system_health)"     || { echo "Node not reachable at \$URL" >&2; exit 1; }
header="\$(rpc chain_getHeader)"
genesis="\$(rpc chain_getBlockHash '[0]' | jq -r .result)"
mining="\$(rpc hegemon_miningStatus | jq -c .result)"
version="\$(rpc system_version | jq -r .result)"
height_hex="\$(jq -r '.result.number // "0x0"' <<<"\$header")"
echo "Version   : \$version"
echo "Peers     : \$(jq -r .result.peers <<<"\$health")   syncing: \$(jq -r .result.isSyncing <<<"\$health")"
echo "Tip height: \$((height_hex))"
if [[ "\$genesis" == "$EXPECTED_GENESIS" ]]; then echo "Genesis   : OK (\$genesis)"
else echo "Genesis   : MISMATCH! got \$genesis expected $EXPECTED_GENESIS"; fi
echo "Mining    : \$mining"
EOF

  # ---- wallet create --------------------------------------------------------
  cat > "$BIN_DIR/hegemon-wallet-create" <<EOF
#!/usr/bin/env bash
# Create a NEW wallet store (refuses to overwrite an existing one).
set -euo pipefail
CONF="\${HEGEMON_CONF:-$CONF_FILE}"; [[ -f "\$CONF" ]] && source "\$CONF"
STORE="\${1:-\$HEGEMON_WALLET_STORE}"
if [[ -e "\$STORE" ]]; then echo "Wallet store already exists at \$STORE — not touching it." >&2; exit 1; fi
read -r -s -p "New wallet passphrase: " P1; echo >&2
read -r -s -p "Confirm passphrase:    " P2; echo >&2
[[ -n "\$P1" ]] || { echo "Passphrase cannot be empty" >&2; exit 1; }
[[ "\$P1" == "\$P2" ]] || { echo "Passphrases do not match" >&2; exit 1; }
out="\$(printf '%s\n{"id":1,"method":"status.get","params":{}}\n' "\$P1" | "$BIN_DIR/hegemon-walletd" --store "\$STORE" --mode create)"
unset P1 P2
addr="\$(jq -r '.result.primaryAddress // empty' <<<"\$out" 2>/dev/null || true)"
[[ -n "\$addr" ]] || { echo "Wallet creation failed: \$out" >&2; exit 1; }
chmod go-rwx "\$STORE" 2>/dev/null || true
echo "Wallet created at \$STORE"
echo "Address: \$addr"
# Save the payout address straight into the config so hegemon-miner works
# immediately (no need to re-open the wallet).
"$BIN_DIR/hegemon-set-address" "\$addr" >/dev/null && echo "Payout address saved to config (\$CONF)."
echo "IMPORTANT: back up the wallet store AND your passphrase. No mnemonic is shown."
echo "Next: hegemon-miner"
EOF

  # ---- wallet address -------------------------------------------------------
  cat > "$BIN_DIR/hegemon-wallet-address" <<EOF
#!/usr/bin/env bash
# Print your shielded receive address. '--save' stores it for hegemon-miner.
set -euo pipefail
CONF="\${HEGEMON_CONF:-$CONF_FILE}"; [[ -f "\$CONF" ]] && source "\$CONF"
save=0; [[ "\${1:-}" == "--save" ]] && { save=1; shift; }
STORE="\${1:-\$HEGEMON_WALLET_STORE}"
# No strict file/dir pre-check: let walletd decide whether the store opens
# (the store layout may be a file or a directory depending on the build).
if [[ ! -e "\$STORE" ]]; then
  echo "Warning: \$STORE not found; trying to open it anyway..." >&2
fi
read -r -s -p "Wallet passphrase: " P; echo >&2
out="\$(printf '%s\n{"id":1,"method":"status.get","params":{}}\n' "\$P" | "$BIN_DIR/hegemon-walletd" --store "\$STORE" --mode open 2>&1 || true)"
unset P
addr="\$(grep -o '"primaryAddress" *: *"[^"]*"' <<<"\$out" | head -1 | sed 's/.*: *"\(.*\)"/\1/' || true)"
if [[ -z "\$addr" ]]; then
  echo "Could not read address from wallet: \$out" >&2
  echo "You can still set the address manually:  hegemon-set-address <address>" >&2
  echo "or edit \$CONF and set HEGEMON_MINER_ADDRESS=\"<address>\"" >&2
  exit 1
fi
if [[ "\$save" == 1 ]]; then
  "$BIN_DIR/hegemon-set-address" "\$addr" >&2
fi
printf '%s\n' "\$addr"
EOF

  # ---- wallet balance -------------------------------------------------------
  cat > "$BIN_DIR/hegemon-wallet-balance" <<EOF
#!/usr/bin/env bash
# Sync the wallet against the local node (HTTP RPC) and print status/balance.
# The first scan can take a long time; let it finish before trusting balances.
set -euo pipefail
CONF="\${HEGEMON_CONF:-$CONF_FILE}"; [[ -f "\$CONF" ]] && source "\$CONF"
STORE="\${1:-\$HEGEMON_WALLET_STORE}"
exec "$BIN_DIR/hegemon-wallet" status --store "\$STORE" --ws-url "http://127.0.0.1:\${HEGEMON_RPC_PORT:-9944}"
EOF

  chmod 0755 "$BIN_DIR"/hegemon-{start,miner,status,set-address,wallet-create,wallet-address,wallet-balance}
  ok "Helper commands installed"

  # Older installs may have left helper copies in another PATH directory
  # (e.g. ~/.local/bin) that shadow the new ones. Point them at the new ones.
  local f name other
  for f in "$BIN_DIR"/hegemon-*; do
    name="$(basename "$f")"
    for other in "$HOME/.local/bin" /usr/local/bin /usr/bin; do
      [[ "$other" == "$BIN_DIR" ]] && continue
      if [[ -f "$other/$name" && ! "$other/$name" -ef "$f" ]]; then
        warn "Replacing stale $other/$name with link to $f"
        $SUDO ln -sf "$f" "$other/$name" 2>/dev/null || true
      fi
    done
  done
  hash -r 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# 4. Optional systemd service
# -----------------------------------------------------------------------------
install_systemd() {
  [[ "$OS" == Linux ]] || { warn "--systemd is Linux only; skipping."; return; }
  have systemctl || { warn "systemctl not found; skipping service install."; return; }
  local unit=/etc/systemd/system/hegemon-node.service
  log "Installing systemd service $unit"
  $SUDO tee "$unit" >/dev/null <<EOF
[Unit]
Description=Hegemon ${VERSION} testnet node (set HEGEMON_SERVICE_ARGS=--mine in $HEGEMON_HOME/service.env to mine)
After=network-online.target time-sync.target
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
Environment=HEGEMON_CONF=$CONF_FILE
EnvironmentFile=-$HEGEMON_HOME/service.env
ExecStart=/usr/bin/env bash -c 'exec $BIN_DIR/hegemon-start \$HEGEMON_SERVICE_ARGS'
Restart=on-failure
RestartSec=10
KillSignal=SIGTERM
TimeoutStopSec=120
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  [[ -f "$HEGEMON_HOME/service.env" ]] || \
    printf '# Leave empty for relay mode, or set to --mine to run the miner.\nHEGEMON_SERVICE_ARGS=\n' > "$HEGEMON_HOME/service.env"
  $SUDO systemctl daemon-reload
  ok "Service installed. Start: sudo systemctl enable --now hegemon-node ; logs: journalctl -u hegemon-node -f"
}

# -----------------------------------------------------------------------------
# 5. Make sure the commands are on PATH
# -----------------------------------------------------------------------------
setup_path() {
  case ":$PATH:" in *":$BIN_DIR:"*) ok "$BIN_DIR is already in PATH"; return ;; esac
  PATH_WAS_MISSING=1
  local line="export PATH=\"$BIN_DIR:\$PATH\"   # added by hegemon-install.sh"
  local rc added=0
  for rc in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.zshrc" "$HOME/.bash_profile"; do
    # always handle .bashrc/.profile; others only if they already exist
    if [[ -f "$rc" || "$rc" == "$HOME/.bashrc" || "$rc" == "$HOME/.profile" ]]; then
      if ! grep -qsF "$BIN_DIR:" "$rc"; then
        printf '\n%s\n' "$line" >> "$rc"
        added=1
      fi
    fi
  done
  [[ $added == 1 ]] && ok "Added $BIN_DIR to PATH in your shell startup files"
  # Also link the commands into /usr/local/bin when possible, so they work
  # immediately in the current shell without re-login.
  if [[ "$BIN_DIR" != /usr/local/bin ]] && { [[ -w /usr/local/bin ]] || [[ -n "$SUDO" ]]; }; then
    local f
    for f in "$BIN_DIR"/hegemon-*; do
      $SUDO ln -sf "$f" "/usr/local/bin/$(basename "$f")" 2>/dev/null || true
    done
    case ":$PATH:" in *":/usr/local/bin:"*) PATH_WAS_MISSING=0
      ok "Linked hegemon-* commands into /usr/local/bin" ;; esac
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  printf '%s\n' "${C_B}Hegemon ${VERSION} installer — mode: ${MODE}, platform: ${PLAT}${C_0}"
  mkdir -p "$HEGEMON_HOME"

  if [[ "$HELPERS_ONLY" == 1 ]]; then
    [[ -x "$BIN_DIR/hegemon-node" ]] || warn "$BIN_DIR/hegemon-node not found — run the full install first."
    mkdir -p "$BIN_DIR" "$DATA_DIR"
    write_config
    write_helpers
    [[ "$INSTALL_SYSTEMD" == 1 ]] && install_systemd
    setup_path
    cat <<EOF

${C_G}${C_B}Helpers and config updated.${C_0}
 Set your payout address (pick one):
   nano $CONF_FILE        -> HEGEMON_MINER_ADDRESS="<address>"
   hegemon-set-address <address>
 Then start mining:        ${C_B}hegemon-miner${C_0}
EOF
    return 0
  fi

  if [[ "$SKIP_DEPS" == 0 ]]; then
    install_system_deps
    [[ "$MODE" == source ]] && install_rust
  else
    [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
  fi
  have curl || die "curl is required"

  if [[ "$MODE" == source ]]; then
    have git   || die "git is required"
    have cargo || die "cargo not found (remove --skip-deps or install Rust)"
    build_from_source
  else
    download_prebuilt
  fi

  install_binaries
  write_config
  write_helpers
  [[ "$INSTALL_SYSTEMD" == 1 ]] && install_systemd

  have jq || warn "jq not found — wallet helper scripts need it (install jq)."

  log "Installed version check"
  "$BIN_DIR/hegemon-node"   --version 2>/dev/null || true
  "$BIN_DIR/hegemon-wallet" --version 2>/dev/null || true

  setup_path

  cat <<EOF

${C_G}${C_B}Hegemon ${VERSION} installed.${C_0}

 1) Start a relay node and let it sync:   ${C_B}hegemon-start${C_0}
 2) In another terminal, check the node:   ${C_B}hegemon-status${C_0}
      (genesis must be OK, peers > 0, height rising)
 3) Create a wallet (if you have none):    ${C_B}hegemon-wallet-create${C_0}
      (the new address is saved into the config automatically)
 4) OR set an address manually:            ${C_B}hegemon-set-address <address>${C_0}
      or edit $CONF_FILE -> HEGEMON_MINER_ADDRESS="<address>"
 5) Stop the relay (Ctrl+C), then mine:    ${C_B}hegemon-miner${C_0}
      threads: set HEGEMON_MINE_THREADS in $CONF_FILE
 6) Check rewards:                         ${C_B}hegemon-wallet-balance${C_0}

 Ports: P2P 30333/tcp (open it in the firewall to help the network), RPC 127.0.0.1:9944
 Data : $DATA_DIR    Wallet file: $WALLET_STORE    Config: $CONF_FILE
 Keep the system clock synced (NTP/chrony); mining is testnet-only.
EOF
  if [[ "$PATH_WAS_MISSING" == 1 ]]; then
    printf '\n%s IMPORTANT: run this once in your current terminal (or open a new one):%s\n' "$C_Y$C_B" "$C_0"
    printf '      %sexport PATH="%s:$PATH"%s\n' "$C_B" "$BIN_DIR" "$C_0"
  fi
}

main "$@"
