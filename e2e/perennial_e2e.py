#!/usr/bin/env python3
"""
LOCAL END-TO-END REHEARSAL of Perennial — contracts, keeper, and UI together.

    python3 contracts/e2e/perennial_e2e.py          (needs anvil, forge, cast, node)

What it proves, on a throwaway anvil chain (31337) with anvil's public dev keys:
  1. The REAL deploy scripts run in the forced mainnet order. Phase 1: DeployBuilders
     (registries + badge, with an ONBOARDER hot wallet) and the phase-1 keeper runs with
     no market on chain. Phase 2: DeployOracle -> DeployNanoLedger -> DeployPerennial
     (reusing the phase-1 registries: SeasonPool + BuilderFund + MarketsPerennial) ->
     DeployNanoStack -> Handoff -> VerifyRoles (with the ONBOARDER) — and afterwards the
     deployer holds no power at all.
  2. The oracle allowlist refuses a self-made oracle at createMarket.
  3. Markets on one builder's milestone feed, driven through the UI's own code path
     (frontend/scripts/e2e-perennial.ts) and settled by the keeper's own code:
        m1  YES   the builder ships; keeper attests in the window; keeper resolves
        m3  NO    opened after, threshold = count + 1; the count does not move
        m2  VOID  keeper offline for its whole window; a trader voids it -> the
                  agent's held 20% goes to the SeasonPool
        m4  VOID  our agent answers wrong, a watcher proves it and is paid the 20%
     Every buy/sell fills exactly at the UI's quote, every redeem pays exactly the UI's
     preview, every trade's 1% splits 30/20/50 and the 50% is credited as income of the
     builder the market is about.
  4. Builder income: after the epoch ends the keeper's income crank (keeper/income.py
     inside caretaker.py) pays gross - progressive tax - 1% fee to payoutOf, the tax to
     the SeasonPool (a high-volume builder crosses the first bracket), and a deactivated
     builder's income is frozen until the Safe sweeps it to the SeasonPool.
  5. Verified builders: one builder with two projects (github + domain), each with its
     own signed proof; the onboarding batch (per builder) sent by the onboarder; the
     badge; per-project milestone feeds and counts; one proof removed (project lapsed,
     builder verified), all removed (badge lapsed), restored.
  6. Owner transfer (proposeOwner/acceptOwnership) and a recovery (startRecovery ->
     7 days -> finishRecovery): proofs re-signed, the badge follows the owner (same
     serial), payouts follow the owner, income earned before the recovery is paid to
     the recovered owner.
  7. A season: the SeasonPool funded by real taxes + a void escrow + a frozen sweep;
     season-rewards.ts over the window; the Safe file published as ADMIN; the builder
     claims with its proof (20% cap enforced, one claim only).
  8. Accounting closes: USDC conserved to the unit, ledger solvent, the fund's
     outstanding == unclaimed income, the pool covers unallocated + reserved.

Nothing here touches a real network: every step refuses a chain id other than 31337.
"""
import json, os, re, shutil, socket, subprocess, sys, time, pathlib, base64
import tempfile as tempfile_mod
import threading, http.server, functools, datetime

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
# more dev accounts from anvil's public test mnemonic
EXTRA = (("builder2", 10), ("watcher", 11), ("vbuilder", 12), ("vdeployer", 13), ("stranger", 14), ("onboarder", 15),
         ("whale", 16), ("vpayout", 17), ("vowner2", 18), ("vrecovered", 19), ("rounds", 20),
         ("session", 21))
FEED_WINDOW = 3600          # the caretaker's default feed challenge window
SETTLEMENT_WINDOW = 3600
RESOLUTION_GRACE = 86400
EPOCH_LENGTH = 86400        # BuilderFund epoch (mainnet: 30 days)
RECOVERY_DELAY = 7 * 86400
U = 10**6
MINTED = {"operator": 1_000, "resolver": 1_000, "builder": 1_000, "alice": 1_000, "bob": 1_000,
          "attacker": 1_000, "watcher": 1_000, "whale": 60_000, "rounds": 1_000}
FEE_BPS, CREATOR, AGENT = 100, 3000, 2000        # the landing page: 1% of every trade, 30 / 20 / 50
# lib/LaunchSchedule.sol: 0% to $1,000; 10% to $10,000; 20% to $50,000; 30% above (per builder per epoch)
LAUNCH_SCHEDULE = ((1_000 * U, 0), (10_000 * U, 1000), (50_000 * U, 2000), (2**128 - 1, 3000))
ZERO32 = "0x" + "00" * 32


def split(c):
    """The 1% trading fee on an amount c and its legs (exact contract rounding)."""
    fee = c * FEE_BPS // 10_000
    creator = fee * CREATOR // 10_000
    agent = fee * AGENT // 10_000
    return fee, creator, agent, fee - creator - agent


def progressive_tax(gross, brackets=LAUNCH_SCHEDULE):
    """BuilderFund.progressiveTax: marginal, floored per slice."""
    tax, lower = 0, 0
    for i, (up, rate) in enumerate(brackets):
        if gross <= lower:
            break
        upper = 2**256 if i == len(brackets) - 1 else up
        tax += (min(gross, upper) - lower) * rate // 10_000
        lower = upper
    return tax


def income_split(gross):
    """(tax, fee, net) of claimFor on `gross` under the launch schedule."""
    tax = progressive_tax(gross)
    fee = (gross - tax) * 100 // 10_000
    return tax, fee, gross - tax - fee


PASS, FAIL = [], []


def check(cond, what, detail=""):
    (PASS if cond else FAIL).append(what)
    print(("  ok   " if cond else "  FAIL ") + what + ("" if cond or not detail else f"  <- {detail}"), flush=True)
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
        self.proc = subprocess.Popen(["anvil", "--port", str(self.port), "--silent", "--accounts", "24"])
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

    def block(self):
        return int(run(["cast", "block-number", "--rpc-url", self.rpc]).stdout.strip())

    def warp_to(self, ts):
        run(["cast", "rpc", "evm_setNextBlockTimestamp", str(ts), "--rpc-url", self.rpc])
        run(["cast", "rpc", "evm_mine", "--rpc-url", self.rpc])

    def increase_time(self, secs):
        run(["cast", "rpc", "evm_increaseTime", str(secs), "--rpc-url", self.rpc])
        run(["cast", "rpc", "evm_mine", "--rpc-url", self.rpc])

    def close(self):
        self.proc.terminate(); self.proc.wait()


def selector(err_sig):
    return run(["cast", "sig", err_sig]).stdout.strip()


def reverted_with(text, name):
    """A revert text names custom error `name` (decoded or as its 4-byte selector)."""
    return bool(text) and (name in text or selector(f"{name}()")[2:] in text.lower())


def main():
    for tool in ("anvil", "forge", "cast", "node", "npx"):
        if not shutil.which(tool):
            raise SystemExit(f"missing tool: {tool}")
    c = Chain()
    mn = "test test test test test test test test test test test junk"
    for name, idx in EXTRA:
        KEYS[name] = run(["cast", "wallet", "private-key", "--mnemonic", mn, "--mnemonic-index", str(idx)]).stdout.strip()
    A = {k: c.addr(k) for k in KEYS}
    try:
        rehearse(c, A)
    finally:
        c.close()
    print(f"\n{len(PASS)} checks passed, {len(FAIL)} failed")


def forge_script(c, name, env):
    r = run(["forge", "script", f"script/{name}.s.sol:{name}", "--rpc-url", c.rpc, "--broadcast", "--slow",
             "--private-key", KEYS["deployer"], "-vv"], env=env, cwd=CONTRACTS)
    return r.stdout


def grab(log, label):
    m = re.search(rf"{re.escape(label)}\s*:?\s*(0x[0-9a-fA-F]{{40}})", log)
    if not m:
        raise SystemExit(f"no address for '{label}' in script output:\n{log[-3000:]}")
    return m.group(1)


def serve(d):
    """A throwaway static HTTP server over directory d (proof files, GitHub stand-ins)."""
    d.mkdir(parents=True, exist_ok=True)
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a, **k):
            pass
    h = functools.partial(Quiet, directory=str(d))
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), h)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, srv.server_address[1]


