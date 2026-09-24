#!/usr/bin/env bash
#
# Bridge USDC to/from Arc over Circle's CCTP v2, entirely from the CLI.
#
# No MetaMask, no browser, no wallet that knows about chain 5042. This exists
# because Arc cannot be added to most wallets today (Circle publishes no public
# mainnet RPC), and because deploying contracts never needed a wallet UI anyway.
#
#   ./cctp-bridge.sh <source-chain> <amount-usdc> [recipient]
#
# Example:
#   PRIVATE_KEY=0x... ./cctp-bridge.sh base 25
#
# Steps: approve -> depositForBurn (burn on source) -> poll Circle's attestation
# -> receiveMessage (mint on Arc).
#
# IMPORTANT: step 4 costs gas ON ARC. Gas on Arc is USDC, so the very first
# transfer cannot self-relay — you need a small USDC balance on Arc first. See
# "Bootstrapping gas" in src/bridge/README.md. Once you hold ~1 USDC on Arc you
# can relay unlimited transfers (a mint costs ~0.006 USDC).
#
# The mint is permissionless (destinationCaller = 0), so ANY funded address can
# deliver it — set RELAY_KEY to relay with a different key than the one that burned.

set -euo pipefail

TOKEN_MESSENGER=0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d
MESSAGE_TRANSMITTER=0x81D40F21F12A8F0E3252Bccb954D722d4c464B64
ARC_DOMAIN=26
ARC_RPC="${ARC_RPC:-https://rpc.mainnet.arc.io}"   # Circle canonical endpoint only
IRIS=https://iris-api.circle.com

case "${1:-}" in
  ethereum)  SRC_RPC=https://ethereum-rpc.publicnode.com;      SRC_DOMAIN=0;  USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 ;;
  base)      SRC_RPC=https://base-rpc.publicnode.com;          SRC_DOMAIN=6;  USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 ;;
  arbitrum)  SRC_RPC=https://arbitrum-one-rpc.publicnode.com;  SRC_DOMAIN=3;  USDC=0xaf88d065e77c8cC2239327C5EDb3A432268e5831 ;;
  optimism)  SRC_RPC=https://optimism-rpc.publicnode.com;      SRC_DOMAIN=2;  USDC=0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85 ;;
  polygon)   SRC_RPC=https://polygon-bor-rpc.publicnode.com;   SRC_DOMAIN=7;  USDC=0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359 ;;
  arc)       SRC_RPC="$ARC_RPC";                               SRC_DOMAIN=26; USDC=0x3600000000000000000000000000000000000000 ;;
  *) echo "usage: $0 <ethereum|base|arbitrum|optimism|polygon|arc> <amount-usdc> [recipient]"; exit 1 ;;
esac

AMOUNT_HUMAN="${2:?amount in USDC required}"
: "${PRIVATE_KEY:?export PRIVATE_KEY}"

SENDER=$(cast wallet address --private-key "$PRIVATE_KEY")
RECIPIENT="${3:-$SENDER}"
AMOUNT=$(python3 -c "print(int(round(float('$AMOUNT_HUMAN')*10**6)))")

# Arc's burn cap is 100k USDC per message; other chains allow 10M.
echo "source        : $1 (domain $SRC_DOMAIN)"
echo "destination   : Arc (domain $ARC_DOMAIN)"
echo "sender        : $SENDER"
echo "recipient     : $RECIPIENT"
echo "amount        : $AMOUNT_HUMAN USDC ($AMOUNT base units)"

BAL=$(cast call "$USDC" "balanceOf(address)(uint256)" "$SENDER" --rpc-url "$SRC_RPC" | awk '{print $1}')
echo "source balance: $(python3 -c "print(f'{$BAL/1e6:,.6f}')") USDC"
[ "$BAL" -ge "$AMOUNT" ] || { echo "ERROR: insufficient USDC on source chain"; exit 1; }

# Standard transfer: free, waits for source finality. Fast costs a fraction of
# a bp and settles in seconds — pass FAST=1 to use it.
if [ "${FAST:-0}" = "1" ]; then
  FINALITY=1000
  FEE_BPS=$(curl -s "$IRIS/v2/burn/USDC/fees/$SRC_DOMAIN/$ARC_DOMAIN" \
    | python3 -c "import json,sys;print(next(t['minimumFee'] for t in json.load(sys.stdin) if t['finalityThreshold']==1000))")
  MAX_FEE=$(python3 -c "print(max(1,int($AMOUNT*$FEE_BPS/10000*1.5)))")
  echo "speed         : FAST (Circle fee ${FEE_BPS} bps, maxFee $MAX_FEE)"
