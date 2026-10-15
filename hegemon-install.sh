#!/usr/bin/env bash
# Ubuntu Server/Desktop 24.04 LTS, Intel/AMD 64-bit. No elevation required.
# Runs as the current account; never installs system packages or switches users.
# Official v0.10.3 public testnet, pinned and hash-checked (2026-10-15).
# Usage: bash hegemon-ubuntu.sh [--mine] [--threads 4] [--install-only]
# Never run with bash -x: wallet passwords must not be traced.
set +x
set -euo pipefail
umask 077
ulimit -c 0
if [[ "$(uname -s):$(uname -m)" != Linux:x86_64 ]]; then
  echo 'This official release supports Linux x86_64 (Intel/AMD), not Linux ARM.' >&2
  exit 1
fi
# Help must work without installing packages or starting a tmux session.
for argument in "$@"; do
  case "$argument" in
    --help|-h)
      cat <<'HELP'
Usage: bash hegemon-ubuntu.sh [OPTIONS]
Ubuntu Server/Desktop 24.04 x86_64: user-local, no-elevation installer.
Creates Desktop/hegemon/data, verifies Hegemon v0.10.3, and uses tmux if present.
No Downloads folder, graphical desktop, login shell or user switching needed.
Requires Python 3.11+ and working system TLS certificates; tmux is optional.

  --directory PATH   Installation folder (default: your Desktop/hegemon)
  --mine             Offer mining after sync, NTP and checkpoint checks
  --threads N        Mining threads (default: half your logical CPUs)
  --rpc-port PORT    Loopback HTTP RPC port (default: 9944)
  --p2p-port PORT    P2P port (default: 30333)
  --install-only     Install/verify only; do not start tmux, node or wallet
  --no-tmux          Run in this terminal instead (stops on SSH disconnect)

Never calls sudo, su, apt or chown; never changes system users or permissions.
Uses the running account's registered home, not an incorrectly inherited HOME.
Already root? It warns and continues AS ROOT; it does not drop privileges.
Wallet passwords are never saved. Missing dependencies are reported, not installed.
With tmux: Ctrl+B then D to detach; re-run to reconnect. Without tmux: keep SSH open.
An existing tmux terminal is reused. No automatic reboot startup is installed.
HELP
      exit 0
      ;;
  esac
done
if ! command -v python3 >/dev/null 2>&1; then
  echo 'Python 3.11+ is required (Ubuntu 24.04 normally includes 3.12).' >&2
  echo 'Use an image with Python or ask your provider to supply it. No system changes were made.' >&2
  exit 1
fi
# Do not pass inherited shell startup hooks to tmux or its child Bash.
unset BASH_ENV ENV
script_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
exec python3 - "$script_path" "$@" <<'HEGEMON_PYTHON'
import argparse
import fcntl
import getpass
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import select
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile

VERSION = "0.10.3"
BASE_URL = f"https://github.com/Pauli-Group/Hegemon/releases/download/v{VERSION}/"
ARCHIVE = f"hegemon-testnet-{VERSION}-linux-x86_64.zip"
ARCHIVE_HASH = "d91d9ab40e9ca96e793a14ac3c612d09c303c376b25d930f6f9ae814d43799b4"
GENESIS = "0x506fc2cd5ed367cc68d6d23a987fe6e4a7916fde02a249105ab91884a1e6fa59"
HASHES = {
    "hegemon-node-linux-x86_64": "10138d3ba57752a782b229e068decca9729358c375b01f4660895be519643789",
    "wallet-linux-x86_64": "24200cdd56144890e35914769eb3746aff2dfcbf2e45b167faa21d0c41d807b1",
    "walletd-linux-x86_64": "c26b7d7c88057fa72fd45d3751b43fc0d7cecb92591566a66a0fdc6f7196fff6",
}


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def configure_account():
    """Resolve the effective account independently of HOME/SUDO_USER/LOGNAME."""
    try:
        account = pwd.getpwuid(os.geteuid())
    except KeyError as error:
        raise RuntimeError("Current UID has no account entry; ask the provider to configure its home.") from error
    home = Path(account.pw_dir)
    if not home.is_absolute() or str(home) in ("/", "/nonexistent"):
        raise RuntimeError("Current account has no usable registered home directory.")
    if os.environ.get("HOME") != str(home):
        print(f"Correcting inherited HOME for account {account.pw_name}: {home}")
        # XDG locations inherited from a different account can redirect writes too.
        for key in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR"):
            os.environ.pop(key, None)
    os.environ.update(HOME=str(home), USER=account.pw_name, LOGNAME=account.pw_name, SHELL="/bin/bash")
    for key in ("BASH_ENV", "ENV", "SUDO_USER", "SUDO_UID", "SUDO_GID"):
        os.environ.pop(key, None)
    print(f"Running as {account.pw_name} (UID {os.geteuid()}); no privilege elevation or user switching.")
    if os.geteuid() == 0:
        print("WARNING: launched as root, so node/wallet will also run as root.\n"
              "A normal account is recommended; this script does not drop privileges.", file=sys.stderr)
    return home


