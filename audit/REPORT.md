# REGI buyback: internal security review

**Date:** 2026-09-26
**Scope:** `src/buyback/RegiBuyback.sol`, `RegiFeeSplitter.sol`, `UniswapV4Minimal.sol`, `INanoLedgerMinimal.sol`, `script/DeployBuyback.s.sol` (361 lines of contract code).
**Branch:** `audit/regi-buyback`, cut from `fix/mainnet-readiness` at 257231f.
**Reviewer:** Claude (internal review with tooling). This is **not** a substitute for the external audit the spec requires.

## Summary

| Severity | Count | Status |
|---|---|---|
| Critical | 0 | |
| High | 0 | |
| Medium | 0 | |
| Low | 3 fixed + 3 open (design decisions) | L-1, L-2 and L-3 fixed with tests. L-4, L-5 and L-6 are yours to decide. |
| Informational | 7 | |

No path was found for USDC to leave `RegiBuyback` except as swap spend into the PoolManager. No path was found for REGI to rest anywhere but `0x…dEaD`, or for the 40/60 split, the 7-day delay or the round rules to be bypassed. Each claim below is backed by a tool result.

## Methodology and results

| Technique | Tool | Result |
|---|---|---|
| Static analysis | Slither 0.11.5 (101 detectors) | 18 results before fixes, 16 after. None exploitable; triage below. |
| Static analysis | Aderyn 0.6.8 | 3 "High" and 5 "Low" labels. All false positives or style on review (triage below). |
| Stateful invariant fuzzing | Foundry | 7 invariants × 2,000 sequences × 300 calls = **600,000 calls each**, run on the code before and after the fixes. All hold. |
| Reach check | Foundry replay | Over 6,000 random actions: 683 burns, 172 rounds, 204 partial fills, 122 held distributes, 24 accepted and 219 cancelled redirects. The campaign really exercises the risky states. |
| Mutation testing | 14 planted bugs (audit/mutate.py) | **14 of 14 caught** by the unit and audit suites (details below). |
| Coverage-guided fuzzing | Echidna 2.3.3 | 7 properties (same handler) over **500,804 calls**: all pass. A first run falsified one property; that was a harness artifact (the handler's private clock missed Echidna's own time jumps: a redirect accepted after 7.04 real days was wrongly flagged). The handler now reads real block time. |
| Symbolic execution | Halmos 0.3.3 (z3, bitwuzla 0.9.1) | **Proven for every input:** the price limit is always above v4's minimum, the limit is below any real pool price (so the swap direction is always valid), 0.98995² ≥ 0.98 (so the cap is at most 2%), `BalanceDelta` decoding round-trips for all value pairs, and owed USDC equals the delta's magnitude. **Out of solver reach** (timeouts, no counterexample): the exact-floor identity and the 40/60 split, which are 256-bit multiply-then-divide. Both are covered by 100,000-run fuzz twins and exercised 600,000 times in the invariant campaign. |
| Fork fuzzing | Foundry on an Arc mainnet fork (real PoolManager, Argus hook, REGI) | 40 runs × 6 random steps. Every chunk lands REGI at dead, is never better than spot, and is no worse than spot minus fees and the 2% cap. The L-2 settle check passes against the real PoolManager. |
| Live rehearsal | Arc testnet (real v4 PoolManager, Arc's real USDC transfer) | Keeper and visitor presses both burned to dead (deployments/arc-testnet-buyback-rehearsal.json). |
| External contracts | Bytecode review | Argus hook, REGI and its reward tracker: no DELEGATECALL, no SELFDESTRUCT, no EIP-1967 slot, so the code can't be changed. Hook taxes are constants (1% buy, 3% sell); snipe tax is 0; the hook is bonded at tick 376,400, above the market, while buys move the tick down. |

### Invariants (test/buyback/audit/BuybackInvariant.t.sol)

1. USDC leaves a buyback only as swap spend (`balance + totalUsdcSpent` never decreases).
2. A buyback never holds REGI.
3. `0x…dEaD`'s REGI equals the sum of `totalRegiBurned`.
4. The PoolManager received exactly the sum of `totalUsdcSpent`.
5. Round counters stay sane: at most 4 chunks left, a round is always counted, `totalChunks` equals successful presses.
6. `heldForBuyback` is non-zero only while a redirect is pending, and always backed by USDC.
7. The Safe receives exactly the 60% legs.

**Per-action checks** in the handler:
- **Presses:**
  - no press succeeds during cooldown;
  - no round opens below $200;
  - every new round is exactly 4 chunks;
  - each chunk counts the round down;
  - a spend is never 0 and never above the chunk;
  - a failed press changes nothing.
- **Splitter:**
  - `distribute` splits exactly the new money at floor(40%);
  - during a pending redirect the 40% is held, and the old buyback is not paid;
  - accept and cancel release the held share to the right buyback;
  - accept happens no earlier than 7 days after the proposal.
- **Outsiders:** they can't propose, accept, cancel, or run the swap callback.

### Mutation testing (audit/mutation-run.txt)

B1 leak 1 wei · B2 keep REGI · B3 no cooldown · B4 trigger at half · B5 five chunks · B6 $60 chunks · B7 totals not updated · B8 remove the L-1 overcharge guard · B9 ignore the L-2 settle result · S1 41% · S2 pay the old buyback during a pending redirect · S3 accept doesn't release · S4 re-split the held share · S5 no delay. **All 14 caught**, and the source is byte-identical after the run.

## Findings

### L-1 (fixed): USDC paid per chunk was not bounded by the chunk
`unlockCallback` paid whatever the swap delta said was owed. Exact-input swaps never owe more than requested, unless the hook has `beforeSwapReturnsDelta`. This pool's hook doesn't (pinned by a fork test), but the contract relied on that. **Fix:** revert with `Overcharged()` if `usdcIn > amount`. Test: `test_audit_refusesToPayMoreThanTheChunk`.

### L-2 (fixed): `settle()`'s return value was ignored
The PoolManager already enforces full settlement, but the contract didn't check it. **Fix:** revert with `SettlementMismatch()` unless `settle() == usdcIn`. Test: `test_audit_settleMustReportExactlyWhatWasPaid`. The real PoolManager on the mainnet fork passes the check.

### L-3 (fixed): round state was written after the external swap
`chunksLeft` and `nextChunkAt` were updated after `unlock`. The re-entry guard already blocked exploitation, but checks-effects-interactions is safer against future edits. **Fix:** both are now written before the swap; only the totals, which depend on the swap's result, come after. Test: `test_audit_roundIsCountedDownBeforeTheSwap`.

### L-4 (open, design): a leftover below $200 waits for more income
Rounds open only at $200 or more. After partial fills, or if income stops for good, a leftover under $200 stays in the buyback until more arrives. Anyone can top it up to $200 to unlock it, and it can never be taken out, so nothing is lost; it is only delayed. **Option:** after, say, 30 days without a round, allow a round to open with any balance of at least one chunk.

### L-5 (open, design): USDC blocklist and pause
Arc's USDC is Circle's, and Circle can pause it or blocklist addresses.
- **Buyback blocklisted:** it can't pay the pool, so its USDC stays locked. The Safe can redirect the splitter's future 40% elsewhere.
- **Safe blocklisted:** `distribute()` reverts, because `SAFE` is immutable, and all splitter income waits.

**Option:** pay the Safe's leg by pull instead of push, or let the Safe redirect its own leg with the same 7-day delay. The likelihood is low, but the impact while it lasts is total.

### L-6 (open, design): press timing is the presser's choice
Anyone can press whenever a chunk is ready, so they choose the moment within each cooldown window. A trader could press right after pushing the price up. The 2% cap and the hook's 1% + 3% taxes make pumping to exploit a $50 chunk unprofitable (see the M1 note in the spec); what remains is mild timing noise. No change recommended while the hook taxes stay as they are.

### Informational
- **I-1: Arc-only native sends.** `receive()` accepts native value, which on Arc is the same balance as the ERC-20 (verified). On any other chain it would be locked ether, which is Slither's and Aderyn's "locks Ether" flag. DeployBuyback pins chain 5042.
- **I-2: native dust.** Native USDC has 18 decimals and the ERC-20 view has 6, so sub-1e-12 dust is unspendable. It's negligible.
- **I-3: `MAX_IMPACT_BPS` is documentary.** The cap is enforced by `SQRT_LIMIT_NUM/DEN` = 0.98995, proven symbolically to be at most 2%. Changing `MAX_IMPACT_BPS` alone would change nothing.
- **I-4: `status()` can read stale during a swap.** Only the view could observe it, and nothing on chain reads it.
- **I-5: permissionless `distribute()` and `sweepLedger()`.** Anyone can choose when income is split or swept. Harmless.
- **I-6: the Safe can redirect the 40% to itself after 7 days.** By design and publicly visible, and disclosed on the dashboard.
- **I-7: Aderyn H-3 "unsafe casting".** `int128(delta)` intentionally takes the low 128 bits, exactly as v4's `BalanceDelta`. Symbolically proven to round-trip for all inputs.

## Tool triage

- **Slither.**
  - Reentrancy: guarded by `nonReentrant`, plus the PoolManager-only, in-swap-only callback; a re-entry test proves it blocked, and L-3 fixed the ordering.
  - Strict equalities: intended (round and zero checks).
  - Locking ether: I-1.
  - `hooks` zero-check: zero is valid (a pool with no hook).
  - Timestamp use: the cooldown is minutes, so seconds of drift don't matter.
  - Naming: style.
- **Aderyn.** H-1 is I-1. H-2 is L-3. H-3 is I-7. The Lows are style (pragma, literals, modifier order, PUSH0 is supported on Arc) plus the ignored return fixed in L-2.

## What this review does not cover

- An independent human audit, which is still required by the spec before mainnet.
- Economic attacks beyond one chunk: long-running price manipulation across many blocks costs the manipulator the hook's 3% sell tax each time.
- Arc consensus and USDC-contract risk.
- Keeper and dashboard code (reviewed separately in the branch review).
