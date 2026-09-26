#!/usr/bin/env bash
# Generate RegiBuybackRehearsal.sol from src/buyback/RegiBuyback.sol for a TESTNET rehearsal:
# identical source except the contract name and four round constants (a $2 trigger,
# $0.50 chunks, 1-minute cooldown), so a testnet wallet with a few USDC can drive a full
# round through Arc's real native-USDC transfer path. --check exits 1 if the committed
# copy has drifted from the real contract.
set -euo pipefail
cd "$(dirname "$0")/../../.."
gen() {
  sed -e 's/^contract RegiBuyback is /contract RegiBuybackRehearsal is /' \
      -e 's/uint256 public constant TRIGGER = 200e6;/uint256 public constant TRIGGER = 2e6; \/\/ REHEARSAL (mainnet: 200e6)/' \
      -e 's/uint256 public constant CHUNK = 50e6;/uint256 public constant CHUNK = 0.5e6; \/\/ REHEARSAL (mainnet: 50e6)/' \
      -e 's/uint256 public constant COOLDOWN = 10 minutes;/uint256 public constant COOLDOWN = 1 minutes; \/\/ REHEARSAL (mainnet: 10 minutes)/' \
      -e 's#import {PoolKey, SwapParams, IPoolManagerMinimal, IUnlockCallback, V4Lib} from "./UniswapV4Minimal.sol";#import {PoolKey, SwapParams, IPoolManagerMinimal, IUnlockCallback, V4Lib} from "../../../src/buyback/UniswapV4Minimal.sol";#' \
      -e 's#import {INanoLedgerMinimal} from "./INanoLedgerMinimal.sol";#import {INanoLedgerMinimal} from "../../../src/buyback/INanoLedgerMinimal.sol";#' \
      src/buyback/RegiBuyback.sol
}
OUT=test/buyback/rehearsal/RegiBuybackRehearsal.sol
if [ "${1:-}" = "--check" ]; then diff <(gen) "$OUT" >/dev/null && echo "rehearsal copy matches RegiBuyback.sol" || { echo "rehearsal copy drifted: rerun make-rehearsal.sh" >&2; exit 1; }; exit 0; fi
gen > "$OUT"
# Exactly 6 lines differ from the real contract: name, 3 constants, 2 import paths.
n=$(diff src/buyback/RegiBuyback.sol "$OUT" | grep -c '^>' || true)
[ "$n" = 6 ] || { echo "expected 6 changed lines, got $n" >&2; exit 1; }
echo "wrote $OUT (6 lines differ: name, TRIGGER, CHUNK, COOLDOWN, 2 imports)"
