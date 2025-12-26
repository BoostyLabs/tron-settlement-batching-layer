#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# 🚀 BATCHED FLOW TEST - 10 INTENTS (txType=2) ON NILE
# ═══════════════════════════════════════════════════════════════════════════
#
# What this script does:
# 1) Checks backend + schedulers are running
# 2) Submits 10 intents with txType=2 (BATCHED)
# 3) Forces creation of batches immediately (expected: 2 batches with default maxIntents=5)
# 4) Monitors until all created batches are COMPLETED
#
# Important for txType=2:
# - Sender (from) must be in `whitelist.addresses`
# - On startup, backend tries to sync WhitelistRegistry root to match config
#   If you changed whitelist config, restart backend before running this script.

BASE_URL="${BASE_URL:-http://localhost:8080}"

# Sender/recipient used previously in successful Nile tests
FROM="${FROM_ADDRESS:-TKWvD71EMFTpFVGZyqqX9fC6MQgcR9H76M}"
TO="${TO_ADDRESS:-TFZMxv9HUzvsL3M7obrvikSQkuvJsopgMU}"

COUNT="${COUNT:-10}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-0.1}"
TXTYPE="${TXTYPE:-2}" # 2 = BATCHED (requires whitelist proof)
RECIPIENT_COUNT="${RECIPIENT_COUNT:-$COUNT}"

# FeeModule requires recipientCount > 1 for txType=2 (BATCHED).
if [ "${TXTYPE}" = "2" ] && [ "${RECIPIENT_COUNT}" -le 1 ]; then
  echo "❌ Invalid RECIPIENT_COUNT=${RECIPIENT_COUNT} for txType=2 (BATCHED). Must be > 1."
  echo "Tip: set RECIPIENT_COUNT=$COUNT (default) or at least 2."
  exit 1
fi

echo "BATCHED flow: submitting ${COUNT} intents to ${BASE_URL}"
echo "FROM=${FROM}"
echo "TO=${TO}"
echo "txType=${TXTYPE} (BATCHED)"
echo

# ────────────────────────────────────────────────────────────────────────────
# Step 0: backend/scheduler sanity checks
# ────────────────────────────────────────────────────────────────────────────
if ! curl -s -f "${BASE_URL}/api/monitor/stats" > /dev/null 2>&1; then
  echo "❌ Backend is not running at ${BASE_URL}"
  echo "Start it first: ./gradlew bootRun"
  exit 1
fi

BASELINE_BATCH_IDS=()
if curl -s -f "${BASE_URL}/api/monitor/batches" > /dev/null 2>&1; then
  # Track existing batch IDs so we can detect *all* new batches created (including ones created by scheduler).
  # NOTE: macOS ships Bash 3.2 by default (no `mapfile`), so we avoid it.
  BASELINE_BATCH_IDS=($(curl -s "${BASE_URL}/api/monitor/batches" | jq -r '.batches[].batchId'))
fi

STATS=$(curl -s "${BASE_URL}/api/monitor/stats")
BATCHING_ENABLED=$(echo "$STATS" | jq -r '.schedulers.batching.enabled')
EXECUTION_ENABLED=$(echo "$STATS" | jq -r '.schedulers.execution.enabled')
MAX_INTENTS=$(echo "$STATS" | jq -r '.schedulers.batching.maxIntents')

echo "Backend OK. Schedulers:"
echo "  batching.enabled=${BATCHING_ENABLED}"
echo "  execution.enabled=${EXECUTION_ENABLED}"
echo "  batching.maxIntents=${MAX_INTENTS}"
echo

if [ "${BATCHING_ENABLED}" != "true" ] || [ "${EXECUTION_ENABLED}" != "true" ]; then
  echo "❌ Schedulers must be enabled for this test."
  echo "Set env vars and restart backend:"
  echo "  SCHEDULER_BATCHING_ENABLED=true"
  echo "  SCHEDULER_EXECUTION_ENABLED=true"
  exit 1
fi

# Capture baseline counts
BASELINE_BATCHES=$(echo "$STATS" | jq -r '.statistics.totalBatches')
BASELINE_TRANSFERS=$(echo "$STATS" | jq -r '.statistics.totalTransfers')
echo "Baseline: totalBatches=${BASELINE_BATCHES}, totalTransfers=${BASELINE_TRANSFERS}"
echo

refresh_new_batch_ids() {
  # Recompute NEW_BATCH_IDS by diffing current /batches against BASELINE_BATCH_IDS.
  # Also keeps any already-known batch IDs (order: as discovered).
  local current_ids new_ids id old seen
  current_ids=($(curl -s "${BASE_URL}/api/monitor/batches" | jq -r '.batches[].batchId'))
  new_ids=()
  for id in "${current_ids[@]}"; do
    seen=false
    for old in "${BASELINE_BATCH_IDS[@]}"; do
      if [ "$id" = "$old" ]; then
        seen=true
        break
      fi
    done
    if [ "$seen" = "false" ]; then
      # ensure uniqueness in new_ids
      local already=false
      local x
      for x in "${new_ids[@]}"; do
        if [ "$x" = "$id" ]; then
          already=true
          break
        fi
      done
      if [ "$already" = "false" ]; then
        new_ids+=("$id")
      fi
    fi
  done
  NEW_BATCH_IDS=("${new_ids[@]}")
}

# ────────────────────────────────────────────────────────────────────────────
# Step 1: submit intents (txType=2)
# ────────────────────────────────────────────────────────────────────────────
TS=$(date +%s)