def desktop_directory():
    if shutil.which("xdg-user-dir"):
        result = subprocess.run(["xdg-user-dir", "DESKTOP"], capture_output=True, text=True)
        value = Path(result.stdout.strip())
        if result.returncode == 0 and value.is_absolute() and value != Path.home():
            return value
    return Path.home() / "Desktop"


def positive(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def arguments(argv):
    parser = argparse.ArgumentParser(prog="hegemon-ubuntu.sh", description=(
        "Install and run the official Hegemon v0.10.3 testnet node, integrated CPU "
        "miner and terminal wallet. Data is never reset. Ctrl+C stops owned processes."))
    parser.add_argument("--directory", type=Path, default=desktop_directory() / "hegemon",
                        help="installation folder (default: your Desktop/hegemon)")
    parser.add_argument("--install-only", action="store_true", help="download/verify only; no tmux, wallet or node started")
    parser.add_argument("--no-tmux", action="store_true", help="run in the current terminal; not protected from SSH disconnects")
    parser.add_argument("--mine", action="store_true", help="ask to mine after sync, NTP and canonical checkpoint checks")
    parser.add_argument("--threads", type=positive, default=max(1, (os.cpu_count() or 2) // 2),
                        help="CPU mining threads (default: half your logical CPUs)")
    parser.add_argument("--rpc-port", type=positive, default=9944)
    parser.add_argument("--p2p-port", type=positive, default=30333)
    args = parser.parse_args(argv)
    if max(args.rpc_port, args.p2p_port) > 65535 or args.rpc_port == args.p2p_port:
        parser.error("ports must be distinct and between 1 and 65535")
    return args


def launch_tmux(source, options, root):
    """Keep the interactive wallet alive across SSH disconnects; never persist secrets."""
    tmux = shutil.which("tmux")
    if not tmux:
        raise RuntimeError("tmux is unavailable. Run with --no-tmux to use the current terminal.")
    # A private socket per installation avoids attaching to an unrelated session.
    # The normal user owns this directory (0700); no system service is installed.
    socket_path = str(root / ".tmux.sock")
    if len(os.fsencode(socket_path)) >= 104:
        raise RuntimeError("Installation path is too long for a tmux socket. Use a shorter --directory.")
    command = [tmux, "-S", socket_path, "-f", "/dev/null"]
    target = "=hegemon"
    # tmux rejects the /dev/tty alias: it needs the real /dev/pts/N (or console)
    # path so its daemon can reopen the client's terminal. stdin is a heredoc.
    terminal_path = next((os.ttyname(fd) for fd in (1, 2, 0)
                          if os.isatty(fd) and os.ttyname(fd) != "/dev/tty"), None)
    if terminal_path is None:
        raise RuntimeError("Run in an interactive SSH terminal (ssh -t), without redirecting both outputs, or use --install-only.")
    try:
        terminal = os.open(terminal_path, os.O_RDWR)
    except OSError as error:
        raise RuntimeError("Cannot open the SSH terminal for tmux; try --install-only or --no-tmux.") from error
    try:
        exists = subprocess.run(command + ["has-session", "-t", target],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if exists.returncode != 0:
            # shlex.join prevents shell interpretation of paths/options. The child
            # flag prevents recursion; each Popen has its own interpreter input.
            child = shlex.join(["/bin/bash", "--noprofile", "--norc", str(source.resolve()), "--no-tmux", *options,
                                "--directory", str(root)])
            # Keep startup errors visible rather than instantly closing the pane.
            child += ('; result=$?; if [ "$result" -ne 0 ]; then '
                      'printf "\\nLauncher stopped with an error. Press Enter to close.\\n"; '
                      'read -r reply; fi; exit "$result"')
            created = subprocess.run(command + ["new-session", "-d", "-s", "hegemon", "-c", str(root), child],
                                     capture_output=True, text=True)
            if created.returncode != 0:
                # Two simultaneous launchers may race to create the same session.
                exists = subprocess.run(command + ["has-session", "-t", target],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if exists.returncode != 0:
                    raise RuntimeError(f"Cannot start tmux: {created.stderr.strip()}")
        print("Opening Hegemon's persistent tmux terminal. Detach with Ctrl+B, then D.\n"
              "Re-run this script to reconnect. No automatic reboot startup is installed.", flush=True)
        # Python's stdin contains this embedded program, not a TTY. Explicitly
        # connect all three tmux client streams to the controlling terminal.
        attached = subprocess.run(command + ["attach-session", "-t", target],
                                  stdin=terminal, stdout=terminal, stderr=terminal)
        if attached.returncode != 0:
            raise RuntimeError("tmux attach failed. Re-run this script to reconnect; the session may still be running.")
    finally:
        os.close(terminal)


def download(url, destination):
    for attempt in range(3):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "Hegemon-Ubuntu-Installer/1"})
            with urllib.request.urlopen(request, timeout=60) as response, destination.open("wb") as out:
                shutil.copyfileobj(response, out)
            return
        except (OSError, ValueError):
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)


def install(root, source):
    release = root / "releases" / f"v{VERSION}"
    release.mkdir(parents=True, exist_ok=True)
    # Recheck installed executables on every launch. Never touch data on repair.
    if not all((release / name).is_file() and digest(release / name) == expected
               for name, expected in HASHES.items()):
        print(f"Downloading official Hegemon v{VERSION} Linux x86_64 bundle...", flush=True)
        with tempfile.TemporaryDirectory(prefix=".download-", dir=root) as temporary:
            stage = Path(temporary)
            archive = stage / ARCHIVE
            sidecar = stage / (ARCHIVE + ".sha256")
            download(BASE_URL + ARCHIVE, archive)
            download(BASE_URL + ARCHIVE + ".sha256", sidecar)
            checksum_fields = sidecar.read_text().split()
            published = checksum_fields[0] if checksum_fields else ""
            if published != ARCHIVE_HASH or digest(archive) != ARCHIVE_HASH:
                raise RuntimeError("Release SHA-256 mismatch. Nothing will be executed.")
            with zipfile.ZipFile(archive) as bundle:
                # Extract only known flat members; never extract arbitrary paths or symlinks.
                for name, expected in HASHES.items():
                    target = stage / name
                    target.write_bytes(bundle.read(name))
                    if digest(target) != expected:
                        raise RuntimeError(f"Binary checksum mismatch: {name}")
                for name in HASHES:
                    os.replace(stage / name, release / name)
                (release / "TESTNET-README.txt").write_bytes(bundle.read("TESTNET-README.txt"))
    for name in HASHES:
        (release / name).chmod(0o700)
    launcher = root / "hegemon-ubuntu.sh"
    if source.resolve() != launcher.resolve():
        # Atomic copy keeps a complete reusable single-file launcher in Desktop/hegemon.
        temporary = root / ".launcher-new"
        temporary.write_bytes(source.read_bytes())
        temporary.chmod(0o700)
        os.replace(temporary, launcher)
    launcher.chmod(0o700)
    print(f"Verified binaries: {release}\nReusable launcher: {launcher}")
    return release


class Session:
    def __init__(self, args, root, release, tty):
        self.args, self.root, self.release, self.tty = args, root, release, tty
        self.data = root / "data"
        self.store = self.data / "wallet" / "wallet.store"
        self.url = f"http://127.0.0.1:{args.rpc_port}"
        self.node = self.wallet = None
        self.mining = False
        self.address = None
        self.sequence = 0
        self.environment = {key: value for key, value in os.environ.items()
                            if not key.startswith("HEGEMON_")}
        self.environment.update(NO_COLOR="1", RUST_LOG="hegemon_node=info,consensus=info,network=info")
        for folder in (self.data / "node", self.store.parent, root / "logs"):
            folder.mkdir(parents=True, exist_ok=True)
            folder.chmod(0o700)
        stamp = time.strftime("%Y%m%d-%H%M%S") + f"-{os.getpid()}"
        self.node_log_path = root / "logs" / f"node-{stamp}.log"
        self.node_log = self.node_log_path.open("ab", buffering=0)
        self.wallet_log = (root / "logs" / f"wallet-{stamp}.log").open("ab", buffering=0)

    def prompt(self, message):
        print(message, end="", flush=True)
        value = self.tty.readline()
        if not value:
            raise EOFError("Terminal closed")
        return value.rstrip("\r\n")

    def wallet_request(self, method, params=None, timeout=120):
        self.sequence += 1
        request = {"id": self.sequence, "method": method, "params": params or {}}
        self.wallet.stdin.write(json.dumps(request) + "\n")
        self.wallet.stdin.flush()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if select.select([self.wallet.stdout], [], [], 10)[0]:
                line = self.wallet.stdout.readline()
                if not line:
                    raise RuntimeError("Wallet exited. Check its log; wrong passwords never reset the wallet.")
                response = json.loads(line)
                if response.get("id") != self.sequence:
                    raise RuntimeError("Unexpected wallet response ID")
                if response.get("ok") is not True:
                    raise RuntimeError(f"Wallet request failed: {response.get('error')}")
                return response["result"]
            if method == "sync.once":
                print("Wallet scan still running; first scans may take a long time.", flush=True)
        raise RuntimeError("Wallet request timed out. Stop and reopen safely; do not reset the wallet.")

    def open_wallet(self):
        mode = "open"
        if not self.store.exists():
            print(f"No wallet exists at {self.store}\nIf you already own a wallet, quit and copy its store here while it is closed.")
            if self.prompt("Create a NEW testnet wallet? Type CREATE (anything else quits): ") != "CREATE":
                raise RuntimeError("No wallet created; existing wallets elsewhere were not changed.")
            mode = "create"
        password = getpass.getpass("Wallet passphrase: ")
        if not password or password != password.strip() or "\n" in password or "\r" in password:
            raise RuntimeError("Use a nonempty passphrase without leading/trailing whitespace or newlines.")
        if mode == "create":
            if len(password) < 12:
                raise RuntimeError("Use at least 12 characters for a new wallet passphrase.")
            if password != getpass.getpass("Confirm passphrase: "):
                raise RuntimeError("Passphrases do not match; no wallet created.")
        self.wallet = subprocess.Popen(
            [str(self.release / "walletd-linux-x86_64"), "--store", str(self.store), "--mode", mode],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.wallet_log,
            text=True, bufsize=1, cwd=self.data, env=self.environment, start_new_session=True)
        # Private pipe only: never put the passphrase in argv, environment or a file.
        self.wallet.stdin.write(password + "\n")
        self.wallet.stdin.flush()
        del password
        status = self.wallet_request("status.get")
        self.address = status["primaryAddress"]
        if not self.address.startswith("shca1"):
            raise RuntimeError("Wallet did not provide a supported shielded receive address.")
        (self.store.parent / "receive-address.txt").write_text(self.address + "\n")
        print(f"Wallet open: {self.store}\nPublic receive address: {self.store.parent / 'receive-address.txt'}")
        if mode == "create":
            print("IMPORTANT: This wallet has no mnemonic output. Back up the closed wallet store\n"
                  "and keep its passphrase separately. Losing either can lose access to funds.")
            if self.prompt("Type SAVED to acknowledge this backup requirement: ") != "SAVED":
                raise RuntimeError("Wallet created and retained; quitting before node startup.")

    def rpc(self, method, params=None):
        payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}).encode()
        request = urllib.request.Request(self.url, data=payload, headers={"Content-Type": "application/json"})
        # Local RPC must not pass through an HTTP proxy.
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=10) as response:
            result = json.load(response)
        if result.get("error") is not None or "result" not in result:
            raise RuntimeError(f"RPC {method} failed: {result}")
        return result["result"]

    @staticmethod
    def stop_process(process, label):
        if process is not None and process.poll() is None:
            print(f"Stopping {label}; waiting for clean database flush...", flush=True)
            process.terminate()
            while True:
                try:
                    process.wait(timeout=30)
                    break
                except subprocess.TimeoutExpired:
                    print(f"Still waiting for {label}; not force-killing or deleting data.", flush=True)

    def start_node(self, mine=False):
        self.stop_process(self.node, "node")
        self.node = None
        # Refuse occupied ports, including an unmanaged existing node. Never kill it.
        for port in (self.args.rpc_port, self.args.p2p_port):
            with socket.socket() as probe:
                probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                try:
                    probe.bind(("0.0.0.0", port))
                except OSError as error:
                    raise RuntimeError(f"Port {port} is occupied. Stop the other node or choose different ports.") from error
        env = self.environment.copy()
        env.update(HEGEMON_SEEDS="hegemon.pauli.group:30333,devnet.hegemonprotocol.com:30333",
                   HEGEMON_MINE="1" if mine else "0", HEGEMON_BOOTSTRAP_AUTHORING="0",
                   HEGEMON_MINE_THREADS=str(self.args.threads))
        if mine:
            env["HEGEMON_MINER_ADDRESS"] = self.address
        self.node = subprocess.Popen(
            [str(self.release / "hegemon-node-linux-x86_64"), "--dev", "--base-path", str(self.data / "node"),
             "--rpc-methods", "safe", "--rpc-port", str(self.args.rpc_port),
             "--port", str(self.args.p2p_port), "--name", "HegemonUbuntuDesktop"],
            cwd=self.data, env=env, stdin=subprocess.DEVNULL,
            stdout=self.node_log, stderr=subprocess.STDOUT, start_new_session=True)
        self.mining = mine
        print(f"Node running; mining requested={mine}; local RPC={self.url}\nLog: {self.node_log_path}")
        for _ in range(90):
            if self.node.poll() is not None:
                raise RuntimeError(f"Node exited; inspect {self.node_log_path}")
            try:
                genesis = self.rpc("chain_getBlockHash", [0])
            except (OSError, ValueError, RuntimeError):
                time.sleep(1)
                continue
            if genesis != GENESIS:
                raise RuntimeError(f"Wrong testnet genesis: {genesis}. Data was NOT reset.")
            return
        raise RuntimeError("Node RPC did not become ready. Check the node log and rerun to resume.")

    def node_status(self):
        if self.node.poll() is not None:
            raise RuntimeError(f"Node exited; inspect {self.node_log_path}")
        health = self.rpc("system_health")
        header = self.rpc("chain_getHeader")
        mining = self.rpc("hegemon_miningStatus")
        print(f"Node height={int(header['number'], 16)} | peers={health.get('peers')} | "
              f"syncing={health.get('isSyncing')} | mining requested={self.mining} | "
              f"mining gate={mining.get('mining_sync_gate_open')} | "
              f"mining active={mining.get('is_mining')} | hashes/s={mining.get('hash_rate')} | "
              f"blocks found={mining.get('blocks_found')}", flush=True)
        return (health.get("peers", 0) > 0 and health.get("isSyncing") is False
                and mining.get("syncing") is False), mining

    def sync_wallet(self):
        print("Scanning the local node into the persistent wallet (up to two hours per scan)...", flush=True)
        self.wallet_request("sync.once", {"ws_url": self.url, "force_rescan": False}, timeout=7200)
        status = self.wallet_request("status.get")
        print(f"Wallet scan succeeded; height={status.get('lastSyncedHeight')}")
        print("Balances (raw base units): " + json.dumps(status.get("balances", []), indent=2))

    def enable_mining(self):
        ready, mining = self.node_status()
        if not ready or mining.get("mining_sync_gate_open") is not True:
            print("Mining stays OFF until connected, synchronized, and the mining gate is open.")
            return
        try:
            ntp = subprocess.run(["timedatectl", "show", "-p", "NTPSynchronized", "--value"],
                                 capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            ntp = None
        if ntp is None or ntp.returncode != 0 or ntp.stdout.strip() != "yes":
            print("Mining stays OFF: system time is not confirmed synchronized.\n"
                  "Ask your provider to enable/verify host time synchronization.\n"
                  "Containers may not expose timedatectl. This script will not change the host clock.")
            return
        print("Get a recent block HEIGHT and HASH from a trusted, synced public-testnet operator.\n"
              "Do NOT copy your own node's hash as the independent checkpoint.")
        height = self.prompt("Canonical checkpoint height (decimal, blank cancels): ")
        if not re.fullmatch(r"[1-9][0-9]*", height):
            print("Cancelled: a positive checkpoint height is required.")
            return
        expected = self.prompt("Trusted block hash (0x + 64 hex characters): ").lower()
        if not re.fullmatch(r"0x[0-9a-f]{64}", expected):
            print("Cancelled: invalid hash.")
            return
        if self.rpc("chain_getBlockHash", [int(height)]) != expected:
            print("Mining stays OFF: canonical checkpoint does not match (or height not reached).")
            return
        if self.prompt(f"Mine testnet using {self.args.threads} CPU threads? Type MINE: ") != "MINE":
            return
        self.start_node(mine=True)
        print("Mining opted in. The node's sync gate still controls when work starts.")

    def run(self):
        self.open_wallet()
        self.start_node()
        print("Waiting for node catch-up before scanning the wallet. Ctrl+C stops safely; rerun to resume.")
        while True:
            ready, _ = self.node_status()
            if ready:
                break
            time.sleep(15)
        self.sync_wallet()
        if self.args.mine:
            self.enable_mining()
        print("Commands: m = enable mining, r = relay only, s = sync wallet now,\n"
              "          n = node status, q = quit and stop node/wallet.\n"
              "Wallet automatically scans every 60 seconds while this terminal stays open.")
        while True:
            print("[m/r/s/n/q] (Enter = status): ", end="", flush=True)
            if select.select([self.tty], [], [], 60)[0]:
                line = self.tty.readline()
                if not line:
                    return
                command = line.strip().lower()
            else:
                print()
                command = "s"
            if command == "q":
                return
            if command == "m":
                if self.mining:
                    print("Mining already requested.")
                else:
                    self.enable_mining()
            elif command == "r":
                self.start_node(mine=False)
            elif command == "s":
                ready, _ = self.node_status()
                if ready:
                    self.sync_wallet()
                else:
                    print("Node catching up; wallet scan deferred. Cached balance may be stale.")
            else:
                self.node_status()

    def close(self):
        self.stop_process(self.wallet, "wallet")
        self.stop_process(self.node, "node")
        self.wallet_log.close()
        self.node_log.close()


def interrupted(_signal, _frame):
    raise KeyboardInterrupt


def main(argv):
    if sys.version_info < (3, 11):
        raise RuntimeError("Python 3.11+ is required; no system packages will be installed.")
    configure_account()
    source = Path(argv[0])
    args = arguments(argv[1:])
    os.umask(0o077)
    distro = __import__("platform").freedesktop_os_release()
    if distro.get("ID") != "ubuntu" or distro.get("VERSION_ID") != "24.04":
        print("Warning: intended for Ubuntu 24.04 LTS x86_64; your distribution differs.")
    root = args.directory.expanduser().resolve()
    try:
        root.mkdir(parents=True, exist_ok=True)
        if root.stat().st_uid != os.geteuid():
            raise RuntimeError(f"{root} belongs to another account. Use its owner or choose an empty --directory you own.\n"
                               "Existing wallet data will not be moved, replaced, or have ownership changed.")
        root.chmod(0o700)
    except PermissionError as error:
        raise RuntimeError(f"Cannot access {root} as this account. Choose a writable --directory you own.\n"
                           "No system permission or ownership changes will be attempted.") from error
    # Start/reattach before taking the process lock. The child acquires the lock
    # and installs binaries; reconnecting must not contend with its live lock.
    if not args.install_only and not args.no_tmux and not os.environ.get("TMUX"):
        if shutil.which("tmux"):
            launch_tmux(source, argv[1:], root)
            return
        print("tmux is not installed. Continuing in this terminal without installing packages.\n"
              "Keep SSH open: disconnecting will stop the node/wallet. Re-run to resume saved data.")
    # Lock belongs to the launcher, not the children. Crashes do not leave stale PID ownership.
    with (root / ".launcher.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("Another launcher is using this folder. Do not run two copies.") from error
        release = install(root, source)
        print(f"All node/wallet data: {root / 'data'}\nTestnet only. This is a terminal wallet, not a GUI.")
        for folder in (root / "data" / "node", root / "data" / "wallet"):
            folder.mkdir(parents=True, exist_ok=True)
            folder.chmod(0o700)
        if args.install_only:
            return
        if os.environ.get("TMUX"):
            print("SSH-safe tmux session: detach with Ctrl+B then D; node/wallet keep running.\n"
                  "This does not start automatically after a server reboot.")
        # A TTY is not seekable: r+ would construct an invalid BufferedRandom.
        # getpass independently opens the controlling TTY with echo disabled.
        with open("/dev/tty", "r") as tty:
            session = Session(args, root, release, tty)
            signal.signal(signal.SIGTERM, interrupted)
            signal.signal(signal.SIGHUP, interrupted)
            try:
                session.run()
            finally:
                # A second Ctrl+C must not interrupt database flushing.
                for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                    signal.signal(sig, signal.SIG_IGN)
                session.close()
                print(f"Stopped. Data retained in {root / 'data'}; back up your closed wallet now.")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except KeyboardInterrupt:
        print("\nStopped by user.")
        sys.exit(130)
    except (OSError, RuntimeError, ValueError, KeyError, EOFError, zipfile.BadZipFile) as error:
        print(f"ERROR: {error}\nNo automatic reset or wallet deletion was performed.", file=sys.stderr)
        sys.exit(1)
HEGEMON_PYTHON
