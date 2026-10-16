#!/usr/bin/env python3
"""Apply the remote-mining patch to a Hegemon v0.10.3 source checkout.

Usage: python3 apply_patch.py /path/to/Hegemon   (checked out at tag v0.10.3)

Changes (additive; consensus rules untouched):
  * node_impl.rs: prepare_work_for(addr) / *_coinbase_action_for(addr) so a
    block template can pay any shielded address (local mining unchanged).
  * remote_mining.rs (new): token-protected JSON-RPC listener
    (mining_getWork / mining_submit / mining_stats) for hegemon-cpuminer.
  * mod.rs: register module.  service.rs: start the listener at boot.
Idempotent: re-running on an already patched tree is a no-op.
"""
import os
import shutil
import sys

root = sys.argv[1] if len(sys.argv) > 1 else "."
nat = os.path.join(root, "node", "src", "native")
here = os.path.dirname(os.path.abspath(__file__))


def read(name):
    with open(os.path.join(nat, name)) as f:
        return f.read()


def write(name, text):
    with open(os.path.join(nat, name), "w") as f:
        f.write(text)


def replace_once(text, old, new, what):
    if text.count(old) != 1:
        sys.exit(f"patch failed: anchor for {what} not found exactly once (is this v0.10.3?)")
    return text.replace(old, new)


# ---------------------------------------------------------------- node_impl.rs
s = read("node_impl.rs")
if "fn auto_coinbase_action_for(" not in s:
    s = replace_once(s, '''    pub(crate) fn append_auto_coinbase_action(
        &self,
        height: u64,
        actions: &mut Vec<PendingAction>,
        received_ms: u64,
    ) -> Result<Option<PendingAction>> {
        let Some(action) = self.auto_coinbase_action(height, actions, received_ms)? else {
            return Ok(None);
        };
        actions.push(action.clone());
        Ok(Some(action))
    }

    pub(crate) fn auto_coinbase_action(
        &self,
        height: u64,
        actions: &[PendingAction],
        received_ms: u64,
    ) -> Result<Option<PendingAction>> {
        let Some(miner_address) = self.config.miner_address.as_deref() else {
            return Ok(None);
        };''', '''    #[allow(dead_code)]
    pub(crate) fn append_auto_coinbase_action(
        &self,
        height: u64,
        actions: &mut Vec<PendingAction>,
        received_ms: u64,
    ) -> Result<Option<PendingAction>> {
        self.append_auto_coinbase_action_for(
            self.config.miner_address.as_deref(),
            height,
            actions,
            received_ms,
        )
    }

    pub(crate) fn append_auto_coinbase_action_for(
        &self,
        miner_address: Option<&str>,
        height: u64,
        actions: &mut Vec<PendingAction>,
        received_ms: u64,
    ) -> Result<Option<PendingAction>> {
        let Some(action) =
            self.auto_coinbase_action_for(miner_address, height, actions, received_ms)?
        else {
            return Ok(None);
        };
        actions.push(action.clone());
        Ok(Some(action))
    }

    #[allow(dead_code)]
    pub(crate) fn auto_coinbase_action(
        &self,
        height: u64,
        actions: &[PendingAction],
        received_ms: u64,
    ) -> Result<Option<PendingAction>> {
        self.auto_coinbase_action_for(
            self.config.miner_address.as_deref(),
            height,
            actions,
            received_ms,
        )
    }

    pub(crate) fn auto_coinbase_action_for(
        &self,
        miner_address: Option<&str>,
        height: u64,
        actions: &[PendingAction],
        received_ms: u64,
    ) -> Result<Option<PendingAction>> {
        let Some(miner_address) = miner_address else {
            return Ok(None);
        };''', "coinbase helpers")

if "fn prepare_work_for(" not in s:
    s = replace_once(s, '''    pub(crate) fn prepare_work(&self) -> Result<NativeWork> {
        let state = self.state.read();
        let best = &state.best;
        if !self.block_tree.contains_key(best.hash.as_slice())? {
            return Err(anyhow!("missing native block {}", hex32(&best.hash)));
        }
        let mut pending_actions = select_mineable_actions(&state);
        if self.config.miner_address.is_some() {''', '''    pub(crate) fn prepare_work(&self) -> Result<NativeWork> {
        self.prepare_work_for(self.config.miner_address.as_deref())
    }

    /// Build a block template whose coinbase pays `coinbase_address`
    /// (local miner: HEGEMON_MINER_ADDRESS; remote miner: worker address).
    pub(crate) fn prepare_work_for(&self, coinbase_address: Option<&str>) -> Result<NativeWork> {
        let state = self.state.read();
        let best = &state.best;
        if !self.block_tree.contains_key(best.hash.as_slice())? {
            return Err(anyhow!("missing native block {}", hex32(&best.hash)));
        }
        let mut pending_actions = select_mineable_actions(&state);
        if coinbase_address.is_some() {''', "prepare_work")
    a = s.index("pub(crate) fn prepare_work_for(")
    b = s.index("pub(crate) fn import_mined_block(")
    body = s[a:b]
    if body.count("self.append_auto_coinbase_action(") != 3:
        sys.exit("patch failed: expected 3 coinbase calls in prepare_work")
    body = body.replace("self.append_auto_coinbase_action(",
                        "self.append_auto_coinbase_action_for(coinbase_address, ")
    s = s[:a] + body + s[b:]
write("node_impl.rs", s)

# ---------------------------------------------------------- mod.rs / service.rs
s = read("mod.rs")
if "mod remote_mining;" not in s:
    s = replace_once(s, "mod pow;\n", "mod pow;\nmod remote_mining;\n", "mod list")
    write("mod.rs", s)

s = read("service.rs")
if "remote_mining::start_remote_mining" not in s:
    s = replace_once(s, "    let listener = TcpListener::bind(config.rpc_addr)",
                     "    remote_mining::start_remote_mining(Arc::clone(&node)).await?;\n\n"
                     "    let listener = TcpListener::bind(config.rpc_addr)", "rpc bind")
    write("service.rs", s)

shutil.copy(os.path.join(here, "remote_mining.rs"), os.path.join(nat, "remote_mining.rs"))
print("remote-mining patch applied to", os.path.abspath(root))
