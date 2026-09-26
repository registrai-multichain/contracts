# NanoLedger: internal security review

**Date:** 2026-09-27
**Scope:** `src/nanopay/NanoLedger.sol` (352 lines, byte-identical on fix/mainnet-readiness and feat/market-economics) and `script/DeployNanoLedger.s.sol`.
**Reviewer:** Claude (internal review with tooling). Not an independent external audit.

## Result

**No Critical, High, Medium or Low issues in the contract.** One deploy-process change was made to the script: the mainnet ledger is born owned by the Admin Safe.

- **Solvency by construction.** `totalOwed` moves only on deposit and withdraw. Everything else (internal transfers, allowances, streams, pools) re-assigns ownership inside `totalOwed`, so `USDC held >= totalOwed` always.
- **No admin path to user money.**
  - `GOVERNOR` can only register pool sources (which can spend only their *own* balance) and skim USDC *above* `totalOwed`.
  - `DEFAULT_ADMIN` only manages roles.
  - Nothing can move or freeze a user's balance, and nothing can block a withdrawal.

## Tools

| Technique | Result |
|---|---|
| Slither 0.11.5 | 9 results: strict equalities (intended), timestamp use in streams (second-level drift is harmless), naming. Nothing exploitable. |
| Aderyn 0.6.8 | 0 High. Lows are style or intended: centralization (the governor's limited powers above), a loop in `batchPay`, PUSH0 (supported on Arc), the ignored `_grantRole` bool, the ignored `settleStream` return in `cancelStream` (by design), the loop counter's default 0. |
| Existing tests | 28 unit tests plus 2 invariants (solvency, no over-credit): pass. |
| New audit invariants (test/nanopay/audit/NanoLedgerAudit.t.sol) | Handler covers **every** public function: deposit/depositTo, withdraw (and over-withdraw), internalTransfer, batchPay, approve/transferFromInternal, open/settle/cancel streams (including by strangers, and huge rates), pools (create, setShares, accrue, claim, double claim, stranger ops), donations, skim, stranger governance. **6 invariants × 2,000 × 300 = 600,000 calls each: all hold.** |
| Mutation testing (audit/nanoledger/mutate.py) | **16 of 16 planted bugs caught.** Covered: withdraw not debiting totalOwed or skipping its balance check, transfers not debiting, allowance not checked or not reduced, stream not reserved or not recording settlement or refunding the whole cap or uncapped, accrue not debiting, double claim, setShares dropping pending, skim taking owed money, anyone registering sources / creating pools / cancelling streams. Source byte-identical afterwards. |
| On chain | The same contract has run on Arc testnet with real testnet USDC (Arc's native-transfer precompile), including the 2026-09-26 buyback rehearsal's withdrawals through it. |

### The new invariants

1. **Solvency:** held ≥ `totalOwed`.
2. **`totalOwed`** equals deposits minus withdrawals, exactly.
3. **Exact conservation:** `totalOwed` equals free balances plus open-stream reserves plus (accrued − credited-from-pools).
4. **Held** equals `totalOwed` plus donations not yet skimmed, exactly.
5. **Everyone can exit in full.** At any moment: cancel every open stream, claim every pool for everyone, withdraw every balance. All succeed, everyone is paid in full, and only pool rounding dust stays owed.
6. **Per-action checks:**
   - No allowance is overspent or left unreduced.
   - Closed streams never pay again or reopen, and no stream settles beyond its cap.
   - Claims pay exactly what is claimable, and a second claim pays nothing.
   - The governor skims exactly the surplus and never owed money; strangers can't skim, register sources, cancel others' streams, or touch pools.

## Informational

- **I-1: approve race.** `approveSpender` overwrites the allowance, as ERC-20 `approve` does. A spender could front-run a lowered allowance. Standard mitigation: set to 0 first. Only apps the user approves (MarketsV4 one-click) are spenders.
- **I-2: global pool ids.** Pool ids share one namespace (documented L3 in code). Nothing on mainnet uses pools, and RoleTable asserts MarketsV4 is not a source.
- **I-3: pool dust.** Rounding dust stays owed forever (documented L2), in the ledger's favour. It is bounded by accrued amounts.
- **I-4: absurd shares.** A source that sets absurd share counts could make its own payees' claim overflow and revert. Only governor-registered sources can, and there are none.
- **I-5: Arc native sends.** The ledger has no `receive()`, so plain native USDC sends to it revert. That is correct, since deposits go through `depositTo`.

## Deploy (script/DeployNanoLedger.s.sol)

- **New behaviour.** `run()` reads `ADMIN`. On mainnet it is required and must be the Admin Safe `0xFeE9…80Fb`, and the script asserts the deployer holds no role.
- **Handoff-compatible** (confirmed with arc-78): Handoff skips roles ADMIN already has and only renounces what the deployer holds.
- **Legacy path kept.** `deploy(Config)`, deployer-owned until Handoff, stays for the full-stack order. arc-78's DeployScripts (32) and BuilderSideAudit (28) suites pass.
- **Mainnet dry run** (no broadcast, from 0x84C7…2E5e, 2026-09-27): NanoLedger `0x82CC64bc010Bc244E63654817202B5330f1Ac112` (address depends on the deployer's nonce at broadcast time), USDC 0x3600…, DEFAULT_ADMIN + GOVERNOR = Safe, deployer holds no role, ~0.08 USDC gas. A non-Safe ADMIN is refused.
