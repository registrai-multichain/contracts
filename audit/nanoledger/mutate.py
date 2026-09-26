"""Mutation testing for NanoLedger: plant one bug at a time, run the unit tests, the
original solvency invariant and the audit suite; record whether any test catches it.
The file is restored from the exact text read before each mutant (never from git)."""
import subprocess, pathlib
ROOT = pathlib.Path(__file__).resolve().parents[2]
F = "src/nanopay/NanoLedger.sol"
M = [
 ("N1 withdraw keeps totalOwed", "            totalOwed -= amount; // amount <= bal <= totalOwed\n", ""),
 ("N2 withdraw skips the balance check", "        if (amount > bal) revert InsufficientBalance();\n        unchecked {\n            balanceOf[msg.sender] = bal - amount;", "        unchecked {\n            balanceOf[msg.sender] = bal - amount;"),
 ("N3 transfer doesn't debit the sender", "        unchecked { balanceOf[from] = bal - amount; }\n        balanceOf[to] += amount;", "        balanceOf[to] += amount;"),
 ("N4 allowance not reduced", "            unchecked { allowance[from][msg.sender] = a - amount; }\n", ""),
 ("N5 allowance not checked", "            if (amount > a) revert InsufficientAllowance();\n", ""),
 ("N6 stream not reserved", "        unchecked { balanceOf[msg.sender] = bal - cap; } // reserve: leaves free balance, stays in totalOwed\n", ""),
 ("N7 settle doesn't record settled", "            s.settled = streamed;\n", ""),
 ("N8 cancel refunds the whole cap", "        uint256 remainder = s.cap - s.settled;", "        uint256 remainder = s.cap;"),
 ("N9 stream not capped", "        if (rate > cap / elapsed) return cap;\n", "        if (rate > type(uint256).max / elapsed) return cap;\n"),
 ("N10 accrue doesn't debit the source", "        unchecked { balanceOf[msg.sender] = bal - amount; }\n        p.accPerShare", "        p.accPerShare"),
 ("N11 claim doesn't advance (double claim)", "        claimedPerShare[poolId][msg.sender] = acc;\n        if (owed > 0) {", "        if (owed > 0) {"),
 ("N12 setShares drops pending instead of paying it", "            if (owed > 0) balanceOf[payee] += owed;\n", ""),
 ("N13 skim takes everything", "        surplus = held > totalOwed ? held - totalOwed : 0;", "        surplus = held;"),
 ("N14 anyone can register a source", "    function setSource(address source, bool allowed) external onlyRole(GOVERNOR_ROLE) {", "    function setSource(address source, bool allowed) external {"),
 ("N15 anyone can create a pool", "        if (!isSource[msg.sender]) revert NotSource();\n", ""),
 ("N16 anyone can cancel a stream", "        if (s.from != msg.sender) revert NotStreamOwner();\n", ""),
]
def run(cmd): return subprocess.run(cmd, cwd=ROOT, shell=True, capture_output=True, text=True)
out = []
p = ROOT / F
for name, old, new in M:
    src = p.read_text()
    if old not in src:
        out.append((name, "MUTANT DID NOT APPLY")); print(out[-1], flush=True); continue
    p.write_text(src.replace(old, new, 1))
    try:
        r = run("FOUNDRY_INVARIANT_RUNS=200 FOUNDRY_INVARIANT_DEPTH=150 forge test --match-path 'test/nanopay/{NanoLedger,NanoLedgerInvariant,audit/NanoLedgerAudit}.t.sol' 2>&1 | grep -E '^\\[(PASS|FAIL)|Compiler run failed|Error \\('")
        failed = [l for l in r.stdout.splitlines() if l.startswith('[FAIL')]
        compiled = "Compiler run failed" not in r.stdout and "Error (" not in r.stdout
        passed = [l for l in r.stdout.splitlines() if l.startswith('[PASS')]
        if not compiled: out.append((name, "DID NOT COMPILE (mutant invalid)"))
        elif failed: out.append((name, f"CAUGHT by {len(failed)} test(s)"))
        elif passed: out.append((name, "SURVIVED"))
        else: out.append((name, "NO TESTS RAN (harness problem)"))
    finally:
        p.write_text(src)
    print(out[-1], flush=True)
print("\nsummary:", sum(1 for _, v in out if v.startswith("CAUGHT")), "of", len(out), "caught")
