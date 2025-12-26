#!/bin/bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"

# Sender/recipient used previously in successful Nile tests
FROM="${FROM_ADDRESS:-TKWvD71EMFTpFVGZyqqX9fC6MQgcR9H76M}"
TO="${TO_ADDRESS:-TFZMxv9HUzvsL3M7obrvikSQkuvJsopgMU}"

COUNT="${COUNT:-20}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-0.1}"

echo "Submitting ${COUNT} intents to ${BASE_URL}"
echo "FROM=${FROM}"
echo "TO=${TO}"

# Capture baseline
BASELINE=$(curl -s "${BASE_URL}/api/monitor/batches")
BASELINE_BATCHES=$(echo "$BASELINE" | jq -r '.totalBatches')
BASELINE_TRANSFERS=$(echo "$BASELINE" | jq -r '.statistics.totalTransfers')
echo "Baseline: totalBatches=${BASELINE_BATCHES}, totalTransfers=${BASELINE_TRANSFERS}"

TS=$(date +%s)

for ((i=0; i<COUNT; i++)); do
  NONCE=$((TS + i))
  AMOUNT=$((1000000 + (i * 10000))) # 1.0 + i*0.01 token (assuming 6 decimals)
  TXTYPE=$(( i % 2 )) # alternate 0 (DELAYED), 1 (INSTANT)

  # recipientCount must be 1 for txType 0/1
  BODY=$(jq -nc --arg from "$FROM" --arg to "$TO" --arg amount "$AMOUNT" \
    --argjson nonce "$NONCE" --argjson timestamp "$TS" --argjson recipientCount 1 --argjson txType "$TXTYPE" \
    '{from:$from,to:$to,amount:$amount,nonce:$nonce,timestamp:$timestamp,recipientCount:$recipientCount,txType:$txType}')

  HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/api/intents" \
    -H "Content-Type: application/json" -d "$BODY")

  if [ "$HTTP" != "202" ]; then
    echo "Failed submit at i=$i (HTTP=$HTTP)"
    echo "$BODY"
    exit 1
  fi

  printf "submitted %2d/%d nonce=%d txType=%d amount=%s\n" $((i+1)) "$COUNT" "$NONCE" "$TXTYPE" "$AMOUNT"
  sleep "$SLEEP_BETWEEN"
done

echo
echo "Waiting for batching+execution..."

# Wait until we see expected number of new transfers and completed batches stabilizing.
# With default scheduler.maxIntents=5, expect ~4 new batches for 20 intents.
DEADLINE=$(( $(date +%s) + 180 ))

while [ $(date +%s) -lt $DEADLINE ]; do
  RESP=$(curl -s "${BASE_URL}/api/monitor/batches")
  TOTAL_BATCHES=$(echo "$RESP" | jq -r '.totalBatches')
  TOTAL_TRANSFERS=$(echo "$RESP" | jq -r '.statistics.totalTransfers')
  EXECUTED_TRANSFERS=$(echo "$RESP" | jq -r '.statistics.executedTransfers')

  NEW_BATCHES=$((TOTAL_BATCHES - BASELINE_BATCHES))
  NEW_TRANSFERS=$((TOTAL_TRANSFERS - BASELINE_TRANSFERS))

  echo "status: newBatches=${NEW_BATCHES} newTransfers=${NEW_TRANSFERS} executed=${EXECUTED_TRANSFERS}/${TOTAL_TRANSFERS}"

  # We consider "done" when we have at least COUNT new transfers AND all transfers are executed.
  if [ "$NEW_TRANSFERS" -ge "$COUNT" ] && [ "$EXECUTED_TRANSFERS" -eq "$TOTAL_TRANSFERS" ]; then
    echo "All transfers executed."
    break
  fi
  sleep 5
done

echo
echo "Monitor batches:"
echo "${BASE_URL}/api/monitor/batches"



