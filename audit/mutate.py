"""Mutation testing for the REGI buyback: plant one bug at a time in a src file, run the
invariant campaign and the reach replay, and record whether any test catches it. The file
is restored from the exact text read before each mutant."""
import subprocess, sys, pathlib
ROOT = pathlib.Path(__file__).resolve().parents[1]
B, S = "src/buyback/RegiBuyback.sol", "src/buyback/RegiFeeSplitter.sol"
MUTANTS = [
  ("B1 leak 1 wei to an outsider", B, "            USDC.safeTransfer(address(POOL_MANAGER), usdcIn);", "            USDC.safeTransfer(address(POOL_MANAGER), usdcIn);\n            USDC.safeTransfer(address(0xBEEF), 1);"),
  ("B2 keep the REGI instead of burning", B, "POOL_MANAGER.take(REGI, DEAD, regiOut);", "POOL_MANAGER.take(REGI, address(this), regiOut);"),
  ("B3 no cooldown", B, "        if (block.timestamp < nextChunkAt) revert Cooldown(nextChunkAt);\n", ""),
  ("B4 trigger at half", B, "            if (bal < TRIGGER) revert NotReady();", "            if (bal < TRIGGER / 2) revert NotReady();"),
  ("B5 five chunks per round", B, "            chunksLeft = CHUNKS_PER_ROUND;", "            chunksLeft = CHUNKS_PER_ROUND + 1;"),
  ("B6 chunk of 60 instead of 50", B, "        uint256 amount = bal < CHUNK ? bal : CHUNK;", "        uint256 amount = bal < CHUNK + 10e6 ? bal : CHUNK + 10e6;"),
  ("B7 totals not updated", B, "        totalUsdcSpent += usdcIn;\n", ""),
  ("B8 no overcharge guard (L-1)", B, "        if (usdcIn > amount) revert Overcharged();\n", ""),
  ("B9 settle() result unchecked (L-2)", B, "            if (POOL_MANAGER.settle() != usdcIn) revert SettlementMismatch();", "            POOL_MANAGER.settle();"),
  ("S1 41% instead of 40%", S, "    uint256 public constant BUYBACK_BPS = 4000;", "    uint256 public constant BUYBACK_BPS = 4100;"),
  ("S2 pay the old buyback during a pending repoint", S, "        if (pendingBuyback != address(0)) {", "        if (false) {"),
  ("S3 accept doesn't release the held share", S, "        pendingSince = 0;\n        _releaseHeld();\n    }\n\n    function cancelBuyback", "        pendingSince = 0;\n    }\n\n    function cancelBuyback"),
  ("S4 re-split the held share", S, "        uint256 bal = USDC.balanceOf(address(this)) - heldForBuyback;", "        uint256 bal = USDC.balanceOf(address(this));"),
  ("S5 no repoint delay", S, "        if (block.timestamp < at) revert TooEarly(at);", ""),
]
def run(cmd):
    return subprocess.run(cmd, cwd=ROOT, shell=True, capture_output=True, text=True)
results = []
for name, f, old, new in MUTANTS:
    p = ROOT / f
    src = p.read_text()
    if old not in src:
        results.append((name, "MUTANT DID NOT APPLY")); continue
    p.write_text(src.replace(old, new, 1))
    try:
        r = run("FOUNDRY_INVARIANT_RUNS=300 FOUNDRY_INVARIANT_DEPTH=200 forge test --match-path 'test/buyback/**' --no-match-path '*Fork*' 2>&1 | grep -E '^\\[(PASS|FAIL)'")
        failed = [l.split('(')[0].split(' ')[-1] for l in r.stdout.splitlines() if l.startswith('[FAIL')]
        results.append((name, f"CAUGHT by {len(failed)} test(s): {', '.join(failed)[:160]}" if failed else "SURVIVED"))
    finally:
        p.write_text(src)  # restore the exact pre-mutant text (never git: uncommitted work must survive)
    print(results[-1], flush=True)
print("\nsummary:", sum(1 for _, v in results if v.startswith("CAUGHT")), "of", len(results), "caught")