def rehearse(c, A):
    print("== 0. local chain + USDC at Arc's canonical address")
    run(["forge", "build"], cwd=CONTRACTS)
    # several tests define a MockUSDC; take test/MockUSDC.sol (forge nests the path only on a name clash)
    art = next(p for p in (CONTRACTS / "out" / "test" / "MockUSDC.sol" / "MockUSDC.json", CONTRACTS / "out" / "MockUSDC.sol" / "MockUSDC.json")
               if p.exists() and "test/MockUSDC.sol" in json.loads(p.read_text())["metadata"]["settings"]["compilationTarget"])
    code = json.loads(art.read_text())["deployedBytecode"]["object"]
    run(["cast", "rpc", "anvil_setCode", USDC, code, "--rpc-url", c.rpc])
    for who, amt in MINTED.items():
        c.send("deployer", USDC, "mint(address,uint256)", A[who], amt * U)
    check(c.uint(USDC, "balanceOf(address)(uint256)", A["alice"]) == 1_000 * U, "USDC live at 0x3600 on the local chain")

    print("== 1a. mainnet phase 1: builders before markets (registries + badge only)")
    log = forge_script(c, "DeployBuilders", {"ADMIN": A["admin"], "OPERATOR": A["operator"], "ONBOARDER": A["onboarder"], "BADGE_CHAIN_LABEL": "Local",
                       "BADGE_IMAGE_BASE": "https://registrai.cc/badge/local/"})
    S = {k: grab(log, k) for k in ("BuilderRegistry", "CaretakerRegistry", "VerifiedBuilderBadge")}
    code_of = lambda a: run(["cast", "code", a, "--rpc-url", c.rpc]).stdout.strip()
    check(all(code_of(a) not in ("", "0x") for a in S.values()), "phase 1 deploys exactly the builder side: registries + badge")
    role = lambda name: run(["cast", "keccak", name]).stdout.strip()
    has = lambda where, r, who: c.call(where, "hasRole(bytes32,address)(bool)", r, who) == "true"
    check(has(S["VerifiedBuilderBadge"], role("ISSUER_ROLE"), A["onboarder"]) and has(S["CaretakerRegistry"], role("GOVERNOR_ROLE"), A["onboarder"])
          and not has(S["BuilderRegistry"], role("REGISTRAR_ROLE"), A["onboarder"])
          and not has(S["VerifiedBuilderBadge"], role("REVOKER_ROLE"), A["onboarder"])
          and not any(has(S[k], ZERO32, A["onboarder"]) for k in ("BuilderRegistry", "CaretakerRegistry", "VerifiedBuilderBadge"))
          and not any(has(S[k], ZERO32, A["deployer"]) for k in ("BuilderRegistry", "CaretakerRegistry", "VerifiedBuilderBadge")),
          "the onboarder hot wallet holds only badge ISSUER + caretaker GOVERNOR (no REVOKER, no REGISTRAR); the deployer holds nothing")
    p1dir = pathlib.Path(tempfile_mod.mkdtemp(prefix="p1-keeper-"))
    r = run(["python3", "keeper/builders_keeper.py"], cwd=ARC, ok=False,
            env={"RPC": c.rpc, "PRIVATE_KEY": KEYS["operator"], "BUILDER_REGISTRY": S["BuilderRegistry"],
                 "CARETAKER_REGISTRY": S["CaretakerRegistry"], "VERIFIED_BADGE": S["VerifiedBuilderBadge"],
                 "CHAIN_ID": "31337", "BUILDERS_DATA_DIR": str(p1dir)})
    out = r.stdout + r.stderr
    check(r.returncode == 0 and "builders: 0 verified" in out and "lacks STATUS_ROLE" not in out,
          "the phase-1 keeper runs with no market, fund, pool, oracle or feed on chain", out[-800:])

    print("== 1. real deploy scripts, forced mainnet order (phase 2 reuses the phase-1 registries)")
    common = {"USDC": USDC, "SETTLEMENT_WINDOW": str(SETTLEMENT_WINDOW), "RESOLUTION_GRACE": str(RESOLUTION_GRACE),
              "APPROVED_AGENT": A["operator"], "DISPUTE_RESOLVER": A["resolver"]}
    log = forge_script(c, "DeployOracle", {**common, "MIN_BOND": str(10 * U), "POINTS": "0x0000000000000000000000000000000000000000"})
    S.update({"Registry": grab(log, "Registry"), "Attestation": grab(log, "Attestation"), "Dispute": grab(log, "Dispute")})
    log = forge_script(c, "DeployNanoLedger", common)
    S["NanoLedger"] = grab(log, "NanoLedger")
    log = forge_script(c, "DeployPerennial", {**common, "REGISTRY": S["Registry"], "ATTESTATION": S["Attestation"],
                       "NANO_LEDGER": S["NanoLedger"], "EPOCH_LENGTH": str(EPOCH_LENGTH),
                       "PROTOCOL_TREASURY": A["treasury"],
                       "BUILDER_REGISTRY": S["BuilderRegistry"], "CARETAKER_REGISTRY": S["CaretakerRegistry"],
                       # the phase-1 badge: a builder market needs its builder's badge live
                       "VERIFIED_BADGE": S["VerifiedBuilderBadge"], "OPERATOR": A["operator"], "ONBOARDER": A["onboarder"]})
    check(grab(log, "BuilderRegistry").lower() == S["BuilderRegistry"].lower()
          and grab(log, "CaretakerRegistry").lower() == S["CaretakerRegistry"].lower(),
          "DeployPerennial reuses the phase-1 registries (no second BuilderRegistry)")
    for k in ("SeasonPool", "BuilderFund", "MarketsPerennial", "WonderEscrow"):
        S[k] = grab(log, k)
    FUND, POOL, MP = S["BuilderFund"], S["SeasonPool"], S["MarketsPerennial"]
    check(c.call(MP, "FUND()(address)").lower() == FUND.lower() and c.call(FUND, "SEASON_POOL()(address)").lower() == POOL.lower()
          and c.uint(FUND, "EPOCH_LENGTH()(uint256)") == EPOCH_LENGTH
          and c.call(FUND, "PROTOCOL_TREASURY()(address)").lower() == A["treasury"].lower()
          and c.call(FUND, "BUILDERS()(address)").lower() == S["BuilderRegistry"].lower(),
          "MarketsPerennial.FUND() is the fund; the fund pays into the SeasonPool, over the phase-1 registries, epoch 1 day")
    log = forge_script(c, "DeployNanoStack", {**common, "REGISTRY": S["Registry"], "ATTESTATION": S["Attestation"],
                       "NANO_LEDGER": S["NanoLedger"], "TREASURY": A["treasury"]})
    S["MarketsV4"] = grab(log, "MarketsV4")
    stack = {"ADMIN": A["admin"], "REGISTRY": S["Registry"], "ATTESTATION": S["Attestation"], "NANO_LEDGER": S["NanoLedger"],
             "BUILDER_REGISTRY": S["BuilderRegistry"], "CARETAKER_REGISTRY": S["CaretakerRegistry"],
             "BUILDER_FUND": FUND, "SEASON_POOL": POOL, "MARKETS_PERENNIAL": MP, "MARKETS_V4": S["MarketsV4"],
             "WONDER_ESCROW": S["WonderEscrow"]}
    forge_script(c, "Handoff", stack)
    vlog = forge_script(c, "VerifyRoles", {**stack, "DEPLOYER": A["deployer"], "ONBOARDER": A["onboarder"]})
    check("OK: onboarder holds no market/admin role" in vlog, "phase 2 VerifyRoles: the onboarder holds no market or admin role")
    check("OK: role table verified" in vlog, "DeployOracle -> NanoLedger -> Perennial -> NanoStack -> Handoff -> VerifyRoles all succeeded")

    markets_role = c.call(FUND, "MARKETS_ROLE()(bytes32)")
    funder_role = c.call(POOL, "FUNDER_ROLE()(bytes32)")
    gov = c.call(MP, "GOVERNOR_ROLE()(bytes32)")
    check(c.fails_with("deployer", FUND, "grantRole(bytes32,address)", markets_role, A["deployer"]) != "",
          "deployer can no longer grant itself the fund's MARKETS_ROLE (no fake builder income)")
    check(c.fails_with("deployer", POOL, "publishSeason(uint256,bytes32,uint256,uint64)", 1, "0x" + "11" * 32, 1, c.now() + 999) != ""
          and c.fails_with("deployer", MP, "setApprovedAgent(address,bool)", A["deployer"], "true") != "",
          "deployer can no longer publish a season or approve an agent")
    check(all(has(FUND, r, A["admin"]) for r in (ZERO32, c.call(FUND, "GOVERNOR_ROLE()(bytes32)")))
          and all(has(POOL, r, A["admin"]) for r in (ZERO32, c.call(POOL, "GOVERNOR_ROLE()(bytes32)")))
          and has(MP, gov, A["admin"]) and has(MP, ZERO32, A["admin"]),
          "ADMIN (multisig stand-in) holds the fund, pool and markets admin roles")
    check(has(FUND, markets_role, MP) and not has(FUND, markets_role, A["admin"]) and has(POOL, funder_role, FUND)
          and not has(POOL, funder_role, A["admin"]),
          "only MarketsPerennial credits builder income and only the fund funds the season pool")

    print("== 2. onboarding (post-handoff: every privileged step is ADMIN's)")
    c.send("builder", S["BuilderRegistry"], "registerBuilderWithProject(string,string)", "github.com/example/shipper",
           "github:example/shipper")   # a project: a badge (needed for builder markets) needs one
    bid = c.uint(S["BuilderRegistry"], "builderIdOf(address)(uint256)", A["builder"])
    c.send("admin", S["CaretakerRegistry"], "setCaretaker(uint256,address)", bid, A["operator"])
    check(bid > 0 and c.call(S["CaretakerRegistry"], "isCaretaker(uint256,address)(bool)", bid, A["operator"]) == "true",
          f"builder #{bid} registered, operator is its caretaker")
    c.send("admin", S["VerifiedBuilderBadge"], "issue(uint256)", bid)   # builder markets need a live badge
    check(c.uint(S["VerifiedBuilderBadge"], "serialOf(uint256)(uint256)", bid) > 0,
          f"builder #{bid} holds a Verified Builder badge (a builder market needs a live one)")

    # The caretaker's own feed-provisioning parameters (independent resolver, bond from the Registry).
    os.environ.update({k: "0x0" for k in ("RPC", "PRIVATE_KEY", "MARKETS_PERENNIAL", "NANO_LEDGER",
                                           "CARETAKER_REGISTRY", "BUILDER_REGISTRY", "REGISTRY", "ATTESTATION")})
    import caretaker
    fp, why = caretaker.feed_params(A["operator"], A["resolver"], c.call(S["Registry"], "MIN_BOND()(uint256)"), FEED_WINDOW)
    check(fp is not None, "caretaker.feed_params accepts an independent resolver", why)
    check(caretaker.feed_params(A["operator"], A["operator"], "10000000")[0] is None, "caretaker refuses to make itself resolver")
    meth = run(["cast", "keccak", "example/shipper-ships-release"]).stdout.strip()
    c.send("operator", USDC, "approve(address,uint256)", S["Registry"], fp["bond"])
    r = json.loads(c.send("operator", S["Registry"], "createFeed(string,bytes32,uint256,uint256,address)",
                          "example/shipper-ships-release", meth, fp["bond"], fp["window"], fp["resolver"]).stdout)
    feed = next(l["topics"][1] for l in r["logs"] if l["address"].lower() == S["Registry"].lower())
    c.send("operator", S["Registry"], "registerAgent(bytes32,bytes32,uint256)", feed, meth, fp["bond"])
    # wonder markets: the operator (FEED_ROLE) binds the feed to its builder, or the builder leg goes to the SeasonPool
    c.send("operator", MP, "setFeedSubject(bytes32,(uint8,uint256,bytes32))", feed, f"(1,{bid},{'0x' + '00' * 32})")
    check(c.call(MP, "isApprovedFeed(bytes32,address)(bool)", feed, A["operator"]) == "true",
          "milestone feed provisioned and passes the oracle allowlist")

    print("== 3. B1: a self-made oracle cannot open a market")
    c.send("attacker", USDC, "approve(address,uint256)", S["Registry"], 20 * U)
    r = json.loads(c.send("attacker", S["Registry"], "createFeed(string,bytes32,uint256,uint256,address)",
                          "rigged", meth, 10 * U, FEED_WINDOW, A["attacker"]).stdout)
    rigged = next(l["topics"][1] for l in r["logs"] if l["address"].lower() == S["Registry"].lower())
    c.send("attacker", S["Registry"], "registerAgent(bytes32,bytes32,uint256)", rigged, meth, 10 * U)
    err = c.fails_with("attacker", MP, "createMarket(uint256,bytes32,address,int256,uint8,uint256,uint256)",
                       bid, rigged, A["attacker"], 1, 1, c.now() + 7200, 5 * U)
    check(err != "" and ("AgentNotApproved" in err or "0x" in err), "createMarket on an attacker-resolved feed reverts", err[-200:])

    # ── UI driver ──
    contracts_ui = {k: S[k] for k in ("NanoLedger", "BuilderRegistry", "MarketsPerennial", "CaretakerRegistry", "BuilderFund", "SeasonPool")}
    contracts_ui["USDC"] = USDC
    builder_of_market = {}              # marketId -> builderId (for the income ledger below)
    credited = {}                       # builderId -> builder legs credited by the trades we made

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
        if action == "create":
            builder_of_market[res["marketId"].lower()] = int(kw["builderId"])
        if action in ("buy", "sell") and res.get("legs"):
            b = builder_of_market[kw["marketId"].lower()]
            credited[b] = credited.get(b, 0) + int(res["legs"]["payee"])
        return res

    keeper = CastChain(c.rpc, MP, S["Attestation"], KEYS["operator"])
    count = {"v": 0}
    providers = {feed.lower(): lambda now: (count["v"], f"releases:{count['v']}")}
    kstate = {}

    def keeper_tick():
        return tick(keeper, A["operator"], providers, kstate, SETTLEMENT_WINDOW)

    led = lambda who: c.uint(S["NanoLedger"], "balanceOf(address)(uint256)", who)
    coll = lambda m: c.uint(MP, "collateralOf(bytes32)(uint256)", m)
    escrow = lambda m: c.uint(MP, "agentEscrow(bytes32)(uint256)", m)
    income_of = lambda e, b: c.uint(FUND, "incomeOf(uint256,uint256)(uint256)", e, b)
    unallocated = lambda: c.uint(POOL, "unallocated()(uint256)")
    epoch_now = lambda: c.uint(FUND, "currentEpoch()(uint256)")
    pool_expected = {"v": 0}            # what the SeasonPool must hold, source by source

    def settles_with_split(label, m, creator_addr, action):
        """Run `action` (a resolve): nothing is charged at settlement; only the
        agent's held 20% of the trading fees is released, to the agent."""
        held = escrow(m)
        before = (led(creator_addr), led(A["operator"]), led(FUND), led(POOL))
        out = action()
        after = (led(creator_addr), led(A["operator"]), led(FUND), led(POOL))
        check(held > 0 and after[1] - before[1] == held and after[0] == before[0] and after[2:] == before[2:] and escrow(m) == 0,
              f"{label}: nothing charged at settlement; the agent's held 20% ({held/U:.4f}) released to it")
        return out

    print("== 4. m1 (YES): create via the UI path, trade, the builder ships, keeper settles")
    ov = ui("overview")
    check(ov["fundStatus"] == "live", "UI overview: the BuilderFund is live for these markets (fundStatus)")
    for who in ("alice", "bob"):
        ui("deposit", who, amount=str(300 * U))
    try:
        ui("create", "alice", builderId=bid, feedId=feed, expiryIn=7200, liquidity=str(10 * U))
        check(False, "create form must refuse a feed with no on-chain reading")
    except SystemExit as refused:
        check("no on-chain reading" in str(refused), "create form refuses while the builder's count has never been read")
    # the caretaker publishes the builder's current count (0) as soon as the feed exists
    c.send("operator", S["Attestation"], "attest(bytes32,int256,bytes32)", feed, 0, "0x" + "00" * 31 + "01")
    m1 = ui("create", "alice", builderId=bid, feedId=feed, expiryIn=7200, liquidity=str(10 * U))
    check(m1["threshold"] == "1" and m1["latest"] == "0", "create form: threshold = latest on-chain reading (0) + 1 = 1", m1)
    M1 = m1["marketId"]
    epoch0 = epoch_now()
    check(epoch0 == 0, "the fund is in epoch 0 while the first markets trade")
    b1 = ui("buy", "bob", marketId=M1, side="Yes", amount=str(20 * U))
    check(b1["quoteMatched"], f"bob buys YES 20 USDC -> {int(b1['sharesOut'])/U:.4f} shares, exactly the UI quote")
    fee, cr, ag, bl = split(20 * U)
    check(b1["fee"] == str(fee) and c.uint(MP, "netCost(bytes32,address)(uint256)", M1, A["bob"]) == 20 * U - fee
          and int(b1["legs"]["payee"]) == bl and income_of(0, bid) == bl,
          f"1% trading fee: {fee/U:.2f} of bob's 20 (creator {cr/U:.2f} / agent held {ag/U:.2f} / builder #{bid} income {bl/U:.2f}); net cost 19.80")
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
    err = c.fails_with("bob", MP, "buy(bytes32,uint8,uint256,uint256,uint256)", M1, 0, U, 0, 2**256 - 1)
    check("0xb2094b59" in err or "MarketExpired" in err, "no last look: buying after expiry reverts (MarketExpired)")
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
    r = settles_with_split("m1 resolve", M1, A["alice"], keeper_tick)
    check(("resolve", M1.lower()) in [(a[0], a[1].lower()) for a in r["actions"]], "keeper resolves m1", r)
    st = ui("status", marketId=M1)
    check(st["status"] == "resolved-yes" and st["yesWon"], "m1 resolved YES (count 1 >= 1)")

    c.warp_to(int(m3["expiry"]) + 5)
    r = keeper_tick()                                # count still 1: the builder did not ship again
    check("attest" in [a[0] for a in r["actions"]], "keeper attests the unchanged count for m3's window", r)
    c.warp_to(c.now() + FEED_WINDOW + 60)
    r = settles_with_split("m3 resolve", M3, A["bob"], keeper_tick)
    check(("resolve", M3.lower()) in [(a[0], a[1].lower()) for a in r["actions"]], "keeper resolves m3", r)
    st = ui("status", marketId=M3)
    check(st["status"] == "resolved-no" and not st["yesWon"], "m3 resolved NO (count 1 < 2)")

    # m2: the keeper is offline for m2's entire window (no ticks) -> voidable
    c.warp_to(int(m2["expiry"]) + SETTLEMENT_WINDOW + 60)
    check(ui("status", marketId=M2)["status"] == "voidable", "UI status: voidable when nothing settled in the window")
    held2 = escrow(M2)
    pool_before, un_before, fund_before, agent_before = led(POOL), unallocated(), led(FUND), led(A["operator"])
    v = ui("voidMarket", "bob", marketId=M2)
    check(ui("status", marketId=M2)["status"] == "voided", "a trader voids m2 through the UI path")
    check(int(v["challengerReward"]) == 0 and held2 > 0 and int(v["seasonPoolAmount"]) == held2
          and led(POOL) - pool_before == held2 and unallocated() - un_before == held2 and led(FUND) == fund_before
          and led(A["operator"]) == agent_before and escrow(M2) == 0,
          f"silent agent earns nothing: its held 20% ({held2/U:.4f}) goes through the fund to the SeasonPool (unallocated)")
    pool_expected["v"] += held2
    r = keeper_tick()
    check(r["actions"] == [], "keeper: idempotent afterwards", r)

    print("== 5a. reputation: the real indexer, after honest settlements")
    rep_contracts = {"MarketsPerennial": MP, "MarketsV4": S["MarketsV4"], "Attestation": S["Attestation"], "Dispute": S["Dispute"]}

    def reputation(prior=None):
        payload = {"rpc": c.rpc, "contracts": rep_contracts, "fromBlock": 0}
        if prior is not None:
            payload["prior"] = prior
        r = run(["npx", "--yes", "tsx", "scripts/reputation.ts", json.dumps(payload)], cwd=FRONTEND, ok=False)
        line = (r.stdout.strip().splitlines() or ["{}"])[-1]
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            raise SystemExit(f"reputation CLI printed no JSON:\n{r.stdout[-1500:]}\n{r.stderr[-1500:]}")

    def agent_bond(feed_id, who):
        out = c.call(S["Registry"], "getAgent(bytes32,address)((bytes32,uint256,uint256,uint256,uint256,bool,bool))", feed_id, who)
        return int(out.strip("()").split(",")[1].split()[0])

    def coverage_matches(label, market_id, record, level_mult_bps):
        ui_cov = ui("coverage", marketId=market_id, record=record)
        bond = agent_bond(feed, A["operator"])
        col = coll(market_id)
        recommended = 50 * U * level_mult_bps * col // (10_000 * 1_000 * U)
        check(int(ui_cov["bond"]) == bond and int(ui_cov["openCollateral"]) == col and int(ui_cov["recommended"]) == recommended,
              f"{label}: UI coverage = independent calc — bond {bond/U:.2f}, at risk {col/U:.2f}, "
              f"recommended {recommended/U:.4f} ({level_mult_bps/10_000:.2f}x), {ui_cov['coveragePct']}% covered")
        return ui_cov

    # m5 stays open (30 days) so the operator has live exposure on its feed
    m5 = ui("create", "alice", builderId=bid, feedId=feed, expiryIn=30 * 86400, liquidity=str(10 * U))
    M5 = m5["marketId"]
    check(ui("buy", "bob", marketId=M5, side="Yes", amount=str(8 * U))["quoteMatched"], "bob buys YES 8 on m5 (left open)")
    rep1 = reputation()
    op = A["operator"].lower()
    expected = (20 + 5 + 15 + 6) * U + int(s1["collateralOut"]) + int(s1["fee"])
    r1 = rep1["reputation"]["agents"].get(op) or {}
    check(int(r1.get("score", -1)) == expected and r1.get("level") == 1 and r1.get("settledMarkets") == 2 and not r1.get("caught"),
          f"operator reputation = exactly the trading volume of m1 + m3 ({expected/U:.4f} USDC), level 1, 2 settled; void m2 not counted")
    coverage_matches("level 1", M5, r1, 10_000)

    print("== 5b. m4 (VOID by challenge): our agent answers wrong, a watcher proves it, and is paid")
    c.send("builder2", S["BuilderRegistry"], "registerBuilderWithProject(string,string)", "github.com/example/second",
           "github:example/second")
    bid2 = c.uint(S["BuilderRegistry"], "builderIdOf(address)(uint256)", A["builder2"])
    c.send("admin", S["VerifiedBuilderBadge"], "issue(uint256)", bid2)  # builder markets need a live badge
    c.send("admin", S["CaretakerRegistry"], "setCaretaker(uint256,address)", bid2, A["operator"])
    meth2 = run(["cast", "keccak", "example/second-ships-release"]).stdout.strip()
    c.send("operator", USDC, "approve(address,uint256)", S["Registry"], fp["bond"])
    r = json.loads(c.send("operator", S["Registry"], "createFeed(string,bytes32,uint256,uint256,address)",
                          "example/second-ships-release", meth2, fp["bond"], fp["window"], fp["resolver"]).stdout)
    feed2 = next(l["topics"][1] for l in r["logs"] if l["address"].lower() == S["Registry"].lower())
    c.send("operator", S["Registry"], "registerAgent(bytes32,bytes32,uint256)", feed2, meth2, fp["bond"])
    c.send("operator", S["MarketsPerennial"], "setFeedSubject(bytes32,(uint8,uint256,bytes32))", feed2, f"(1,{bid2},{'0x' + '00' * 32})")
    c.send("operator", S["Attestation"], "attest(bytes32,int256,bytes32)", feed2, 0, "0x" + "00" * 31 + "02")   # first reading: 0
    m4 = ui("create", "alice", builderId=bid2, feedId=feed2, expiryIn=7200, liquidity=str(10 * U))
    M4 = m4["marketId"]
    check(ui("buy", "bob", marketId=M4, side="Yes", amount=str(10 * U))["quoteMatched"], "bob buys YES 10 on m4 at the UI quote")
    check(ui("buy", "alice", marketId=M4, side="No", amount=str(4 * U))["quoteMatched"], "alice buys NO 4 on m4 at the UI quote")
    c.warp_to(int(m4["expiry"]) + 5)
    # the second builder shipped nothing (count 0), but our agent attests 5 — a wrong answer that would pay YES
    r = json.loads(c.send("operator", S["Attestation"], "attest(bytes32,int256,bytes32)", feed2, 5, "0x" + "ab" * 32).stdout)
    att = next(l["topics"][1] for l in r["logs"] if l["address"].lower() == S["Attestation"].lower())
    stake = c.uint(S["Dispute"], "challengeStake(bytes32)(uint256)", att)
    c.send("watcher", USDC, "approve(address,uint256)", S["Dispute"], stake)
    r = json.loads(c.send("watcher", S["Dispute"], "challenge(bytes32,bytes32)", att, "0x" + "cd" * 32).stdout)
    did = next(l["topics"][1] for l in r["logs"] if l["address"].lower() == S["Dispute"].lower())
    ruling = json.loads(c.send("resolver", S["Dispute"], "resolve(bytes32,uint8)", did, 2).stdout)   # AttestationInvalid
    ruling_block = int(ruling["blockNumber"], 16)
    check(c.call(S["Dispute"], "invalidatedBy(bytes32)(address)", att).lower() == A["watcher"].lower()
          and c.call(S["Registry"], "isActiveAgent(bytes32,address)(bool)", feed2, A["operator"]) == "false",
          "independent resolver rules the answer Invalid: agent slashed and retired on that feed")
    c.warp_to(int(m4["expiry"]) + SETTLEMENT_WINDOW + 60)
    check(ui("status", marketId=M4)["status"] == "voidable", "no valid answer in the window: m4 is voidable")
    held4 = escrow(M4)
    w_before, pool_before = led(A["watcher"]), led(POOL)
    v = ui("voidMarket", "bob", marketId=M4)
    check((v["challenger"] or "").lower() == A["watcher"].lower() and int(v["challengerReward"]) == held4 > 0
          and led(A["watcher"]) - w_before == held4 and escrow(M4) == 0 and int(v["seasonPoolAmount"]) == 0
          and led(POOL) == pool_before,
          f"the watcher who proved the answer wrong receives the agent's held 20% ({held4/U:.4f} USDC); the pool gets nothing")
    for who, paid in (("bob", 10), ("alice", 4)):
        nc = c.uint(MP, "netCost(bytes32,address)(uint256)", M4, A[who])
        check(nc == paid * U - split(paid * U)[0] and c.uint(MP, "redeemable(bytes32,address)(uint256)", M4, A[who]) == nc,
              f"{who}'s refund = net cost after the 1% trading fee: {paid} -> {nc/U:.2f}")

    print("== 5c. reputation after the proven wrong answer")
    rep2 = reputation(prior=rep1["cursor"])
    fresh = reputation()
    check(rep2["reputation"] == fresh["reputation"], "resumed indexer (from the first run's cursor) == a from-scratch run")
    r2 = rep2["reputation"]["agents"].get(op) or {}
    check(r2.get("caught") is True and int(r2.get("score", -1)) == 0 and r2.get("level") == 0 and int(r2.get("caughtAt") or -1) == ruling_block,
          f"operator caught at the ruling's block {ruling_block}: score wiped to 0, level 0 (2x bond)")
    coverage_matches("level 0 (caught)", M5, r2, 20_000)

    print("== 6. everyone collects exactly the UI's preview")
    for m in (M1, M2, M3, M4):
        for who in ("alice", "bob"):
            y = c.uint(MP, "yesBalance(bytes32,address)(uint256)", m, A[who])
            n = c.uint(MP, "noBalance(bytes32,address)(uint256)", m, A[who])
            preview = c.uint(MP, "redeemable(bytes32,address)(uint256)", m, A[who])   # what the panel shows
            if preview == 0:
                # the panel disables the button ("nothing to redeem"); the contract agrees
                if y or n:
                    check(c.fails_with(who, MP, "redeem(bytes32)", m) != "",
                          f"{who} holds only losing shares on {m[:8]}: UI offers nothing, contract refuses")
                continue
            res = ui("redeem", who, marketId=m)
            check(res["previewMatched"], f"{who} redeems {m[:8]}: {int(res['payout'])/U:.4f} USDC = UI preview")
    for m, who in ((M1, "alice"), (M3, "bob"), (M2, "alice"), (M4, "alice")):
        res = ui("claimLP", who, marketId=m)
        check(int(res["payout"]) > 0, f"creator {who} claims LP on {m[:8]}: {int(res['payout'])/U:.4f} USDC")
    dust = c.uint(S["NanoLedger"], "balanceOf(address)(uint256)", MP) - coll(M5) - escrow(M5)
    check(0 <= dust <= 10, f"MarketsPerennial holds only the open m5 plus dust after every exit ({dust} units)")

    print("== 7. builder income: epoch 0 ends, the keeper's income crank pays it (and freezes a deactivated builder's)")
    check(epoch_now() == 0 and income_of(0, bid) == credited[bid] and income_of(0, bid2) == credited[bid2]
          and c.uint(FUND, "outstanding()(uint256)") == credited[bid] + credited[bid2] == led(FUND),
          f"every trade credited its market's builder: #{bid} {credited[bid]/U:.4f}, #{bid2} {credited[bid2]/U:.4f} USDC "
          f"(the 50% legs, exactly); the fund holds exactly the outstanding income")
    econ = ui("economy")
    check(econ["fundStatus"] == "live" and int(econ["epoch"]) == 0 and int(econ["epochLength"]) == EPOCH_LENGTH
          and int(econ["outstanding"]) == credited[bid] + credited[bid2] and int(econ["unallocated"]) == unallocated()
          and len(econ["schedule"]) == 4,
          "UI economy strip: epoch 0 of 1 day, outstanding income, season pool balance and the 4-bracket launch schedule")
    # The Safe freezes builder #2 (e.g. a fraud report) before its income is paid.
    check(c.fails_with("onboarder", S["BuilderRegistry"], "setActive(uint256,bool)", bid2, "false") != "",
          "the onboarder cannot deactivate a builder (REGISTRAR is the Safe's)")
    c.send("admin", S["BuilderRegistry"], "setActive(uint256,bool)", bid2, "false")
    err = c.fails_with("alice", FUND, "claimFor(uint256,uint256)", 0, bid)
    check(reverted_with(err, "EpochNotEnded"), "nobody can claim epoch 0 before it ends", err[-200:])
    c.warp_to(c.uint(FUND, "epochEnd(uint256)(uint256)", 0) + 1)
    check(epoch_now() == 1, "warped past epochEnd(0): epoch 1")

    # the full keeper (caretaker.py), isolated from the live state files, used from here on
    data_dir = pathlib.Path(tempfile_mod.mkdtemp(prefix="caretaker-e2e-"))
    kenv = {"RPC": c.rpc, "PRIVATE_KEY": KEYS["operator"], "MARKETS_PERENNIAL": MP,
            "NANO_LEDGER": S["NanoLedger"], "CARETAKER_REGISTRY": S["CaretakerRegistry"], "BUILDER_REGISTRY": S["BuilderRegistry"],
            "REGISTRY": S["Registry"], "ATTESTATION": S["Attestation"], "SEASON_POOL": POOL,
            "FEED_RESOLVER": A["resolver"], "FEED_CHALLENGE_WINDOW": str(FEED_WINDOW), "CHAIN_ID": "31337", "AUTO_OPEN_MARKETS": "false",
            "CARETAKER_DATA_DIR": str(data_dir), "VERIFIED_BADGE": S["VerifiedBuilderBadge"], "BADGE_LAPSE_TICKS": "1"}

    def keeper_tick_full():
        r = run(["python3", "keeper/caretaker.py"], env=kenv, cwd=ARC, ok=False)
        out = r.stdout + r.stderr
        if r.returncode != 0 or "tick done" not in out:
            raise SystemExit(f"caretaker tick failed:\n{out[-3000:]}")
        return out

    g1 = income_of(0, bid)
    t1, f1, n1 = income_split(g1)
    before = (led(A["builder"]), led(A["treasury"]), led(POOL), unallocated(), led(A["builder2"]))
    log0 = keeper_tick_full()
    after = (led(A["builder"]), led(A["treasury"]), led(POOL), unallocated(), led(A["builder2"]))
    want = f"income: claimed epoch 0 for builder #{bid}: gross {g1} tax {t1} fee {f1} net {n1} -> {A['builder'].lower()}"
    check(want in log0, f"keeper: '{want}'", log0[-2500:])
    check(t1 == 0 and after[0] - before[0] == n1 and after[1] - before[1] == f1 and after[2] == before[2] and after[3] == before[3],
          f"builder #{bid} paid exactly: net {n1/U:.6f} to its payout (the owner), 1% of gross-tax ({f1/U:.6f}) to the "
          f"treasury, tax 0 to the pool (below the $1,000 bracket)")
    check(f"ALERT caretaker: builder {bid2} income for epoch 0 is frozen (inactive) — the Safe may sweepFrozen" in log0
          and after[4] == before[4] and c.call(FUND, "claimed(uint256,uint256)(bool)", 0, bid2) == "false",
          f"deactivated builder #{bid2}: the keeper ALERTs the frozen income and pays nothing", log0[-2500:])
    err = c.fails_with("alice", FUND, "claimFor(uint256,uint256)", 0, bid2)
    check(reverted_with(err, "BuilderInactive"), f"claimFor(0, #{bid2}) reverts BuilderInactive for anyone", err[-200:])
    check(c.fails_with("operator", FUND, "sweepFrozen(uint256,uint256)", 0, bid2) != "", "only the Safe can sweep frozen income")
    g2 = income_of(0, bid2)
    pool_before, un_before = led(POOL), unallocated()
    c.send("admin", FUND, "sweepFrozen(uint256,uint256)", 0, bid2)
    check(led(POOL) - pool_before == g2 and unallocated() - un_before == g2 and led(A["builder2"]) == before[4]
          and c.call(FUND, "claimed(uint256,uint256)(bool)", 0, bid2) == "true" and c.uint(FUND, "outstanding()(uint256)") == 0,
          f"Safe sweepFrozen: builder #{bid2}'s whole income ({g2/U:.6f}, untaxed) goes to the SeasonPool; nothing outstanding")
    pool_expected["v"] += g2
    rows2 = ui("income", builderId=bid2)["rows"]
    check(any(int(r["epoch"]) == 0 and r["state"] == "swept" for r in rows2), "UI income card shows builder #2's epoch 0 as swept", rows2)
    log1 = keeper_tick_full()
    check(f"epoch 0 builder #{bid2} already claimed or swept" in log1 and "is frozen" not in log1,
          "next keeper tick: the swept pair is dropped, no repeated ALERT", log1[-1500:])

    V = verified_builders_stage(c, A, S, ui, keeper_tick_full, data_dir, led, income_of, unallocated, epoch_now, pool_expected, credited)
    season_stage(c, A, S, V, led, unallocated, pool_expected, reverted_with)
    for srv in V["servers"]:
        srv.shutdown()
    oracle_agent_stage(c, A, S, V, kenv, keeper_tick_full, data_dir, led)
    rounds_stage(c, A, S, led)

    print("== 13. accounting")
    # one more trade in the current epoch: income that stays outstanding (not claimable yet)
    ep = epoch_now()
    b = ui("buy", "bob", marketId=V["M10"], side="Yes", amount=str(10 * U))
    check(b["quoteMatched"], f"bob buys YES 10 on the open domain market in epoch {ep} (income not yet claimable)")
    # every USDC unit minted is somewhere accountable: wallets + ledger (which backs all internal balances)
    minted = sum(MINTED.values()) * U
    wallets = sum(c.uint(USDC, "balanceOf(address)(uint256)", A[w]) for w in KEYS)
    ledger_held = c.uint(USDC, "balanceOf(address)(uint256)", S["NanoLedger"])
    registry_held = c.uint(USDC, "balanceOf(address)(uint256)", S["Registry"])
    dispute_held = c.uint(USDC, "balanceOf(address)(uint256)", S["Dispute"])
    check(dispute_held == 0, "no stake left stuck in Dispute after the ruling")
    check(wallets + ledger_held + registry_held + dispute_held == minted,
          f"USDC conserved: wallets {wallets/U:.2f} + ledger {ledger_held/U:.2f} + bonds {registry_held/U:.2f} = {minted/U:.0f}")
    total_owed = c.uint(S["NanoLedger"], "totalOwed()(uint256)")
    check(ledger_held >= total_owed, f"ledger solvent: holds {ledger_held} >= owes {total_owed}")
    # the fund: outstanding == every (epoch, builder) with income not yet claimed or swept, from the logs
    logs = json.loads(run(["cast", "logs", "--from-block", "0", "--address", FUND, "IncomeCredited(uint256,uint256,uint256)",
                           "--rpc-url", c.rpc, "--json"]).stdout or "[]")
    pairs = {(int(l["topics"][1], 16), int(l["topics"][2], 16)) for l in logs}
    unclaimed = sum(income_of(e, bb) for e, bb in pairs if c.call(FUND, "claimed(uint256,uint256)(bool)", e, bb) == "false")
    outstanding = c.uint(FUND, "outstanding()(uint256)")
    check(outstanding == unclaimed == led(FUND) == int(b["legs"]["payee"]) > 0,
          f"fund outstanding {outstanding/U:.6f} == unclaimed income over {len(pairs)} (epoch, builder) pairs == its ledger balance")
    reserved = c.uint(POOL, "reserved()(uint256)")
    check(led(POOL) >= unallocated() + reserved and led(POOL) == pool_expected["v"],
          f"SeasonPool holds {led(POOL)/U:.6f} >= unallocated {unallocated()/U:.6f} + reserved {reserved/U:.6f}; "
          f"== void escrow + frozen sweep + taxes - season claims")


