# Common markets: internal security review

**Date:** 2026-09-27
**Reviewer:** Claude (internal review with tooling; not an independent external audit).

**Scope:**
- Contracts: `MarketsV4.sol`, `BinaryMarket.sol`, `SettlementPolicy.sol`, `Registry.sol`, `Attestation.sol`, `Dispute.sol`.
- Deploy scripts: `DeployOracle`, `DeployNanoStack`, `HandoffCommonMarkets`.
- Keeper paths for settlement, bonds and rotation.

**Commits:**
- Reviewed: `fix/mainnet-readiness` at `7167e69`.
- Fixes: `d51be4c` (arc-78, branch `fix/audit-2026-09-27`), re-audited below and fast-forwarded into `fix/mainnet-readiness`.

## Result

No Critical findings. One High, three Medium and several Low findings. All fixed or accepted before launch.

| ID | Severity | Finding | Status |
|---|---|---|---|
| O-H1 | High | The agent could make its own wrong reading impossible to challenge. It locked its bond by challenging throwaway readings, so `challenge` reverted `NoAvailableBond`, the wrong reading finalized and it settled the market. | **Fixed** (d51be4c). A challenge is always accepted. The lock is min(stake, free) and may be 0. An Invalid ruling always deactivates the agent. |
| O-M1 / V-M1 | Medium | Forced void of the event market: two challenges lock the whole bond before expiry, so the agent cannot attest in the settlement window. | **Fixed**. Keeper: keeps free bond at multiple × minBond, tops up on each Challenged event, and stops periodic event publishes during the pre-expiry dispute window. Contract: markets do not trade or open while the bond is locked. |
| B-M1 | Medium | Void refunds are per-account net cost floored at 0. On a certain void, a trader using two accounts takes up to about 59% of the LP seed, then cuts honest refunds. | **Vector closed** (d51be4c: no trading or opening while the agent cannot attest). **Residual accepted:** a visibly offline agent, bounded by the 5 USDC seed per round. **Planned:** position-based void payouts. |
| O-L1 | Low | The agent could pre-empt challenges of its own reading and collect its own slash. | **Fixed**: `AgentCannotChallenge`. This is defence in depth; O-H1's fix is what protects the market. |
| V-L1 | Low | Sessions: a delegate's sell right is a count, so it can sell shares the owner rebought by hand. | **Documented** (NatSpec). Bounded by the spend cap. |
| V-L2 | Low | Keeper: a late reading for round A could land in round B's window on the same feed. | **Fixed**: the keeper re-reads the chain clock and refuses within 90 s of the window end; the feed rotation is 15 (reuse after 75 min, window 60 min). |
| V-L3 | Low | A loser challenges a reading and waits: the market voids if the Safe never rules. | **Accepted** (process). The Safe must rule promptly. |
| Info | Info | See the list below. | See the list below. |

Info findings:
- `HandoffCommonMarkets.verify` only checked the deployer's roles. **Fixed**: the launch script now rebuilds V4's role table from logs.
- Approved creators could name the rounds agent. **Accepted**: none will be approved.
- `setSession` does not bump the epoch.
- `quote*` ignores AgentInactive and AgentBondLocked. The UI maps these errors to plain text.
- Trades below 100 units pay no fee.
- There is no pause for open markets.
- A reading ruled Invalid voids the market rather than correcting it.

## Trust assumptions after the fixes

- **Agent (keeper hot key):** can post any value and can skip a reading, which forces a void. A wrong reading is now always challengeable. It becomes final only if nobody challenges it within the dispute window (10 min for rounds). **There is no independent watcher yet**; one is recommended before real volume. The agent cannot back-date readings, resolve disputes or move user funds.
- **Admin Safe (resolver and governor):**
  - Rules on challenged readings. It must rule on the *value*, including throwaway readings in a window: a throwaway ruled Valid can settle the market.
  - Its response time bounds liveness. Anyone can hold a round Pending for 2 USDC; the market waits for the ruling or voids after the 7-day grace.
  - Its governor powers are approvals for future markets only. There is no path to user collateral.
- **Data:** rounds settle on the median of Coinbase, Kraken and OKX. This is off chain.

## Tooling

