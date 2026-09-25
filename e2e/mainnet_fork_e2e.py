#!/usr/bin/env python3
"""
END-TO-END TEST OF THE MAINNET BUILDER SIDE ON A LOCAL FORK OF ARC MAINNET.

    python3 contracts/e2e/mainnet_fork_e2e.py [--skip-bytecode]   (needs anvil, cast, forge, node/npx)

Forks Arc mainnet (chain 5042) at the latest block with anvil and drives the REAL
phase-1 deployment (BuilderRegistry, CaretakerRegistry, VerifiedBuilderBadge as
deployed at block 22642042), the REAL keeper (keeper/builders_keeper.py, with the
addresses of keeper/config.arc-mainnet-builders.json) and the REAL website
libraries (claim signing, proof validation, scripts/onboard-batch.ts --network
mainnet, the /builders gallery live overlay and the /admin queue + Safe files).

Nothing is ever sent to the real mainnet: anvil reads mainnet state lazily and
every transaction here goes to the fork's http://127.0.0.1:<port> (run() refuses
any cast network command whose --rpc-url is not the fork or the local signing
oracle, and ETH_RPC_URL is never passed on).

Roles on the fork:
  - the ADMIN Safe, the ONBOARDER and the OPERATOR are impersonated
    (anvil_impersonateAccount, funded with anvil_setBalance);
  - builders are fresh random keys;
  - the keeper signs with a fresh test key that the impersonated Safe grants
    STATUS_ROLE on the fork's badge (the real operator key is not here); the
    keeper's OPERATOR stays the real 0xe528… (the caretaker every onboarding
    batch sets), so statuses are exactly mainnet's;
  - claims are signed by scripts/e2e-perennial.ts `claim` (the /verify code) on a
    separate throwaway anvil (31337) used only as a signing oracle: that driver
    refuses every chain but 31337, and it stays that way.

Proof hosting: local stand-ins for raw.githubusercontent.com and for the builder
domains 127.0.0.1 / localhost (one server, dispatched on the Host header), via the
keeper's and the site's explicit test overrides (PROOF_GITHUB_BASE,
PROOF_DOMAIN_SCHEME=http, PROOF_DOMAIN_PORT). The gallery harness reads them
through the page's own direct-read path with a fetch that maps only those URLs.

Exit status: 0 when every check passed, 1 otherwise.
"""
import base64, datetime, functools, http.server, json, os, pathlib, re, secrets, shutil, socket
import subprocess, sys, tempfile, threading, time

HERE = pathlib.Path(__file__).resolve().parent
CONTRACTS = HERE.parent
ARC = CONTRACTS.parent
FRONTEND = ARC / "frontend"
KEEPER = ARC / "keeper"
sys.path.insert(0, str(KEEPER))

MAINNET_RPC = "https://rpc.mainnet.arc.io"
CHAIN_ID = 5042
CFG_PATH = KEEPER / "config.arc-mainnet-builders.json"
CFG = json.loads(CFG_PATH.read_text())
DEPLOYMENT = json.loads((CONTRACTS / "deployments" / "arc-mainnet-builders.json").read_text())
SITE_DEPLOYMENT = json.loads((FRONTEND / "src" / "lib" / "deployments" / "arc-mainnet.json").read_text())

BR, CR, BADGE = CFG["registry_addr"], CFG["caretaker_registry_addr"], CFG["badge_addr"]
OPERATOR = CFG["operator_addr"]
SAFE = DEPLOYMENT["roles"]["admin_safe_2of3"]
ONBOARDER = DEPLOYMENT["roles"]["onboarder_issuer_governor"]
DEPLOYER = DEPLOYMENT["roles"]["deployer_holds_nothing"]
ZERO32 = "0x" + "00" * 32
ZERO = "0x" + "00" * 20
FUND = hex(1_000 * 10**18)            # 1,000 USDC of native gas (18 decimals on Arc)
RECOVERY_DELAY = 7 * 86400
TODAY = datetime.date.today().isoformat()

PASS, FAIL = [], []
LOCAL_RPCS = set()                    # the fork and the signing oracle, once started
NETWORK_CMDS = {"send", "call", "rpc", "code", "chain-id", "block", "block-number", "balance", "nonce", "logs",
                "receipt", "tx", "storage", "estimate", "publish", "mktx"}


def check(cond, what, detail=""):
    (PASS if cond else FAIL).append(what)
    print(("  ok   " if cond else "  FAIL ") + what + ("" if cond or not detail else f"  <- {str(detail)[-1500:]}"), flush=True)
    return bool(cond)


def _guard(cmd):
    """Never let a cast network command reach anything but a local anvil started here."""
    if not cmd or pathlib.Path(str(cmd[0])).name != "cast":
        return
    sub = str(cmd[1]) if len(cmd) > 1 else ""
    if sub == "wallet" or sub not in NETWORK_CMDS:
        return
    args = [str(a) for a in cmd]
    if "--rpc-url" not in args:
        raise SystemExit(f"REFUSED (no --rpc-url, cast would pick a default): {' '.join(args)[:200]}")
    url = args[args.index("--rpc-url") + 1]
    if url not in LOCAL_RPCS or not url.startswith("http://127.0.0.1:"):
        raise SystemExit(f"REFUSED: cast {sub} to {url}, which is not a local anvil started by this test")


SCRUB = ("ETH_RPC_URL", "ETH_FROM", "ETH_KEYSTORE", "ETH_KEYSTORE_ACCOUNT", "ETH_PASSWORD", "PRIVATE_KEY",
         "CARETAKER_PRIVATE_KEY", "SOCIAL_PRIVATE_KEY", "MAINNET_OPERATOR_PRIVATE_KEY", "MAINNET_OPERATOR_KEYSTORE",
         "MAINNET_OPERATOR_PASSWORD_FILE", "BUILDERS_PRIVATE_KEY", "BUILDERS_ENV_FILE", "BUILDERS_CONFIG", "CHAIN", "ETH_CHAIN",
         "BADGE_LAPSE_TICKS", "PROOF_GITHUB_BASE", "PROOF_DOMAIN_SCHEME", "PROOF_DOMAIN_PORT", "GITHUB_API_BASE",
         "BUILDERS_PREFLIGHT_ONLY", "RPC", "OPERATOR", "BUILDER_REGISTRY", "CARETAKER_REGISTRY", "VERIFIED_BADGE", "CHAIN_ID")


def clean_env(extra=None):
    env = {k: v for k, v in os.environ.items() if k not in SCRUB}
    env.update(extra or {})
    return env


def run(cmd, env=None, cwd=None, ok=True, timeout=900):
    _guard(cmd)
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True, env=clean_env(env), cwd=cwd, timeout=timeout)
    if ok and r.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(map(str, cmd))[:300]}\n{r.stdout[-2500:]}\n{r.stderr[-2500:]}")
    return r


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close()
    return p


def keccak(s):
    return run(["cast", "keccak", s]).stdout.strip()


def selector(sig):
    return run(["cast", "sig", sig]).stdout.strip()


def reverted_with(text, name):
    return bool(text) and (name in text or selector(f"{name}()")[2:] in text.lower())


def addr_of(key):
    return run(["cast", "wallet", "address", "--private-key", key]).stdout.strip()


def new_key():
    return "0x" + secrets.token_hex(32)


