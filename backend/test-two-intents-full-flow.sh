#!/bin/bash

# ═══════════════════════════════════════════════════════════════════════════
# 🚀 FULL FLOW TEST - 2 INTENTS ON NILE
# ═══════════════════════════════════════════════════════════════════════════
# 
# This script tests the COMPLETE Java backend flow with 2 intents:
# 1. Submit 2 transfer intents via REST API
# 2. Monitor batch creation
# 3. Wait for batch unlock time
# 4. Monitor execution
# 5. Verify success on Nile blockchain
#
# ═══════════════════════════════════════════════════════════════════════════

set -e

BASE_URL="http://localhost:8080"
TIMESTAMP=$(date +%s)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║          🚀 FULL FLOW TEST - 2 INTENTS ON NILE 🚀                      ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# STEP 0: Check backend is running
# ═══════════════════════════════════════════════════════════════════════════

echo -e "${CYAN}═══ STEP 0: Checking Backend Status ═══${NC}"
echo ""

if ! curl -s -f $BASE_URL/api/monitor/stats > /dev/null 2>&1; then
    echo -e "${RED}❌ Backend is not running!${NC}"
    echo ""
    echo "Please start the backend first:"
    echo "  ./gradlew bootRun"
    echo ""
    exit 1
fi

echo -e "${GREEN}✅ Backend is running${NC}"

# Check configuration
CONFIG=$(curl -s $BASE_URL/api/monitor/stats)
BATCHING_ENABLED=$(echo $CONFIG | jq -r '.schedulers.batching.enabled')
EXECUTION_ENABLED=$(echo $CONFIG | jq -r '.schedulers.execution.enabled')
MAX_INTENTS=$(echo $CONFIG | jq -r '.schedulers.batching.maxIntents')
MAX_DELAY=$(echo $CONFIG | jq -r '.schedulers.batching.maxDelaySeconds')

echo ""
echo "Configuration:"
echo "  • Batching enabled:  $BATCHING_ENABLED"
echo "  • Execution enabled: $EXECUTION_ENABLED"
echo "  • Max intents:       $MAX_INTENTS"
echo "  • Max delay:         ${MAX_DELAY}s"
echo ""

if [ "$BATCHING_ENABLED" != "true" ] || [ "$EXECUTION_ENABLED" != "true" ]; then
    echo -e "${RED}❌ Schedulers are not enabled!${NC}"
    echo ""
    echo "Please enable schedulers in application.yaml or set environment variables:"
    echo "  SCHEDULER_BATCHING_ENABLED=true"
    echo "  SCHEDULER_EXECUTION_ENABLED=true"
    echo ""
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 1: Get initial statistics
# ═══════════════════════════════════════════════════════════════════════════

echo -e "${CYAN}═══ STEP 1: Initial Statistics ═══${NC}"
echo ""

INITIAL_STATS=$(curl -s $BASE_URL/api/monitor/stats)
INITIAL_TRANSFERS=$(echo $INITIAL_STATS | jq -r '.statistics.totalTransfers')
INITIAL_BATCHES=$(echo $INITIAL_STATS | jq -r '.statistics.totalBatches')
INITIAL_COMPLETED=$(echo $INITIAL_STATS | jq -r '.statistics.completedBatches')

echo "Current state:"
echo "  • Total transfers:    $INITIAL_TRANSFERS"
echo "  • Total batches:      $INITIAL_BATCHES"
echo "  • Completed batches:  $INITIAL_COMPLETED"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# STEP 2: Submit 2 transfer intents
# ═══════════════════════════════════════════════════════════════════════════

echo -e "${CYAN}═══ STEP 2: Submit 2 Transfer Intents ═══${NC}"
echo ""

FROM_ADDRESS="TKWvD71EMFTpFVGZyqqX9fC6MQgcR9H76M"
TO_ADDRESS="TFZMxv9HUzvsL3M7obrvikSQkuvJsopgMU"

# Intent 1 - DELAYED (txType 0)
NONCE1=$TIMESTAMP
AMOUNT1=5000000  # 5 USDT

echo -e "${BLUE}Intent 1 (DELAYED):${NC}"
echo "  • From:   $FROM_ADDRESS"
echo "  • To:     $TO_ADDRESS"
echo "  • Amount: 5.0 USDT"
echo "  • Nonce:  $NONCE1"
echo "  • Type:   0 (DELAYED)"
echo ""