| Technique | Result |
|---|---|
| Slither (V4 plus dependencies; Dispute) | No exploitable findings. Reentrancy flags concern trusted callees only (Circle USDC and our own registry). "Divide before multiply" in `_sellMath` is intended rounding in the pool's favour, verified below. |
| Aderyn | 2 "High": reentrancy (trusted callees) and "weak randomness" (record IDs, not randomness). Both false positives. The Lows are style or intended. |
| Manual review, 3 parallel reviewers | Findings above. Every finding has a PoC in `test/audit/common/`. The PoCs were re-run independently, and the fix commit flips each one to assert the fix. |
| Invariants (BinaryMarket) | 3 invariants × 128k calls hold: ledger balance equals obligations exactly; trading conservation (supply + reserve = C, k never decreases); settled coverage (`claimsLeft` exact, dust bounded). |
| Fuzz | Settlement selection matches a reference model in 20k runs. BinaryMarket: sole-trader round trips, dust extraction, resolve and void conservation, extreme prices, 1000–5000 runs each. All hold. |
| Mutation testing (`mutate.py`, separate worktree) | 46 mutants, 43 caught. The 3 survivors are equivalent or legacy (details below). Logs: `mutation-run-7167e69.txt` and `mutation-run-d51be4c.txt`. |
| Full suite at d51be4c | 867 passed, 0 failed (non-fork). Keeper: 378 passed. |

## Mutation testing

**46 planted bugs, 43 caught.** Each is one line changed in `src/`, run against the whole non-fork suite. The run used a separate worktree, so concurrent tests never saw a mutant. The final tally uses the fix commit wherever a mutant was re-run.

Every mutant that undoes part of a fix is caught:
- F1–F8: the agent challenging its own reading; trading or opening while the bond is locked; an Invalid ruling slashing nothing; a Valid ruling leaving the bond locked; locking more than is free; refusing challenges when no bond is free (the H-1 regression); a slash that doesn't deactivate the agent.
- V1–V8: creation gate, session spend, session shares, session expiry, fee legs, void escrow, agent approval, epoch binding.

The three survivors:
- **M10** (drop the InsufficientShares check) and **M11** (drop MarketNotExpired in resolve) are *equivalent*. Checked arithmetic, and the settlement state (`SettlementPending`), still revert with the same effect, just a different error.
- **A3** (valueAt keeps an Invalid reading) is in a function only the legacy `Markets.sol` uses. The legacy suite doesn't cover it, and it is out of this launch's scope.

Two lessons for this harness:
- The first run reported two "did not compile" results. Both were transient: re-run individually, P3 is caught.
- A1's anchor first matched the identical line in `valueAt` instead of `firstInWindow`. Re-anchored, A1 is caught.

## Re-audit of d51be4c

- **Dispute:**
  - The stake is always the feed's minBond, and the lock is min(stake, free).
  - A Valid ruling unlocks exactly the stored `lockedBond`. An Invalid ruling slashes exactly `lockedBond`.
  - `Registry.slash(…, 0)` still deactivates the agent and marks it slashed; slashed agents cannot re-register.
  - Arc USDC accepts zero-amount transfers (checked on mainnet), so an Invalid ruling with nothing locked cannot revert.
- **BinaryMarket:** `_bondFree` gates `_open` and `_trading` (buy and sell). Redeem, claim and void are not gated, so nobody is stuck in a settled market.
- **New surface:** anyone can hold any reading Pending for minBond. This is liveness only (the griefer loses the stake on a Valid ruling). While challenges lock the bond, the feed stops trading until the keeper tops up. Both are accepted.

## Verdict

**Go for the common-markets launch from `fix/mainnet-readiness` at `d51be4c` or later**, provided the following hold:

1. The keeper update (settle.py send guard, 15-feed rotation, overlap guard, free-bond upkeep, event quiet period) is the version running on the server. arc-78 synced `rounds.py` 8bd49342a590; confirm settle.py and oracle_health.py are also synced.
2. The Safe signers commit to ruling on every challenge within the settlement window (1 h for rounds). They rule on the reading's **value**, throwaway readings included. Batched rulings via MultiSend are ready.
3. Round seeds stay at 5 USDC until position-based void payouts (B-M1 plan (a)) land.

Before real volume, recommended:
- an independent watcher (a second key that re-checks readings and challenges wrong ones)
- agent-key hardening (a dedicated no-login user, no password file on disk, a fresh key, a firewall)
- a bug bounty
- an external audit.
