# Registrai · Contracts

Solidity contracts for **Registrai** — a permissionless onchain registry of bonded oracle agents, plus a binary prediction-market layer that resolves automatically against those agents' attestations. Multichain by design — deployed first on **Arc testnet** (Circle's stablecoin-native chain), porting to HyperEVM and Sui as the protocol expands.

## What's in here

| Contract | Purpose |
|---|---|
| `Registry.sol` | Feeds, agents, bonds, slashing accounting. Bonds lock during pending disputes. |
| `Attestation.sol` | Agents publish signed attestations; finalization respects the dispute window. |
| `Dispute.sol` | Optimistic challenge flow with symmetric stakes; per-feed resolver decides. |
| `Markets.sol` | Constant-product binary prediction markets. Resolves against `Attestation.valueAt` at expiry. 0.70% trading fee, split 40 bps creator / 20 bps agent / 10 bps treasury. |

## Live deployment

Arc testnet (chain id `5042002`):

| Contract | Address |
|---|---|
| Registry | [`0xa7db7FA00193baC5315335899b008A013FAFf384`](https://testnet.arcscan.app/address/0xa7db7FA00193baC5315335899b008A013FAFf384) |
| Attestation | [`0x9F1B338326cfb4389e70AEb5685ed5491E60aBE5`](https://testnet.arcscan.app/address/0x9F1B338326cfb4389e70AEb5685ed5491E60aBE5) |
| Dispute | [`0x96E46513955ECb09eEECca36ee04A18D79785D11`](https://testnet.arcscan.app/address/0x96E46513955ECb09eEECca36ee04A18D79785D11) |
| Markets · USDC | [`0xabB8Ad614dacF8F402Ad15EC07B85f300899C8BF`](https://testnet.arcscan.app/address/0xabB8Ad614dacF8F402Ad15EC07B85f300899C8BF) |
| Markets · EURC | [`0x3d2A1B77475aaB7E2e074C4Aa0b51c764831D669`](https://testnet.arcscan.app/address/0x3d2A1B77475aaB7E2e074C4Aa0b51c764831D669) |

Frontend: [registrai.cc](https://registrai.cc).
Full deployment manifest: [`deployments/arc-testnet.json`](./deployments/arc-testnet.json).

## Develop

```sh
forge test                        # 48 tests
```

## Deploy

```sh
USDC=0x3600000000000000000000000000000000000000 \
forge script script/Deploy.s.sol \
  --rpc-url $RPC \
  --private-key $PRIVATE_KEY \
  --broadcast
```

For the EURC variant of Markets, see `script/DeployMarketsEURC.s.sol`.

## Read a feed in three lines

```solidity
IAttestation oracle = IAttestation(0x9F1B...);
(int256 value, uint256 timestamp, bool finalized) =
    oracle.latestValue(feedId, agentAddress);
```

Don't trust unfinalized values in money-moving paths — wait for the dispute window to close.

## Promises

- **No admin keys.** Contracts are immutable from block one.
- **No protocol token.** Bonds in USDC, no governance asset.
- **Oracle layer free.** The registry charges nothing — reading, attesting, bonding is free forever.
- **Markets layer earns.** 0.7% trading fee, 40/20/10 split between creator, agent, and treasury. Real revenue, no token speculation.

## Security

- 48 Foundry tests covering happy paths, access control, slashing math, dispute flow, FPMM solvency, agent registration check.
- Disclosure: open a GitHub issue or contact the team via [registrai.cc](https://registrai.cc).

## License

MIT. See [LICENSE](./LICENSE).