HTTP_CODE1=$(curl -s -w "%{http_code}" -o /dev/null -X POST $BASE_URL/api/intents \
    -H "Content-Type: application/json" \
    -d "{
      \"from\": \"$FROM_ADDRESS\",
      \"to\": \"$TO_ADDRESS\",
      \"amount\": \"$AMOUNT1\",
      \"nonce\": $NONCE1,
      \"timestamp\": $TIMESTAMP,
      \"recipientCount\": 1,
      \"txType\": 0
    }")

if [ "$HTTP_CODE1" != "202" ]; then
    echo -e "${RED}❌ Failed to submit intent 1! HTTP Code: $HTTP_CODE1${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Intent 1 submitted${NC}"
sleep 0.5

# Intent 2 - INSTANT (txType 1)
NONCE2=$((TIMESTAMP + 1))
AMOUNT2=10000000  # 10 USDT

echo ""
echo -e "${BLUE}Intent 2 (INSTANT):${NC}"
echo "  • From:   $FROM_ADDRESS"
echo "  • To:     $TO_ADDRESS"
echo "  • Amount: 10.0 USDT"
echo "  • Nonce:  $NONCE2"
echo "  • Type:   1 (INSTANT)"
echo ""

HTTP_CODE2=$(curl -s -w "%{http_code}" -o /dev/null -X POST $BASE_URL/api/intents \
    -H "Content-Type: application/json" \
    -d "{
      \"from\": \"$FROM_ADDRESS\",
      \"to\": \"$TO_ADDRESS\",
      \"amount\": \"$AMOUNT2\",
      \"nonce\": $NONCE2,
      \"timestamp\": $TIMESTAMP,
      \"recipientCount\": 1,
      \"txType\": 1
    }")

if [ "$HTTP_CODE2" != "202" ]; then
    echo -e "${RED}❌ Failed to submit intent 2! HTTP Code: $HTTP_CODE2${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Intent 2 submitted${NC}"
echo ""

sleep 1

# Verify pending count
STATS=$(curl -s $BASE_URL/api/monitor/stats)
PENDING=$(echo $STATS | jq -r '.statistics.pendingTransfers')

echo "Pending transfers: $PENDING"
echo ""

if [ "$PENDING" != "2" ]; then
    echo -e "${YELLOW}⚠️  Expected 2 pending transfers, got $PENDING${NC}"
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 3: Trigger batch creation immediately
# ═══════════════════════════════════════════════════════════════════════════

echo -e "${CYAN}═══ STEP 3: Trigger Batch Creation ═══${NC}"
echo ""

echo "Note: We have 2 intents and max is $MAX_INTENTS"
echo "We can either:"
echo "  a) Wait ${MAX_DELAY}s for auto-batching"
echo "  b) Submit $((MAX_INTENTS - 2)) more intents"
echo "  c) Manually trigger batching now"
echo ""

echo -e "${BLUE}Manually triggering batch creation...${NC}"
echo ""

BATCH_RESPONSE=$(curl -s -X POST $BASE_URL/api/monitor/create-batch-now)
echo "$BATCH_RESPONSE" | jq '.'
echo ""

BATCH_CREATED=$(echo $BATCH_RESPONSE | jq -r '.success')

if [ "$BATCH_CREATED" = "true" ]; then
    BATCH_ID=$(echo $BATCH_RESPONSE | jq -r '.batchId')
    MERKLE_ROOT=$(echo $BATCH_RESPONSE | jq -r '.merkleRoot')
    TX_COUNT=$(echo $BATCH_RESPONSE | jq -r '.txCount')
    
    echo -e "${GREEN}✅ Batch created successfully!${NC}"
    echo ""
    echo "Batch details:"
    echo "  • Batch ID:     $BATCH_ID"
    echo "  • Merkle Root:  ${MERKLE_ROOT:0:20}..."
    echo "  • TX Count:     $TX_COUNT"
    echo ""
else
    echo -e "${RED}❌ Batch creation failed!${NC}"
    echo ""
    ERROR=$(echo $BATCH_RESPONSE | jq -r '.error // "Unknown error"')
    echo "Error: $ERROR"
    echo ""
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 4: Check batch status and unlock time
# ═══════════════════════════════════════════════════════════════════════════

echo -e "${CYAN}═══ STEP 4: Check Batch Status ═══${NC}"
echo ""

sleep 2  # Wait for batch submission to finalize

BATCH_DETAILS=$(curl -s "$BASE_URL/api/monitor/batch/$BATCH_ID")
STATUS=$(echo $BATCH_DETAILS | jq -r '.batch.status')
UNLOCK_TIME=$(echo $BATCH_DETAILS | jq -r '.batch.unlockTime')
CURRENT_TIME=$(date +%s)

