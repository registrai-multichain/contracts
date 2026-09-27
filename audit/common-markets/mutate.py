"""Mutation testing for the common markets (MarketsV4, BinaryMarket, SettlementPolicy,
Attestation, Dispute): plant one bug at a time and record whether the suite catches it.

Runs in a separate worktree (argv[1]) so concurrent test runs in the main checkout never
see a planted bug. Each file is restored from the exact text read before its mutant."""
import pathlib, subprocess, sys

ROOT = pathlib.Path(sys.argv[1]).resolve()
V, M = "src/nanopay/MarketsV4.sol", "src/nanopay/BinaryMarket.sol"
P, A, D = "src/nanopay/SettlementPolicy.sol", "src/Attestation.sol", "src/Dispute.sol"
MUTANTS = [
  # MarketsV4: creation, sessions, fee routing
  ("V1 anyone creates markets (C-1)", V, "        if (msg.sender != agent && !approvedCreator[msg.sender]) revert NotTheAgent();\n", ""),
  ("V2 session spend unchecked", V, "        if (collateralIn > s.spendLeft) revert SessionSpendExceeded();\n", ""),
  ("V3 session sells beyond its buys (H-1)", V, "        if (sharesIn > mine) revert SessionSharesExceeded();\n", ""),
  ("V4 expired sessions still trade", V, "        if (block.timestamp >= s.expiry) revert SessionInvalid();", "        if (false) revert SessionInvalid();"),
  ("V5 treasury leg to the caller", V, "        _pay(TREASURY, treasuryFee);", "        _pay(msg.sender, treasuryFee);"),
  ("V6 void escrow never to the challenger", V, "            _pay(challenger, escrow);", "            _pay(TREASURY, escrow);"),
  ("V7 unapproved agents allowed", V, "        if (!approvedAgent[agent]) revert AgentNotApproved();\n", ""),
  ("V8 session shares not bound to the epoch (L-1)", V,
   "        _sessionShares[owner][msg.sender][sessionEpoch[owner][msg.sender]][marketId][outcome] += shares;",
   "        _sessionShares[owner][msg.sender][0][marketId][outcome] += shares;"),
  # BinaryMarket: creation checks, curve, trading gates
  ("M1 off-grid expiries", M, "        if (expiry % EXPIRY_GRID() != 0) revert ExpiryOffGrid();\n", ""),
  ("M2 no buy deadline", M, "        if (block.timestamp > deadline) revert DeadlineExpired();\n        Core storage m = _trading(marketId);\n        if (collateralIn == 0)", "        Core storage m = _trading(marketId);\n        if (collateralIn == 0)"),
  ("M3 no buy slippage check", M, "        if (sharesOut < minSharesOut) revert SlippageExceeded();\n", ""),
  ("M4 sell root floored (pays over the curve)", M, "Math.sqrt(disc, Math.Rounding.Ceil)", "Math.sqrt(disc, Math.Rounding.Floor)"),
  ("M5 buy reserve floored (k shrinks)", M, "            yesAfter = Math.ceilDiv(k, noAfterMint);", "            yesAfter = k / noAfterMint;"),
  ("M6 trading an hour past expiry", M, "        if (block.timestamp >= m.expiry) revert MarketExpired();", "        if (block.timestamp > m.expiry + 1 hours) revert MarketExpired();"),
  ("M7 trading with an inactive agent (L-2)", M, "        if (!REGISTRY.isActiveAgent(m.feedId, m.agent)) revert AgentInactive();\n", ""),
  ("M8 sell profit lowers others' net cost", M, "        uint256 d = out < nc ? out : nc;", "        uint256 d = nc;"),
  ("M9 payee leg ignores the creator's", M, "        uint256 payeeFee = fee - creatorFee - agentFee;", "        uint256 payeeFee = fee - agentFee;"),
  ("M10 sell more shares than held", M, "            if (bal < sharesIn) revert InsufficientShares();\n", ""),
  # BinaryMarket: settlement and claims
  ("M11 resolve before expiry", M, "        if (block.timestamp < m.expiry) revert MarketNotExpired();\n", ""),
  ("M12 resolve while waiting", M, "        if (state != Settlement.Resolvable) revert SettlementPending();", "        if (state == Settlement.Open) revert SettlementPending();"),
  ("M13 void while resolvable", M, "        if (state != Settlement.Voidable) revert NotVoidable();", "        if (state == Settlement.Open) revert NotVoidable();"),
  ("M14 redeem twice", M, "        yesBalance[marketId][holder] = 0;\n        noBalance[marketId][holder] = 0;\n", ""),
  ("M15 claimLP twice", M, "        lpShares[marketId][msg.sender] = 0;\n", ""),
  ("M16 void refunds more than C", M, "        uint256 traderPool = tnc < c ? tnc : c;", "        uint256 traderPool = tnc;"),
  ("M17 sweep before every claim", M, "        if (claimsLeft[marketId] != 0) revert ClaimsOutstanding();\n", ""),
  ("M18 agent escrow paid twice", M, "            agentEscrow[marketId] = 0;\n            LEDGER.internalTransfer(m.agent, escrow);", "            LEDGER.internalTransfer(m.agent, escrow);"),
  ("M19 > evaluated as >=", M, "        if (c == Comparator.GreaterThan) return value > threshold;", "        if (c == Comparator.GreaterThan) return value >= threshold;"),
  ("M20 void escrow not zeroed", M, "        agentEscrow[marketId] = 0;\n        _voidEscrow(", "        _voidEscrow("),
  # SettlementPolicy
  ("P1 window twice as long", P, "        uint256 close = expiry + SETTLEMENT_WINDOW;", "        uint256 close = expiry + SETTLEMENT_WINDOW * 2;"),
  ("P2 settle on an unfinalized reading", P, "        if (found && finalized) return (Settlement.Resolvable, v);", "        if (found) return (Settlement.Resolvable, v);"),
  ("P3 void a pending dispute before the grace", P, "        if (block.timestamp > close + RESOLUTION_GRACE) return (Settlement.Voidable, 0);", "        if (block.timestamp > close) return (Settlement.Voidable, 0);"),
  ("P4 no feed settleability check", P, "        if (registry.getFeed(feedId).disputeWindow >= RESOLUTION_GRACE) revert FeedUnsettleable();\n", ""),
  # Attestation
  ("A1 settle on a reading ruled invalid", A, "            if (att.timestamp > to) break;\n            if (att.status == DisputeStatus.ResolvedInvalid) continue;\n", "            if (att.timestamp > to) break;\n"),
  ("A3 valueAt uses an invalid reading (legacy Markets only)", A, "            if (att.timestamp > atTimestamp) continue;\n            if (att.status == DisputeStatus.ResolvedInvalid) continue;\n", "            if (att.timestamp > atTimestamp) continue;\n"),
  ("A2 readings after the window count", A, "            if (att.timestamp > to) break;\n            if (att.status", "            if (false) break;\n            if (att.status"),
  # Dispute
  ("D1 challenge after finality", D, "        if (block.timestamp >= att.finalizedAt) revert WindowClosed();\n", ""),
  ("D2 anyone rules a dispute", D, "        if (msg.sender != d.resolver) revert NotResolver();\n", ""),
  ("D3 invalid ruling doesn't slash", D, "            REGISTRY.slash(att.feedId, att.agent, d.challengerBond, d.challenger);", "            REGISTRY.unlockBond(att.feedId, att.agent, d.challengerBond);"),
  ("D4 an attestation challenged twice", D, "        if (disputeOf[attestationId] != bytes32(0)) revert AlreadyChallenged();\n", ""),
  # Fix commit d51be4c (audit 2026-09-27): each mutant undoes one piece of a fix
  ("F1 agent may challenge its own reading (L-1 fix)", D, "        if (msg.sender == att.agent) revert AgentCannotChallenge();\n", ""),
  ("F2 trading while the bond is locked (M-1 fix)", M, "        if (!_bondFree(m.feedId, m.agent)) revert AgentBondLocked();\n", ""),
  ("F3 opening while the bond is locked (M-1 fix)", M, "        if (!_bondFree(feedId, agent)) revert AgentBondLocked();\n", ""),
  ("F4 invalid ruling slashes nothing", D, "REGISTRY.slash(att.feedId, att.agent, d.lockedBond, d.challenger);", "REGISTRY.slash(att.feedId, att.agent, 0, d.challenger);"),
  ("F5 valid ruling leaves the bond locked", D, "            if (d.lockedBond > 0) REGISTRY.unlockBond(att.feedId, att.agent, d.lockedBond);\n", ""),
  ("F6 lock the full stake even when not free", D, "        uint256 locked = available < stake ? available : stake;", "        uint256 locked = stake;"),
  ("F7 refuse challenges when no bond is free (H-1 regression)", D, "        uint256 available = REGISTRY.availableBond(att.feedId, att.agent);", "        uint256 available = REGISTRY.availableBond(att.feedId, att.agent);\n        if (available == 0) revert AgentCannotChallenge();"),
  ("F8 slash doesn't deactivate the agent", "src/Registry.sol", "        a.active = false;\n        a.slashed = true;", "        a.slashed = true;"),
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