for ((i=0; i<COUNT; i++)); do
  NONCE=$((TS + i))
  AMOUNT=$((1000000 + (i * 10000))) # 1.0 + i*0.01 token (assuming 6 decimals)

  BODY=$(jq -nc --arg from "$FROM" --arg to "$TO" --arg amount "$AMOUNT" \
    --argjson nonce "$NONCE" --argjson timestamp "$TS" --argjson recipientCount "$RECIPIENT_COUNT" --argjson txType "$TXTYPE" \
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

# ────────────────────────────────────────────────────────────────────────────
# Step 2: force batch creation now (repeat until pending < 2)
# ────────────────────────────────────────────────────────────────────────────
echo "Triggering batch creation..."

# Some batches may be created by the scheduler while we are submitting/triggering.
# We'll detect the authoritative list of "new" batch IDs later by diffing /api/monitor/batches.
CREATED_BATCH_IDS=()

while true; do
  STATS=$(curl -s "${BASE_URL}/api/monitor/stats")
  PENDING=$(echo "$STATS" | jq -r '.statistics.pendingTransfers')

  if [ "$PENDING" -lt 2 ]; then
    if [ "$PENDING" -eq 1 ]; then
      echo "⚠️  1 pending intent remains; cannot create a valid batch (needs >=2)."
      echo "    Submit one more intent or wait for manual handling."
    fi
    break
  fi

  RESP=$(curl -s -X POST "${BASE_URL}/api/monitor/create-batch-now")
  OK=$(echo "$RESP" | jq -r '.success // false')
  if [ "$OK" != "true" ]; then
    echo "❌ create-batch-now failed:"
    echo "$RESP" | jq '.'
    exit 1
  fi

  BID=$(echo "$RESP" | jq -r '.batchId')
  CREATED_BATCH_IDS+=("$BID")
  echo "✅ Created batchId=${BID} (pending was ${PENDING})"

  # Small pause so monitor endpoints reflect newly stored batch
  sleep 1
done

# Resolve final list of newly created batch IDs (covers scheduler-created batches too).
NEW_BATCH_IDS=()
refresh_new_batch_ids

if [ "${#NEW_BATCH_IDS[@]}" -eq 0 ]; then
  echo "❌ No NEW batches detected after submitting intents."
  echo "Check backend logs and /api/monitor/batches."
  exit 1
fi

echo
echo "New batches detected: ${NEW_BATCH_IDS[*]}"
echo

# ────────────────────────────────────────────────────────────────────────────
# Step 3: monitor execution until all created batches complete
# ────────────────────────────────────────────────────────────────────────────
echo "Monitoring execution (up to 180s)..."
DEADLINE=$(( $(date +%s) + 180 ))

while [ $(date +%s) -lt $DEADLINE ]; do
  # Pick up any additional batches that might have been created asynchronously by the scheduler.
  refresh_new_batch_ids
  if [ "${#NEW_BATCH_IDS[@]}" -eq 0 ]; then
    echo "⚠️  No new batches visible yet; waiting..."
    sleep 2
    continue
  fi

  ALL_DONE=true
  echo "---- $(date) ----"
  for BID in "${NEW_BATCH_IDS[@]}"; do
    DETAILS=$(curl -s "${BASE_URL}/api/monitor/batch/${BID}")
    STATUS=$(echo "$DETAILS" | jq -r '.batch.status // .status // "UNKNOWN"')
    EXECUTED=$(echo "$DETAILS" | jq -r '.batch.transfers | map(select(.executed == true)) | length')
    TOTAL=$(echo "$DETAILS" | jq -r '.batch.transfers | length')
    echo "batchId=${BID} status=${STATUS} executed=${EXECUTED}/${TOTAL}"

    if [ "$STATUS" = "FAILED" ]; then
      # Helpful hint for txType=2 issues: if whitelistProof is empty, contract will revert NotWhitelisted.
      NEEDS_WL=$(echo "$DETAILS" | jq -r '[.batch.transfers[].txData.txType] | any(. == 2)')
      if [ "$NEEDS_WL" = "true" ]; then
        WL_EMPTY_CNT=$(echo "$DETAILS" | jq -r '[.batch.transfers[] | select(.txData.txType == 2) | (.whitelistProofSize // 0)] | map(select(. == 0)) | length')
        if [ "$WL_EMPTY_CNT" != "0" ]; then
          echo "   ↳ Detected txType=2 with EMPTY whitelistProof (count=${WL_EMPTY_CNT})."
          echo "   ↳ Fix: ensure the sender is in whitelist config and restart backend so it can sync the on-chain whitelist root."
          echo "      - Check application.yaml: whitelist.addresses"
          echo "      - If you use .env/env vars, make sure WHITELIST_ADDRESSES is NOT empty and includes FROM=${FROM}"
        fi
      fi
      echo "❌ Batch ${BID} FAILED. Check backend logs (common causes: whitelist root mismatch, not whitelisted, insufficient balance/allowance)."
      exit 1
    fi
    if [ "$STATUS" != "COMPLETED" ]; then
      ALL_DONE=false
    fi
  done

  if [ "$ALL_DONE" = "true" ]; then
    echo "✅ All created batches COMPLETED."
    exit 0
  fi

  sleep 5
done

echo "⚠️  Timed out waiting for completion. Check:"
echo "  - ${BASE_URL}/api/monitor/batches"
echo "  - backend logs"
exit 1


