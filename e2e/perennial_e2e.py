#!/usr/bin/env python3
"""
LOCAL END-TO-END REHEARSAL of Perennial — contracts, keeper, and UI together.

    python3 contracts/e2e/perennial_e2e.py          (needs anvil, forge, cast, node)

What it proves, on a throwaway anvil chain (31337) with anvil's public dev keys:
  1. The REAL deploy scripts run in the forced mainnet order — DeployOracle ->
     DeployNanoLedger -> DeployPerennial -> DeployArbiter -> DeployNanoStack ->
     Handoff -> VerifyRoles — and afterwards the deployer holds no power at all.
  2. The oracle allowlist refuses a self-made oracle at createMarket.
  3. Three markets on one builder's milestone feed, driven through the UI's own
     code path (frontend/scripts/e2e-perennial.ts) and settled by the keeper's own
     code (keeper/settle.py):
        m1  YES   the builder ships; keeper attests in the window; keeper resolves
        m3  NO    opened after, threshold = count + 1; the count does not move
        m2  VOID  keeper offline for its whole window; a trader voids it
     Every buy/sell must fill exactly at the UI's quote, every redeem must pay
     exactly the UI's preview.
  4. The fees flow to the builder: arbiter proposal -> finalize -> closeEpoch ->
     claim -> stream -> the builder withdraws USDC.
  5. Accounting closes: markets and escrow drain to dust, nothing is stuck.

Nothing here touches a real network: every step refuses a chain id other than 31337.
"""
import json, os, re, shutil, socket, subprocess, sys, time, pathlib

HERE = pathlib.Path(__file__).resolve().parent
CONTRACTS = HERE.parent
ARC = CONTRACTS.parent
FRONTEND = ARC / "frontend"
sys.path.insert(0, str(ARC / "keeper"))
from settle import CastChain, tick  # noqa: E402  the keeper's real settlement loop

USDC = "0x3600000000000000000000000000000000000000"
KEYS = {  # anvil's well-known dev keys — worthless anywhere but a local anvil
    "deployer": "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
    "operator": "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
    "resolver": "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
    "admin":    "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
    "builder":  "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
    "alice":    "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba",
    "bob":      "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e",
    "attacker": "0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356",
    "arbres":   "0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97",
    "treasury": "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6",
}
FEED_WINDOW = 3600          # the caretaker's default feed challenge window
SETTLEMENT_WINDOW = 3600
RESOLUTION_GRACE = 86400
ARB_CHALLENGE = 600
EPOCH_LENGTH = 7200
STREAM_WINDOW = 3600
U = 10**6

PASS, FAIL = [], []


def check(cond, what, detail=""):
    (PASS if cond else FAIL).append(what)
    print(("  ok   " if cond else "  FAIL ") + what + ("" if cond or not detail else f"  <- {detail}"))
    if not cond:
        raise SystemExit(f"\nFAILED: {what}\n{detail}")


def run(cmd, env=None, cwd=None, ok=True):
    r = subprocess.run(cmd, capture_output=True, text=True, env={**os.environ, **(env or {})}, cwd=cwd)
    if ok and r.returncode != 0:
        raise SystemExit(f"command failed: {' '.join(map(str, cmd))[:300]}\n{r.stdout[-2500:]}\n{r.stderr[-2500:]}")
    return r


