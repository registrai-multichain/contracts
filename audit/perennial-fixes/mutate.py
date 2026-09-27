"""Mutation testing for the Perennial audit fixes (2026-09-27): WonderEscrow (no vault,
per-epoch buckets, post-cancel sweep block, 90/10 sweep), BuilderFund (late income,
incremental tax, skim, schedule notice), SeasonPool (deadline cap) and the deploy
guards (DeployPerennial, RoleTable exact check). One planted bug at a time.

Runs in a separate worktree (argv[1]) so concurrent test runs never see a planted
bug. Each file is restored from the exact text read before its mutant."""
import pathlib, subprocess, sys

ROOT = pathlib.Path(sys.argv[1]).resolve()
E, F, S = "src/perennial/WonderEscrow.sol", "src/perennial/BuilderFund.sol", "src/perennial/SeasonPool.sol"
D, R = "script/DeployPerennial.s.sol", "script/lib/RoleTable.sol"
MUTANTS = [
  ("E1 release credits the whole escrow to the current epoch (bunching)", E,
   "                if (b.epoch < current) FUND.creditLate(builderId, b.epoch, b.amount);\n                else FUND.credit(builderId, b.amount);",
   "                FUND.credit(builderId, b.amount);"),
  ("E2 a cancel does not block the sweep", E, "        sweepBlockedUntil[key] = uint64(block.timestamp + RELEASE_DELAY);\n", ""),
  ("E3 sweep ignores the block", E, "        if (block.timestamp < sweepBlockedUntil[key]) revert SweepBlocked();\n", ""),
  ("E4 release keeps the buckets", E, "        delete pendingRelease[key];\n        delete _buckets[key];\n", "        delete pendingRelease[key];\n"),
  ("E5 sweep keeps the buckets", E, "        firstCreditAt[key] = 0;\n        delete _buckets[key];\n", "        firstCreditAt[key] = 0;\n"),
  ("E6 no bucket cap", E, "(bs[n - 1].epoch == epoch || n == MAX_BUCKETS)", "(bs[n - 1].epoch == epoch)"),
  ("E7 credit unbacked", E, "        if (LEDGER.balanceOf(address(this)) < totalEscrow) revert Unfunded();\n", ""),
  ("E8 sweep pays the treasury nothing", E, "        uint256 toTreasury = (amount * SWEEP_TREASURY_BPS) / 10_000;", "        uint256 toTreasury = 0;"),
  ("F1 late income into the current epoch", F, "        if (block.timestamp < epochEnd(epoch)) revert EpochNotEnded();\n        incomeOf[epoch][builderId] += amount;",
   "        incomeOf[epoch][builderId] += amount;"),
  ("F2 increment taxed as fresh income", F, "        tax = progressiveTax(income, b) - progressiveTax(paid, b);", "        tax = progressiveTax(income - paid, b);"),
  ("F3 skim takes builders' income", F, "        if (bal <= outstanding) return 0;\n        amount = bal - outstanding;", "        amount = bal;"),
  ("F4 schedule notice back to one epoch", F, "        uint256 effective = currentEpoch() + SCHEDULE_DELAY + 1;", "        uint256 effective = currentEpoch() + SCHEDULE_DELAY;"),
  ("F5 sweepFrozen moves paid income again", F, "        uint256 gross = income - paid;\n        paidGross[epoch][builderId] = income;\n        outstanding -= gross;\n        _toSeason(gross);",
   "        uint256 gross = income;\n        paidGross[epoch][builderId] = income;\n        outstanding -= gross;\n        _toSeason(gross);"),
  ("S1 season deadline uncapped", S, " || deadline > block.timestamp + MAX_SEASON_LENGTH", ""),
  ("D1 any mainnet epoch >= 7 days", D, 'require(c.epochLength == 30 days, "mainnet: EPOCH_LENGTH must be 30 days");', 'require(c.epochLength >= 7 days, "mainnet: EPOCH_LENGTH must be 30 days");'),
  ("D2 treasury on any ledger", D, "_isContract(c.protocolTreasury) && _ledgerOf(c.protocolTreasury) == c.ledger", "_isContract(c.protocolTreasury)"),
  ("D3 caretakers not pinned by code", D, "                c.caretakers.codehash == address(new CaretakerRegistry(BuilderRegistry(c.builders), c.deployer)).codehash,", "                true,"),
  ("D4 builders address not pinned", D, 'require(c.builders == MAINNET_BUILDER_REGISTRY, "mainnet: BUILDER_REGISTRY is not the live phase-1 BuilderRegistry");', ""),
  ("D5 escrow not given LATE", D, "        d.fund.grantRole(d.fund.LATE_ROLE(), address(d.escrow)); // releases credit the epochs escrow was earned in\n", ""),
  ("R1 any season-pool governor allowed", R, "        if (where == s.seasonPool) {\n            if (role == GOVERNOR) return a == admin;", "        if (where == s.seasonPool) {\n            if (role == GOVERNOR) return true;"),
  ("R2 any fund admin allowed", R, "        if (role == DEFAULT_ADMIN) return a == admin;\n        if (where == s.builders)", "        if (role == DEFAULT_ADMIN) return true;\n        if (where == s.builders)"),
]
TEST = ("FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=64 FOUNDRY_FUZZ_RUNS=128 "
        "forge test --fail-fast --no-match-path '*Fork*' 2>&1 | grep -E '^\\[(PASS|FAIL)|Compiler run failed|Error'")

only = set(sys.argv[2:])
for name, f, old, new in MUTANTS:
    if only and name.split()[0] not in only:
        continue
    p = ROOT / f
    src = p.read_text()
    if old not in src:
        print((name, "MUTANT DID NOT APPLY"), flush=True)
        continue
    p.write_text(src.replace(old, new, 1))
    try:
        r = subprocess.run(TEST, cwd=ROOT, shell=True, capture_output=True, text=True)
        failed = [l.split("(")[0].split(" ")[-1] for l in r.stdout.splitlines() if l.startswith("[FAIL")]
        if "Compiler run failed" in r.stdout:
            res = "DID NOT COMPILE"
        else:
            res = f"CAUGHT by {failed[0]}" if failed else "SURVIVED"
    finally:
        p.write_text(src)
    print((name, res), flush=True)
