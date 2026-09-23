# BridgeRouter — bidirectional USDC over CCTP v2

A fee-taking wrapper over Circle's CCTP v2. Every chain ↔ Arc, both directions.

Not a bridge in the custody sense: it holds no liquidity, mints nothing, and
retains no balance between transactions. It takes a basis-point fee on the
source chain and forwards the remainder to Circle's canonical `TokenMessenger`,
which burns it and mints native USDC on the destination. Every transfer emits
`DepositForBurn` **from Circle's own contract** — that verifiability is the
product differentiator, given the pre-launch Arc namespace contains sites that
took deposits and never burned anything.

## Verified facts (checked live, not from docs)

| Thing | Value |
|---|---|
| Arc CCTP domain | **26** (`MessageTransmitterV2.localDomain()`) |
| Arc native USDC | `0x3600000000000000000000000000000000000000`, 6 decimals |
| Arc per-message burn cap | **100,000 USDC** (other chains: 10,000,000) |
| `depositForBurn` selector | `0x8e0250ee` — v2 only; v1's `0x6fd3504e` is absent |
| Fast transfer INTO Arc | 0.25 bps (Ethereum), 0.325 (Base), 0.35 (Arbitrum) |
| Fast transfer OUT of Arc | **0 bps** — currently free |
| Standard transfer | 0 bps both directions |

Fees are **not symmetric** and change per route — always read them from
`https://iris-api.circle.com/v2/burn/USDC/fees/{src}/{dst}` rather than assuming.

On Arc, USDC is the gas token and `0x3600…0000` is the ERC-20 *view of the
native balance* (verified: native and ERC-20 balances match for the same
account). A bridged user therefore arrives already holding gas — no faucet,
no second step.

## One address on every chain

Deployed through CreateX CREATE3, so the address does not depend on the
initcode — which matters because the constructor takes a per-chain USDC
address. CREATE2 would give eleven different addresses.

Salt layout required by CreateX's `_guard`:

```
bytes[0..20)  deployer address   -> permissioned; only this EOA can use it
byte[20]      0x00               -> NO cross-chain redeploy protection.
                                    0x01 hashes in block.chainid and would
                                    produce a different address per chain.
bytes[21..32) keccak256("registrai.bridge.router.v1")[0..11]
```

For deployer `0xb7eCf980a4732B75E57e2eC80903deE3964F2573` the router lands at:

```
0xad96eAAa50C2c8919169980Efe8c46eD6b175b67
```

This deployer is separate from the testnet deployer/treasury/agent key
(`0x84C7…2E5e`), so a compromise of the attesting agent does not carry the
bridge with it. **Change the deployer and this address changes** — recompute
before publishing it anywhere:

```bash
DEP=<deployer>
SALT="$(echo $DEP | tr 'A-Z' 'a-z')00$(cast keccak 'registrai.bridge.router.v1' | cut -c3-24)"
GUARDED=$(cast keccak "$(cast abi-encode 'f(address,bytes32)' $DEP $SALT)")
cast call 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed \
  "computeCreate3Address(bytes32,address)(address)" \
  $GUARDED 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed --rpc-url <any-rpc>
```

CreateX is deployed byte-identical at `0xba5Ed0…ba5Ed` on all eleven chains,
Arc included.

## Deploy

```bash
export PRIVATE_KEY=0x...
export FEE_RECIPIENT=0x...        # where the router fee lands
export ROUTER_OWNER=0x...         # optional, defaults to FEE_RECIPIENT
export FEE_BPS=50                 # 0.50% == MAX_FEE_BPS, the contract's hard cap

forge script script/DeployBridgeRouter.s.sol --rpc-url <chain> --broadcast
```

Re-running against an already-deployed chain is a no-op. The script asserts the
deployed address matches its prediction and that USDC/messenger/fee/owner were
wired correctly, so a mismatch aborts rather than leaving a half-configured
router.

Chains: Arc, Ethereum, Base, Arbitrum, OP Mainnet, Polygon PoS, Avalanche,
Unichain, Linea, World Chain, Sonic.

## Fee