def verified_builders_stage(c, A, S, ui, keeper_tick_full, data_dir, led, income_of, unallocated, epoch_now, pool_expected, credited):
    """Registrai Verified Builders, builder-projects model: one builder, two projects,
    each with its own proof (/verify's own claim code) -> self-register -> the real
    onboard-batch (per builder) sent by the onboarder -> badge -> real keeper ticks;
    then income with tax, an owner transfer and a recovery."""
    print("== 9. verified builders: one builder, two projects (github + domain) -> batch -> badge -> keeper")
    MP, FUND, POOL, BR, CR, BADGE = (S["MarketsPerennial"], S["BuilderFund"], S["SeasonPool"], S["BuilderRegistry"],
                                     S["CaretakerRegistry"], S["VerifiedBuilderBadge"])
    root = pathlib.Path(tempfile_mod.mkdtemp(prefix="vb-e2e-"))
    gh_srv, gh_port = serve(root / "raw")        # stand-in for raw.githubusercontent.com
    dom_srv, dom_port = serve(root / "domain")   # the builder's own site
    api_srv, api_port = serve(root / "api")      # stand-in for api.github.com
    proof_env = {"PROOF_GITHUB_BASE": f"http://127.0.0.1:{gh_port}", "PROOF_DOMAIN_SCHEME": "http",
                 "PROOF_DOMAIN_PORT": str(dom_port), "GITHUB_API_BASE": f"http://127.0.0.1:{api_port}"}
    os.environ.update(proof_env)   # the ui() driver, the batch script and the keepers inherit these
    today = datetime.date.today().isoformat()
    V = {"season_from": c.block(), "servers": (gh_srv, dom_srv, api_srv)}
    import verified as kv
    GH, DOM = "github:acme/tool", "domain:127.0.0.1"
    gh_file = root / "raw/acme/tool/HEAD/.registrai.json"
    dom_file = root / "domain/.well-known/registrai.json"
    gh_file.parent.mkdir(parents=True, exist_ok=True); dom_file.parent.mkdir(parents=True, exist_ok=True)
    latest = lambda f: int(c.call(S["Attestation"], "latestValue(bytes32,address)(int256,uint256,bool)", f, A["operator"]).split()[0])

    def sign_both(owner):
        """Both projects' proofs, signed by `owner` (the domain one also by its deployer), served."""
        fa = ui("claim", claim={"builder": A[owner].lower(), "source": GH, "deployers": [], "country": "PL", "chain": 31337, "issued": today},
                builderKey=KEYS[owner])["file"]
        fb = ui("claim", claim={"builder": A[owner].lower(), "source": DOM, "deployers": [A["vdeployer"].lower()], "country": "PL",
                                "chain": 31337, "issued": today}, builderKey=KEYS[owner], deployerKeys=[KEYS["vdeployer"]])["file"]
        gh_file.write_text(json.dumps(fa)); dom_file.write_text(json.dumps(fb))
        return fa, fb

    # open source: one published release on acme/tool (dated by the CHAIN clock, which
    # this rehearsal warps), plus a pre-release and a bare tag that must NOT count
    gh_iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
    rel = root / "api/repos/acme/tool/releases"; rel.parent.mkdir(parents=True)
    releases = [{"tag_name": "v1.0.0", "published_at": gh_iso(c.now() - 3 * 86400), "draft": False, "prerelease": False},
                {"tag_name": "v1.0.1-rc", "published_at": gh_iso(c.now() - 2 * 86400), "draft": False, "prerelease": True}]
    rel.write_text(json.dumps(releases))
    (root / "api/repos/acme/tool/tags").write_text(json.dumps([{"name": "v1.0.0"}, {"name": "just-a-tag"}]))
    # closed source: two contracts deployed by the project's deployer wallet (nonces 0, 1)
    init = "0x600a600c600039600a6000f3602a60005260206000f3"   # tiny contract returning 42
    for _ in range(2):
        run(["cast", "send", "--rpc-url", c.rpc, "--private-key", KEYS["vdeployer"], "--create", init])
    fa, fb = sign_both("vbuilder")
    c.send("vbuilder", BR, "registerBuilderWithProject(string,string)", "https://acme.dev", GH)
    vid = c.uint(BR, "builderIdOf(address)(uint256)", A["vbuilder"])
    c.send("vbuilder", BR, "addProject(string)", DOM)
    pids = [int(x) for x in re.findall(r"\d+", c.call(BR, "projectsOf(uint256)(uint256[])", vid))]
    srcs = [c.call(BR, "projects(uint256)(uint256,string,bool,uint64)", p).splitlines()[1].strip().strip('"') for p in pids]
    check(vid > 0 and len(pids) == 2 and srcs == [GH, DOM] and c.uint(BR, "activeProjectCount(uint256)(uint256)", vid) == 2
          and c.call(BR, "builders(uint256)(address,string,bytes,uint64,bool)", vid).splitlines()[1].strip('"') == "https://acme.dev",
          f"builder #{vid} registered with registerBuilderWithProject + addProject: projects #{pids[0]} {GH}, #{pids[1]} {DOM}; "
          f"the profile is free-form (no claim in it)")
    V["vid"], V["pids"] = vid, pids
    # the old owner routes its payouts to a separate wallet
    c.send("vbuilder", CR, "setPayout(uint256,address)", vid, A["vpayout"])
    check(c.call(CR, "payoutOf(uint256)(address)", vid).lower() == A["vpayout"].lower(), "the builder owner sets its payout wallet")

    # forgeries: both implementations must refuse
    forged_dep = {"builder": A["stranger"].lower(), "source": DOM, "deployers": [A["vdeployer"].lower()], "country": "DE", "chain": 31337, "issued": today}
    ff = ui("claim", claim=forged_dep, builderKey=KEYS["stranger"])["file"]      # the deployer never signed
    ts = ui("validateProof", file=ff, expectedSource=DOM, onchainOwner=A["stranger"], chainId=31337)["result"]
    py_ok, py_why = kv.validate_proof(ff, DOM, A["stranger"], 31337)
    check(not ts["valid"] and ts["rule"] == 5 and not py_ok,
          f"claiming someone else's deployer is refused by the website (rule {ts['rule']}) and the keeper ({py_why[:40]})")
    wrong = ui("claim", claim=fa["claim"], builderKey=KEYS["stranger"])["file"]       # signed by the wrong wallet
    ts2 = ui("validateProof", file=wrong, expectedSource=GH, onchainOwner=A["vbuilder"], chainId=31337)["result"]
    py2, _ = kv.validate_proof(wrong, GH, A["vbuilder"], 31337)
    check(not ts2["valid"] and not py2, "a claim signed by the wrong wallet is refused by both")
    ts3 = ui("validateProof", file=fa, expectedSource=DOM, onchainOwner=A["vbuilder"], chainId=31337)["result"]
    py3x, _ = kv.validate_proof(fa, DOM, A["vbuilder"], 31337)
    check(not ts3["valid"] and ts3["rule"] == 2 and not py3x, "one project's proof does not vouch for another project (rule 2, both)")
    py3, why3 = kv.validate_proof(fa, GH, A["vbuilder"], 31337)
    py4, why4 = kv.validate_proof(fb, DOM, A["vbuilder"], 31337)
    check(py3 and py4, "the keeper accepts both proof files the website library produced (the domain one co-signed by its deployer)", f"{why3} {why4}")

    # the soulbound badge from phase 1
    check(c.call(BADGE, "hasRole(bytes32,address)(bool)", ZERO32, A["deployer"]) == "false"
          and c.call(BADGE, "hasRole(bytes32,address)(bool)", run(["cast", "keccak", "STATUS_ROLE"]).stdout.strip(), A["operator"]) == "true",
          "badge (phase 1): the deployer holds no role, the operator holds STATUS only")

    # the real onboarding batch, executed by the onboarder hot wallet (the fast path)
    out_dir = root / "batch"
    run(["npx", "--yes", "tsx", "scripts/onboard-batch.ts", "--network", "local", "--rpc", c.rpc,
         "--builder-registry", BR, "--caretaker-registry", CR,
         "--operator", A["operator"], "--chain-id", "31337", "--badge", BADGE, "--out", str(out_dir)], cwd=FRONTEND)
    txs = json.loads((out_dir / "onboard-batch.safe.json").read_text())["transactions"]
    check(len(txs) == 2 and txs[0]["to"].lower() == CR.lower() and txs[1]["to"].lower() == BADGE.lower(),
          f"onboard-batch is per builder: setCaretaker then issue for the one pending builder with two projects ({len(txs)} txs)")
    for t in txs:
        run(["cast", "send", t["to"], t["data"], "--rpc-url", c.rpc, "--private-key", KEYS["onboarder"]])
    check(c.call(CR, "isCaretaker(uint256,address)(bool)", vid, A["operator"]) == "true",
          "after the onboarder sends the batch our operator is the builder's caretaker")
    serial = c.uint(BADGE, "serialOf(uint256)(uint256)", vid)
    V["serial"] = serial
    issued_at = c.uint(BADGE, "issuedAt(uint256)(uint64)", serial)
    check(serial == 3 and c.call(BADGE, "ownerOf(uint256)(address)", serial).lower() == A["vbuilder"].lower(),
          f"badge No. {serial:03d} (one per builder, not per project; builders #1 and #2 hold 001 and 002) is held by "
          f"the builder itself")
    check(c.fails_with("vbuilder", BADGE, "transferFrom(address,address,uint256)", A["vbuilder"], A["stranger"], serial) != "",
          "the badge is soulbound: its holder cannot transfer it")
    check(c.fails_with("operator", BADGE, "issue(uint256)", vid) != "", "the keeper's operator key cannot issue a badge")
    check(c.fails_with("onboarder", BADGE, "revoke(uint256)", vid) != "", "the onboarder cannot revoke a badge (REVOKER is Safe-only)")

    def badge_json(s):
        uri = c.call(BADGE, "tokenURI(uint256)(string)", s).strip().strip('"')
        return json.loads(base64.b64decode(uri.split(",", 1)[1]))
    j = badge_json(serial)
    attrs = {a["trait_type"]: a["value"] for a in j["attributes"]}
    check(j["name"] == f"Registrai Verified Builder No. {serial:03d}" and set(attrs) == {"Status", "Serial", "Builder ID", "Chain", "Issued"}
          and attrs["Status"] == "Verified" and attrs["Builder ID"] == vid and attrs["Chain"] == "Local"
          and j["image"] == f"https://registrai.cc/badge/local/{serial}.jpg" and j["external_url"].endswith(f"?builder={vid}"),
          "tokenURI: on-chain JSON names the serial, status, builder id, chain and issue date — no Source attribute")
    art = root / "badge-art"
    run(["python3", "scripts/render-badges.py", "--network", "local", "--upto", "1", "--out", str(art)], cwd=FRONTEND)
    check(all((art / "local" / f).stat().st_size > 20_000 for f in ("1.jpg", "1-lapsed.jpg", "card.jpg")),
          "render-badges produces the badge, lapsed and share-card images")

    # first keeper tick: one milestone feed per verified project, counts published
    markets_by_op_before = c.uint(MP, "createdBy(address)(uint256)", A["operator"])
    log1 = keeper_tick_full()
    check("builders: 1 verified (2 verified projects)" in log1, "keeper sees one verified builder with two verified projects", log1[-1500:])
    st = json.loads((data_dir / "caretaker-state.json").read_text())
    kA, kB = f"#{vid}|{GH}", f"#{vid}|{DOM}"
    fA, fB = (st.get(kA) or {}).get("milestoneFeedId"), (st.get(kB) or {}).get("milestoneFeedId")
    check(bool(fA) and bool(fB) and fA != fB, f"state is keyed per project ({kA}, {kB}), one milestone feed each", list(st))
    V["fA"], V["fB"] = fA, fB
    for f_ in (fA, fB):   # the operator binds each project feed to its builder (keeper/wonder.py does this live)
        c.send("operator", MP, "setFeedSubject(bytes32,(uint8,uint256,bytes32))", f_, f"(1,{vid},{'0x' + '00' * 32})")
    check("[tool] recorded release(s) v1.0.0 (count 1" in log1 and "[tool] published milestone count 1 on-chain" in log1
          and latest(fA) == 1, f"open-source project milestone recorded and published on-chain: 1 published release "
          f"(the pre-release and the bare tag do not count) = {latest(fA)}", log1[-3000:])
    check("[127.0.0.1] published milestone count 2 on-chain" in log1 and latest(fB) == 2,
          f"closed-source project milestone published on-chain: contracts deployed by its deployer = {latest(fB)}", log1[-3000:])
    check(all(c.call(MP, "isApprovedFeed(bytes32,address)(bool)", f, A["operator"]) == "true" for f in (fA, fB)),
          "both project feeds pass the oracle allowlist (independent resolver)")
    check(c.uint(MP, "createdBy(address)(uint256)", A["operator"]) == markets_by_op_before,
          "the keeper opened no market itself (auto_open_markets=false)")

    # the season market: a community member opens it; traders (not the builder, creator or agent) trade it
    m9 = ui("create", "bob", builderId=vid, feedId=fA, expiryIn=7200, liquidity=str(5 * U))
    check(m9["threshold"] == "2", "a community member opens a market on the verified builder's github project: >= 1 + 1 = 2")
    M9 = m9["marketId"]
    V["M9"] = M9
    ep1 = epoch_now()
    V["ep_whale"] = ep1
    wash = 0
    ui("deposit", "whale", amount=str(MINTED["whale"] * U))
    for i in range(3):   # a high-volume trader: round trips, so this builder's epoch income crosses $1,000
        amt = led(A["whale"])
        b = ui("buy", "whale", marketId=M9, side="Yes", amount=str(amt))
        s = ui("sell", "whale", marketId=M9, side="Yes", shares=b["sharesOut"])
        check(b["quoteMatched"] and s["quoteMatched"],
              f"whale round trip {i + 1}: buys YES {amt/U:,.2f} and sells it all back, exactly at the UI quotes")
        wash += amt + int(s["grossOut"])
    # season rule v2: round trips inside the 24h hold time count 0; only positions HELD count
    hold = ui("buy", "whale", marketId=M9, side="Yes", amount=str(600 * U))
    check(hold["quoteMatched"], "the whale then buys YES 600 and holds it to settlement")
    a9 = ui("buy", "alice", marketId=M9, side="Yes", amount=str(20 * U))
    check(a9["quoteMatched"], "alice buys YES 20 on the season market at the UI quote")
    V["m9_volume"] = 600 * U + 20 * U
    V["m9_wash"] = wash
    gross = income_of(ep1, vid)
    check(gross == credited[vid] and gross > 1_000 * U,
          f"builder #{vid}'s income in epoch {ep1}: {gross/U:,.6f} USDC (exactly the 50% legs; above the $1,000 tax-free bracket)")
    rows = ui("income", builderId=vid)["rows"]
    row = next((r for r in rows if int(r["epoch"]) == ep1), {})
    tW, fW, nW = income_split(gross)
    check(int(row.get("gross", -1)) == gross and int(row.get("tax", -1)) == tW > 0 and row.get("state") == "open",
          f"UI income card: epoch {ep1} open, gross {gross/U:,.2f}, tax {tW/U:.6f} (10% of the slice above $1,000)", row)

    print("== 9a. one proof removed: that project lapses, the builder stays verified")
    dom_file.unlink()
    run(["cast", "send", "--rpc-url", c.rpc, "--private-key", KEYS["vdeployer"], "--create", init])   # a 3rd deploy
    log2 = keeper_tick_full()
    check(f"ALERT caretaker: [builder #{vid} project #{pids[1]} {DOM}] lapsed" in log2
          and "builders: 1 verified (1 verified projects)" in log2,
          "removing the domain proof: that project gets an ALERT, the builder stays verified on its github project", log2[-2000:])
    check(latest(fB) == 2, "lapsed project: no heartbeat, its published count stays at 2 despite a 3rd deploy")
    check(latest(fA) == 1 and c.call(BADGE, "lapsed(uint256)(bool)", serial) == "false",
          "the other project is unaffected and the badge stays verified")

    print("== 9b. all proofs removed: the badge lapses; restored: verified again")
    gh_file.unlink()
    log3 = keeper_tick_full()
    check(f"[builder {vid}] badge No. {serial:03d} marked LAPSED" in log3 and f"ALERT caretaker: [builder #{vid}" in log3
          and "builders: 0 verified (0 verified projects)" in log3,
          "no verified project left: the keeper alerts and marks the badge lapsed on-chain", log3[-2000:])
    check(c.call(BADGE, "isLapsed(uint256)(bool)", serial) == "true" and badge_json(serial)["image"].endswith(f"/{serial}-lapsed.jpg")
          and c.call(BADGE, "ownerOf(uint256)(address)", serial).lower() == A["vbuilder"].lower(),
          "the lapsed badge reads Lapsed (lapsed art) and stays with its builder")
    check(latest(fA) == 1 and latest(fB) == 2, "both counts frozen while lapsed")
    gh_file.write_text(json.dumps(fa)); dom_file.write_text(json.dumps(fb))      # proofs back
    rel.write_text(json.dumps([{"tag_name": "v1.1.0", "published_at": gh_iso(c.now()), "draft": False,
                                "prerelease": False}] + releases))                # and the builder ships a release
    log4 = keeper_tick_full()
    check(c.call(BADGE, "lapsed(uint256)(bool)", serial) == "false" and "builders: 1 verified (2 verified projects)" in log4,
          "proofs restored: the builder and its badge are verified again on the next tick", log4[-2000:])
    check("[tool] recorded release(s) v1.1.0 (count 2" in log4 and latest(fA) == 2 and latest(fB) == 3,
          "counts resume: github 2 (a new release, days after the last), domain 3 (the deploy made while lapsed)", log4[-3000:])

    print("== 9c. the season market settles YES through the keeper")
    c.warp_to(int(m9["expiry"]) + 5)
    log5 = keeper_tick_full()
    check(f"settle: attest {fA.lower()} 2" in log5.lower() and f"as of {int(m9['expiry'])}" in log5,
          "keeper attests the github project's count AS OF M9's expiry (2) in M9's window", log5[-2000:])
    c.warp_to(c.now() + FEED_WINDOW + 60)
    log6 = keeper_tick_full()
    check(f"settle: resolve {M9.lower()}" in log6.lower(), "keeper resolves M9", log6[-2000:])
    st9 = ui("status", marketId=M9)
    check(st9["status"] == "resolved-yes" and st9["yesWon"], "M9 resolved YES (count 2 >= 2)")
    res = ui("redeem", "alice", marketId=M9)
    check(res["previewMatched"], f"alice redeems M9: {int(res['payout'])/U:.4f} USDC = UI preview")
    V["season_resolved_block"] = c.block()

    r = run(["python3", "keeper/builders_keeper.py"], cwd=ARC, ok=False,
            env={"RPC": c.rpc, "PRIVATE_KEY": KEYS["operator"], "BUILDER_REGISTRY": BR,
                 "CARETAKER_REGISTRY": CR, "VERIFIED_BADGE": BADGE, "CHAIN_ID": "31337",
                 "BUILDERS_DATA_DIR": str(data_dir)})
    out = r.stdout + r.stderr
    check(r.returncode == 0 and "builders: 1 verified," in out and "projects: 2 verified," in out and "marked" not in out,
          "the phase-1 keeper agrees with the full keeper: 1 verified builder, 2 verified projects, no badge change", out[-800:])

    print("== 10. income with tax: the high-volume epoch ends, the keeper pays it")
    c.warp_to(c.uint(FUND, "epochEnd(uint256)(uint256)", ep1) + 1)
    before = (led(A["vpayout"]), led(A["treasury"]), led(POOL), unallocated(), c.uint(FUND, "outstanding()(uint256)"))
    log7 = keeper_tick_full()
    after = (led(A["vpayout"]), led(A["treasury"]), led(POOL), unallocated(), c.uint(FUND, "outstanding()(uint256)"))
    want = f"income: claimed epoch {ep1} for builder #{vid}: gross {gross} tax {tW} fee {fW} net {nW} -> {A['vpayout'].lower()}"
    check(want in log7, f"keeper: '{want}'", log7[-2500:])
    check(after[0] - before[0] == nW and after[1] - before[1] == fW and after[2] - before[2] == tW and after[3] - before[3] == tW
          and before[4] - after[4] == gross,
          f"exact: net {nW/U:,.6f} to the payout the owner set, fee {fW/U:.6f} (1% of gross-tax) to the treasury, "
          f"tax {tW/U:.6f} to the SeasonPool (unallocated)")
    pool_expected["v"] += tW

    print("== 10a. owner transfer: proposeOwner -> acceptOwnership; proofs re-signed; the badge follows")
    c.send("vbuilder", BR, "proposeOwner(address)", A["vowner2"])
    check(c.fails_with("stranger", BR, "acceptOwnership(uint256)", vid) != "", "only the proposed wallet can accept")
    c.send("vowner2", BR, "acceptOwnership(uint256)", vid)
    check(c.call(BR, "ownerOf(uint256)(address)", vid).lower() == A["vowner2"].lower()
          and c.uint(BR, "builderIdOf(address)(uint256)", A["vowner2"]) == vid and c.uint(BR, "builderIdOf(address)(uint256)", A["vbuilder"]) == 0,
          f"builder #{vid} now belongs to the new wallet (same id, same projects)")
    check(c.call(CR, "payoutOf(uint256)(address)", vid).lower() == A["vowner2"].lower()
          and A["vpayout"].lower() in c.call(CR, "payoutRecord(uint256)(address,address)", vid).lower(),
          "the payout the old owner set is ignored: payoutOf == the new owner")
    for f, src in ((fa, GH), (fb, DOM)):
        t = ui("validateProof", file=f, expectedSource=src, onchainOwner=A["vowner2"], chainId=31337)["result"]
        p, _ = kv.validate_proof(f, src, A["vowner2"], 31337)
        check(not t["valid"] and t["rule"] == 4 and not p, f"the old owner's {src} proof lapses after the transfer (rule 4, both)")
    fa, fb = sign_both("vowner2")
    log8 = keeper_tick_full()
    check(f"badge No. {serial:03d} synced to the new owner" in log8 and "builders: 1 verified (2 verified projects)" in log8,
          "keeper tick: the badge is synced to the new owner; both re-signed projects verified", log8[-2000:])
    check(c.call(BADGE, "ownerOf(uint256)(address)", serial).lower() == A["vowner2"].lower() and c.uint(BADGE, "serialOf(uint256)(uint256)", vid) == serial
          and c.uint(BADGE, "issuedAt(uint256)(uint64)", serial) == issued_at and c.call(BADGE, "lapsed(uint256)(bool)", serial) == "false"
          and c.uint(BADGE, "balanceOf(address)(uint256)", A["vbuilder"]) == 0,
          f"badge No. {serial:03d} now held by the new owner: same serial, same issue date, still verified")
    # a second market on the domain project, left open: its income is earned before the recovery
    m10 = ui("create", "alice", builderId=vid, feedId=fB, expiryIn=30 * 86400, liquidity=str(5 * U))
    check(m10["threshold"] == "4", "a market on the domain project's own feed: >= 3 + 1 = 4")
    V["M10"] = m10["marketId"]
    ep2 = epoch_now()
    check(ui("buy", "bob", marketId=V["M10"], side="Yes", amount=str(10 * U))["quoteMatched"],
          f"bob buys YES 10 on it in epoch {ep2}: income for builder #{vid}")
    g_rec = income_of(ep2, vid)

    print("== 11. recovery: the Safe moves the builder to a recovered wallet after 7 days")
    check(c.fails_with("onboarder", BR, "startRecovery(uint256,address)", vid, A["vrecovered"]) != "",
          "the onboarder cannot start a recovery (REGISTRAR is the Safe's)")
    c.send("admin", BR, "startRecovery(uint256,address)", vid, A["vrecovered"])
    check(A["vrecovered"].lower() in c.call(BR, "recoveryOf(uint256)(address,uint64)", vid).lower(), "the Safe starts a recovery")
    err = c.fails_with("stranger", BR, "finishRecovery(uint256)", vid)
    check(reverted_with(err, "RecoveryNotReady"), "finishRecovery before 7 days reverts", err[-200:])
    c.increase_time(RECOVERY_DELAY + 60)
    c.send("stranger", BR, "finishRecovery(uint256)", vid)
    check(c.call(BR, "ownerOf(uint256)(address)", vid).lower() == A["vrecovered"].lower()
          and c.call(CR, "payoutOf(uint256)(address)", vid).lower() == A["vrecovered"].lower(),
          f"after 7 days anyone finishes it: builder #{vid} is owned (and paid) by the recovered wallet")
    check(epoch_now() > ep2 and c.call(FUND, "claimed(uint256,uint256)(bool)", ep2, vid) == "false",
          f"epoch {ep2} (earned before the recovery) ended unclaimed")
    before_rec = led(A["vrecovered"])
    ci = ui("claimIncome", "stranger", builderId=vid, epoch=ep2)
    tR, fR, nR = income_split(g_rec)
    check(ci["previewMatched"] and int(ci["gross"]) == g_rec and int(ci["net"]) == nR and int(ci["fee"]) == fR
          and (ci["payout"] or "").lower() == A["vrecovered"].lower() and led(A["vrecovered"]) - before_rec == nR,
          f"UI claimIncome (anyone): epoch {ep2} income paid exactly as previewed ({nR/U:.6f} net) to the recovered owner")
    pool_expected["v"] += tR
    fa, fb = sign_both("vrecovered")
    log9 = keeper_tick_full()
    check(f"badge No. {serial:03d} synced to the new owner" in log9 and c.call(BADGE, "ownerOf(uint256)(address)", serial).lower() == A["vrecovered"].lower()
          and c.uint(BADGE, "serialOf(uint256)(uint256)", vid) == serial and "builders: 1 verified (2 verified projects)" in log9
          and f"epoch {ep2} builder #{vid} already claimed or swept" in log9,
          f"keeper tick: badge No. {serial:03d} synced to the recovered owner; re-signed projects verified; the claimed epoch dropped",
          log9[-2500:])
    rows = ui("income", builderId=vid)["rows"]
    paid = {int(r["epoch"]): r for r in rows if r["state"] == "claimed"}
    check(ep1 in paid and ep2 in paid and (paid[ep2].get("payout") or "").lower() == A["vrecovered"].lower()
          and (paid[ep1].get("payout") or "").lower() == A["vpayout"].lower(),
          "UI income card: both epochs claimed, each to the payout of its day (old owner's wallet, then the recovered owner)", rows)
    V["season_to"] = c.block()
    return V


