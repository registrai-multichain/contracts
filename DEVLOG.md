# Devlog

Reverse-chronological work journal for [Registrai](https://registrai.cc) — permissionless onchain registry of bonded oracle agents and the prediction markets they resolve. Every entry pairs what shipped with onchain proof.

---

## 2026-05-16 · Verifiable agents shipped — rule contracts live

**Shipped end to end on the same day as the design.** Today's architecture used to trust the off-chain agent process to (a) fetch honest data and (b) compute the right value from it. The bond + slash mechanism deterred lying, but the math itself was opaque. As of this commit the math is verifiable bytecode anyone can read.

**What landed today:**

- `IAgentRule.sol` + reference implementations `MedianRule` and `TrimmedMeanRule(1000)` deployed to Arc testnet:
  - MedianRule: [`0x415fb74629d8eab51b7991679cec6cb71f3fb997`](https://testnet.arcscan.app/address/0x415fb74629d8eab51b7991679cec6cb71f3fb997)
  - TrimmedMeanRule (10% per tail): [`0x772a40fee7b51542cf09c8c26c9e7b786d162a70`](https://testnet.arcscan.app/address/0x772a40fee7b51542cf09c8c26c9e7b786d162a70)
- `Registry.registerAgentWithRule(...)` parallel to `registerAgent` — backward compatible; existing agents unchanged
- `Attestation.attestWithRule(feedId, int256[] rawInputs)` reads the agent's bound rule, computes the value via `rule.submit(rawInputs)`, stores the result, and emits an `Attested` event with `inputHash = keccak256(abi.encode(rawInputs))` — anyone watching the chain can re-derive the input vector and re-call the rule to confirm
- 25 new contract tests (including a 256-run fuzz over MedianRule). Full suite **86/86 green**
- `@registrai/agent-sdk@0.2.0` adds the rule-bound path. `defineAgent({ rule: '0x…' })` switches `run()`'s return shape from `{ value, inputHash }` to `{ rawInputs }`; SDK calls `attestWithRule` under the hood and never computes the final value off-chain in this path
- `/agents/create` on the site gained a rule picker: none / Median / Trimmed Mean 10% / Custom address. Success panel hands back a pre-filled SDK snippet for the chosen rule. Card 02 on the landing page stays `beta`.

**The invariant the protocol now guarantees** for any rule-bound agent: pull `inputHash` from the `Attested` event → reconstruct `rawInputs` from the attest tx calldata → re-call `rule.submit(rawInputs)` yourself → confirm the stored `value` matches. Aggregation math is no longer trust-by-markdown.

**What's next on this milestone:**
- BoundedScalarRule (range guards + max-step-bps) — round 2
- Migrate at least one first-party agent (Warsaw resi or Polish CPI) to use the new path, so the dashboard shows a "verifiable" badge on a live feed
- Phala TEE attestation for the data-fetch half — that closes the trust loop end to end

**The split:**

| Trust layer | Where | Hardens via |
|---|---|---|
| Data fetch | Off-chain worker | TEE attestation (Phala SGX) — later |
| Aggregation rule | Onchain contract | Verifiable bytecode — this milestone |
| Final attestation | Onchain Attestation contract | Already in place |

**Shape of the build:**
- `IAgentRule.sol` — `submit(int256[] raw) returns (int256 finalValue)`
- Three reference templates: `MedianRule`, `TrimmedMeanRule(trimPct)`, `BoundedScalarRule(min, max, maxStepBps)`
- `Registry.registerAgent(feedId, methodHash, bond, ruleContract)` — when `ruleContract != 0`, Attestation accepts only attestations whose `inputHash == keccak256(rawInputs)` and value matches `ruleContract.submit(rawInputs)`. The methodology hash *becomes* the rule bytecode hash.
- SDK extension: `defineAgent({ rule: '0x…' })` switches the submission shape from `(value, inputHash)` to `(rawInputs)`.

**Why it matters for Registrai:** every other oracle protocol treats aggregation as a trusted black box. Making it onchain bytecode flips the pitch from "permissionless registry of agents" to "permissionless registry of *verifiable* agents" — a real product moat, not just a brand claim. ~3-4 days of work, lands in v0.2.

---

## 2026-05-15 · Market-maker vault + end-to-end resolve test, live

**Shipped**

- **`MarketMakerVault.sol`** — pooled USDC for operator-driven liquidity bootstrapping. Anyone can deposit and burn shares to withdraw against current NAV. An authorized operator routes funds into `buy` / `sell` / `addLiquidity` calls on Markets; resolved winnings flow back into the vault and depositors claim their slice. v1 NAV is conservative (USDC balance only) — immune to AMM-state sandwich attacks. 1e6 virtual offset neuters the classic first-depositor share-inflation attack.
- **9 new contract tests**; full suite 61/61 green.
- **Deployed live** at [`0x79F09d46dA4cA607f8805930778fBfFDAad0E9D8`](https://testnet.arcscan.app/address/0x79F09d46dA4cA607f8805930778fBfFDAad0E9D8), seeded with 50 USDC from the treasury so judges land on a non-empty pool.
- **`/vault` page** on the site — live NAV, share price, your position, deposit/withdraw form.
- **MM bot wired through the vault** — bot's operator key signs `vault.executeBuy(...)` instead of `markets.buy(...)`. Every MM trade originates from the vault address onchain.
- **Operator/agent separation** — the MM operator is now wallet `0x9FB5…6959`, distinct from the oracle agent wallet `0x84C7…2E5e`. Oracle agents do not trade markets keyed to their own attestations.

**Onchain stress + invariant tests**

| Test | Iterations | Result |
|---|---|---|
| MM stress (price-target convergence) | 20 / 11 trades | 0 invariant failures, AMM k strictly grew per buy, model converged within 5pp spread tolerance |
| Sell-side (`vault.executeSell`) | 5 / 5 sells | 0 failures, NAV+ and AMM k+ on every iter |
| End-to-end resolve | 1 full cycle, ~1h wall-clock | PnL +0.4482 USDC on 0.5 USDC YES bet — matched theory exactly |

**End-to-end resolve test breakdown** (~1 hour, all onchain on Arc testnet):

1. `createFeed` — feed [`0xec0679c7…`](https://testnet.arcscan.app/) with the minimum allowed dispute window (1h)
2. `approve` + `registerAgent` — 10 USDC bond locked
3. `attest(17500)` — finalizes at +1h
4. `createMarket(threshold=17000, GreaterThan, 5 USDC seed)` — market [`0x7c06d272a8067667f433e5882e29edc7b24c46235c3f6409175c8e7736b32dcb`](https://testnet.arcscan.app/)
5. `vault.executeBuy(YES, 0.5 USDC)` → 0.9482 YES shares acquired at price ~0.527
6. wait for finalization + market expiry
7. `resolve` — YES won (17500 > 17000)
8. `vault.redeem` — winnings flow back to vault

**Vault NAV: 45.1688 → 45.6170 USDC.** Profit `0.9482 × $1 − 0.5 = $0.4482`, matching exactly.

---

## 2026-05-14 · SDK published to npm + agent repo cutover

**Shipped**

- **`@registrai/agent-sdk` 0.1.0** on npm — 17 kB tarball, 33 files, public scope claimed. Runtime-agnostic: works in Node, Cloudflare Workers, and Phala TEE. Surface: `defineAgent`, `Agent`, `preflight`, `submitAttestation`, `median`, `trimByPercentile`, `hashRecords`, `fetchText`, `fetchJson`, `log`, plus minimal viem-compatible ABIs.
- **Agent repo cutover** — replaced the duplicated `src/sdk/` copy with `@registrai/agent-sdk` as a dependency. Net delta: −477 LOC, +27 LOC. Worker still bundles cleanly via wrangler dry-run; tsc clean; 13/13 tests pass.
- **Status badge pass** — audited every page on the site so `beta`/`soon` labels match reality. Feed detail page was missing the per-page badge; added.

---

## 2026-05-13 · Macro agents + Markets v5 with LP shares & fees

**Shipped**

- **Two new first-party oracle agents**, both Cloudflare-Worker-driven on a daily 14:00 UTC cron:
  - **Polish CPI Y/Y** in basis points — sources from GUS official monthly inflation reports
  - **ECB main refinancing operations rate** in basis points — sources from ECB Statistical Data Warehouse
- Each agent ships with its own methodology document hashed and pinned for verification: [`warsaw-resi-v1.md`](https://github.com/registrai-multichain/contracts/blob/main/methodology/warsaw-resi-v1.md), [`polish-cpi-v1.md`](https://github.com/registrai-multichain/contracts/blob/main/methodology/polish-cpi-v1.md), [`ecb-rate-v1.md`](https://github.com/registrai-multichain/contracts/blob/main/methodology/ecb-rate-v1.md).
- **Markets v5** — fundamentally upgraded:
  - **70 bps trading fee** per trade, split **40 / 20 / 10** to creator / agent / treasury. Oracle layer remains free; revenue only on Markets.
  - **LP shares** — `addLiquidity` mints proportional shares against current reserves (Polymarket-style: preserves pool odds rather than drifting toward 50/50).
  - **`claimLP`** — after resolution, LPs withdraw their share of the snapshotted winning-side reserve.
  - **`redeem()` decoupled from reserves** — user outcome balances and pool reserves are now separate buckets. Burning user shares no longer drains the LP pot.
- 7 markets seeded across the 3 feeds, all live.

**Notable engineering**

- Fixed stack-too-deep in `Markets.sell` by enabling `via_ir + optimizer = true`. The viaIR pass exposed a latent test bug in `test_valueAt_walksHistory` where two `block.timestamp` reads were being folded into one local; fixed with explicit `vm.warp(literal)` + `uint256 t = literal`.
- First attempt at proportional `addLiquidity` drifted price toward 50/50 when reserves were imbalanced. Polymarket-style fix: `yesToPool = amount * y / total`, user receives residual outcome shares.
- First attempt at `claimLP` decremented `totalLpShares` per claim, causing remaining LPs to claim 100% of the pot. Fixed by leaving `totalLpShares` constant and only zeroing the claimer's slot.

---

## 2026-05-11 to 2026-05-12 · Bootstrap on Arc testnet

**Shipped**

- Initial contracts deployed to Arc testnet (chain id 5042002):
  - [`Registry`](https://testnet.arcscan.app/address/0xA8E6f5aC6410231Db1422f3B17987Cf657807224) — feed creation, agent registration with bond
  - [`Attestation`](https://testnet.arcscan.app/address/0x04227E2e53041165CB38D5C0aFadCC95096ae5f4) — agent-signed value submissions with dispute-window finalization
  - [`Dispute`](https://testnet.arcscan.app/address/0x113200D3515758C70ea75fE636e579cCed4066A5) — symmetric-bond disputes, slashing on `ResolvedInvalid`
  - [`Markets`](https://testnet.arcscan.app/address/0xcaB9aB405F89AC701c3CAcCF110bF94f3A10cD86) — binary prediction markets resolved by attestations, FPMM trading
  - [`Markets/EURC`](https://testnet.arcscan.app/address/0x3e456845aa2747a617EBe91Cd04e74752D890833) — same Markets code over EURC collateral, proving currency-agnosticism
- **First feed**: Warsaw residential PLN/sqm. First-party agent registered, bonded, attesting daily at 14:00 UTC.
- **Frontend** at [registrai.cc](https://registrai.cc) — Next.js 14 static export on Cloudflare Pages, viem for chain reads, JetBrains Mono + Instrument Serif (data-terminal aesthetic).

---

*This devlog is updated as work happens. The canonical source is [`contracts/DEVLOG.md`](https://github.com/registrai-multichain/contracts/blob/main/DEVLOG.md); the live render is at [registrai.cc/devlog](https://registrai.cc/devlog).*