class Chain:
    def __init__(self):
        s = socket.socket(); s.bind(("127.0.0.1", 0)); self.port = s.getsockname()[1]; s.close()
        self.rpc = f"http://127.0.0.1:{self.port}"
        self.proc = subprocess.Popen(["anvil", "--port", str(self.port), "--silent"])
        for _ in range(50):
            if run(["cast", "chain-id", "--rpc-url", self.rpc], ok=False).stdout.strip() == "31337":
                break
            time.sleep(0.2)
        assert self.chain_id() == 31337

    def chain_id(self):
        return int(run(["cast", "chain-id", "--rpc-url", self.rpc]).stdout.strip())

    def addr(self, who):
        return run(["cast", "wallet", "address", "--private-key", KEYS[who]]).stdout.strip()

    def call(self, to, sig, *args):
        return run(["cast", "call", to, sig, *map(str, args), "--rpc-url", self.rpc]).stdout.strip()

    def uint(self, to, sig, *args):
        return int(self.call(to, sig, *args).split()[0])

    def send(self, who, to, sig, *args, ok=True):
        return run(["cast", "send", to, sig, *map(str, args), "--rpc-url", self.rpc,
                    "--private-key", KEYS[who], "--json"], ok=ok)

    def fails_with(self, who, to, sig, *args):
        """Simulate as `who`; return the revert text (empty when it would succeed)."""
        r = run(["cast", "call", to, sig, *map(str, args), "--rpc-url", self.rpc,
                 "--from", self.addr(who)], ok=False)
        return "" if r.returncode == 0 else (r.stderr + r.stdout)

    def now(self):
        return int(run(["cast", "block", "latest", "--field", "timestamp", "--rpc-url", self.rpc]).stdout.strip())

    def warp_to(self, ts):
        run(["cast", "rpc", "evm_setNextBlockTimestamp", str(ts), "--rpc-url", self.rpc])
        run(["cast", "rpc", "evm_mine", "--rpc-url", self.rpc])

    def close(self):
        self.proc.terminate(); self.proc.wait()


def main():
    for tool in ("anvil", "forge", "cast", "node", "npx"):
        if not shutil.which(tool):
            raise SystemExit(f"missing tool: {tool}")
    c = Chain()
    A = {k: c.addr(k) for k in KEYS}
    try:
        rehearse(c, A)
    finally:
        c.close()
    print(f"\n{len(PASS)} checks passed, {len(FAIL)} failed")


def forge_script(c, name, env):
    r = run(["forge", "script", f"script/{name}.s.sol:{name}", "--rpc-url", c.rpc, "--broadcast",
             "--private-key", KEYS["deployer"], "-vv"], env=env, cwd=CONTRACTS)
    return r.stdout


def grab(log, label):
    m = re.search(rf"{re.escape(label)}\s*:?\s*(0x[0-9a-fA-F]{{40}})", log)
    if not m:
        raise SystemExit(f"no address for '{label}' in script output:\n{log[-3000:]}")
    return m.group(1)


