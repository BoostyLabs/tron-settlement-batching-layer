#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# 🚀 FULL FLOW TEST - 2 INTENTS (txType=2 / BATCHED) ON NILE
# ═══════════════════════════════════════════════════════════════════════════
#
# Goal:
# - Submit 2 intents with txType=2 (BATCHED)
# - Force batch creation
# - Verify whitelistProof is NON-EMPTY for each transfer (this validates whitelist service)
# - Monitor execution until COMPLETED
#
# Requirements:
# - Backend running at BASE_URL
# - FROM address is included in whitelist.addresses
# - Backend logs should show "Whitelist root already matches config" (or successful sync)

BASE_URL="${BASE_URL:-http://localhost:8080}"
FROM_ADDRESS="${FROM_ADDRESS:-TKWvD71EMFTpFVGZyqqX9fC6MQgcR9H76M}"
TO_ADDRESS="${TO_ADDRESS:-TFZMxv9HUzvsL3M7obrvikSQkuvJsopgMU}"

TIMESTAMP=$(date +%s)
TXTYPE=2

echo "Submitting 2 intents (txType=${TXTYPE}) to ${BASE_URL}"
echo "FROM=${FROM_ADDRESS}"
echo "TO=${TO_ADDRESS}"
echo

if ! curl -s -f "${BASE_URL}/api/monitor/stats" >/dev/null 2>&1; then
  echo "❌ Backend is not running at ${BASE_URL}"
  exit 1
fi

STATS=$(curl -s "${BASE_URL}/api/monitor/stats")
BATCHING_ENABLED=$(echo "$STATS" | jq -r '.schedulers.batching.enabled')
EXECUTION_ENABLED=$(echo "$STATS" | jq -r '.schedulers.execution.enabled')
if [ "$BATCHING_ENABLED" != "true" ] || [ "$EXECUTION_ENABLED" != "true" ]; then
  echo "❌ Schedulers must be enabled."
  echo "  batching.enabled=$BATCHING_ENABLED"
  echo "  execution.enabled=$EXECUTION_ENABLED"
  exit 1
fi

NONCE1=$TIMESTAMP
NONCE2=$((TIMESTAMP + 1))

AMOUNT1=1000000
AMOUNT2=2000000
# For txType=2 (BATCHED) the FeeModule requires recipientCount > 1.
# For this 2-intents batch, recipientCount=2 is the natural value.
RECIPIENT_COUNT=2

submit_intent() {
  local nonce="$1"
  local amount="$2"
  local body
  body=$(jq -nc \
    --arg from "$FROM_ADDRESS" \
    --arg to "$TO_ADDRESS" \
    --arg amount "$amount" \
    --argjson nonce "$nonce" \
    --argjson timestamp "$TIMESTAMP" \
    --argjson recipientCount "$RECIPIENT_COUNT" \
    --argjson txType "$TXTYPE" \
    '{from:$from,to:$to,amount:$amount,nonce:$nonce,timestamp:$timestamp,recipientCount:$recipientCount,txType:$txType}')

  local http
  http=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/api/intents" \
    -H "Content-Type: application/json" -d "$body")
  if [ "$http" != "202" ]; then
    echo "❌ Intent submit failed (HTTP=$http): $body"
    exit 1
  fi
}

echo "Submitting intent 1..."
submit_intent "$NONCE1" "$AMOUNT1"
echo "✅ Intent 1 submitted"

echo "Submitting intent 2..."
submit_intent "$NONCE2" "$AMOUNT2"
echo "✅ Intent 2 submitted"
echo

echo "Triggering batch creation..."
RESP=$(curl -s -X POST "${BASE_URL}/api/monitor/create-batch-now")
OK=$(echo "$RESP" | jq -r '.success // false')
if [ "$OK" != "true" ]; then
  echo "❌ create-batch-now failed:"
  echo "$RESP" | jq '.'
  exit 1
fi

BATCH_ID=$(echo "$RESP" | jq -r '.batchId')
echo "✅ Batch created: batchId=${BATCH_ID}"
echo

echo "Checking whitelistProof..."
DETAILS=$(curl -s "${BASE_URL}/api/monitor/batch/${BATCH_ID}")
WL_SIZES=$(echo "$DETAILS" | jq -r '.batch.transfers | map(.whitelistProofSize)')
echo "whitelistProof sizes: ${WL_SIZES}"

EMPTY_CNT=$(echo "$DETAILS" | jq -r '[.batch.transfers[] | .whitelistProofSize] | map(select(. == 0)) | length')
if [ "$EMPTY_CNT" != "0" ]; then
  echo "❌ whitelistProof is empty for ${EMPTY_CNT} transfers."
  echo "This means the backend did NOT generate whitelist proofs (txType=2 will revert NotWhitelisted)."
  echo "Fix:"
  echo "  - Ensure FROM is in whitelist.addresses (TRON base58)."
  echo "  - Restart backend (whitelist root sync runs on startup)."
  exit 1
fi
echo "✅ whitelistProof generated for all transfers"
echo

echo "Monitoring execution (up to 60s)..."
DEADLINE=$(( $(date +%s) + 60 ))
while [ $(date +%s) -lt $DEADLINE ]; do
  DETAILS=$(curl -s "${BASE_URL}/api/monitor/batch/${BATCH_ID}")
  STATUS=$(echo "$DETAILS" | jq -r '.batch.status')
  EXECUTED=$(echo "$DETAILS" | jq -r '.batch.transfers | map(select(.executed == true)) | length')
  TOTAL=$(echo "$DETAILS" | jq -r '.batch.transfers | length')
  echo "status=${STATUS} executed=${EXECUTED}/${TOTAL}"

  if [ "$STATUS" = "COMPLETED" ]; then
    echo "✅ COMPLETED"
    exit 0
  fi
  if [ "$STATUS" = "FAILED" ]; then
    echo "❌ FAILED (check backend logs for revert reason)"
    exit 1
  fi
  sleep 5
done

echo "⚠️ Timed out waiting for completion. Check:"
echo "  ${BASE_URL}/api/monitor/batch/${BATCH_ID}"
exit 1