echo "Batch status:"
echo "  • Status:       $STATUS"
echo "  • Unlock time:  $UNLOCK_TIME"
echo "  • Current time: $CURRENT_TIME"
echo ""

if [ "$UNLOCK_TIME" != "null" ] && [ "$UNLOCK_TIME" != "0" ]; then
    WAIT_TIME=$((UNLOCK_TIME - CURRENT_TIME))
    if [ "$WAIT_TIME" -gt 0 ]; then
        echo -e "${YELLOW}⚠️  Batch is locked for ${WAIT_TIME} more seconds${NC}"
        echo ""
        echo -e "${BLUE}Waiting for unlock time...${NC}"
        echo ""
        
        # Wait with countdown
        for ((i=$WAIT_TIME; i>0; i--)); do
            if [ $((i % 5)) -eq 0 ] || [ $i -le 5 ]; then
                echo -e "  ⏳ ${i}s remaining..."
            fi
            sleep 1
        done
        
        echo ""
        echo -e "${GREEN}✅ Batch is now unlocked!${NC}"
        echo ""
    else
        echo -e "${GREEN}✅ Batch is already unlocked!${NC}"
        echo ""
    fi
else
    echo -e "${GREEN}✅ No timelock (unlock time is 0)${NC}"
    echo ""
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 5: Monitor execution
# ═══════════════════════════════════════════════════════════════════════════

echo -e "${CYAN}═══ STEP 5: Monitor Execution ═══${NC}"
echo ""

echo "Execution scheduler checks every 5 seconds"
echo "Monitoring for up to 60 seconds..."
echo ""

EXECUTION_SUCCESS=false

for i in {1..12}; do
    sleep 5
    
    BATCH_DETAILS=$(curl -s "$BASE_URL/api/monitor/batch/$BATCH_ID")
    STATUS=$(echo $BATCH_DETAILS | jq -r '.batch.status')
    EXECUTED_COUNT=$(echo $BATCH_DETAILS | jq -r '.batch.transfers | map(select(.executed == true)) | length')
    TOTAL_COUNT=$(echo $BATCH_DETAILS | jq -r '.batch.transfers | length')
    
    echo -e "  [${i}/12] Status: ${STATUS}, Executed: ${EXECUTED_COUNT}/${TOTAL_COUNT}"
    
    if [ "$STATUS" = "COMPLETED" ]; then
        echo ""
        echo -e "${GREEN}✅ Batch execution completed!${NC}"
        EXECUTION_SUCCESS=true
        break
    elif [ "$STATUS" = "FAILED" ]; then
        echo ""
        echo -e "${RED}❌ Batch execution failed!${NC}"
        break
    fi
done

echo ""

if [ "$EXECUTION_SUCCESS" != "true" ]; then
    if [ "$STATUS" = "FAILED" ]; then
        echo -e "${RED}Execution failed. Check logs for details.${NC}"
    else
        echo -e "${YELLOW}Execution still in progress or not started yet.${NC}"
        echo "Current status: $STATUS"
    fi
    echo ""
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 6: View detailed batch information
# ═══════════════════════════════════════════════════════════════════════════

echo -e "${CYAN}═══ STEP 6: Batch Details ═══${NC}"
echo ""

BATCH_DETAILS=$(curl -s "$BASE_URL/api/monitor/batch/$BATCH_ID")
echo "$BATCH_DETAILS" | jq '{
  batchId: .batch.batchId,
  status: .batch.status,
  merkleRoot: .batch.merkleRoot,
  unlockTime: .batch.unlockTime,
  transfers: .batch.transfers | map({
    from: .txData.from,
    to: .txData.to,
    amount: .txData.amount,
    txType: .txData.txType,
    executed: .executed
  })
}'
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# STEP 7: Verify on Nile blockchain (if execution succeeded)
# ═══════════════════════════════════════════════════════════════════════════