class Anvil:
    def __init__(self, fork=False):
        self.port = free_port()
        self.rpc = f"http://127.0.0.1:{self.port}"
        LOCAL_RPCS.add(self.rpc)
        cmd = ["anvil", "--port", str(self.port), "--silent"]
        if fork:
            cmd += ["--fork-url", MAINNET_RPC, "--chain-id", str(CHAIN_ID)]
        self.proc = subprocess.Popen(cmd, env=clean_env())
        want = str(CHAIN_ID if fork else 31337)
        for _ in range(240):
            if run(["cast", "chain-id", "--rpc-url", self.rpc], ok=False).stdout.strip() == want:
                break
            time.sleep(0.25)
        else:
            raise SystemExit(f"anvil did not come up on {self.rpc}")
        self.info = json.loads(self.cast("rpc", "anvil_nodeInfo").stdout)

    def cast(self, *a, ok=True):
        return run(["cast", *a, "--rpc-url", self.rpc], ok=ok)

    def call(self, to, sig, *args):
        return self.cast("call", to, sig, *map(str, args)).stdout.strip()

    def uint(self, to, sig, *args):
        return int(self.call(to, sig, *args).split()[0])

    def fails_as(self, who, to, sig, *args):
        """eth_call as `who`: the revert text, or "" when it would succeed."""
        r = self.cast("call", to, sig, *map(str, args), "--from", who, ok=False)
        return "" if r.returncode == 0 else (r.stderr + r.stdout)

    def fund(self, who):
        self.cast("rpc", "anvil_setBalance", who, FUND)

    def impersonate(self, who):
        self.cast("rpc", "anvil_impersonateAccount", who)
        self.fund(who)

    def _receipt(self, r):
        try:
            d = json.loads(r.stdout)
        except ValueError:
            return None
        return d

    def send_as(self, who, to, sig, *args, ok=True):
        r = self.cast("send", to, sig, *map(str, args), "--from", who, "--unlocked", "--json", ok=ok)
        return self._receipt(r) if r.returncode == 0 else None

    def send_data_as(self, who, to, data, ok=True):
        r = self.cast("send", to, data, "--from", who, "--unlocked", "--json", ok=ok)
        return self._receipt(r) if r.returncode == 0 else None

    def send_key(self, key, to, sig, *args, ok=True):
        r = self.cast("send", to, sig, *map(str, args), "--private-key", key, "--json", ok=ok)
        return self._receipt(r) if r.returncode == 0 else None

    def increase_time(self, secs):
        self.cast("rpc", "evm_increaseTime", str(secs))
        self.cast("rpc", "evm_mine")

    def close(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()


# ─────────────────────────────── proof stand-ins ───────────────────────────────

class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a, **k):
        pass


def serve_dir(d):
    d.mkdir(parents=True, exist_ok=True)
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=str(d)))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, srv.server_address[1]


def serve_domains(root):
    """One server for the builder domains, dispatched on the Host header: <root>/<host>/..."""
    root.mkdir(parents=True, exist_ok=True)

    class ByHost(Quiet):
        def translate_path(self, path):
            host = (self.headers.get("Host") or "").rsplit(":", 1)[0].lower()
            self.directory = str(root / host) if host in ("127.0.0.1", "localhost") else str(root / "_none")
            return super().translate_path(path)
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(ByHost, directory=str(root)))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, srv.server_address[1]


# ───────────────────────────────── the test ─────────────────────────────────

def main():
    for tool in ("anvil", "forge", "cast", "node", "npx"):
        if not shutil.which(tool):
            raise SystemExit(f"missing tool: {tool}")
    skip_bytecode = "--skip-bytecode" in sys.argv
    print(f"== forking Arc mainnet ({MAINNET_RPC}) with anvil, chain id {CHAIN_ID}")
    fork = Anvil(fork=True)
    oracle = Anvil(fork=False)
    servers = []
    try:
        T = Test(fork, oracle, servers)
        T.run(skip_bytecode)
    except SystemExit as e:
        if e.code not in (None, 0):
            check(False, f"aborted: {e}")
    except Exception as e:  # an unexpected error is a failure, reported like one
        import traceback
        traceback.print_exc()
        check(False, f"aborted: {type(e).__name__}: {str(e)[:400]}")
    finally:
        for s in servers:
            s.shutdown()
        fork.close()
        oracle.close()
    print(f"\n{len(PASS)} checks passed, {len(FAIL)} failed")
    for f in FAIL:
        print(f"  FAILED: {f}")
    sys.exit(1 if FAIL else 0)


