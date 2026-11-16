#!/usr/bin/env bash
# Deploys the testnet stand-ins the testnet deployment needs on the Robinhood testnet (46630) and records them in
# $QZ_DEPLOYMENTS_DIR/robinhood-testnet.assets.json (default <repo>/deployments). Idempotent: when the file exists and
# its USDG has code on QZ_RPC_URL, nothing is deployed. `deploy-r1.sh robinhood-testnet` runs this first.
#   QZ_RPC_URL, DEPLOYER_PRIVATE_KEY (environment only), QZ_WETH (optional, default: the testnet's real WETH9).
# It moves the deployer nonce: run it BEFORE `deploy-lz.sh testnet predict` (which seals an adapter address for the
# nonce the testnet deployment will start at).
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS="$(cd "$HERE/../.." && pwd)"
REPO="$(cd "$CONTRACTS/.." && pwd)"
DEPLOYMENTS_DIR="${QZ_DEPLOYMENTS_DIR:-$REPO/deployments}"
FILE="$DEPLOYMENTS_DIR/robinhood-testnet.assets.json"
RPC="${QZ_RPC_URL:?QZ_RPC_URL required}"
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY required}"

if [ -f "$FILE" ] && [ "$(cast codesize "$(jq -r .usdg "$FILE")" --rpc-url "$RPC" 2>/dev/null || echo 0)" != "0" ]; then
  echo "testnet assets exist: $FILE"
  exit 0
fi
mkdir -p "$DEPLOYMENTS_DIR"
OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT
(cd "$CONTRACTS" && forge script script/testnet/DeployTestnetAssets.s.sol:DeployTestnetAssets --rpc-url "$RPC" --broadcast > "$OUT" 2>&1) \
  || { tail -n 30 "$OUT" >&2; exit 1; }
sed -n 's/^ *QZ_ASSETS_JSON://p' "$OUT" | tail -n 1 | jq . > "$FILE.tmp"
mv "$FILE.tmp" "$FILE"
echo "deployed testnet assets: $FILE"
