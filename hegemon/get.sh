#!/usr/bin/env bash
# =============================================================================
#  get.sh — download the Hegemon scripts from the public repo and run one.
#
#    curl -fsSL https://raw.githubusercontent.com/daddyxminer-cell/my-scripts/main/hegemon/get.sh | bash -s -- cpuminer
#    curl -fsSL https://raw.githubusercontent.com/daddyxminer-cell/my-scripts/main/hegemon/get.sh | bash -s -- pool-node
#    curl -fsSL https://raw.githubusercontent.com/daddyxminer-cell/my-scripts/main/hegemon/get.sh | bash -s -- node
#    curl -fsSL https://raw.githubusercontent.com/daddyxminer-cell/my-scripts/main/hegemon/get.sh | bash -s -- miner
#
#  Targets:
#    node       -> hegemon.sh            (node + wallet + miner, official release)
#    miner      -> hegemon-miner.sh      (extra VPS running its own mining node)
#    pool-node  -> hegemon-pool-node.sh  (your node + remote-mining endpoint)
#    cpuminer   -> hegemon-cpuminer.sh   (standalone CPU miner, no node)
#    (none)     -> only download / update, then print the commands
#  Any further arguments are passed to the chosen script.
# =============================================================================
set -euo pipefail

REPO="${HEGEMON_SCRIPTS_REPO:-https://github.com/daddyxminer-cell/my-scripts.git}"
BRANCH="${HEGEMON_SCRIPTS_BRANCH:-main}"
DEST="${HEGEMON_SCRIPTS_DIR:-$HOME/hegemon-scripts}"

SUDO=""; [[ ${EUID:-$(id -u)} -ne 0 ]] && SUDO="sudo"
if ! command -v git >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then $SUDO apt-get update -qq && $SUDO apt-get install -y -qq git ca-certificates >/dev/null
  elif command -v dnf >/dev/null 2>&1; then $SUDO dnf install -y git
  else echo "please install git" >&2; exit 1; fi
fi

if [[ -d "$DEST/.git" ]]; then
  git -C "$DEST" fetch -q --depth 1 origin "$BRANCH"
  git -C "$DEST" reset -q --hard "origin/$BRANCH"
else
  rm -rf "$DEST"
  git clone -q --depth 1 --branch "$BRANCH" "$REPO" "$DEST"
fi
cd "$DEST/hegemon"
chmod +x ./*.sh
echo "[get] Hegemon scripts ready in $DEST/hegemon ($(git -C "$DEST" rev-parse --short HEAD))"

target="${1:-}"; [[ $# -gt 0 ]] && shift
case "$target" in
  node)      script=hegemon.sh ;;
  miner)     script=hegemon-miner.sh ;;
  pool-node) script=hegemon-pool-node.sh ;;
  cpuminer)  script=hegemon-cpuminer.sh ;;
  "")        echo "Run one of:"
             echo "  cd $DEST/hegemon && bash hegemon.sh             # node + wallet + miner"
             echo "  cd $DEST/hegemon && bash hegemon-pool-node.sh   # node VPS: remote-mining endpoint"
             echo "  cd $DEST/hegemon && bash hegemon-cpuminer.sh    # mining VPS: standalone CPU miner"
             echo "  cd $DEST/hegemon && bash hegemon-miner.sh       # extra VPS with its own mining node"
             exit 0 ;;
  *) echo "unknown target '$target' (node|miner|pool-node|cpuminer)" >&2; exit 2 ;;
esac
# keep the user's terminal for interactive prompts when piped from curl
if [[ ! -t 0 && -r /dev/tty ]]; then exec bash "./$script" "$@" < /dev/tty; fi
exec bash "./$script" "$@"