else
  FINALITY=2000; MAX_FEE=0
  echo "speed         : STANDARD (free, waits for source finality)"
fi

MINT_RECIPIENT=$(cast to-uint256 "$(cast to-dec "$RECIPIENT")")

echo
echo "[1/4] approving $TOKEN_MESSENGER ..."
cast send "$USDC" "approve(address,uint256)" "$TOKEN_MESSENGER" "$AMOUNT" \
  --private-key "$PRIVATE_KEY" --rpc-url "$SRC_RPC" >/dev/null
echo "      ok"

echo "[2/4] depositForBurn ..."
BURN_TX=$(cast send "$TOKEN_MESSENGER" \
  "depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32)" \
  "$AMOUNT" "$ARC_DOMAIN" "$MINT_RECIPIENT" "$USDC" \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  "$MAX_FEE" "$FINALITY" \
  --private-key "$PRIVATE_KEY" --rpc-url "$SRC_RPC" --json | python3 -c "import json,sys;print(json.load(sys.stdin)['transactionHash'])")
echo "      burn tx: $BURN_TX"

echo "[3/4] waiting for Circle's attestation ..."
for i in $(seq 1 200); do
  RESP=$(curl -s "$IRIS/v2/messages/$SRC_DOMAIN?transactionHash=$BURN_TX" || true)
  STATUS=$(echo "$RESP" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin); m=(d.get('messages') or [{}])[0]
    print(m.get('status','pending'))
except Exception: print('indexing')" 2>/dev/null || echo indexing)
  if [ "$STATUS" = "complete" ]; then echo "      attested after $((i*5))s"; break; fi
  printf '\r      status=%s  %ss elapsed' "$STATUS" "$((i*5))"; sleep 5
done
[ "$STATUS" = "complete" ] || { echo; echo "ERROR: not attested yet. The burn is on-chain and stays valid — rerun the relay step later with burn tx $BURN_TX"; exit 1; }

MESSAGE=$(echo "$RESP" | python3 -c "import json,sys;print(json.load(sys.stdin)['messages'][0]['message'])")
ATTESTATION=$(echo "$RESP" | python3 -c "import json,sys;print(json.load(sys.stdin)['messages'][0]['attestation'])")

echo "[4/4] delivering the mint on Arc ..."
RELAY="${RELAY_KEY:-$PRIVATE_KEY}"
RELAYER=$(cast wallet address --private-key "$RELAY")
RELAY_GAS=$(cast balance "$RELAYER" --rpc-url "$ARC_RPC")
echo "      relayer $RELAYER holds $(python3 -c "print(f'{$RELAY_GAS/1e18:.6f}')") USDC on Arc"
if [ "$RELAY_GAS" = "0" ]; then
  cat <<EOF

      STOPPED: the relayer has no gas on Arc, and gas on Arc is USDC.
      Your burn is complete and the attestation is valid indefinitely.

      Get ~1 USDC onto Arc, then rerun just this step:
        cast send $MESSAGE_TRANSMITTER "receiveMessage(bytes,bytes)" \\
          $MESSAGE \\
          $ATTESTATION \\
          --private-key \$RELAY_KEY --rpc-url $ARC_RPC

      Or set RELAY_KEY to any address that already has USDC on Arc — the mint
      is permissionless and still pays out to $RECIPIENT.
EOF
  exit 2
fi

cast send "$MESSAGE_TRANSMITTER" "receiveMessage(bytes,bytes)" "$MESSAGE" "$ATTESTATION" \
  --private-key "$RELAY" --rpc-url "$ARC_RPC" >/dev/null
echo "      minted"

echo
NEW=$(cast call "$USDC" "balanceOf(address)(uint256)" "$RECIPIENT" --rpc-url "$ARC_RPC" 2>/dev/null | awk '{print $1}' || echo 0)
echo "Arc balance of $RECIPIENT: $(python3 -c "print(f'{${NEW:-0}/1e6:,.6f}')") USDC"
echo "That balance is also your gas — on Arc they are the same balance."