def oracle_agent_stage(c, A, S, V, kenv, keeper_tick_full, data_dir, led):
    """Our agent does every oracle duty, through the REAL keeper process: a
    config-driven data feed (a Coinbase stand-in), bond health, a common market on
    MarketsV4 settled as of its expiry, a challenge alerted with its preimage, the
    ruling reported, the market resolved, claims counted to zero."""
    print("== 12b. our agent, every oracle duty: data feed, bond health, MarketsV4, dispute watch")
    from decimal import Decimal
    V4, REG, ATT, DISP, OP = S["MarketsV4"], S["Registry"], S["Attestation"], S["Dispute"], A["operator"]
    root = pathlib.Path(tempfile_mod.mkdtemp(prefix="cb-e2e-"))
    srv, port = serve(root)
    candles = root / "products/BTC-USD/candles"; candles.parent.mkdir(parents=True)
    price = lambda t0: 64000 + (t0 // 60 % 1000) / 100          # a deterministic price per closed minute
    t_start = (c.now() // 60) * 60 - 600
    candles.write_text(json.dumps([[t, price(t), price(t), price(t), price(t), 1.0]
                                   for t in range(t_start + 6 * 3600, t_start - 60, -60)]))   # newest first, like Coinbase
    as_of = lambda at: max(t for t in range(t_start, t_start + 6 * 3600, 60) if t + 60 <= at)
    scaled = lambda at: int(Decimal(str(price(as_of(at)))) * 100)
    kenv.update({"MARKETS_V4": V4, "MARKETS_V4_DEPLOY_BLOCK": str(c.block()), "DISPUTE": DISP,
                 "DATA_FEEDS": json.dumps([{"key": "btc-usd", "kind": "coinbase-spot", "product": "BTC-USD", "decimals": 2,
                                            "disputeWindow": 3600, "publishEvery": 3600,
                                            "apiBase": f"http://127.0.0.1:{port}"}])})
    agent_bond = lambda f: int(c.call(REG, "getAgent(bytes32,address)((bytes32,uint256,uint256,uint256,uint256,bool,bool))",
                                      f, OP).strip("()").split(",")[1].split()[0])
    min_bond = lambda f: int(c.call(REG, "getFeed(bytes32)((address,string,bytes32,uint256,uint256,address,uint256,bool))",
                                    f).strip("()").split(",")[-5].split()[0])

    log = keeper_tick_full()
    st = json.loads((data_dir / "caretaker-state.json").read_text())
    feed = st["dataFeeds"]["btc-usd"]["feedId"]
    pub = int(c.call(ATT, "latestValue(bytes32,address)(int256,uint256,bool)", feed, OP).split()[0])
    check("data feed btc-usd provisioned" in log and "data feed btc-usd: published" in log and pub > 0,
          f"config data_feeds: the keeper provisions registrai-data:btc-usd ({feed[:10]}…, independent resolver) and "
          f"publishes {pub / 100:,.2f} from the Coinbase stand-in", log[-2500:])
    check(agent_bond(feed) == 5 * min_bond(feed) and agent_bond(V["fA"]) == 5 * min_bond(V["fA"])
          and "oracle: topUpBond" in log,
          f"bond health: the data feed and the milestone feed are bonded at 5x minBond "
          f"({agent_bond(feed) / U:.0f} USDC), so one challenge can no longer freeze them", log[-2500:])

    # a common market on it, opened by a community member; our agent is its (approved) agent
    expiry = ((c.now() // 3600) + 2) * 3600                      # on the hour
    thr = scaled(expiry) - 1                                     # YES iff the price as of expiry >= thr
    for who, amt in (("bob", 20), ("alice", 10)):
        c.send(who, USDC, "approve(address,uint256)", S["NanoLedger"], amt * U)
        c.send(who, S["NanoLedger"], "deposit(uint256)", amt * U)
        c.send(who, S["NanoLedger"], "approveSpender(address,uint256)", V4, 2**256 - 1)
    r = json.loads(c.send("bob", V4, "createMarket(bytes32,address,int256,uint8,uint256,uint256)",
                          feed, OP, thr, 1, expiry, 5 * U).stdout)
    mid = [l for l in r["logs"] if l["address"].lower() == V4.lower() and len(l["topics"]) == 4][0]["topics"][1]
    q = c.call(V4, "quoteBuy(bytes32,uint8,uint256)(uint256,uint256)", mid, 0, 3 * U).splitlines()[0].split()[0]
    c.send("alice", V4, "buy(bytes32,uint8,uint256,uint256,uint256)", mid, 0, 3 * U, q, 2**256 - 1)
    keeper_tick_full()                                           # discovered while trading: nothing to do yet

    c.warp_to(expiry + 5)
    log = keeper_tick_full()
    want = scaled(expiry)
    check(f"settle: attest {feed.lower()} {want}" in log.lower() and f"as of {expiry}" in log,
          f"MarketsV4: the keeper discovers the common market and attests BTC as of its expiry ({want / 100:,.2f}, "
          f"the close of the minute ending at {expiry})", log[-2500:])
    n = c.uint(ATT, "historyLength(bytes32,address)(uint256)", feed, OP)
    att = None
    for i in range(n):
        a = c.call(ATT, "historyAt(bytes32,address,uint256)(bytes32)", feed, OP, i).strip()
        ts = int(c.call(ATT, "getAttestation(bytes32)((bytes32,address,int256,uint256,bytes32,bytes32,uint8,uint256))",
                        a).strip("()").split(",")[3].split()[0])
        if ts >= expiry:
            att = a; break
    stake = c.uint(DISP, "challengeStake(bytes32)(uint256)", att)
    c.send("watcher", USDC, "approve(address,uint256)", DISP, stake)
    ch = json.loads(c.send("watcher", DISP, "challenge(bytes32,bytes32)", att, "0x" + "ab" * 32).stdout)
    did = [l for l in ch["logs"] if l["address"].lower() == DISP.lower()][0]["topics"][1]
    log = keeper_tick_full()
    check("CHALLENGED" in log and f"preimage: feed {feed.lower()} value {want} as of {expiry}" in log.lower()
          and "coinbase:btc-usd:1m-close@" in log.lower() and "FROZEN" not in log,
          "dispute watch: the challenge is ALERTed at once with the reading's preimage (the resolver can recompute its "
          "input hash); the feed is NOT frozen (4x minBond still free)", log[-2500:])
    c.send("resolver", DISP, "resolve(bytes32,uint8)", did, 1)          # AttestationValid
    c.increase_time(61)                    # a read market is rechecked at most once a minute (RPC budget)
    log = keeper_tick_full()
    check("ruled VALID" in log and f"settle: resolve {mid.lower()}" in log.lower(),
          "the ruling (VALID) is reported, and the keeper resolves the common market on the upheld reading", log[-2500:])
    phase = c.call(V4, "getMarket(bytes32)((bytes32,address,int256,uint8,uint256,address,uint256,uint256,uint8,bool,uint256))",
                   mid).strip("()").split(",")
    check(phase[8].strip() == "1" and phase[9].strip() == "true", "MarketsV4 market Resolved, YES (price >= threshold)")
    c.send("alice", V4, "redeem(bytes32)", mid)
    c.send("bob", V4, "claimLP(bytes32)", mid)
    log = keeper_tick_full()
    check(c.uint(V4, "claimsLeft(bytes32)(uint256)", mid) == 0 and c.uint(V4, "unpaid(bytes32)(uint256)", mid) == 0
          and led(V4) == 0 and "tick done" in log,
          "every claimant claimed; resolve left no dust to sweep; MarketsV4 holds nothing")
    srv.shutdown()


def rounds_stage(c, A, S, led):
    """Common-markets launch: 5-minute Up/Down price rounds and an event market,
    run by the REAL rounds agent (keeper/rounds.py, its own key) against the
    deployed MarketsV4 and a Coinbase stand-in."""
    print("== 12c. common markets: 5-minute Up/Down rounds + an event market (keeper/rounds.py)")
    import rounds as R
    V4, REG, ATT, AG = S["MarketsV4"], S["Registry"], S["Attestation"], A["rounds"]
    MT = "(bytes32,address,int256,uint8,uint256,address,uint256,uint256,uint8,bool,uint256)"
    mk = lambda mid: c.call(V4, f"getMarket(bytes32)({MT})", mid).strip("()").split(",")
    root = pathlib.Path(tempfile_mod.mkdtemp(prefix="rounds-e2e-"))
    srv, port = serve(root)
    down = set()
    def btc(t0):   # minute t0's close: moves differently each 5 minutes, so rounds go Up and Down
        return 80000 + [0, 150, 310, 120, 90, 400][(t0 // 300) % 6] + (t0 // 60 % 5) / 100
    def eth(t0):
        return 2600 + (t0 // 60 % 50) / 10
    def write_candles():
        now = c.now()
        for prod, fn in (("BTC-USD", btc), ("ETH-USD", eth)):
            f = root / f"products/{prod}/candles"; f.parent.mkdir(parents=True, exist_ok=True)
            start = (now // 60) * 60
            # as on Coinbase: every closed minute AND the minute still trading, whose
            # provisional close differs from its final one (the agent must never read it)
            rows = [] if prod in down else [[t, fn(t), fn(t), fn(t), fn(t), 1.0] for t in range(start - 60, start - 7200, -60)]
            if prod not in down:
                rows.insert(0, [start, 0, 0, 0, fn(start) + 777, 1.0])
            f.write_text(json.dumps(rows))
    close = lambda fn, b: int(round(fn(b - 60) * 100))          # the close of the minute ending at boundary b
    c.send("admin", V4, "setApprovedAgent(address,bool)", AG, "true")
    base = f"http://127.0.0.1:{port}"
    first = (c.now() // 300 + 2) * 300
    ev_expiry = first + 1500
    cfg = {"rpc": c.rpc, "markets_v4_addr": V4, "attestation_addr": ATT, "oracle_registry_addr": REG,
           "ledger_addr": S["NanoLedger"], "usdc_addr": USDC, "agent_addr": AG, "feed_resolver": A["resolver"],
           "dispute_window": 600, "seed": 5 * U, "round_secs": 300, "settlement_window": SETTLEMENT_WINDOW,
           "markets_v4_deploy_block": c.block(),
           # the providers' quiet-book fallback runs on CHAIN time here (anvil is warped)
           "assets": [{"key": "btc-usd", "kind": "coinbase-spot", "product": "BTC-USD", "decimals": 2, "apiBase": base,
                       "_clock": c.now},
                      {"key": "eth-usd", "kind": "coinbase-spot", "product": "ETH-USD", "decimals": 2, "apiBase": base,
                       "_clock": c.now}],
           "events": [{"key": "arc-token-tradable", "kind": "curated", "value": 1, "since": None, "evidence": "",
                       "expiry": ev_expiry, "threshold": 1, "seed": 10 * U, "publishEvery": 3600, "disputeWindow": 600}]}
    chain = R.CastRoundsChain(cfg, KEYS["rounds"])
    provs = R.build_providers(cfg)
    state, all_alerts = {}, []
    def tick_at(t):
        c.warp_to(t)
        write_candles()
        acts, alerts = R.tick(cfg, chain, state, provs)
        all_alerts.extend(alerts)
        return acts, alerts

    # boundary b0: feeds, the event market, and the first round to bet on: [b1, b2]
    b0 = first
    b1, b2, b3 = b0 + 300, b0 + 600, b0 + 900
    btc_a, eth_a = cfg["assets"]
    n = R.feed_count(cfg)
    acts, alerts = tick_at(b0 + 5)
    ck1 = R.change_key(btc_a, b1, 300, n)
    fb1, fev = state["feeds"][ck1], state["feeds"]["arc-token-tradable"]
    feed_t = "(address,string,bytes32,uint256,uint256,address,uint256,bool)"
    fbw = c.call(REG, f"getFeed(bytes32)({feed_t})", fb1).strip("()").split(",")
    changes = [k for k in state["feeds"] if ":5m-" in k]
    check(n == 13 and len(changes) == 2 * n and int(fbw[-4].split()[0]) == 600
          and fbw[-3].strip().lower() == A["resolver"].lower() and "registrai-data:btc-usd-5m-change-" in fbw[1],
          f"the rounds agent provisions {n} rotating 5-minute CHANGE feeds per asset (a feed is reused only after its "
          f"last round's 1-hour settlement window): 10-minute challenge window, independent resolver", fbw)
    r1 = {st_["key"]: mid for mid, st_ in state["own"].items() if st_["expiry"] == b1}
    m1 = mk(r1["btc-usd"])
    check(set(r1) == {"btc-usd", "eth-usd"} and m1[2].strip() == "0" and int(m1[4].split()[0]) == b1
          and m1[3].strip() == "0" and m1[1].strip().lower() == AG.lower() and m1[0].strip().lower() == fb1,
          "at b0 the agent opens the NEXT round [b1, b2]: betting until b1 (its expiry), 'change > 0?' on the "
          "round's own change feed, our agent settles it", m1)
    try:
        provs[ck1](b1)
        unknowable = False
    except Exception as e:
        unknowable = getattr(e, "not_yet", False)
    check(unknowable, "while betting is open the round's change cannot even be computed (its start minute is in the future)")
    evm = state["events"]["arc-token-tradable"]["market"]
    check(evm and int(mk(evm)[4].split()[0]) == ev_expiry and alerts == [],
          "the event market opens once: 'Arc token publicly tradable before <expiry>?' (>= 1), seeded 10 USDC", alerts)

    # pre-settlement trading on the BTC round: both sides, a partial exit, all before b1
    mid = r1["btc-usd"]
    for who, amt in (("alice", 30), ("bob", 30)):
        c.send(who, USDC, "approve(address,uint256)", S["NanoLedger"], amt * U)
        c.send(who, S["NanoLedger"], "deposit(uint256)", amt * U)
        c.send(who, S["NanoLedger"], "approveSpender(address,uint256)", V4, 2**256 - 1)
    q_up = c.call(V4, "quoteBuy(bytes32,uint8,uint256)(uint256,uint256)", mid, 0, 8 * U).splitlines()[0].split()[0]
    c.send("alice", V4, "buy(bytes32,uint8,uint256,uint256,uint256)", mid, 0, 8 * U, q_up, 2**256 - 1)
    q_dn = c.call(V4, "quoteBuy(bytes32,uint8,uint256)(uint256,uint256)", mid, 1, 6 * U).splitlines()[0].split()[0]
    c.send("bob", V4, "buy(bytes32,uint8,uint256,uint256,uint256)", mid, 1, 6 * U, q_dn, 2**256 - 1)
    c.warp_to(b0 + 200)
    half = int(q_up) // 2
    q_sell = c.call(V4, "quoteSell(bytes32,uint8,uint256)(uint256,uint256)", mid, 0, half).splitlines()[0].split()[0]
    before = led(A["alice"])
    c.send("alice", V4, "sell(bytes32,uint8,uint256,uint256,uint256)", mid, 0, half, q_sell, 2**256 - 1)
    check(led(A["alice"]) - before == int(q_sell) > 0,
          f"before betting closes: alice buys UP, bob buys DOWN at the quotes, alice sells half her UP at "
          f"{int(q_sell)/U:.4f} = quoteSell (pre-settlement exit through the AMM)")
    c.send("bob", V4, "buy(bytes32,uint8,uint256,uint256,uint256)", r1["eth-usd"], 0, 5 * U, 0, 2**256 - 1)

    # one-click betting: alice grants a session key once; it bets FOR her with no signature of hers
    c.send("alice", V4, "setSession(address,uint128,uint64)", A["session"], 3 * U, c.now() + 86400, "--value", "0.1ether")
    no_before, led_before = c.uint(V4, "noBalance(bytes32,address)(uint256)", mid, A["alice"]), led(A["alice"])
    c.send("session", V4, "buyFor(address,bytes32,uint8,uint256,uint256,uint256)", A["alice"], mid, 1, 2 * U, 0, 2**256 - 1)
    over = c.fails_with("session", V4, "buyFor(address,bytes32,uint8,uint256,uint256,uint256)", A["alice"], mid, 1, 2 * U, 0, 2**256 - 1)
    check(c.uint(V4, "noBalance(bytes32,address)(uint256)", mid, A["alice"]) > no_before
          and led(A["alice"]) == led_before - 2 * U and led(A["session"]) == 0
          and reverted_with(over, "SessionSpendExceeded"),
          "one-click session: alice signs once (setSession, gas forwarded to the key); the key buys DOWN for her "
          "(her balance pays, her shares), holds nothing itself, and stops at the 3 USDC cap", over[-200:])

    # b1: betting on [b1, b2] closes as the round starts; the next round opens
    down.add("ETH-USD")                        # the ETH source goes down from here: its round cannot settle
    acts, alerts = tick_at(b1 + 5)
    late_buy = c.fails_with("alice", V4, "buy(bytes32,uint8,uint256,uint256,uint256)", mid, 0, 1 * U, 0, 2**256 - 1)
    late_sell = c.fails_with("alice", V4, "sell(bytes32,uint8,uint256,uint256,uint256)", mid, 0, 1000, 0, 2**256 - 1)
    check(reverted_with(late_buy, "MarketExpired") and reverted_with(late_sell, "MarketExpired"),
          "from b1 the round is in play and nobody can trade it: buy and sell revert MarketExpired", late_buy[-200:])
    r2 = {st_["key"]: m for m, st_ in state["own"].items() if st_["expiry"] == b2}
    check(set(r2) == {"btc-usd"} and mk(r2["btc-usd"])[0].strip().lower() != fb1
          and not any(st_["key"] == "eth-usd" and st_["expiry"] == b2 for st_ in state["own"].values()),
          "the next round [b2, b3] opens on ANOTHER change feed; ETH source down: no new ETH round", (r2, alerts))
    found = c.call(ATT, "firstInWindow(bytes32,address,uint256,uint256)(bool,int256,uint256,bool)", fb1, AG, b1,
                   b1 + SETTLEMENT_WINDOW).splitlines()
    check(found[0] == "false", "mid-round there is no reading on the round's feed: nothing to settle on yet")

    # b2: the round ended; the agent attests its CHANGE on its own feed
    tick_at(b2 + 5)
    found = c.call(ATT, "firstInWindow(bytes32,address,uint256,uint256)(bool,int256,uint256,bool)", fb1, AG, b1,
                   b1 + SETTLEMENT_WINDOW).splitlines()
    chg = close(btc, b2) - close(btc, b1)
    check(found[0] == "true" and int(found[1].split()[0]) == chg and int(found[2].split()[0]) >= b2,
          f"at b2 the agent attests round [b1, b2]'s change on its feed: {close(btc, b2)/100:,.2f} - "
          f"{close(btc, b1)/100:,.2f} = {chg/100:+,.2f}", found)
    f2 = mk(r2["btc-usd"])[0].strip()
    found2 = c.call(ATT, "firstInWindow(bytes32,address,uint256,uint256)(bool,int256,uint256,bool)", f2, AG, b2,
                    b2 + SETTLEMENT_WINDOW).splitlines()
    check(found2[0] == "false", "and the round in play now ([b2, b3], betting closed at b2) has no reading yet")
    acts, alerts = tick_at(b2 + 5 + 600 + 5)   # the reading is final after its 10-minute window
    up_won = chg > 0
    m1 = mk(mid)
    check(m1[8].strip() == "1" and (m1[9].strip() == "true") == up_won and ("resolve", mid) in acts,
          f"~10 minutes after the round ended, the agent resolves it: {'UP' if up_won else 'DOWN'} ({chg/100:+,.2f})", acts)
    winner = "alice" if up_won else "bob"
    owed = c.uint(V4, "redeemable(bytes32,address)(uint256)", mid, A[winner])
    before = led(A[winner])
    c.send(winner, V4, "redeem(bytes32)", mid)
    check(owed > 0 and led(A[winner]) - before == owed, f"{winner} redeems {owed/U:.4f} USDC (1 per winning share)")
    check(state["own"][mid]["lpClaimed"] and any(a[0] == "claimLP" and a[1] == mid for a in acts),
          "the agent takes its seed liquidity back from the settled round (claimLP) for the next rounds")

    # the event: it happens before its deadline; the market settles YES as of expiry
    cfg["events"][0].update({"since": c.now(), "evidence": "https://example.com/arc-token-listing"})
    c.send("alice", V4, "buy(bytes32,uint8,uint256,uint256,uint256)", evm, 0, 4 * U, 0, 2**256 - 1)
    tick_at(ev_expiry + 5)
    tick_at(ev_expiry + 620)
    e = mk(evm)
    check(e[8].strip() == "1" and e[9].strip() == "true",
          "event market: the curated value (1, with its evidence URL) as of the deadline settles it YES")

    # the ETH round with the source down all window long: it voids, traders get their net cost back
    eth_mid = r1["eth-usd"]
    tick_at(b1 + SETTLEMENT_WINDOW * 4 // 5)   # past 3/4 of the window: the agent alerts
    acts, alerts = tick_at(b1 + SETTLEMENT_WINDOW + 10)
    check(mk(eth_mid)[8].strip() == "2" and ("void", eth_mid) in acts
          and any(eth_mid in a and "no reading" in a for a in all_alerts),
          "ETH source down for the whole settlement window: the round voids (and the agent ALERTed while it could act)",
          all_alerts[-5:])
    refund = c.uint(V4, "redeemable(bytes32,address)(uint256)", eth_mid, A["bob"])
    before = led(A["bob"])
    c.send("bob", V4, "redeem(bytes32)", eth_mid)
    check(refund == 5 * U - 5 * U // 100 and led(A["bob"]) - before == refund,
          f"bob's ETH position is refunded its net cost ({refund/U:.2f} = 5 less the 1% fee)")
    down.discard("ETH-USD")
    tick_at(c.now() + 30)
    tick_at(c.now() + 700)                     # past the 10-minute challenge window of the last readings
    settled_by = c.now() - 900                 # expired + read + 10-minute window: must be settled by now
    old = [m for m, st_ in state["own"].items() if st_["expiry"] < settled_by]
    left = [m for m in old if not state["own"][m]["lpClaimed"]]
    check(old and not left,
          f"all {len(old)} rounds old enough to be final are settled and the agent took back every seed", left)
    srv.shutdown()


def season_stage(c, A, S, V, led, unallocated, pool_expected, reverted_with):
    print("== 12. a season: the pool (taxes + void escrow + frozen sweep) -> season-rewards -> Safe publish -> claim")
    POOL, vid = S["SeasonPool"], V["vid"]
    total = unallocated()
    check(total == pool_expected["v"] == led(POOL) and total > 0,
          f"the SeasonPool holds {total/U:.6f} USDC, all unallocated: void escrow + frozen income + progressive tax")
    out_dir = pathlib.Path(tempfile_mod.mkdtemp(prefix="season-"))
    r = run(["npx", "--yes", "tsx", "scripts/season-rewards.ts", "--network", "local", "--rpc", c.rpc, "--season", "1",
             "--total", f"{total // U}.{total % U:06d}", "--from-block", str(V["season_from"]), "--to-block", str(V["season_to"]),
             "--markets", S["MarketsPerennial"], "--builder-registry", S["BuilderRegistry"], "--caretaker-registry", S["CaretakerRegistry"],
             "--badge", S["VerifiedBuilderBadge"], "--operator", A["operator"], "--from-deploy-block", "0", "--out", str(out_dir)],
            cwd=FRONTEND, ok=False)
    if r.returncode != 0:
        raise SystemExit(f"season-rewards failed:\n{r.stdout[-2000:]}\n{r.stderr[-2000:]}")
    f = json.loads((out_dir / "season-1.json").read_text())
    safe = json.loads((out_dir / "season-1.safe.json").read_text())
    rows = {int(b["builderId"]): b for b in f["builders"]}
    cap = total * 2000 // 10_000
    row = rows.get(vid) or {}
    mk = {m["marketId"].lower(): m for m in row.get("markets", [])}
    check(list(rows) == [vid] and f["eligible"] == [vid] and int(row["amount"]) == cap and row["capped"]
          and int(f["total"]) == total,
          f"season-rewards: only builder #{vid} is eligible (badge verified, ours); its share is capped at 20% ({cap/U:.6f})",
          json.dumps(f)[:1500])
    check(V["M9"].lower() in mk and int(mk[V["M9"].lower()]["volume"]) == V["m9_volume"] >= 500 * U,
          f"its points come from M9 (resolved YES in the window): counted volume {V['m9_volume']/U:,.2f} USDC — positions "
          f"HELD by non-builder traders; the whale's {V['m9_wash']/U:,.2f} USDC of same-day round trips count 0 (rule v2)")
    tx = safe["transactions"][0]
    check(len(safe["transactions"]) == 1 and tx["to"].lower() == POOL.lower(), "the Safe file is one publishSeason call to the SeasonPool")
    check(c.fails_with("operator", POOL, "publishSeason(uint256,bytes32,uint256,uint64)", 1, f["root"], total, int(f["deadline"])) != "",
          "only the Safe (GOVERNOR) can publish a season")
    run(["cast", "send", tx["to"], tx["data"], "--rpc-url", c.rpc, "--private-key", KEYS["admin"]])
    season = c.call(POOL, "seasons(uint256)(bytes32,uint256,uint256,uint64,bool)", 1).splitlines()
    check(season[0].strip().lower() == f["root"].lower() and int(season[1].split()[0]) == total and unallocated() == 0
          and c.uint(POOL, "reserved()(uint256)") == total,
          "ADMIN sends the Safe file's calldata: season 1 published (root, total reserved, nothing left unallocated)")
    proof = "[" + ",".join(row["proof"]) + "]"
    err = c.fails_with("stranger", POOL, "claim(uint256,uint256,uint256,bytes32[])", 1, vid, cap + 1, proof)
    check(reverted_with(err, "AboveCap"), "claiming more than 20% of the season total reverts (AboveCap)", err[-200:])
    before = led(A["vrecovered"])
    c.send("stranger", POOL, "claim(uint256,uint256,uint256,bytes32[])", 1, vid, cap, proof)
    check(led(A["vrecovered"]) - before == cap, f"anyone claims builder #{vid}'s season reward with its proof: {cap/U:.6f} to its payout")
    pool_expected["v"] -= cap
    err = c.fails_with("stranger", POOL, "claim(uint256,uint256,uint256,bytes32[])", 1, vid, cap, proof)
    check(reverted_with(err, "AlreadyClaimed"), "a second claim reverts (AlreadyClaimed)", err[-200:])


if __name__ == "__main__":
    main()