def rehearse(c, A):
    print("== 0. local chain + USDC at Arc's canonical address")
    run(["forge", "build"], cwd=CONTRACTS)
    art = CONTRACTS / "out" / "test" / "MockUSDC.sol" / "MockUSDC.json"   # several tests define a MockUSDC; take test/MockUSDC.sol
    code = json.loads(art.read_text())["deployedBytecode"]["object"]
    run(["cast", "rpc", "anvil_setCode", USDC, code, "--rpc-url", c.rpc])
    for who in ("operator", "resolver", "builder", "alice", "bob", "attacker"):
        c.send("deployer", USDC, "mint(address,uint256)", A[who], 1_000 * U)
    check(c.uint(USDC, "balanceOf(address)(uint256)", A["alice"]) == 1_000 * U, "USDC live at 0x3600 on the local chain")

    print("== 1. real deploy scripts, forced mainnet order")
    common = {"USDC": USDC, "SETTLEMENT_WINDOW": str(SETTLEMENT_WINDOW), "RESOLUTION_GRACE": str(RESOLUTION_GRACE),
              "APPROVED_AGENT": A["operator"], "DISPUTE_RESOLVER": A["resolver"]}
    log = forge_script(c, "DeployOracle", {**common, "MIN_BOND": str(10 * U), "POINTS": "0x0000000000000000000000000000000000000000"})
    S = {"Registry": grab(log, "Registry"), "Attestation": grab(log, "Attestation"), "Dispute": grab(log, "Dispute")}
    log = forge_script(c, "DeployNanoLedger", common)
    S["NanoLedger"] = grab(log, "NanoLedger")
    log = forge_script(c, "DeployPerennial", {**common, "REGISTRY": S["Registry"], "ATTESTATION": S["Attestation"],
                       "NANO_LEDGER": S["NanoLedger"], "EPOCH_LENGTH": str(EPOCH_LENGTH), "STREAM_WINDOW": str(STREAM_WINDOW)})
    for k in ("BuilderRegistry", "CaretakerRegistry", "ProgressPool", "MarketsPerennial"):
        S[k] = grab(log, k)
    log = forge_script(c, "DeployArbiter", {**common, "NANO_LEDGER": S["NanoLedger"], "PROGRESS_POOL": S["ProgressPool"],
                       "BUILDER_REGISTRY": S["BuilderRegistry"], "CARETAKER_REGISTRY": S["CaretakerRegistry"],
                       "PROPOSER": A["operator"], "RESOLVER": A["arbres"], "CHALLENGE_WINDOW": str(ARB_CHALLENGE),
                       "STAKE_PER_PROPOSAL": str(50 * U), "MAX_WEIGHT_PER_PROPOSAL": "10", "RESOLVE_TIMEOUT": str(RESOLUTION_GRACE)})
    S["ProgressArbiter"] = grab(log, "ProgressArbiter")
    log = forge_script(c, "DeployNanoStack", {**common, "REGISTRY": S["Registry"], "ATTESTATION": S["Attestation"],
                       "NANO_LEDGER": S["NanoLedger"], "FORFEIT_SINK": S["ProgressPool"], "TREASURY": A["treasury"]})
    S["MarketsV4"] = grab(log, "MarketsV4")
    stack = {"ADMIN": A["admin"], "REGISTRY": S["Registry"], "ATTESTATION": S["Attestation"], "NANO_LEDGER": S["NanoLedger"],
             "BUILDER_REGISTRY": S["BuilderRegistry"], "CARETAKER_REGISTRY": S["CaretakerRegistry"],
             "PROGRESS_POOL": S["ProgressPool"], "MARKETS_PERENNIAL": S["MarketsPerennial"],
             "MARKETS_V4": S["MarketsV4"], "PROGRESS_ARBITER": S["ProgressArbiter"]}
    forge_script(c, "Handoff", stack)
    forge_script(c, "VerifyRoles", {**stack, "DEPLOYER": A["deployer"]})
    check(True, "DeployOracle -> NanoLedger -> Perennial -> Arbiter -> NanoStack -> Handoff -> VerifyRoles all succeeded")

    gov = c.call(S["ProgressPool"], "GOVERNOR_ROLE()(bytes32)")
    prog = c.call(S["ProgressPool"], "PROGRESS_ROLE()(bytes32)")
    admin_role = "0x" + "00" * 32
    check("AccessControl" in c.fails_with("deployer", S["ProgressPool"], "grantRole(bytes32,address)", prog, A["deployer"])
          or c.fails_with("deployer", S["ProgressPool"], "grantRole(bytes32,address)", prog, A["deployer"]) != "",
          "deployer can no longer grant itself PROGRESS_ROLE (B2 closed)")
    check(c.fails_with("deployer", S["MarketsPerennial"], "setForfeitSink(address)", A["deployer"]) != "",
          "deployer can no longer redirect fee flows")
    check(c.call(S["ProgressPool"], "hasRole(bytes32,address)(bool)", admin_role, A["admin"]) == "true"
          and c.call(S["MarketsPerennial"], "hasRole(bytes32,address)(bool)", gov, A["admin"]) == "true",
          "ADMIN (multisig stand-in) holds the admin roles")

    print("== 2. onboarding (post-handoff: every privileged step is ADMIN's)")
    c.send("builder", S["BuilderRegistry"], "registerBuilder(string)", "github.com/example/shipper")
    bid = c.uint(S["BuilderRegistry"], "builderIdOf(address)(uint256)", A["builder"])
    c.send("admin", S["CaretakerRegistry"], "setCaretaker(uint256,address)", bid, A["operator"])
    check(bid > 0 and c.call(S["CaretakerRegistry"], "isCaretaker(uint256,address)(bool)", bid, A["operator"]) == "true",
          f"builder #{bid} registered, operator is its caretaker")

    # The caretaker's own feed-provisioning parameters (independent resolver, bond from the Registry).
    os.environ.update({k: "0x0" for k in ("RPC", "PRIVATE_KEY", "PROGRESS_POOL", "MARKETS_PERENNIAL", "NANO_LEDGER",
                                           "CARETAKER_REGISTRY", "BUILDER_REGISTRY", "PROGRESS_ARBITER", "REGISTRY", "ATTESTATION")})
    import caretaker
    fp, why = caretaker.feed_params(A["operator"], A["resolver"], c.call(S["Registry"], "MIN_BOND()(uint256)"), FEED_WINDOW)
    check(fp is not None, "caretaker.feed_params accepts an independent resolver", why)
    check(caretaker.feed_params(A["operator"], A["operator"], "10000000")[0] is None, "caretaker refuses to make itself resolver")
    meth = run(["cast", "keccak", "example/shipper-ships-release"]).stdout.strip()
    c.send("operator", USDC, "approve(address,uint256)", S["Registry"], 2 * fp["bond"])
    r = json.loads(c.send("operator", S["Registry"], "createFeed(string,bytes32,uint256,uint256,address)",
                          "example/shipper-ships-release", meth, fp["bond"], fp["window"], fp["resolver"]).stdout)
    feed = next(l["topics"][1] for l in r["logs"] if l["address"].lower() == S["Registry"].lower())
    c.send("operator", S["Registry"], "registerAgent(bytes32,bytes32,uint256)", feed, meth, fp["bond"])
    check(c.call(S["MarketsPerennial"], "isApprovedFeed(bytes32,address)(bool)", feed, A["operator"]) == "true",
          "milestone feed provisioned and passes the oracle allowlist")

    print("== 3. B1: a self-made oracle cannot open a market")
    c.send("attacker", USDC, "approve(address,uint256)", S["Registry"], 20 * U)
    r = json.loads(c.send("attacker", S["Registry"], "createFeed(string,bytes32,uint256,uint256,address)",
                          "rigged", meth, 10 * U, FEED_WINDOW, A["attacker"]).stdout)
    rigged = next(l["topics"][1] for l in r["logs"] if l["address"].lower() == S["Registry"].lower())
    c.send("attacker", S["Registry"], "registerAgent(bytes32,bytes32,uint256)", rigged, meth, 10 * U)
    err = c.fails_with("attacker", S["MarketsPerennial"], "createMarket(uint256,bytes32,address,int256,uint8,uint256,uint256)",
                       bid, rigged, A["attacker"], 1, 1, c.now() + 7200, 5 * U)
    check(err != "" and ("AgentNotApproved" in err or "0x" in err), "createMarket on an attacker-resolved feed reverts", err[-200:])

    # ── UI driver ──
    contracts_ui = {k: S[k] for k in ("NanoLedger", "BuilderRegistry", "ProgressPool", "MarketsPerennial", "CaretakerRegistry")}
    contracts_ui["USDC"] = USDC

    def ui(action, who=None, **kw):
        payload = {"rpc": c.rpc, "contracts": contracts_ui, "operator": A["operator"], "action": action, **kw}
        if who:
            payload["key"] = KEYS[who]
        r = run(["npx", "--yes", "tsx", "scripts/e2e-perennial.ts", json.dumps(payload)], cwd=FRONTEND, ok=False)
        line = (r.stdout.strip().splitlines() or ["{}"])[-1]
        try:
            res = json.loads(line)
        except json.JSONDecodeError:
            raise SystemExit(f"ui {action} printed no JSON:\n{r.stdout[-1500:]}\n{r.stderr[-1500:]}")
        if not res.get("ok"):
            raise SystemExit(f"ui {action} failed: {res}")
        return res

    keeper = CastChain(c.rpc, S["MarketsPerennial"], S["Attestation"], KEYS["operator"])
    count = {"v": 0}
    providers = {feed.lower(): lambda now: (count["v"], f"releases:{count['v']}")}
    kstate = {}

    def keeper_tick():
        return tick(keeper, A["operator"], providers, kstate, SETTLEMENT_WINDOW)

    print("== 4. m1 (YES): create via the UI path, trade, the builder ships, keeper settles")
    for who in ("alice", "bob"):
        ui("deposit", who, amount=str(300 * U))
    m1 = ui("create", "alice", builderId=bid, feedId=feed, expiryIn=7200, liquidity=str(10 * U))
    check(m1["threshold"] == "1" and m1["latest"] is None, "create form: threshold = latest count (none) + 1 = 1", m1)
    M1 = m1["marketId"]
    b1 = ui("buy", "bob", marketId=M1, side="Yes", amount=str(20 * U))
    check(b1["quoteMatched"], f"bob buys YES 20 USDC -> {int(b1['sharesOut'])/U:.4f} shares, exactly the UI quote")
    b2 = ui("buy", "alice", marketId=M1, side="No", amount=str(5 * U))
    check(b2["quoteMatched"], "alice buys NO 5 USDC at exactly the UI quote")
    s1 = ui("sell", "bob", marketId=M1, side="Yes", shares=str(int(b1["sharesOut"]) // 4))
    check(s1["quoteMatched"], "bob sells a quarter of his YES at exactly the UI sell quote")
    check(ui("status", marketId=M1)["status"] == "trading", "UI status: trading")
    r = keeper_tick()
    check(r["actions"] == [], "keeper: nothing to do while trading", r)

    exp1 = int(m1["expiry"])
    c.warp_to(exp1 + 5)
    check(ui("status", marketId=M1)["status"] == "waiting", "after expiry, before any attestation: UI says waiting")
    err = c.fails_with("bob", S["MarketsPerennial"], "buy(bytes32,uint8,uint256,uint256)", M1, 0, U, 0)
    check(err != "", "no last look: buying after expiry reverts")
    count["v"] = 1                                   # the builder shipped a release
    r = keeper_tick()
    check([a[0] for a in r["actions"]] == ["attest"], "keeper attests inside the settlement window", r)

    print("== 5. m2 (VOID) and m3 (NO) open after the attestation: threshold = 1 + 1")
    m3 = ui("create", "bob", builderId=bid, feedId=feed, expiryIn=7200, liquidity=str(10 * U))
    m2 = ui("create", "alice", builderId=bid, feedId=feed, expiryIn=7200 + 3 * 3600, liquidity=str(10 * U))
    check(m3["threshold"] == "2" and m2["threshold"] == "2", "threshold follows the attested count (count + 1 = 2)")
    M2, M3 = m2["marketId"], m3["marketId"]
    for m, who, side, amt in ((M3, "alice", "Yes", 15), (M3, "bob", "No", 6), (M2, "bob", "Yes", 12), (M2, "alice", "No", 8)):
        check(ui("buy", who, marketId=m, side=side, amount=str(amt * U))["quoteMatched"], f"{who} buys {side} {amt} on {m[:8]} at the UI quote")

    c.warp_to(c.now() + FEED_WINDOW + 60)            # m1's attestation leaves its dispute window
    check(ui("status", marketId=M1)["status"] == "resolvable", "UI status: resolvable once the attestation is final")
    r = keeper_tick()
    check(("resolve", M1.lower()) in [(a[0], a[1].lower()) for a in r["actions"]], "keeper resolves m1", r)
    st = ui("status", marketId=M1)
    check(st["status"] == "resolved-yes" and st["yesWon"], "m1 resolved YES (count 1 >= 1)")

    c.warp_to(int(m3["expiry"]) + 5)
    r = keeper_tick()                                # count still 1: the builder did not ship again
    check("attest" in [a[0] for a in r["actions"]], "keeper attests the unchanged count for m3's window", r)
    c.warp_to(c.now() + FEED_WINDOW + 60)
    r = keeper_tick()
    check(("resolve", M3.lower()) in [(a[0], a[1].lower()) for a in r["actions"]], "keeper resolves m3", r)
    st = ui("status", marketId=M3)
    check(st["status"] == "resolved-no" and not st["yesWon"], "m3 resolved NO (count 1 < 2)")

    # m2: the keeper is offline for m2's entire window (no ticks) -> voidable
    c.warp_to(int(m2["expiry"]) + SETTLEMENT_WINDOW + 60)
    check(ui("status", marketId=M2)["status"] == "voidable", "UI status: voidable when nothing settled in the window")
    escrow2 = c.uint(S["MarketsPerennial"], "agentEscrow(bytes32)(uint256)", M2)
    sink_before = c.uint(S["NanoLedger"], "balanceOf(address)(uint256)", S["ProgressPool"])
    ui("voidMarket", "bob", marketId=M2)
    check(ui("status", marketId=M2)["status"] == "voided", "a trader voids m2 through the UI path")
    check(c.uint(S["NanoLedger"], "balanceOf(address)(uint256)", S["ProgressPool"]) - sink_before == escrow2 and escrow2 > 0,
          f"m2's escrowed agent fee ({escrow2/U:.4f}) forfeited to the commons")
    r = keeper_tick()
    check(r["actions"] == [], "keeper: idempotent afterwards", r)

    print("== 6. everyone collects exactly the UI's preview")
    for m in (M1, M2, M3):
        for who in ("alice", "bob"):
            y = c.uint(S["MarketsPerennial"], "yesBalance(bytes32,address)(uint256)", m, A[who])
            n = c.uint(S["MarketsPerennial"], "noBalance(bytes32,address)(uint256)", m, A[who])
            st = ui("status", marketId=m)
            # the UI's redeemPayout rule: winners' shares on resolve, (yes+no)/2 on void
            preview = (y + n) // 2 if st["phase"] == 2 else (y if st["yesWon"] else n)
            if preview == 0:
                # the panel disables the button ("nothing to redeem"); the contract agrees
                if y or n:
                    check(c.fails_with(who, S["MarketsPerennial"], "redeem(bytes32)", m) != "",
                          f"{who} holds only losing shares on {m[:8]}: UI offers nothing, contract refuses")
                continue
            res = ui("redeem", who, marketId=m)
            check(res["previewMatched"], f"{who} redeems {m[:8]}: {int(res['payout'])/U:.4f} USDC = UI preview")
    for m, who in ((M1, "alice"), (M3, "bob"), (M2, "alice")):
        res = ui("claimLP", who, marketId=m)
        check(int(res["payout"]) > 0, f"creator {who} claims LP on {m[:8]}: {int(res['payout'])/U:.4f} USDC")
    for m in (M1, M2, M3):
        check(c.uint(S["MarketsPerennial"], "agentEscrow(bytes32)(uint256)", m) == 0, f"escrow of {m[:8]} is empty")
    dust = c.uint(S["NanoLedger"], "balanceOf(address)(uint256)", S["MarketsPerennial"])
    check(dust <= 10, f"MarketsPerennial holds only dust after every exit ({dust} units)")
    agent_paid = c.uint(S["NanoLedger"], "balanceOf(address)(uint256)", A["operator"])
    check(agent_paid > 0, f"agent earned its released fee for m1 and m3 ({agent_paid/U:.4f} USDC in the ledger)")

    print("== 7. the fees reach the builder: arbiter -> epoch -> stream -> withdraw")
    pot_before = c.uint(S["NanoLedger"], "balanceOf(address)(uint256)", S["ProgressPool"])
    check(pot_before > 0, f"commons holds {pot_before/U:.4f} USDC of trading fees + forfeits")
    c.send("operator", USDC, "approve(address,uint256)", S["NanoLedger"], 60 * U)
    c.send("operator", S["NanoLedger"], "deposit(uint256)", 60 * U)
    c.send("operator", S["NanoLedger"], "approveSpender(address,uint256)", S["ProgressArbiter"], 50 * U)
    c.send("operator", S["ProgressArbiter"], "depositBond(uint256)", 50 * U)
    c.send("operator", S["ProgressArbiter"], "propose(address,uint256)", A["builder"], 5)
    err = c.fails_with("alice", S["ProgressArbiter"], "finalize(uint256)", 0)
    check(err != "", "a proposal cannot finalize inside its challenge window")
    c.warp_to(c.now() + ARB_CHALLENGE + 5)
    c.send("alice", S["ProgressArbiter"], "finalize(uint256)", 0)      # permissionless crank
    epoch = c.uint(S["ProgressPool"], "currentEpoch()(uint256)")
    check(c.uint(S["ProgressPool"], "progressWeight(uint256,address)(uint256)", epoch, A["builder"]) == 5,
          "finalized progress credited to the builder for this epoch")
    c.warp_to(c.now() + EPOCH_LENGTH + 5)
    c.send("alice", S["ProgressPool"], "closeEpoch()")
    claimable = c.uint(S["ProgressPool"], "claimable(uint256,address)(uint256)", epoch, A["builder"])
    check(claimable == pot_before, f"sole builder's claimable = the whole pot ({claimable/U:.4f} USDC)")
    r = json.loads(c.send("builder", S["ProgressPool"], "claim(uint256)", epoch).stdout)
    sid = c.uint(S["ProgressPool"], "streamIdOf(uint256,address)(uint256)", epoch, A["builder"])
    c.warp_to(c.now() + STREAM_WINDOW + 120)
    c.send("alice", S["NanoLedger"], "settleStream(uint256)", sid)
    got = c.uint(S["NanoLedger"], "balanceOf(address)(uint256)", A["builder"])
    check(abs(got - claimable) <= STREAM_WINDOW, f"stream vested to the builder: {got/U:.4f} of {claimable/U:.4f} USDC")
    usdc_before = c.uint(USDC, "balanceOf(address)(uint256)", A["builder"])
    c.send("builder", S["NanoLedger"], "withdraw(uint256)", got)
    check(c.uint(USDC, "balanceOf(address)(uint256)", A["builder"]) - usdc_before == got, "builder withdrew real USDC")

    print("== 8. accounting")
    # every USDC unit minted is somewhere accountable: wallets + ledger (which backs all internal balances)
    minted = 6 * 1_000 * U
    wallets = sum(c.uint(USDC, "balanceOf(address)(uint256)", A[w]) for w in KEYS)
    ledger_held = c.uint(USDC, "balanceOf(address)(uint256)", S["NanoLedger"])
    registry_held = c.uint(USDC, "balanceOf(address)(uint256)", S["Registry"])
    check(wallets + ledger_held + registry_held == minted,
          f"USDC conserved: wallets {wallets/U:.2f} + ledger {ledger_held/U:.2f} + bonds {registry_held/U:.2f} = {minted/U:.0f}")
    total_owed = c.uint(S["NanoLedger"], "totalOwed()(uint256)")
    check(ledger_held >= total_owed, f"ledger solvent: holds {ledger_held} >= owes {total_owed}")


if __name__ == "__main__":
    main()