if [ "$EXECUTION_SUCCESS" = "true" ]; then
    echo -e "${CYAN}═══ STEP 7: Verify on Nile Blockchain ═══${NC}"
    echo ""
    
    # Extract transaction details
    TRANSFER_1_FROM=$(echo $BATCH_DETAILS | jq -r '.batch.transfers[0].txData.from')
    TRANSFER_1_TO=$(echo $BATCH_DETAILS | jq -r '.batch.transfers[0].txData.to')
    TRANSFER_1_AMOUNT=$(echo $BATCH_DETAILS | jq -r '.batch.transfers[0].txData.amount')
    
    TRANSFER_2_FROM=$(echo $BATCH_DETAILS | jq -r '.batch.transfers[1].txData.from')
    TRANSFER_2_TO=$(echo $BATCH_DETAILS | jq -r '.batch.transfers[1].txData.to')
    TRANSFER_2_AMOUNT=$(echo $BATCH_DETAILS | jq -r '.batch.transfers[1].txData.amount')
    
    echo "Transfer 1:"
    echo "  • From:   $TRANSFER_1_FROM"
    echo "  • To:     $TRANSFER_1_TO"
    echo "  • Amount: $TRANSFER_1_AMOUNT (5.0 USDT)"
    echo "  • Type:   DELAYED"
    echo ""
    
    echo "Transfer 2:"
    echo "  • From:   $TRANSFER_2_FROM"
    echo "  • To:     $TRANSFER_2_TO"
    echo "  • Amount: $TRANSFER_2_AMOUNT (10.0 USDT)"
    echo "  • Type:   INSTANT"
    echo ""
    
    echo -e "${BLUE}To verify on Nile blockchain:${NC}"
    echo ""
    echo "1. Check Settlement contract events:"
    echo "   https://nile.tronscan.org/#/contract/TDum6BeRGA5hruf1Z2FRfavEZTn5DfWqAJ/events"
    echo ""
    echo "2. Look for 'TransferExecuted' events for batch ID: $BATCH_ID"
    echo ""
    echo "3. Check recipient balance:"
    echo "   https://nile.tronscan.org/#/address/$TO_ADDRESS"
    echo ""
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 8: Final statistics
# ═══════════════════════════════════════════════════════════════════════════

echo -e "${CYAN}═══ STEP 8: Final Statistics ═══${NC}"
echo ""

FINAL_STATS=$(curl -s $BASE_URL/api/monitor/stats)
FINAL_TRANSFERS=$(echo $FINAL_STATS | jq -r '.statistics.totalTransfers')
FINAL_BATCHES=$(echo $FINAL_STATS | jq -r '.statistics.totalBatches')
FINAL_COMPLETED=$(echo $FINAL_STATS | jq -r '.statistics.completedBatches')
FINAL_PENDING=$(echo $FINAL_STATS | jq -r '.statistics.pendingTransfers')

echo "Statistics:"
echo "  • Total transfers:    $FINAL_TRANSFERS (was $INITIAL_TRANSFERS, +$((FINAL_TRANSFERS - INITIAL_TRANSFERS)))"
echo "  • Total batches:      $FINAL_BATCHES (was $INITIAL_BATCHES, +$((FINAL_BATCHES - INITIAL_BATCHES)))"
echo "  • Completed batches:  $FINAL_COMPLETED (was $INITIAL_COMPLETED, +$((FINAL_COMPLETED - INITIAL_COMPLETED)))"
echo "  • Pending transfers:  $FINAL_PENDING"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║                        🎯 TEST SUMMARY 🎯                               ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""

echo -e "${GREEN}✓${NC} Backend running and configured"
echo -e "${GREEN}✓${NC} 2 transfer intents submitted"
echo -e "${GREEN}✓${NC} Batch created (ID: $BATCH_ID)"

if [ "$EXECUTION_SUCCESS" = "true" ]; then
    echo -e "${GREEN}✓${NC} Batch execution completed successfully"
    echo ""
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${MAGENTA}              🎉 SUCCESS! ALL TESTS PASSED 🎉             ${NC}"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Your Java backend successfully:"
    echo "  1. ✓ Received 2 transfer intents"
    echo "  2. ✓ Created a merkle tree batch"
    echo "  3. ✓ Submitted batch to Nile blockchain"
    echo "  4. ✓ Waited for unlock time"
    echo "  5. ✓ Executed both transfers on-chain"
    echo ""
    echo "Verify on Nile blockchain:"
    echo "  🔗 https://nile.tronscan.org/#/contract/TDum6BeRGA5hruf1Z2FRfavEZTn5DfWqAJ/events"
    echo ""
else
    echo -e "${YELLOW}⚠${NC} Batch execution status: $STATUS"
    echo ""
    echo "Possible reasons:"
    echo "  • Still processing (check logs)"
    echo "  • Insufficient balance or allowance"
    echo "  • Contract configuration issue"
    echo ""
    echo "Check backend logs for details:"
    echo "  ./gradlew bootRun"
fi

echo ""
echo "View all batches:"
echo "  curl $BASE_URL/api/monitor/batches | jq"
echo ""
echo "View this batch:"
echo "  curl $BASE_URL/api/monitor/batch/$BATCH_ID | jq"
echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