class Test:
    def __init__(self, fork, oracle, servers):
        self.c, self.oracle, self.servers = fork, oracle, servers
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="mainnet-fork-e2e-"))
        self.kdir = self.root / "keeper-state"
        self.batches = 0
        self.seen = {}           # builder id -> every keeper status seen for it
        self.batched = set()     # builder ids any onboarding batch ever touched
        self.K, self.A = {}, {}  # name -> key / address

    # ── actors ──
    def actor(self, name):
        self.K[name] = new_key()
        self.A[name] = addr_of(self.K[name])
        self.c.fund(self.A[name])
        return self.A[name]

    # ── website driver (signing oracle) ──
    def site(self, action, **kw):
        z = "0x0000000000000000000000000000000000000001"
        payload = {"rpc": self.oracle.rpc, "contracts": {"NanoLedger": z, "BuilderRegistry": BR, "MarketsPerennial": z,
                                                          "CaretakerRegistry": CR, "USDC": z},
                   "operator": OPERATOR, "action": action, **kw}
        r = run(["npx", "--yes", "tsx", "scripts/e2e-perennial.ts", json.dumps(payload)], cwd=FRONTEND, ok=False)
        line = (r.stdout.strip().splitlines() or ["{}"])[-1]
        res = json.loads(line)
        if not res.get("ok"):
            raise RuntimeError(f"site {action} failed: {res}")
        return res

    def claim(self, owner, source, deployers=(), deployer_keys=(), country="PL"):
        c = {"builder": self.A[owner].lower(), "source": source, "deployers": [self.A[d].lower() for d in deployers],
             "country": country, "chain": CHAIN_ID, "issued": TODAY}
        return self.site("claim", claim=c, builderKey=self.K[owner], deployerKeys=[self.K[d] for d in deployer_keys])["file"]

    def site_validate(self, file, source, owner_addr):
        return self.site("validateProof", file=file, expectedSource=source, onchainOwner=owner_addr, chainId=CHAIN_ID)["result"]

    # ── gallery harness ──
    def gallery(self):
        payload = {"rpc": self.c.rpc, "action": "gallery", "githubBase": f"http://127.0.0.1:{self.gh_port}", "domainPort": self.dom_port}
        r = run(["npx", "--yes", "tsx", "scripts/e2e-builders-gallery.ts", json.dumps(payload)], cwd=FRONTEND, ok=False)
        res = json.loads((r.stdout.strip().splitlines() or ["{}"])[-1])
        if not res.get("ok"):
            raise RuntimeError(f"gallery harness failed: {res} {r.stderr[-800:]}")
        return {b["id"]: b for b in res["builders"]}, res["admin"]

    def harness(self, action, **kw):
        r = run(["npx", "--yes", "tsx", "scripts/e2e-builders-gallery.ts", json.dumps({"rpc": self.c.rpc, "action": action, **kw})],
                cwd=FRONTEND, ok=False)
        res = json.loads((r.stdout.strip().splitlines() or ["{}"])[-1])
        if not res.get("ok"):
            raise RuntimeError(f"harness {action} failed: {res}")
        return res

    # ── proofs on the stand-ins ──
    def proof_path(self, source):
        kind, _, rest = source.partition(":")
        if kind == "github":
            return self.root / "raw" / rest / "HEAD" / ".registrai.json"
        return self.root / "domains" / rest / ".well-known" / "registrai.json"

    def publish(self, source, file):
        p = self.proof_path(source)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(file))

    def unpublish(self, source):
        self.proof_path(source).unlink(missing_ok=True)

    # ── keeper ──
    def keeper_env(self, key):
        return {"RPC": self.c.rpc, "PRIVATE_KEY": key, "BUILDER_REGISTRY": BR, "CARETAKER_REGISTRY": CR,
                "VERIFIED_BADGE": BADGE, "OPERATOR": OPERATOR, "CHAIN_ID": str(CFG["chain_id"]),
                "BUILDERS_DATA_DIR": str(self.kdir), **self.proof_env}

    def tick(self, key=None, expect_rc=0):
        """One keeper tick. expect_rc=3: a tick whose operator sends fail must
        exit 3 (after 'tick done'), so run-keeper.sh reports it as failed."""
        r = run(["python3", "keeper/builders_keeper.py"], env=self.keeper_env(key or self.K["status"]), cwd=ARC, ok=False)
        out = r.stdout + r.stderr
        if r.returncode != expect_rc or "tick done" not in out:
            raise RuntimeError(f"keeper tick failed (rc {r.returncode}):\n{out[-3000:]}")
        return out

    def keeper_statuses(self):
        """The keeper's own per-builder statuses (verified.scan_registry, what builders_keeper.py runs)."""
        import verified as kv
        os.environ.update(self.proof_env)
        try:
            recs = kv.scan_registry(BR, CR, OPERATOR, CHAIN_ID, rpc=self.c.rpc)
        finally:
            for k in self.proof_env:
                os.environ.pop(k, None)
        if recs is None:
            raise RuntimeError("keeper scan_registry could not read the fork")
        out = {r["id"]: r for r in recs}
        for i, r in out.items():
            self.seen.setdefault(i, set()).add(r["status"])
        return out

    def agree(self, step, ids):
        """The website's gallery overlay and the keeper agree on every builder in `ids`."""
        ks = self.keeper_statuses()
        g, admin = self.gallery()
        bad = []
        for i in ids:
            kst = ks.get(i, {}).get("status")
            row = g.get(i) or {}
            if kst != row.get("status"):
                bad.append(f"#{i} keeper {kst} gallery {row.get('status')}")
            kp = {p["id"]: p["status"] for p in ks.get(i, {}).get("projects", [])}
            gp = {p["id"]: p["status"] for p in row.get("projects", [])}
            # a deactivated builder: the keeper still grades its projects, the gallery shows them all inactive
            if kst != "inactive" and kp != gp:
                bad.append(f"#{i} projects keeper {kp} gallery {gp}")
            serial = self.c.uint(BADGE, "serialOf(uint256)(uint256)", i)
            gb = row.get("badge")
            if serial:
                shown = self.c.call(BADGE, "isLapsed(uint256)(bool)", serial) == "true"
                if not gb or gb["serial"] != serial or gb["lapsed"] != shown:
                    bad.append(f"#{i} badge chain No.{serial} lapsed={shown} gallery {gb}")
            elif gb:
                bad.append(f"#{i} gallery shows badge {gb} but serialOf is 0")
        summary = ", ".join(f"#{i} {ks.get(i, {}).get('status')}" for i in ids)
        check(not bad, f"{step}: gallery overlay == keeper ({summary})", "; ".join(bad))
        return ks, g, admin

    # ── onboarding batch (the real CLI, --network mainnet) ──
    def onboard_batch(self, *extra):
        self.batches += 1
        out = self.root / f"batch-{self.batches}"
        r = run(["npx", "--yes", "tsx", "scripts/onboard-batch.ts", "--network", "mainnet", "--rpc", self.c.rpc, "--out", str(out), *extra],
                env=self.proof_env, cwd=FRONTEND, ok=False)
        if r.returncode != 0:
            raise RuntimeError(f"onboard-batch failed:\n{r.stdout[-1500:]}\n{r.stderr[-2500:]}")
        safe = json.loads((out / "onboard-batch.safe.json").read_text())
        txs = [dict(t, call=self.decode(t)) for t in safe["transactions"]]
        for t in txs:
            if t["call"][0] in ("setCaretaker", "issue", "addProjectFor"):
                self.batched.add(int(t["call"][1][0]))
        return safe, txs, r.stderr

    SIGS = ("setCaretaker(uint256,address)", "issue(uint256)", "registerFor(address,string)", "addProjectFor(uint256,string)")

    def decode(self, t):
        sel = t["data"][:10].lower()
        for sig in self.SIGS:
            if selector(sig).lower() == sel:
                vals = run(["cast", "decode-calldata", sig, t["data"]]).stdout.strip().splitlines()
                return sig.split("(")[0], [v.strip().strip('"') for v in vals]
        return "?", []

    def badge_json(self, serial):
        uri = self.c.call(BADGE, "tokenURI(uint256)(string)", serial)
        uri = json.loads(uri) if uri.startswith('"') else uri
        head, _, b64 = uri.partition(",")
        if head != "data:application/json;base64":
            raise ValueError(f"unexpected tokenURI prefix {head!r}")
        return json.loads(base64.b64decode(b64).decode("utf-8"))   # strict: control chars in strings raise

    def builder_id(self, who):
        return self.c.uint(BR, "builderIdOf(address)(uint256)", self.A[who])

    def project_ids(self, bid):
        return [int(x) for x in re.findall(r"\d+", self.c.call(BR, "projectsOf(uint256)(uint256[])", bid))]

    # ───────────────────────────── stages ─────────────────────────────

    def run(self, skip_bytecode):
        c = self.c
        self.stage0_fork_and_config(skip_bytecode)
        self.stage1_roles_on_chain()
        self.stage2_wrapper_guards()
        self.stage3_setup()
        self.stage4_register()
        self.stage5_forgeries()
        self.stage6_cap()
        self.stage7_batch_onboarder()
        self.stage8_role_checks()
        self.stage9_batch_safe()
        self.stage10_lapse_restore()
        self.stage11_transfer()
        self.stage12_recovery()
        self.stage13_revoke()
        self.stage14_adversaries_final()

    def stage0_fork_and_config(self, skip_bytecode):
        c = self.c
        print("== 0. the fork and the shipped mainnet config")
        fc = c.info.get("forkConfig") or {}
        self.fork_block = int(fc.get("forkBlockNumber") or 0)
        check(c.info["environment"]["chainId"] == CHAIN_ID and fc.get("forkUrl") == MAINNET_RPC and self.fork_block > CFG["deploy_block"],
              f"anvil forks Arc mainnet at block {self.fork_block} (chain id {CHAIN_ID}); every tx below goes to {c.rpc}")
        sb = SITE_DEPLOYMENT["builders"]
        same = lambda a, b: str(a).lower() == str(b).lower()
        check(all(same(x, y) for x, y in ((BR, DEPLOYMENT["contracts"]["BuilderRegistry"]), (BR, sb["BuilderRegistry"]),
                                          (CR, DEPLOYMENT["contracts"]["CaretakerRegistry"]), (CR, sb["CaretakerRegistry"]),
                                          (BADGE, DEPLOYMENT["contracts"]["VerifiedBuilderBadge"]), (BADGE, sb["VerifiedBuilderBadge"]),
                                          (OPERATOR, DEPLOYMENT["roles"]["operator_keeper_badgeStatus"]), (OPERATOR, sb["operator"])))
              and CFG["deploy_block"] == DEPLOYMENT["deployBlock"] == sb["deployBlock"] and CFG["chain_id"] == CHAIN_ID
              and CFG["rpc"] == MAINNET_RPC,
              "keeper config, contracts deployment record and the site's arc-mainnet.json agree (addresses, operator, deploy block)")
        info = self.harness("info")
        check(info["network"] == "mainnet" and info["chainId"] == CHAIN_ID and same(info["contracts"]["BuilderRegistry"], BR)
              and same(info["contracts"]["CaretakerRegistry"], CR) and same(info["contracts"]["VerifiedBuilderBadge"], BADGE)
              and same(info["operator"], OPERATOR) and int(info["deployBlock"]) == CFG["deploy_block"] and info["badgesOn"]
              and info["imageBase"] == DEPLOYMENT["badge"]["imageBase"],
              "the website's BUILDERS resolves to mainnet with these contracts, operator, deploy block and badge art base", info)
        code = lambda a: c.cast("code", a).stdout.strip()
        check(all(code(a) not in ("", "0x") for a in (BR, CR, BADGE, SAFE)), "the three contracts and the Safe have code on the fork")
        check(c.call(BADGE, "BUILDERS()(address)").lower() == BR.lower() and c.call(CR, "BUILDERS()(address)").lower() == BR.lower(),
              "badge and caretaker registry are bound to the BuilderRegistry")
        check(c.call(BADGE, "chainLabel()(string)").strip('"') == DEPLOYMENT["badge"]["chainLabel"]
              and c.call(BADGE, "imageBase()(string)").strip('"') == DEPLOYMENT["badge"]["imageBase"]
              and c.call(BADGE, "externalBase()(string)").strip('"') == DEPLOYMENT["badge"]["externalBase"],
              f"badge metadata bases as recorded: {DEPLOYMENT['badge']['chainLabel']}, {DEPLOYMENT['badge']['imageBase']}")
        self.n0 = c.uint(BR, "nextId()(uint256)")
        self.s0 = c.uint(BADGE, "nextSerial()(uint256)")
        check(self.s0 == 1, f"no badge issued on mainnet yet: serials start at No. 001 on the fork (nextSerial {self.s0}, "
                            f"{self.n0 - 1} builder(s) registered)")
        if skip_bytecode:
            print("  (bytecode comparison skipped: --skip-bytecode)")
            return
        # the deployed bytecode is exactly src/ as built here (immutables masked); a separate out dir so a
        # concurrent `forge build` in contracts/ is not disturbed
        fdir = pathlib.Path(tempfile.gettempdir()) / "registrai-mainnet-fork-e2e-forge"
        run(["forge", "build", "--out", str(fdir / "out"), "--cache-path", str(fdir / "cache")], cwd=CONTRACTS, timeout=1800)
        for name, a in (("BuilderRegistry", BR), ("CaretakerRegistry", CR), ("VerifiedBuilderBadge", BADGE)):
            art = json.loads((fdir / "out" / f"{name}.sol" / f"{name}.json").read_text())
            want, live = bytearray.fromhex(art["deployedBytecode"]["object"][2:]), bytearray.fromhex(code(a)[2:])
            for refs in (art["deployedBytecode"].get("immutableReferences") or {}).values():
                for ref in refs:
                    for b in (want, live):
                        b[ref["start"]:ref["start"] + ref["length"]] = bytes(ref["length"])
            check(want == live, f"deployed {name} bytecode == src/perennial/{name}.sol built now ({len(live)} bytes, immutables masked)")

    def stage1_roles_on_chain(self):
        c = self.c
        print("== 1. the role table on the real deployment")
        R = {n: keccak(n) for n in ("REGISTRAR_ROLE", "GOVERNOR_ROLE", "ISSUER_ROLE", "STATUS_ROLE", "REVOKER_ROLE")}
        self.R = R
        has = lambda where, role, who: c.call(where, "hasRole(bytes32,address)(bool)", role, who) == "true"
        table = {BR: ("BuilderRegistry", (ZERO32, R["REGISTRAR_ROLE"])), CR: ("CaretakerRegistry", (ZERO32, R["GOVERNOR_ROLE"])),
                 BADGE: ("VerifiedBuilderBadge", (ZERO32, R["ISSUER_ROLE"], R["STATUS_ROLE"], R["REVOKER_ROLE"]))}
        held = {}
        for who, label in ((SAFE, "Safe"), (ONBOARDER, "onboarder"), (OPERATOR, "operator"), (DEPLOYER, "deployer")):
            held[label] = {(table[w][0], r) for w, (_, roles) in table.items() for r in roles if has(w, r, who)}
        name = {v: k for k, v in R.items()} | {ZERO32: "DEFAULT_ADMIN"}
        fmt = lambda s: sorted(f"{c_}.{name[r]}" for c_, r in s)
        check(held["Safe"] == {("BuilderRegistry", ZERO32), ("BuilderRegistry", R["REGISTRAR_ROLE"]), ("CaretakerRegistry", ZERO32),
                               ("CaretakerRegistry", R["GOVERNOR_ROLE"]), ("VerifiedBuilderBadge", ZERO32),
                               ("VerifiedBuilderBadge", R["ISSUER_ROLE"]), ("VerifiedBuilderBadge", R["REVOKER_ROLE"])},
              f"Safe holds {fmt(held['Safe'])}", fmt(held["Safe"]))
        check(held["onboarder"] == {("CaretakerRegistry", R["GOVERNOR_ROLE"]), ("VerifiedBuilderBadge", R["ISSUER_ROLE"])},
              f"onboarder holds exactly {fmt(held['onboarder'])}", fmt(held["onboarder"]))
        check(held["operator"] == {("VerifiedBuilderBadge", R["STATUS_ROLE"])}, f"operator holds exactly {fmt(held['operator'])}",
              fmt(held["operator"]))
        check(held["deployer"] == set(), "the deployer holds no role on any of the three contracts", fmt(held["deployer"]))
        check(all(c.call(w, "getRoleAdmin(bytes32)(bytes32)", r) == ZERO32 for w, (_, roles) in table.items() for r in roles),
              "every role is administered by DEFAULT_ADMIN (the Safe alone)")

    def stage2_wrapper_guards(self):
        print("== 2. the mainnet keeper wrapper (run-arc-builders.sh) refuses what it must")
        key = new_key()
        tmpcfg = self.root / "cfg-fork.json"
        tmpcfg.parent.mkdir(parents=True, exist_ok=True)
        tmpcfg.write_text(json.dumps({**CFG, "rpc": self.c.rpc}))
        r = run(["bash", str(KEEPER / "run-arc-builders.sh")], ok=False, env={"BUILDERS_CONFIG": str(tmpcfg), "MAINNET_OPERATOR_PRIVATE_KEY": key})
        check(r.returncode != 0 and "chain_id is 5042 (mainnet) but rpc is" in r.stderr,
              "a mainnet config (chain 5042) pointed at any other RPC (this fork) is refused before any call", r.stderr[-400:])
        r = run(["bash", str(KEEPER / "run-arc-builders.sh")], ok=False,
                env={"BUILDERS_CONFIG": str(tmpcfg), "PRIVATE_KEY": key, "CARETAKER_PRIVATE_KEY": key, "SOCIAL_PRIVATE_KEY": key})
        check(r.returncode != 0 and "no mainnet operator key" in r.stderr,
              "the testnet key names (PRIVATE_KEY, CARETAKER_/SOCIAL_PRIVATE_KEY) are never used for mainnet", r.stderr[-400:])
        # signer check, on the local signing oracle (31337) so no mainnet RPC is ever asked anything
        ocfg = self.root / "cfg-oracle.json"
        ocfg.write_text(json.dumps({**CFG, "rpc": self.oracle.rpc, "chain_id": 31337}))
        r = run(["bash", str(KEEPER / "run-arc-builders.sh")], ok=False,
                env={"BUILDERS_CONFIG": str(ocfg), "MAINNET_OPERATOR_PRIVATE_KEY": key, "BUILDERS_PREFLIGHT_ONLY": "1"})
        check(r.returncode != 0 and f"is not config operator_addr {OPERATOR}" in r.stderr,
              "a signer other than config operator_addr is refused", r.stderr[-400:])
        ocfg.write_text(json.dumps({**CFG, "rpc": self.oracle.rpc, "chain_id": 31337, "operator_addr": addr_of(key)}))
        r = run(["bash", str(KEEPER / "run-arc-builders.sh")], ok=False,
                env={"BUILDERS_CONFIG": str(ocfg), "MAINNET_OPERATOR_PRIVATE_KEY": key, "BUILDERS_PREFLIGHT_ONLY": "1"})
        check(r.returncode == 0 and "preflight ok" in r.stdout, "the matching signer passes the wrapper's preflight", r.stdout + r.stderr)

    def stage3_setup(self):
        c = self.c
        print("== 3. actors, proof stand-ins, the keeper's test signer")
        gh_srv, self.gh_port = serve_dir(self.root / "raw")
        dom_srv, self.dom_port = serve_domains(self.root / "domains")
        self.servers += [gh_srv, dom_srv]
        self.proof_env = {"PROOF_GITHUB_BASE": f"http://127.0.0.1:{self.gh_port}", "PROOF_DOMAIN_SCHEME": "http",
                          "PROOF_DOMAIN_PORT": str(self.dom_port)}
        for who in (SAFE, ONBOARDER, OPERATOR):
            c.impersonate(who)
        for n in ("squatter", "alice", "alice_dep", "hostile", "forger", "capped", "bob", "dora", "alice2", "alice3",
                  "status", "nostatus", "stranger"):
            self.actor(n)
        rcpt = c.send_as(SAFE, BADGE, "grantRole(bytes32,address)", self.R["STATUS_ROLE"], self.A["status"])
        check(rcpt and rcpt["status"] == "0x1" and c.call(BADGE, "hasRole(bytes32,address)(bool)", self.R["STATUS_ROLE"], self.A["status"]) == "true",
              "the impersonated Safe grants the badge's STATUS_ROLE to the keeper's test key (fork only)")
        out = self.tick()
        check("tick done" in out and "lacks STATUS_ROLE" not in out,
              "the real keeper runs against the fork with the mainnet config addresses", out[-600:])

    def stage4_register(self):
        c = self.c
        print("== 4. claims signed by the website code, builders register (registerBuilderWithProject, addProject)")
        self.GH_A, self.DOM_A = "github:acme-e2e/tool", "domain:127.0.0.1"
        self.GH_H, self.GH_B, self.GH_D = "github:hostile-e2e/x", "github:bob-e2e/app", "github:dora-e2e/lib"
        self.DOM_F = "domain:localhost"
        self.HOSTILE = 'Evil"},"image":"javascript:alert(1)","x":"\\u0000\n\t\x01</script><script>alert(1)</script>\u202e🙂 ' + "\\" * 3
        # the squatter registers FIRST, claiming alice's repo, with no proof of its own
        rc = c.send_key(self.K["squatter"], BR, "registerBuilderWithProject(string,string)", "Acme Tools", self.GH_A)
        self.sid = self.builder_id("squatter")
        # alice: github repo + her domain (a closed-source project deployed by alice_dep, who co-signs)
        self.fa = self.claim("alice", self.GH_A)
        self.fb = self.claim("alice", self.DOM_A, deployers=("alice_dep",), deployer_keys=("alice_dep",))
        self.publish(self.GH_A, self.fa); self.publish(self.DOM_A, self.fb)
        c.send_key(self.K["alice"], BR, "registerBuilderWithProject(string,string)", "Acme Tools", self.GH_A)
        self.aid = self.builder_id("alice")
        c.send_key(self.K["alice"], BR, "addProject(string)", self.DOM_A)
        # a builder with a hostile profile name and a valid proof
        self.publish(self.GH_H, self.claim("hostile", self.GH_H))
        c.send_key(self.K["hostile"], BR, "registerBuilderWithProject(string,string)", self.HOSTILE, self.GH_H)
        self.hid = self.builder_id("hostile")
        pa = self.project_ids(self.aid)
        srcs = [c.call(BR, "projects(uint256)(uint256,string,bool,uint64)", p).splitlines()[1].strip().strip('"') for p in pa]
        self.pidsA = pa
        check(rc and self.sid >= self.n0 and self.aid > self.sid and srcs == [self.GH_A, self.DOM_A]
              and c.uint(BR, "activeProjectCount(uint256)(uint256)", self.aid) == 2,
              f"squatter #{self.sid} registered first on alice's repo; alice #{self.aid} with projects {pa} ({self.GH_A}, {self.DOM_A})")
        prof = json.loads(c.cast("call", BR, "builders(uint256)(address,string,bytes,uint64,bool)", self.hid, "--json").stdout)[1]
        check(prof == self.HOSTILE, f"hostile builder #{self.hid} stored its profile byte-for-byte ({len(self.HOSTILE.encode())} bytes)")
        ok1, why1 = self._kv().validate_proof(self.fa, self.GH_A, self.A["alice"], CHAIN_ID)
        ok2, why2 = self._kv().validate_proof(self.fb, self.DOM_A, self.A["alice"], CHAIN_ID)
        s1 = self.site_validate(self.fa, self.GH_A, self.A["alice"]); s2 = self.site_validate(self.fb, self.DOM_A, self.A["alice"])
        check(ok1 and ok2 and s1["valid"] and s2["valid"], "site and keeper both accept the website-signed proofs (chain 5042)", f"{why1} {why2} {s1} {s2}")
        s3 = self.site_validate(self.fa, self.GH_A, self.A["squatter"]); ok3, _ = self._kv().validate_proof(self.fa, self.GH_A, self.A["squatter"], CHAIN_ID)
        check(not s3["valid"] and s3["rule"] == 4 and not ok3, "alice's proof does not vouch for the squatter who holds the same source (rule 4, both)")
        wrongchain = self.site("claim", claim={**self.fa["claim"], "chain": 5042002}, builderKey=self.K["alice"])["file"]
        s4 = self.site_validate(wrongchain, self.GH_A, self.A["alice"]); ok4, _ = self._kv().validate_proof(wrongchain, self.GH_A, self.A["alice"], CHAIN_ID)
        check(not s4["valid"] and s4["rule"] == 1 and not ok4, "a testnet-chain (5042002) proof is refused on mainnet (rule 1, both)")

    def _kv(self):
        import verified as kv
        return kv

    def stage5_forgeries(self):
        c = self.c
        print("== 5. deployer-signature forgery: refused by the site and the keeper")
        # the forger claims alice's deployer on its own domain and signs the deployer slot with ITS OWN key
        f = self.site("claim", claim={"builder": self.A["forger"].lower(), "source": self.DOM_F, "deployers": [self.A["alice_dep"].lower()],
                                      "country": "DE", "chain": CHAIN_ID, "issued": TODAY},
                      builderKey=self.K["forger"], deployerKeys=[self.K["forger"]])["file"]
        f["signatures"]["deployers"] = {self.A["alice_dep"].lower(): f["signatures"]["deployers"][self.A["forger"].lower()]}
        s = self.site_validate(f, self.DOM_F, self.A["forger"]); ok, why = self._kv().validate_proof(f, self.DOM_F, self.A["forger"], CHAIN_ID)
        check(not s["valid"] and s["rule"] == 5 and not ok and "rule 5" in (why or ""),
              "a deployer signature forged with another key is refused (rule 5) by the site and the keeper", f"{s} {why}")
        g = json.loads(json.dumps(f)); g["signatures"]["deployers"] = {}
        s2 = self.site_validate(g, self.DOM_F, self.A["forger"]); ok2, _ = self._kv().validate_proof(g, self.DOM_F, self.A["forger"], CHAIN_ID)
        check(not s2["valid"] and s2["rule"] == 5 and not ok2, "a claimed deployer who never signed is refused (rule 5, both)")
        self.publish(self.DOM_F, f)
        c.send_key(self.K["forger"], BR, "registerBuilderWithProject(string,string)", "", self.DOM_F)
        self.fid = self.builder_id("forger")
        check(self.fid > 0, f"the forger registers #{self.fid} with the forged proof published at {self.DOM_F}")

    def stage6_cap(self):
        c = self.c
        print("== 6. the 16-project cap")
        c.send_key(self.K["capped"], BR, "registerBuilderWithProject(string,string)", "", "github:capped-e2e/p1")
        self.cid = self.builder_id("capped")
        for i in range(2, 17):
            c.send_key(self.K["capped"], BR, "addProject(string)", f"github:capped-e2e/p{i}")
        n = c.uint(BR, "activeProjectCount(uint256)(uint256)", self.cid)
        err = c.fails_as(self.A["capped"], BR, "addProject(string)", "github:capped-e2e/p17")
        check(n == 16 and len(self.project_ids(self.cid)) == 16 and reverted_with(err, "TooManyProjects"),
              f"builder #{self.cid} holds 16 projects; a 17th reverts TooManyProjects", err[-200:])
        last = self.project_ids(self.cid)[-1]
        c.send_key(self.K["capped"], BR, "removeProject(uint256)", last)
        err = c.fails_as(self.A["capped"], BR, "addProject(string)", "github:capped-e2e/p17")
        err2 = c.fails_as(SAFE, BR, "addProjectFor(uint256,string)", self.cid, "github:capped-e2e/p17")
        check(c.uint(BR, "activeProjectCount(uint256)(uint256)", self.cid) == 15 and reverted_with(err, "TooManyProjects")
              and reverted_with(err2, "TooManyProjects"),
              "a removed project still counts: 15 active, and neither the builder nor the Safe (addProjectFor) can add a 17th")

    def stage7_batch_onboarder(self):
        c = self.c
        print("== 7. onboarding batch (a): onboard-batch --network mainnet, sent by the impersonated ONBOARDER")
        ids = [self.sid, self.aid, self.hid, self.fid, self.cid]
        ks, g, admin = self.agree("before onboarding", ids)
        check(ks[self.aid]["status"] == "pending" and ks[self.hid]["status"] == "pending" and ks[self.sid]["status"] == "lapsed"
              and ks[self.fid]["status"] == "lapsed" and ks[self.cid]["status"] == "lapsed" and len(ks[self.cid]["projects"]) == 16,
              "keeper: alice + hostile pending (valid proofs), squatter / forger / capped lapsed (16 projects scanned)")
        check(g[self.aid]["display"] == "nominated" and g[self.hid]["display"] == "nominated"
              and all(g[i]["display"] is None for i in (self.sid, self.fid, self.cid)),
              "gallery: alice and hostile Nominated; squatter, forger and capped not shown at all")
        safe, txs, log = self.onboard_batch()
        calls = [(t["call"][0], t["call"][1]) for t in txs]
        want = [("setCaretaker", [str(self.aid), OPERATOR]), ("issue", [str(self.aid)]),
                ("setCaretaker", [str(self.hid), OPERATOR]), ("issue", [str(self.hid)])]
        norm = lambda cl: [(k, [a.lower() for a in v]) for k, v in cl]
        check(f"network mainnet · chain {CHAIN_ID} · rpc {self.c.rpc}" in log and f"VerifiedBuilderBadge {BADGE}" in log
              and f"operator {OPERATOR}" in log and safe["chainId"] == str(CHAIN_ID),
              "onboard-batch --network mainnet takes registries, operator, badge and deploy block from the shipped config", log[-800:])
        check(norm(calls) == norm(want) and [t["to"].lower() for t in txs] == [CR.lower(), BADGE.lower()] * 2,
              f"batch (a) = setCaretaker + issue for alice #{self.aid} and hostile #{self.hid} only ({len(txs)} txs)", calls)
        check(sorted(admin["included"]) == sorted([self.aid, self.hid]) and admin["revokedRead"],
              "/admin's onboarding queue (website lib) picks exactly the same builders", admin)
        for t in txs:
            rc = c.send_data_as(ONBOARDER, t["to"], t["data"])
            if not (rc and rc["status"] == "0x1"):
                check(False, f"onboarder tx {t['call']} mined", rc)
        sA, sH = c.uint(BADGE, "serialOf(uint256)(uint256)", self.aid), c.uint(BADGE, "serialOf(uint256)(uint256)", self.hid)
        self.serialA, self.serialH = sA, sH
        check(sA == self.s0 and sH == self.s0 + 1 and c.call(BADGE, "ownerOf(uint256)(address)", sA).lower() == self.A["alice"].lower()
              and c.call(BADGE, "ownerOf(uint256)(address)", sH).lower() == self.A["hostile"].lower()
              and c.call(CR, "isCaretaker(uint256,address)(bool)", self.aid, OPERATOR) == "true",
              f"the onboarder's batch: alice holds badge No. {sA:03d}, hostile No. {sH:03d}; the operator is their caretaker")
        j = self.badge_json(sA)
        attrs = {a["trait_type"]: a["value"] for a in j["attributes"]}
        check(j["name"] == f"Registrai Verified Builder No. {sA:03d}" and attrs["Status"] == "Verified" and attrs["Builder ID"] == self.aid
              and attrs["Chain"] == "Arc Mainnet" and attrs["Serial"] == sA and j["image"] == f"{DEPLOYMENT['badge']['imageBase']}{sA}.jpg"
              and j["external_url"] == f"{DEPLOYMENT['badge']['externalBase']}{self.aid}",
              f"tokenURI No. {sA:03d} (profile 'Acme Tools') decodes to valid JSON: Verified, Arc Mainnet, builder #{self.aid}", j)
        try:
            jh = self.badge_json(sH)
            text = json.dumps(jh, ensure_ascii=False)
            ok = (jh["name"] == f"Registrai Verified Builder No. {sH:03d}" and jh["external_url"].endswith(f"={self.hid}")
                  and not any(bit in text for bit in ("Evil", "<script>", "javascript:", "\u202e")))
        except (ValueError, KeyError) as e:
            ok, jh = False, str(e)
        check(ok, f"tokenURI No. {sH:03d} of the hostile-profile builder is valid JSON with nothing of the profile in it", jh)
        out = self.tick()
        ks, g, admin = self.agree("after batch (a) + keeper tick", ids)
        check(ks[self.aid]["status"] == "verified" and ks[self.hid]["status"] == "verified" and "marked" not in out,
              "keeper: alice and hostile verified, no badge change", out[-800:])
        check(g[self.aid]["display"] == "verified" and g[self.aid]["name"] == "Acme Tools"
              and g[self.hid]["display"] == "verified" and g[self.hid]["name"] == "hostile-e2e/x",
              "gallery: both Verified; alice named by her profile, the hostile profile never shown (its repo label instead)",
              {k: g[k]["name"] for k in (self.aid, self.hid)})
        _, txs2, _ = self.onboard_batch()
        check(txs2 == [], "a second batch run finds nothing to do")

    def stage8_role_checks(self):
        c = self.c
        print("== 8. every role check on the real bytecode (eth_call from each role's address; the Safe as control)")
        R, x = self.R, self.A["stranger"]
        calls = {
            "revoke": (BADGE, "revoke(uint256)", self.aid),
            "setActive": (BR, "setActive(uint256,bool)", self.aid, "false"),
            "registerFor": (BR, "registerFor(address,string)", x, ""),
            "addProjectFor": (BR, "addProjectFor(uint256,string)", self.aid, "github:x-e2e/y"),
            "setProjectActive": (BR, "setProjectActive(uint256,bool)", self.pidsA[0], "false"),
            "startRecovery": (BR, "startRecovery(uint256,address)", self.aid, x),
            "grant badge ISSUER": (BADGE, "grantRole(bytes32,address)", R["ISSUER_ROLE"], x),
            "grant badge STATUS": (BADGE, "grantRole(bytes32,address)", R["STATUS_ROLE"], x),
            "grant badge REVOKER": (BADGE, "grantRole(bytes32,address)", R["REVOKER_ROLE"], x),
            "grant caretaker GOVERNOR": (CR, "grantRole(bytes32,address)", R["GOVERNOR_ROLE"], x),
            "grant registry REGISTRAR": (BR, "grantRole(bytes32,address)", R["REGISTRAR_ROLE"], x),
            "grant registry admin": (BR, "grantRole(bytes32,address)", ZERO32, x),
            "setBases": (BADGE, "setBases(string,string)", "https://evil.example/", "https://evil.example/"),
            "issue": (BADGE, "issue(uint256)", self.cid),
            "setCaretaker": (CR, "setCaretaker(uint256,address)", self.cid, x),
            "setLapsed": (BADGE, "setLapsed(uint256,bool)", self.aid, "true"),
        }
        control = {"setLapsed": OPERATOR}          # the Safe holds no STATUS; the operator is the control there
        for k, (to, sig, *args) in calls.items():
            ctl = control.get(k, SAFE)
            if c.fails_as(ctl, to, sig, *args):
                check(False, f"control: {k} succeeds for its role holder", c.fails_as(ctl, to, sig, *args)[-200:])
        denied = {
            "onboarder": (ONBOARDER, [k for k in calls if k not in ("issue", "setCaretaker")]),
            "operator": (OPERATOR, [k for k in calls if k != "setLapsed"]),
            "deployer": (DEPLOYER, list(calls)),
        }
        for label, (who, keys) in denied.items():
            allowed = [k for k in keys if not c.fails_as(who, *calls[k][:2], *calls[k][2:])]
            check(not allowed, f"the {label} cannot: {', '.join(keys)}", f"it CAN: {allowed}")
        check(not c.fails_as(ONBOARDER, *calls["issue"][:2], *calls["issue"][2:]) and not c.fails_as(ONBOARDER, *calls["setCaretaker"][:2], *calls["setCaretaker"][2:])
              and not c.fails_as(OPERATOR, *calls["setLapsed"][:2], *calls["setLapsed"][2:]),
              "and each can do exactly its job: onboarder issue + setCaretaker, operator setLapsed")
        err = c.fails_as(self.A["alice"], BADGE, "transferFrom(address,address,uint256)", self.A["alice"], x, self.serialA)
        check(reverted_with(err, "Soulbound"), "the badge is soulbound: its holder cannot transfer it", err[-200:])

    def stage9_batch_safe(self):
        c = self.c
        print("== 9. onboarding batch (b): sent by the impersonated Safe, with a gasless --register")
        self.publish(self.GH_B, self.claim("bob", self.GH_B))
        c.send_key(self.K["bob"], BR, "registerBuilderWithProject(string,string)", "Bob", self.GH_B)
        self.bid = self.builder_id("bob")
        self.publish(self.GH_D, self.claim("dora", self.GH_D))           # dora has no gas: she DMs her source
        _, txs, log = self.onboard_batch("--register", self.GH_D)
        calls = sorted((t["call"][0], tuple(a.lower() for a in t["call"][1])) for t in txs)
        want = sorted([("setCaretaker", (str(self.bid), OPERATOR.lower())), ("issue", (str(self.bid),)),
                       ("registerFor", (self.A["dora"].lower(), ""))])
        check(calls == want, f"batch (b) = setCaretaker + issue for bob #{self.bid}, registerFor(dora) for the gasless claim", calls)
        reg = next(t for t in txs if t["call"][0] == "registerFor")
        err = c.cast("call", reg["to"], reg["data"], "--from", ONBOARDER, ok=False)
        check(err.returncode != 0, "registerFor in a batch needs the Safe: the onboarder's send would revert (REGISTRAR)")
        for t in txs:
            rc = c.send_data_as(SAFE, t["to"], t["data"])
            if not (rc and rc["status"] == "0x1"):
                check(False, f"Safe tx {t['call']} mined", rc)
        self.did = self.builder_id("dora")
        self.serialB = c.uint(BADGE, "serialOf(uint256)(uint256)", self.bid)
        check(self.serialB == self.s0 + 2 and self.did > 0 and c.call(BADGE, "ownerOf(uint256)(address)", self.serialB).lower() == self.A["bob"].lower(),
              f"the Safe's batch: bob holds badge No. {self.serialB:03d}; dora registered as #{self.did} (no project yet)")
        _, txs, _ = self.onboard_batch("--register", self.GH_D)
        calls = [(t["call"][0], t["call"][1]) for t in txs]
        check(calls == [("addProjectFor", [str(self.did), self.GH_D])], "next batch: addProjectFor(dora, her source)", calls)
        for t in txs:
            c.send_data_as(SAFE, t["to"], t["data"])
        _, txs, _ = self.onboard_batch("--register", self.GH_D)
        calls = [(t["call"][0], [a.lower() for a in t["call"][1]]) for t in txs]
        check(calls == [("setCaretaker", [str(self.did), OPERATOR.lower()]), ("issue", [str(self.did)])],
              "next batch: dora (now pending) gets setCaretaker + issue; nothing to register again", calls)
        for t in txs:
            c.send_data_as(SAFE, t["to"], t["data"])
        self.serialD = c.uint(BADGE, "serialOf(uint256)(uint256)", self.did)
        check(self.serialD == self.s0 + 3 and c.call(BADGE, "ownerOf(uint256)(address)", self.serialD).lower() == self.A["dora"].lower(),
              f"dora, who never paid gas, holds badge No. {self.serialD:03d}")
        self.tick()
        self.ids = [self.sid, self.aid, self.hid, self.fid, self.cid, self.bid, self.did]
        ks, g, _ = self.agree("after batch (b) + keeper tick", self.ids)
        check(all(ks[i]["status"] == "verified" and g[i]["display"] == "verified" for i in (self.aid, self.hid, self.bid, self.did)),
              "alice, hostile, bob, dora verified (keeper) and Verified (gallery)")

    def stage10_lapse_restore(self):
        c = self.c
        sA = self.serialA
        print(f"== 10. alice's proofs removed: lapsed after the 3-tick grace (BADGE_LAPSE_TICKS default), then restored")
        self.unpublish(self.GH_A); self.unpublish(self.DOM_A)
        for n in (1, 2):
            out = self.tick()
            ks, g, _ = self.agree(f"proofs gone, tick {n}", self.ids)
            check(ks[self.aid]["status"] == "lapsed" and c.call(BADGE, "lapsed(uint256)(bool)", sA) == "false" and "marked LAPSED" not in out
                  and g[self.aid]["display"] == "lapsed" and not g[self.aid]["badge"]["lapsed"],
                  f"tick {n}: alice lapsed (gallery greys her at once), the badge is NOT flipped yet (grace {n}/3)", out[-600:])
        out = self.tick()
        ks, g, _ = self.agree("proofs gone, tick 3", self.ids)
        check(f"[builder {self.aid}] badge No. {sA:03d} marked LAPSED" in out and c.call(BADGE, "isLapsed(uint256)(bool)", sA) == "true"
              and g[self.aid]["badge"]["lapsed"],
              f"tick 3: the keeper marks badge No. {sA:03d} LAPSED on chain", out[-800:])
        j = self.badge_json(sA)
        check({a["trait_type"]: a["value"] for a in j["attributes"]}["Status"] == "Lapsed" and j["image"].endswith(f"/{sA}-lapsed.jpg")
              and c.call(BADGE, "ownerOf(uint256)(address)", sA).lower() == self.A["alice"].lower(),
              "tokenURI reads Lapsed (lapsed art); the badge stays with alice")
        self.publish(self.GH_A, self.fa); self.publish(self.DOM_A, self.fb)
        out = self.tick(self.K["nostatus"], expect_rc=3)
        check(f"badge setLapsed(False) failed" in out and "ALERT builders-keeper:" in out and c.call(BADGE, "lapsed(uint256)(bool)", sA) == "true",
              "a keeper key WITHOUT STATUS_ROLE cannot touch the badge (the send reverts, the keeper ALERTs and exits 3)", out[-600:])
        out = self.tick()
        ks, g, _ = self.agree("proofs restored", self.ids)
        check(f"badge No. {sA:03d} marked verified again" in out and c.call(BADGE, "lapsed(uint256)(bool)", sA) == "false"
              and ks[self.aid]["status"] == "verified" and g[self.aid]["display"] == "verified",
              "proofs back: the next tick marks the badge verified again", out[-800:])

    def stage11_transfer(self):
        c = self.c
        sA = self.serialA
        print("== 11. owner transfer: proposeOwner -> acceptOwnership -> keeper sync -> re-sign")
        c.send_key(self.K["alice"], BR, "proposeOwner(address)", self.A["alice2"])
        check(reverted_with(c.fails_as(self.A["stranger"], BR, "acceptOwnership(uint256)", self.aid), "NotPendingOwner"),
              "only the proposed wallet can accept")
        c.send_key(self.K["alice2"], BR, "acceptOwnership(uint256)", self.aid)
        check(c.call(BR, "ownerOf(uint256)(address)", self.aid).lower() == self.A["alice2"].lower()
              and self.builder_id("alice") == 0 and self.builder_id("alice2") == self.aid,
              f"builder #{self.aid} now belongs to alice2 (same id, same projects)")
        out = self.tick()
        ks, g, _ = self.agree("after the transfer, before re-signing", self.ids)
        check(f"badge No. {sA:03d} synced to the new owner" in out and c.call(BADGE, "ownerOf(uint256)(address)", sA).lower() == self.A["alice2"].lower()
              and c.uint(BADGE, "balanceOf(address)(uint256)", self.A["alice"]) == 0 and c.uint(BADGE, "serialOf(uint256)(uint256)", self.aid) == sA,
              f"keeper sync: badge No. {sA:03d} moved to alice2 (same serial)", out[-800:])
        check(ks[self.aid]["status"] == "lapsed" and all("rule 4" in (p["reason"] or "") for p in ks[self.aid]["projects"])
              and c.call(BADGE, "lapsed(uint256)(bool)", sA) == "false",
              "the old owner's proofs no longer count (rule 4): lapsed, but the badge only after the grace")
        check(all(p["status"] == "lapsed" for p in g[self.aid]["projects"]), "gallery: both projects lapsed (a re-sign is needed)")
        self.fa, self.fb = self.claim("alice2", self.GH_A), self.claim("alice2", self.DOM_A, deployers=("alice_dep",), deployer_keys=("alice_dep",))
        self.publish(self.GH_A, self.fa); self.publish(self.DOM_A, self.fb)
        out = self.tick()
        ks, g, _ = self.agree("after re-signing", self.ids)
        check(ks[self.aid]["status"] == "verified" and "marked" not in out and g[self.aid]["display"] == "verified"
              and g[self.aid]["owner"] == self.A["alice2"].lower() and c.call(BADGE, "lapsed(uint256)(bool)", sA) == "false",
              "re-signed by alice2: verified again (keeper + gallery), the badge never lapsed", out[-600:])

    def stage12_recovery(self):
        c = self.c
        sA = self.serialA
        print("== 12. recovery: the Safe's startRecovery (the /admin Safe file) -> 7 days -> finishRecovery -> sync")
        f = self.harness("startRecoveryFile", builderId=self.aid, newOwner=self.A["alice3"])["file"]
        tx = f["transactions"][0]
        check(len(f["transactions"]) == 1 and tx["to"].lower() == BR.lower() and f["chainId"] == str(CHAIN_ID),
              "the /admin startRecovery Safe file: one call to the BuilderRegistry, chain 5042")
        r = c.cast("call", tx["to"], tx["data"], "--from", ONBOARDER, ok=False)
        check(r.returncode != 0, "the onboarder cannot start a recovery (REGISTRAR is the Safe's)")
        rc = c.send_data_as(SAFE, tx["to"], tx["data"])
        check(rc and rc["status"] == "0x1" and self.A["alice3"].lower() in c.call(BR, "recoveryOf(uint256)(address,uint64)", self.aid).lower(),
              "the Safe starts the recovery to alice3")
        err = c.fails_as(self.A["stranger"], BR, "finishRecovery(uint256)", self.aid)
        check(reverted_with(err, "RecoveryNotReady"), "finishRecovery before 7 days reverts RecoveryNotReady", err[-200:])
        c.increase_time(RECOVERY_DELAY + 60)
        c.send_key(self.K["stranger"], BR, "finishRecovery(uint256)", self.aid)
        check(c.call(BR, "ownerOf(uint256)(address)", self.aid).lower() == self.A["alice3"].lower(),
              f"after 7 days anyone finishes it: builder #{self.aid} belongs to alice3")
        out = self.tick()
        self.agree("after the recovery, before re-signing", self.ids)
        check(f"badge No. {sA:03d} synced to the new owner" in out and c.call(BADGE, "ownerOf(uint256)(address)", sA).lower() == self.A["alice3"].lower(),
              f"keeper sync: badge No. {sA:03d} follows the recovery to alice3", out[-800:])
        self.fa, self.fb = self.claim("alice3", self.GH_A), self.claim("alice3", self.DOM_A, deployers=("alice_dep",), deployer_keys=("alice_dep",))
        self.publish(self.GH_A, self.fa); self.publish(self.DOM_A, self.fb)
        self.tick()
        ks, g, _ = self.agree("recovered owner re-signed", self.ids)
        check(ks[self.aid]["status"] == "verified" and g[self.aid]["display"] == "verified" and c.call(BADGE, "lapsed(uint256)(bool)", sA) == "false"
              and c.uint(BADGE, "serialOf(uint256)(uint256)", self.aid) == sA,
              f"alice3 re-signed: verified, badge No. {sA:03d} unchanged")

    def stage13_revoke(self):
        c = self.c
        sB, n_before = self.serialB, c.uint(BADGE, "nextSerial()(uint256)")
        print(f"== 13. the Safe revokes bob's badge (the /admin revoke file: revoke + setActive(false))")
        f = self.harness("revokeFile", builderId=self.bid, serial=sB)["file"]
        txs = f["transactions"]
        check(len(txs) == 2 and txs[0]["to"].lower() == BADGE.lower() and txs[1]["to"].lower() == BR.lower(),
              "the /admin revoke file: revoke(id) on the badge, then setActive(id, false) on the registry")
        check(c.cast("call", txs[0]["to"], txs[0]["data"], "--from", ONBOARDER, ok=False).returncode != 0
              and c.cast("call", txs[1]["to"], txs[1]["data"], "--from", ONBOARDER, ok=False).returncode != 0,
              "neither half can be sent by the onboarder")
        rc = c.send_data_as(SAFE, txs[0]["to"], txs[0]["data"])       # revoke only, first
        check(rc and rc["status"] == "0x1" and c.uint(BADGE, "serialOf(uint256)(uint256)", self.bid) == 0
              and c.fails_as(self.A["stranger"], BADGE, "ownerOf(uint256)(address)", sB) != ""
              and c.fails_as(self.A["stranger"], BADGE, "tokenURI(uint256)(string)", sB) != ""
              and c.uint(BADGE, "nextSerial()(uint256)") == n_before,
              f"revoke: badge No. {sB:03d} burned (no owner, no tokenURI), its serial retired")
        _, txs2, log = self.onboard_batch()
        check(not any(t["call"][1][:1] == [str(self.bid)] for t in txs2) and f"builder #{self.bid}" in log and "revoked" in log,
              "while bob is still active and verified, onboard-batch does NOT re-queue him (revocation history)", log[-800:])
        ks, g, admin = self.agree("badge revoked, builder still active", self.ids)
        check(self.bid in admin["held"] and self.bid not in admin["included"] and self.bid in admin["revoked"],
              "/admin's queue holds bob back too (revoked, not reactivated)", admin)
        rc = c.send_data_as(SAFE, txs[1]["to"], txs[1]["data"])
        check(rc and rc["status"] == "0x1" and c.call(BR, "isActiveBuilderId(uint256)(bool)", self.bid) == "false",
              "setActive(false): bob deactivated")
        out = self.tick()
        ks, g, admin = self.agree("bob revoked + deactivated", self.ids)
        check(ks[self.bid]["status"] == "inactive" and g[self.bid]["display"] is None and "marked" not in out,
              "keeper: bob inactive, nothing to upkeep; gallery: bob no longer shown")
        _, txs3, _ = self.onboard_batch()
        check(not any(t["call"][1][:1] == [str(self.bid)] for t in txs3) and self.bid not in admin["included"],
              "onboard-batch and /admin still never re-queue bob")

    def stage14_adversaries_final(self):
        c = self.c
        print("== 14. the squatter and the forger, over the whole run")
        for label, i in (("squatter", self.sid), ("forger", self.fid), ("capped", self.cid)):
            seen = self.seen.get(i, set())
            check(seen == {"lapsed"} and i not in self.batched and c.uint(BADGE, "serialOf(uint256)(uint256)", i) == 0,
                  f"the {label} #{i}: lapsed in every keeper scan ({len(seen)} status seen: {sorted(seen)}), never in a batch, no badge",
                  f"seen {seen}, batched {sorted(self.batched)}")
        out = self.tick()
        check(f"[builder {self.sid}] lapsed, no verified project" in out and f"[builder {self.fid}] lapsed, no verified project" in out,
              "the keeper reports both as lapsed each tick (for a human to look at)", out[-1200:])
        final = c.uint(BADGE, "nextSerial()(uint256)") - 1
        check(final == self.s0 + 3, f"badges issued on the fork: No. {self.s0:03d}..No. {final:03d} (alice, hostile, bob (revoked), dora)")


if __name__ == "__main__":
    main()
