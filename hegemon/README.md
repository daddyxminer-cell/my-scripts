# Hegemon automated node + wallet + miner script

> **Repository:** https://github.com/daddyxminer-cell/my-scripts (folder `hegemon/`)

## Download

One-liner. It clones or updates the scripts into `~/hegemon-scripts` and starts the one you pick:
```bash
# standalone CPU miner (mining VPS, no node)
curl -fsSL https://raw.githubusercontent.com/daddyxminer-cell/my-scripts/main/hegemon/get.sh | bash -s -- cpuminer
# your node VPS: node with the remote-mining endpoint
curl -fsSL https://raw.githubusercontent.com/daddyxminer-cell/my-scripts/main/hegemon/get.sh | bash -s -- pool-node
# node + wallet + miner (official release)
curl -fsSL https://raw.githubusercontent.com/daddyxminer-cell/my-scripts/main/hegemon/get.sh | bash -s -- node
```
Or with git:
```bash
git clone https://github.com/daddyxminer-cell/my-scripts.git
cd my-scripts/hegemon
bash hegemon-cpuminer.sh        # or hegemon-pool-node.sh / hegemon.sh / hegemon-miner.sh
```
Update later with `git -C ~/hegemon-scripts pull` (or re-run the one-liner).


`hegemon.sh` downloads, installs (or builds), creates a wallet for, and runs a
[Hegemon](https://github.com/Pauli-Group/Hegemon) node and miner on the public
testnet. It follows the upstream `README.md`,
`runbooks/miner_wallet_quickstart.md` and the release `TESTNET-README.txt`.

## Quick start (one command)

```bash
bash hegemon.sh            # = install + wallet + relay -> sync -> mine
```

It will:

1. **Download** the latest release bundle `hegemon-testnet-<ver>-<platform>.zip`
   from GitHub Releases. It **verifies the ZIP SHA-256** and the checksum of each
   binary, then installs `hegemon-node`, `wallet` and `walletd` to `~/.hegemon-auto/bin`.
2. **Create a wallet** with `walletd --mode create` at `~/.hegemon-wallet`. It asks you
   for a passphrase. If the wallet already exists, it is opened and never overwritten.
   The ~2.6 KB shielded `shca1…` address is saved as the mining payout address.
3. **Start a relay node** with the same settings as the official `testnet-start.sh`:
   `--dev --rpc-methods safe`, seeds `hegemon.pauli.group:30333,devnet.hegemonprotocol.com:30333`,
   `HEGEMON_BOOTSTRAP_AUTHORING=0`, persistent data in `~/.hegemon-testnet`.
4. **Check the genesis hash** (`0x506fc2cd…e6fa59`) and **wait for catch-up**:
   at least one peer, not syncing, and height at or above the peer target.
5. **Restart with mining** (`HEGEMON_MINE=1`, `HEGEMON_MINER_ADDRESS`, `HEGEMON_MINE_THREADS`).
   This is the relay-first-then-mine order that upstream recommends.

> A first sync of the public testnet (~123k blocks) takes a while. Progress is
> printed live. Press Ctrl+C at any time; the relay keeps running in the background,
> and `bash hegemon.sh mine` resumes later.

### Mine to an address you already have

`hegemon.sh` normally creates a wallet on the VPS. To send rewards to an
existing address instead (no wallet or passphrase on this VPS):
```bash
bash hegemon.sh --address shca1...            # or --address-file addr.txt
```
On an interactive first run without these flags, it asks:
`1) Create a new wallet on this VPS` or `2) paste an existing address`.

## Commands

| Command | What it does |
|---|---|
| `all` (default) | install + wallet + relay → verify → sync → mine |
| `install` | download a verified release (`--source` builds from git instead) |
| `wallet` | create or open the wallet and save the shielded address |
| `address` | print the shielded address |
| `relay` | run a non-mining testnet node in the background |
| `mine` | relay → genesis check → sync wait → mining |
| `dev` | solo-mine a private, isolated dev chain (temp DB; README step 3) |
| `status` | version, peers, tip, genesis, mining stats |
| `balance` | `sync.once` the wallet against the local node and show the shielded balance |
| `logs` | follow the node log |
| `stop` | clean SIGTERM shutdown (flushes the DB) |
| `update` | install the newest release and restart in the previous mode |
| `systemd` | install a `systemd --user` service so the miner starts at boot |

## Options

```
--source             build from source: git clone @tag, make setup, make node,
                     cargo build --release -p walletd -p wallet
--version vX.Y.Z     release tag (default latest; v0.10.2+ is required, see below)
--threads N          mining threads (default: cores-1; the node caps this itself
                     to keep sync/RPC responsive)
--data-dir PATH      node data dir        --wallet PATH   wallet store
--rpc-port PORT      default 9944         --port PORT     P2P, default 30333
--sync-timeout SEC   give up waiting for sync (0 = forever)
--skip-sync-wait     mine right away (the node's own sync gate still applies)
```

Unattended / CI use: set `HEGEMON_WALLET_PASSPHRASE` or
`HEGEMON_WALLET_PASSPHRASE_FILE`. The passphrase is only piped to walletd on stdin.

## Examples

```bash
bash hegemon.sh --source all          # build everything from source, then mine
bash hegemon.sh --threads 4 mine
bash hegemon.sh status
bash hegemon.sh balance
bash hegemon.sh dev                   # local private chain for experiments
bash hegemon.sh systemd               # run the miner as a service
```

## Standalone CPU miner (no node on the mining VPS)

The stock v0.10.3 node only mines locally: its pool RPCs are disabled stubs and
its RPC listens on 127.0.0.1. These three parts add remote mining **without
changing consensus**:

| Part | Runs on | What it does |
|---|---|---|
| `node-patch/` | (source) | Small additive patch to hegemon-node v0.10.3: a token-protected endpoint (`mining_getWork`, `mining_submit`, `mining_stats`). The node still builds every template itself (coinbase paid to the worker's address) and fully validates every submitted block with the normal import path. |
| `hegemon-pool-node.sh` | your node VPS (161.97.92.49) | Clones v0.10.3, applies the patch, builds, then restarts your node on the same chain data with the endpoint on port **9944**. The node's own RPC moves to 127.0.0.1:9945. Prints the URL and token. |
| `hegemon-cpuminer.sh` + `cpuminer/` | each mining VPS | Builds the Rust `hegemon-cpuminer` for that CPU (`target-cpu=native`, SHA-NI if available), asks for URL, token and payout address, and runs it on all cores as a service. No chain, no sync, no wallet. |

### 1. On the node VPS (once)
```bash
bash hegemon-pool-node.sh install     # 5-40 min build; keeps ~/.hegemon-testnet and the wallet
bash hegemon-pool-node.sh token       # prints URL + TOKEN for the miners
bash hegemon-pool-node.sh status      # height, peers, hashrate and blocks per worker
```
Open TCP 9944 in your provider's firewall (the script opens ufw/firewalld itself).

### 2. On every mining VPS
```bash
bash hegemon-cpuminer.sh              # asks: URL [http://161.97.92.49:9944], token, shca1... address
bash hegemon-cpuminer.sh status       # hashrate, accepted/stale blocks
bash hegemon-cpuminer.sh logs         # live output
bash hegemon-cpuminer.sh benchmark    # local hashrate only
```
Non-interactive: `bash hegemon-cpuminer.sh --url http://161.97.92.49:9944 --token TOKEN --address-file addr.txt --threads 16`.

Rewards are shielded coinbase notes paid to the address you entered. Check them
on the main VPS with `bash hegemon.sh balance`.

**Tested here:** I built the patched node from a fresh v0.10.3 checkout and started
it on a private chain with local mining off. A standalone miner on its own then
mined 41 blocks over HTTP (0 rejected, 2 stale). The **unmodified official v0.10.3
node** synced all 41 blocks with no import errors, and the wallet recovered all
41 rewards (204.77 HGM). The installer, the token check and the address check were
also run end to end. In the sandbox the patched node also connected to the public
testnet (6 peers) and started syncing. While syncing, the endpoint correctly
answered "node is syncing" instead of giving out work.

**Hashrate:** about 1 MH/s per core here (2.5 GHz Xeon, no SHA-NI). CPUs with
SHA-NI (AMD Zen, Intel Ice Lake and later) are several times faster per core.

**Security:** the endpoint only builds templates for the caller and validates
blocks. It exposes no wallet or keys. Keep the token secret, and rotate it with
`bash hegemon-pool-node.sh new-token`.

## Extra mining VPSes, full-node mode (`hegemon-miner.sh`)

Hegemon v0.10.x has **no remote-mining (pool/getwork) RPC**. In the release,
`hegemon_poolWork` and `hegemon_compactJob` return *"not enabled in milestone 1"*,
and the RPC listens on 127.0.0.1 only. So a CPU on another VPS cannot "mine to"
`161.97.92.49:9944`.

The supported setup is to run a **mining node on each extra VPS** and peer it
with your main node over P2P (`161.97.92.49:30333`). Pay every worker to the
**same shielded address**. All rewards then land in the wallet on your main VPS.
The worker holds **no wallet, passphrase or key**, only the public address.

On the MAIN VPS, copy the address:
```bash
bash hegemon.sh address > addr.txt      # ~2.6 KB single line, copy it to the worker
```
On each EXTRA VPS, give the address in whichever way is easiest:
```bash
bash hegemon-miner.sh                             # asks you to paste the address first
bash hegemon-miner.sh --address shca1...          # or pass it directly
bash hegemon-miner.sh --address-file addr.txt     # or read it from a file
HEGEMON_MINER_ADDRESS=shca1... bash hegemon-miner.sh   # or via environment
bash hegemon-miner.sh address                     # change it later (restarts the miner)
bash hegemon-miner.sh show-address                # print the saved address
bash hegemon-miner.sh systemd                     # optional: auto-start at boot
bash hegemon-miner.sh status                      # height, peers, hash rate, blocks found
```
The worker uses your node first as its seed (`--main HOST:PORT`, default
`161.97.92.49:30333`), then the official seeds. Each worker downloads and
verifies the chain itself on first start, which takes a while, then mines once
its sync gate opens. Check rewards on the main VPS with `bash hegemon.sh balance`.

**Thread cap.** The release node mines with at most `min(2, cores-3)` threads,
so a 4-core VPS uses 1 thread. That cap is a local responsiveness setting, not a
consensus rule. `--uncap-threads` builds `hegemon-node` from source at the same
release tag with the cap raised: it keeps 1 core for networking and sync, and the
rest mine. The build needs ~4 GB RAM (or swap) and 30+ minutes.
```bash
bash hegemon-miner.sh --uncap-threads --address-file addr.txt install
bash hegemon-miner.sh --threads 7 start           # e.g. 8-core VPS
```

## Troubleshooting

**`RPC not answering yet` / `Failed to connect to 127.0.0.1 port 9944`.**
After a restart, `hegemon-node` reloads and re-verifies its stored chain
*before* it opens RPC port 9944. On a fully synced testnet (~123k blocks) this
can take **several minutes**. The script now waits for up to 30 minutes and shows
the current startup phase. Change the limit with `HEGEMON_STARTUP_TIMEOUT=<seconds>`.
If the wait is cut short, run `bash hegemon.sh mine` again: it attaches to the
node that is still starting instead of launching a second one.

**`Refusing to mine on an unexpected chain`** used to also appear when RPC simply
wasn't reachable. The script now reports the two cases separately: a *different
chain* (real genesis mismatch) or *RPC not reachable*.

**Node exits during startup.** The script prints the last log lines. Common causes:
- `No space left on device`: the data filesystem is full. The script checks free
  space before starting.
- OOM kill: add RAM or swap.
- Port 9944 or 30333 already in use, often by another `hegemon-node`
  (check with `ss -ltnp | grep 9944`). The script checks the ports before starting.

| Variable | Default | Meaning |
|---|---|---|
| `HEGEMON_STARTUP_TIMEOUT` | 1800 | seconds to wait for RPC after launch |
| `HEGEMON_STOP_TIMEOUT` | 300 | seconds to wait for a clean SIGTERM shutdown before SIGKILL |
| `HEGEMON_MIN_FREE_MB` | 2048 | warn below this much free disk space |

**`balance` sits on "Syncing wallet…" for a long time.**
This is normal for the first scan. The wallet downloads every commitment and
encrypted note on the chain (~1 per block, ~123k on the testnet). It tries to
decrypt each one with your key and rebuilds the commitment tree. It uses one CPU
core at ~100%, and the cost grows with the chain size:
- measured here: 4.7k commitments in 11 s, 11k in 30 s
- so a full testnet scan takes **roughly 30-90+ minutes** on a small VPS

`balance` now shows elapsed time and walletd CPU so you can see it's working.
Ctrl+C is safe: progress is saved after each page and the next run resumes.
Later syncs only fetch new blocks, but they still rebuild the tree. That's
about 20-40 s on a small chain and longer on the full testnet. Use
`bash hegemon.sh balance-cached` for an instant (possibly stale) balance.
Mining does not need the wallet to be synced; rewards are found on the next sync.

## Important notes (from upstream docs)

- **Back up** the wallet store file **and** your passphrase. walletd emits **no mnemonic**.
- **Time sync is required.** Blocks more than 90 s in the future are rejected.
  The script warns if NTP is off (`sudo timedatectl set-ntp true`).
- **v0.10.2+ is mandatory.** The difficulty correction activates at block 120,000,
  and older binaries fork off the chain. The script refuses older tags.
- Open TCP **30333** inbound if you want to be a reachable peer.
- `Connection refused` for `devnet.hegemonprotocol.com` is expected. Upstream says
  that seed is reserved for development.
- A failed wallet sync does **not** mean a zero balance. Don't `--force-rescan` as a routine fix.
- This is alpha / testnet software. The proof backend is still under external review.

Supported platforms: Linux x86_64 and macOS (Intel / Apple Silicon) use prebuilt
binaries. Linux arm64 falls back to a source build automatically.