`feeBps` is configurable by the owner but hard-capped at **`MAX_FEE_BPS = 50`
(0.50%)** as a compile-time constant. The owner cannot raise it beyond that,
which is the point: a bridge whose operator can set an arbitrary fee is a
bridge that can rug.

We launch **at** the cap, 50 bps. That has a useful consequence worth saying
out loud in the UI: our fee can only ever go **down**. It also means there is
no headroom — raising it later would require deploying a new router at a new
address, which is deliberate friction.

For reference, the competition: `cctpbridge.app` charges 50 bps,
`unstabletrd.com` charges 300 bps plus a maker premium that clears around
2.1–2.6× face, and `dyorarc.fun` charged 100–300 bps and never burned anything.

## Tests

```bash
forge test --match-contract BridgeRouterTest          # 14 unit + fuzz
forge test --match-contract BridgeRouterDeployTest    # CREATE3 address identity
forge test --match-contract BridgeRouterForkTest --fork-url https://base-rpc.publicnode.com
```

The fork suite is the one that matters: it runs against Circle's **real**
deployed `TokenMessengerV2` on Base and asserts Circle's own `DepositForBurn`
fires with the router as depositor and Arc (domain 26) as destination. The
mock suite only proves the mock works.

Invariants covered by fuzzing: the router never retains a balance at any fee
level or amount, and `routerFee + amountBurned == amountIn` exactly.

## Bootstrapping gas on Arc

A genuine chicken-and-egg, and it is the one thing that actually gates the
first transfer.

CCTP is burn-and-mint. The mint half is a transaction **on Arc**, and gas on
Arc is USDC — so receiving your first USDC on Arc requires already holding USDC
on Arc. Measured over 100,000 recent blocks (~14h), **zero** CCTP mints were
delivered on Arc: nobody is auto-relaying, and `faucet.circle.com` is testnet
only. There is no ARC token to buy for gas; ARC exists (10B supply, $222M
presale to a16z/BlackRock/Apollo/ICE at $3B FDV) but it is a governance and
validator-coordination asset, not gas, and not publicly available.

What it actually costs, at Arc's 40 gwei:

| Operation | Gas | Cost |
|---|---|---|
| `receiveMessage` (deliver a CCTP mint) | ~150k | **0.006 USDC** |
| Deploy `BridgeRouter` | ~1.2M | **0.048 USDC** |
| Deploy Registry + Attestation + Dispute + Markets | ~6M | **0.24 USDC** |

So the bootstrap requirement is about **one dollar**, not a funding round.

The cheap way in is the part of the OTC book everyone dismisses. The headline
offers clear at 2.0–2.6× face, but the sub-1-USDC dust is priced near par
because nobody wants it — and dust is exactly what a gas bootstrap needs:

| Receive on Arc | Premium | You pay | Rate |
|---|---|---|---|
| 0.20 | 5% | 0.22 | 1.08× |
| 0.30 | 12.5% | 0.35 | 1.16× |
| 0.50 | 17% | 0.60 | 1.21× |
| 0.61 | 18% | 0.74 | 1.22× |
| … 14 offers under 1.41× … | | | |

Sweeping only the offers below ~1.4× yields roughly **5.7 USDC on Arc for about
7.25 USDC on Ethereum**. That is ~950 CCTP mints or ~119 router deploys of gas.
Ignore everything above 1.5×: real money should cross via CCTP at par, and only
the gas seed is worth paying a premium for.

Once seeded, `script/cctp-bridge.sh` self-relays every subsequent transfer and
no premium is ever paid again. The mint is permissionless
(`destinationCaller = 0`), so `RELAY_KEY` can be any funded Arc address while
the USDC still lands at the intended recipient.

## No wallet required

Arc cannot be added to most wallets today — Circle publishes no public mainnet
RPC (chain 5042 is registered with an empty `rpc` array; `rpc.mainnet.arc.io`
returns 403), and even after a manual add, MetaMask will not display USDC
without a `wallet_watchAsset` call (circlefin/arc-node#97).

None of that blocks us. Deployment and relaying are `forge`/`cast` against an
RPC URL; all three working Arc endpoints accept `eth_sendRawTransaction`. The
browser bridge is for users, not for operating the protocol.
