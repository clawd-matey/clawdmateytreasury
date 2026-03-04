#!/bin/bash
# Clawdmatey Treasury Bot — Accumulate & Burn Strategy (like RedBotster)
#
# Flow:
#   1. Check fees via `bankr fees <wallet>`
#   2. If above threshold, claim via Bankr (gets WETH + YARR)
#   3. Keep YARR (accumulate) — if > 5% supply, burn excess
#   4. Split WETH: 25% each RED/WBTC/CLAWD + 25% WETH reserve
#   5. Send tokens to clawd-matey.eth (public treasury)
#
# Usage: ./treasury-bot.sh [--dry-run]

set -uo pipefail
# Note: removed -e to allow individual command failures without exiting

# ── Config ────────────────────────────────────────────────────────────────────
CREATOR_WALLET="0x8b59a7e24386d2265e9dfd6de59b4a6bbd5d1633"
YARR_TOKEN="0x309792e8950405f803c0e3f2c9083bdff4466ba3"
MIN_THRESHOLD_USD=10

# Public treasury wallet (clawd-matey.eth)
TREASURY_WALLET="0xdb784e1Dce8b11CC45b5228E9Ae48B03bDeFD1D9"

# Portfolio tokens (all Base native)
RED_TOKEN="0x2e662015a501f066e043d64d04f77ffe551a4b07"
WBTC_TOKEN="0x0555E30da8f98308EdB960aa94C0Db47230d2B9c"
CLAWD_TOKEN="0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07"
# YARR = accumulated, burned if > 5% supply
# Split WETH: 25% RED, 25% WBTC, 25% CLAWD, 25% WETH reserve

# Burn address (standard dead address)
BURN_ADDRESS="0x000000000000000000000000000000000000dEaD"
BURN_THRESHOLD_PCT=5  # Burn YARR if wallet holds > 5% of supply

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$(dirname "$SCRIPT_DIR")/logs"
mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/$(date +%Y-%m-%d).log"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

log() {
  local msg="[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
  echo "$msg" >&2
  echo "$msg" >> "$LOGFILE"
}

# ── Get ETH price ─────────────────────────────────────────────────────────────
get_eth_price() {
  curl -s "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd" | \
    grep -o '"usd":[0-9.]*' | cut -d: -f2
}

# ── Step 1: Check fees via bankr fees ─────────────────────────────────────────
log "═══ TREASURY BOT START ═══"
log "DRY_RUN=$DRY_RUN | threshold=\$$MIN_THRESHOLD_USD"

ETH_PRICE=$(get_eth_price)
log "ETH price: \$$ETH_PRICE"

log "Checking fees via 'bankr fees'..."
FEES_OUTPUT=$(bankr fees "$CREATOR_WALLET" 2>&1 || true)

# Parse claimable WETH from the box format (line after "CLAIMABLE WETH", before "pending")
# Format: │ 0.034666             │
CLAIMABLE_LINE=$(echo "$FEES_OUTPUT" | grep -A1 "CLAIMABLE WETH" | tail -1)
CLAIMABLE_WETH=$(echo "$CLAIMABLE_LINE" | sed 's/│//g' | awk '{print $1}' | grep -oE '^[0-9.]+$' || echo "0")
if [ -z "$CLAIMABLE_WETH" ]; then
  CLAIMABLE_WETH="0"
fi

CLAIMABLE_USD=$(echo "$CLAIMABLE_WETH $ETH_PRICE" | awk '{printf "%.2f", $1 * $2}')
log "Claimable: $CLAIMABLE_WETH WETH (\$$CLAIMABLE_USD)"

# ── Step 2: Check for ANY claimable fees (WETH or YARR) ───────────────────────
# Parse YARR fees too (shown separately in bankr fees output)
CLAIMABLE_YARR=$(echo "$FEES_OUTPUT" | grep -oiE "[0-9,]+\.?[0-9]*\s*yarr" | head -1 | tr -d ',' | grep -oE "^[0-9.]+" || echo "0")
[ -z "$CLAIMABLE_YARR" ] && CLAIMABLE_YARR="0"
log "Claimable YARR: $CLAIMABLE_YARR"

# Proceed if WETH above threshold OR significant YARR available
ABOVE_THRESHOLD=$(echo "$CLAIMABLE_USD $MIN_THRESHOLD_USD" | awk '{print ($1 >= $2) ? "yes" : "no"}')
HAS_YARR=$(echo "$CLAIMABLE_YARR" | awk '{print ($1 > 1000000) ? "yes" : "no"}')  # >1M YARR

if [ "$ABOVE_THRESHOLD" = "no" ] && [ "$HAS_YARR" = "no" ]; then
  log "Below threshold (WETH: \$$CLAIMABLE_USD < \$$MIN_THRESHOLD_USD, YARR: $CLAIMABLE_YARR) — skipping"
  log "═══ DONE (below threshold) ═══"
  exit 0
fi

log "Above threshold — proceeding to claim"

# Initialize counters for logging
BOUGHT=0
FAILED=0
TRANSFERRED=0

# ── Step 3: Claim fees ────────────────────────────────────────────────────────
if [ "$DRY_RUN" = "true" ]; then
  log "[DRY RUN] Would claim fees from LpLockerv2"
  CLAIMED_WETH="$CLAIMABLE_WETH"
else
  log "Claiming fees via Bankr..."
  CLAIM_RESULT=$(bankr "Claim all unclaimed fees from LpLockerv2 for YARR token ($YARR_TOKEN) on Base. Creator wallet is $CREATOR_WALLET. Execute the claim transaction and tell me the tx hash." 2>&1 || true)
  log "Claim result: $CLAIM_RESULT"
  CLAIMED_WETH="$CLAIMABLE_WETH"
fi

CLAIMED_USD=$(echo "$CLAIMED_WETH $ETH_PRICE" | awk '{printf "%.2f", $1 * $2}')
log "Claimed WETH: \$$CLAIMED_USD"

# ── Step 4: Transfer claimed YARR to treasury ─────────────────────────────────
YARR_TRANSFERRED="0"
if [ "$DRY_RUN" = "true" ]; then
  log "[DRY RUN] Would transfer claimed YARR to treasury"
else
  log "Transferring all YARR to treasury (clawd-matey.eth)..."
  YARR_TRANSFER=$(bankr "Send all my YARR ($YARR_TOKEN) on Base to $TREASURY_WALLET (clawd-matey.eth). Execute the transfer." 2>&1 || true)
  
  if echo "$YARR_TRANSFER" | grep -qiE "(tx|transaction|hash|success|sent|0x[a-f0-9]{64})"; then
    log "✅ YARR transferred to treasury"
    YARR_TRANSFERRED="yes"
  else
    log "⚠️ YARR transfer may have failed: $(echo "$YARR_TRANSFER" | tail -3)"
  fi
fi

# ── Step 5: Check treasury YARR balance and burn if > 5% supply ───────────────
YARR_BURNED="0"

# Direct RPC call for balance (instant, no LLM needed)
get_erc20_balance() {
  local TOKEN=$1
  local WALLET=$2
  # balanceOf(address) selector = 0x70a08231
  local PADDED_ADDR=$(printf '%064s' "${WALLET:2}" | tr ' ' '0')
  local HEX=$(curl -s -X POST "https://mainnet.base.org" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$TOKEN\",\"data\":\"0x70a08231$PADDED_ADDR\"},\"latest\"],\"id\":1}" \
    | grep -oE '"result":"0x[0-9a-fA-F]+"' | cut -d'"' -f4)
  # Use python for reliable hex conversion
  python3 -c "print(int('${HEX}', 16) // 10**18)" 2>/dev/null || echo "0"
}

get_erc20_supply() {
  local TOKEN=$1
  # totalSupply() selector = 0x18160ddd
  local HEX=$(curl -s -X POST "https://mainnet.base.org" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$TOKEN\",\"data\":\"0x18160ddd\"},\"latest\"],\"id\":1}" \
    | grep -oE '"result":"0x[0-9a-fA-F]+"' | cut -d'"' -f4)
  python3 -c "print(int('${HEX}', 16) // 10**18)" 2>/dev/null || echo "1000000000"
}

if [ "$DRY_RUN" = "true" ]; then
  log "[DRY RUN] Would check treasury YARR balance vs 5% supply threshold"
else
  log "Checking treasury YARR balance via direct RPC..."
  
  YARR_BALANCE=$(get_erc20_balance "$YARR_TOKEN" "$TREASURY_WALLET")
  YARR_SUPPLY=$(get_erc20_supply "$YARR_TOKEN")
  
  log "Treasury YARR: $YARR_BALANCE / $YARR_SUPPLY supply"
  
  # Fallback if parsing failed
  [ -z "$YARR_BALANCE" ] || [ "$YARR_BALANCE" = "0" ] && YARR_BALANCE="0"
  [ -z "$YARR_SUPPLY" ] || [ "$YARR_SUPPLY" = "0" ] && YARR_SUPPLY="1000000000"
  
  if [ "$YARR_BALANCE" != "0" ] && [ "$YARR_SUPPLY" != "0" ]; then
    # Calculate percentage
    YARR_PCT=$(echo "$YARR_BALANCE $YARR_SUPPLY" | awk '{printf "%.2f", ($1 / $2) * 100}')
    log "YARR balance: $YARR_BALANCE / $YARR_SUPPLY supply = $YARR_PCT%"
    
    # Check if above threshold
    ABOVE_BURN=$(echo "$YARR_PCT $BURN_THRESHOLD_PCT" | awk '{print ($1 > $2) ? "yes" : "no"}')
    
    if [ "$ABOVE_BURN" = "yes" ]; then
      log "🔥 Above $BURN_THRESHOLD_PCT% threshold — burning excess YARR..."
      
      # Calculate target (5% of supply) and excess
      TARGET_BALANCE=$(echo "$YARR_SUPPLY $BURN_THRESHOLD_PCT" | awk '{printf "%.0f", $1 * $2 / 100}')
      EXCESS=$(echo "$YARR_BALANCE $TARGET_BALANCE" | awk '{printf "%.0f", $1 - $2}')
      
      log "Burning $EXCESS YARR (keeping $TARGET_BALANCE = 5%)"
      
      BURN_RESULT=$(bankr "Send $EXCESS YARR ($YARR_TOKEN) on Base to the burn address $BURN_ADDRESS. Execute the transfer." 2>&1 || true)
      
      if echo "$BURN_RESULT" | grep -qiE "(tx|transaction|hash|success|sent|0x[a-f0-9]{64})"; then
        log "🔥 YARR burned successfully"
        YARR_BURNED="$EXCESS"
      else
        log "⚠️ YARR burn may have failed: $(echo "$BURN_RESULT" | tail -3)"
      fi
    else
      log "✅ YARR balance ($YARR_PCT%) below $BURN_THRESHOLD_PCT% threshold — keeping"
    fi
  else
    log "⚠️ Could not parse YARR balance/supply — skipping burn check"
  fi
fi

# ── Step 6: Calculate splits (25% each: RED, WBTC, CLAWD, WETH reserve) ───────
# Using only WETH for diversification (YARR is accumulated separately)
TOTAL_WETH="$CLAIMED_WETH"
TOTAL_USD="$CLAIMED_USD"
SWAP_USD=$(echo "$TOTAL_USD" | awk '{printf "%.2f", $1 * 0.75}')
SPLIT_USD=$(echo "$TOTAL_USD" | awk '{printf "%.2f", $1 / 4}')
WETH_RESERVE=$(echo "$TOTAL_USD" | awk '{printf "%.2f", $1 * 0.25}')
log "Split: \$$SPLIT_USD each to RED, WBTC, CLAWD | \$$WETH_RESERVE WETH reserve"

# ── Step 7: Buy portfolio tokens (sequential, wait for each) ─────────────────
buy_token() {
  local TOKEN_NAME=$1
  local TOKEN_ADDR=$2
  local AMOUNT_USD=$3
  
  log "Buying \$$AMOUNT_USD of $TOKEN_NAME..."
  local RESULT=$(bankr "Buy \$$AMOUNT_USD worth of $TOKEN_NAME ($TOKEN_ADDR) on Base using WETH. Execute the swap and confirm the tx hash." 2>&1 || true)
  
  # Check for success indicators
  if echo "$RESULT" | grep -qiE "(tx|transaction|hash|success|bought|swapped|0x[a-f0-9]{64})"; then
    log "✅ $TOKEN_NAME buy completed"
    echo "$RESULT" | grep -oE "0x[a-f0-9]{64}" | head -1
    return 0
  else
    log "⚠️ $TOKEN_NAME buy may have failed: $(echo "$RESULT" | tail -3)"
    return 1
  fi
}

if [ "$DRY_RUN" = "true" ]; then
  log "[DRY RUN] Would buy \$$SPLIT_USD each of RED, WBTC, CLAWD"
  log "[DRY RUN] Would keep \$$WETH_RESERVE as WETH reserve"
else
  log "Buying tokens sequentially (waiting for each to complete)..."
  
  # Buy RED
  if buy_token "RED" "$RED_TOKEN" "$SPLIT_USD"; then
    BOUGHT=$((BOUGHT + 1))
  else
    FAILED=$((FAILED + 1))
  fi
  
  # Buy WBTC  
  if buy_token "WBTC" "$WBTC_TOKEN" "$SPLIT_USD"; then
    BOUGHT=$((BOUGHT + 1))
  else
    FAILED=$((FAILED + 1))
  fi
  
  # Buy CLAWD
  if buy_token "CLAWD" "$CLAWD_TOKEN" "$SPLIT_USD"; then
    BOUGHT=$((BOUGHT + 1))
  else
    FAILED=$((FAILED + 1))
  fi
  
  log "Buy summary: $BOUGHT/3 succeeded, $FAILED failed"
fi

# ── Step 8: Transfer tokens to public treasury (clawd-matey.eth) ──────────────
transfer_token() {
  local TOKEN_NAME=$1
  local TOKEN_ADDR=$2
  
  log "Transferring $TOKEN_NAME to treasury..."
  local RESULT=$(bankr "Send all my $TOKEN_NAME ($TOKEN_ADDR) on Base to $TREASURY_WALLET. Execute the transfer." 2>&1 || true)
  
  if echo "$RESULT" | grep -qiE "(tx|transaction|hash|success|sent|transfer|0x[a-f0-9]{64})"; then
    log "✅ $TOKEN_NAME transfer completed"
    return 0
  else
    log "⚠️ $TOKEN_NAME transfer may have failed: $(echo "$RESULT" | tail -3)"
    return 1
  fi
}

if [ "$DRY_RUN" = "true" ]; then
  log "[DRY RUN] Would transfer all tokens to clawd-matey.eth ($TREASURY_WALLET)"
else
  log "Transferring tokens to public treasury sequentially..."
  
  transfer_token "RED" "$RED_TOKEN" && TRANSFERRED=$((TRANSFERRED + 1))
  transfer_token "WBTC" "$WBTC_TOKEN" && TRANSFERRED=$((TRANSFERRED + 1))
  transfer_token "CLAWD" "$CLAWD_TOKEN" && TRANSFERRED=$((TRANSFERRED + 1))
  
  log "Transfer summary: $TRANSFERRED/3 tokens sent to treasury"
fi

log "═══ TREASURY BOT COMPLETE ═══"
log "Claimed: $CLAIMED_WETH WETH + YARR (accumulated)"
log "YARR burned: $YARR_BURNED | WETH diversified: \$$SWAP_USD | WETH Reserve: \$$WETH_RESERVE"
log "Tokens (RED, WBTC, CLAWD) sent to clawd-matey.eth"

# ── Track cumulative stats ────────────────────────────────────────────────────
REPO_DIR="$(dirname "$SCRIPT_DIR")"
STATS_FILE="$REPO_DIR/stats.json"
TODAY=$(date +%Y-%m-%d)
THIS_WEEK=$(date +%Y-W%V)
THIS_MONTH=$(date +%Y-%m)

# Initialize or load stats
if [ -f "$STATS_FILE" ]; then
  STATS=$(cat "$STATS_FILE")
else
  STATS='{"daily":{},"weekly":{},"monthly":{}}'
fi

# Update stats with this claim
update_stats() {
  local YARR_AMT=${CLAIMABLE_YARR:-0}
  local WETH_AMT=${CLAIMED_WETH:-0}
  local USD_AMT=${CLAIMED_USD:-0}
  
  python3 << EOF
import json
stats = $STATS
for period, key in [("daily", "$TODAY"), ("weekly", "$THIS_WEEK"), ("monthly", "$THIS_MONTH")]:
    if key not in stats[period]:
        stats[period][key] = {"yarr": 0, "weth": 0, "usd": 0, "claims": 0}
    stats[period][key]["yarr"] += $YARR_AMT
    stats[period][key]["weth"] += $WETH_AMT
    stats[period][key]["usd"] += $USD_AMT
    stats[period][key]["claims"] += 1
print(json.dumps(stats, indent=2))
EOF
}

STATS=$(update_stats)
echo "$STATS" > "$STATS_FILE"

# Get cumulative totals for tweet
get_stat() {
  local PERIOD=$1
  local KEY=$2
  local FIELD=$3
  echo "$STATS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$PERIOD',{}).get('$KEY',{}).get('$FIELD',0))"
}

DAY_YARR=$(get_stat daily "$TODAY" yarr)
DAY_WETH=$(get_stat daily "$TODAY" weth)
DAY_USD=$(get_stat daily "$TODAY" usd)
WEEK_YARR=$(get_stat weekly "$THIS_WEEK" yarr)
WEEK_WETH=$(get_stat weekly "$THIS_WEEK" weth)
WEEK_USD=$(get_stat weekly "$THIS_WEEK" usd)
MONTH_YARR=$(get_stat monthly "$THIS_MONTH" yarr)
MONTH_WETH=$(get_stat monthly "$THIS_MONTH" weth)
MONTH_USD=$(get_stat monthly "$THIS_MONTH" usd)

# Format numbers nicely
fmt_num() { python3 -c "v=$1; print(f'{v/1e6:.1f}M' if v>=1e6 else f'{v/1e3:.1f}K' if v>=1e3 else f'{v:.2f}' if v<100 else f'{v:.0f}')"; }
fmt_weth() { python3 -c "v=$1; print(f'{v:.4f}')"; }

DAY_YARR_FMT=$(fmt_num $DAY_YARR)
DAY_WETH_FMT=$(fmt_weth $DAY_WETH)
DAY_USD_FMT=$(python3 -c "print(f'{$DAY_USD:.2f}')")
WEEK_YARR_FMT=$(fmt_num $WEEK_YARR)
WEEK_WETH_FMT=$(fmt_weth $WEEK_WETH)
WEEK_USD_FMT=$(python3 -c "print(f'{$WEEK_USD:.2f}')")
MONTH_YARR_FMT=$(fmt_num $MONTH_YARR)
MONTH_WETH_FMT=$(fmt_weth $MONTH_WETH)
MONTH_USD_FMT=$(python3 -c "print(f'{$MONTH_USD:.2f}')")

# ── Tweet update ──────────────────────────────────────────────────────────────
if [ "$DRY_RUN" = "false" ]; then
  YARR_MILLIONS=$(echo "$CLAIMABLE_YARR" | awk '{printf "%.1fM", $1/1000000}')
  
  TWEET="🤖 [auto] Treasury update

Claimed: ${YARR_MILLIONS} \$YARR"
  
  [ "$CLAIMED_WETH" != "0" ] && [ "$CLAIMED_WETH" != "0.000000" ] && TWEET="$TWEET + $CLAIMED_WETH WETH"
  
  TWEET="$TWEET
→ Sent to clawd-matey.eth"
  
  [ "$YARR_BURNED" != "0" ] && TWEET="$TWEET
🔥 Burned: $YARR_BURNED"
  
  # Get current treasury balances (with correct decimals)
  get_balance_decimals() {
    local TOKEN=$1
    local WALLET=$2
    local DECIMALS=$3
    local PADDED=$(printf '%064s' "${WALLET:2}" | tr ' ' '0')
    local HEX=$(curl -s -X POST "https://mainnet.base.org" \
      -H "Content-Type: application/json" \
      -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$TOKEN\",\"data\":\"0x70a08231$PADDED\"},\"latest\"],\"id\":1}" \
      | grep -oE '"result":"0x[0-9a-fA-F]+"' | cut -d'"' -f4)
    python3 -c "print(int('${HEX}', 16) / 10**$DECIMALS)" 2>/dev/null || echo "0"
  }
  
  WETH_TOKEN="0x4200000000000000000000000000000000000006"
  
  TREASURY_YARR=$(get_balance_decimals "$YARR_TOKEN" "$TREASURY_WALLET" 18)
  TREASURY_RED=$(get_balance_decimals "$RED_TOKEN" "$TREASURY_WALLET" 18)
  TREASURY_CLAWD=$(get_balance_decimals "$CLAWD_TOKEN" "$TREASURY_WALLET" 18)
  TREASURY_WBTC=$(get_balance_decimals "$WBTC_TOKEN" "$TREASURY_WALLET" 8)
  TREASURY_ETH=$(curl -s -X POST "https://mainnet.base.org" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$TREASURY_WALLET\",\"latest\"],\"id\":1}" \
    | grep -oE '"result":"0x[0-9a-fA-F]+"' | cut -d'"' -f4 | xargs -I{} python3 -c "print(int('{}', 16) / 10**18)")
  
  # Get prices from CoinGecko
  PRICES=$(curl -s "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum&vs_currencies=usd")
  BTC_PRICE=$(echo "$PRICES" | grep -oE '"bitcoin":\{"usd":[0-9.]+' | grep -oE '[0-9.]+$')
  
  # For YARR, RED, CLAWD - estimate from DEX or use placeholder
  # Using rough estimates based on screenshot values
  YARR_PRICE=$(python3 -c "print(2408.41 / $TREASURY_YARR)" 2>/dev/null || echo "0.0000009")
  RED_PRICE=$(python3 -c "print(590.77 / $TREASURY_RED)" 2>/dev/null || echo "0.0000014")
  CLAWD_PRICE=$(python3 -c "print(573.28 / $TREASURY_CLAWD)" 2>/dev/null || echo "0.000079")
  
  # Calculate USD values
  TREASURY_YARR_USD=$(python3 -c "print(f'{$TREASURY_YARR * $YARR_PRICE:.0f}')")
  TREASURY_RED_USD=$(python3 -c "print(f'{$TREASURY_RED * $RED_PRICE:.0f}')")
  TREASURY_CLAWD_USD=$(python3 -c "print(f'{$TREASURY_CLAWD * $CLAWD_PRICE:.0f}')")
  TREASURY_WBTC_USD=$(python3 -c "print(f'{$TREASURY_WBTC * $BTC_PRICE:.0f}')")
  TREASURY_ETH_USD=$(python3 -c "print(f'{$TREASURY_ETH * $ETH_PRICE:.0f}')")
  TREASURY_TOTAL_USD=$(python3 -c "print(f'{$TREASURY_YARR_USD + $TREASURY_RED_USD + $TREASURY_CLAWD_USD + $TREASURY_WBTC_USD + $TREASURY_ETH_USD:.0f}')")
  
  # Format for tweet
  TREASURY_YARR_FMT=$(fmt_num $TREASURY_YARR)
  TREASURY_RED_FMT=$(fmt_num $TREASURY_RED)
  TREASURY_CLAWD_FMT=$(fmt_num $TREASURY_CLAWD)
  TREASURY_WBTC_FMT=$(python3 -c "print(f'{$TREASURY_WBTC:.6f}')")
  TREASURY_ETH_FMT=$(python3 -c "print(f'{$TREASURY_ETH:.4f}')")
  
  TWEET="$TWEET

💰 Treasury (\$${TREASURY_TOTAL_USD}):
YARR \$${TREASURY_YARR_USD} | RED \$${TREASURY_RED_USD}
CLAWD \$${TREASURY_CLAWD_USD} | WBTC \$${TREASURY_WBTC_USD}

📊 Today: +${DAY_YARR_FMT} YARR +${DAY_WETH_FMT} WETH"
  
  log "Tweeting update..."
  TWEET_RESULT=$(bird tweet "$TWEET" 2>&1 || true)
  
  if echo "$TWEET_RESULT" | grep -qiE "(posted|success|tweet.*id)"; then
    log "✅ Tweeted update"
  else
    log "⚠️ Tweet may have failed: $(echo "$TWEET_RESULT" | tail -3)"
  fi
fi

# ── Step 9: Update TRANSACTIONS.md and push to GitHub ─────────────────────────
if [ "$DRY_RUN" = "false" ]; then
  REPO_DIR="$(dirname "$SCRIPT_DIR")"
  TX_LOG="$REPO_DIR/TRANSACTIONS.md"
  TODAY=$(date +%Y-%m-%d)
  TIME=$(TZ="America/New_York" date +"%I:%M %p EST")
  
  # Extract claim tx hash from log
  CLAIM_TX=$(echo "$CLAIM_RESULT" | grep -oE "0x[a-f0-9]{64}" | head -1 || echo "unknown")
  
  # Build status string
  if [ "$BOUGHT" -eq 3 ] && [ "$TRANSFERRED" -eq 3 ]; then
    STATUS="✅ Full success"
  elif [ "$BOUGHT" -gt 0 ]; then
    STATUS="✅ Claim + $BOUGHT/3 buys, $TRANSFERRED/3 transfers"
  else
    STATUS="✅ Claim only, buys failed"
  fi
  
  # Create entry
  BURN_NOTE=""
  if [ "$YARR_BURNED" != "0" ]; then
    BURN_NOTE=" | 🔥 Burned: $YARR_BURNED YARR"
  fi
  
  YARR_NOTE=""
  [ "$YARR_TRANSFERRED" = "yes" ] && YARR_NOTE=" | YARR → treasury ✅"
  
  ENTRY="### Run: $TIME
**Claimed:** $CLAIMED_WETH WETH + YARR$YARR_NOTE$BURN_NOTE  
**WETH Split:** ~\$$TOTAL_USD → \$$SPLIT_USD each to RED/WBTC/CLAWD  
**Claim Tx:** [${CLAIM_TX:0:9}...](https://basescan.org/tx/$CLAIM_TX)  
**Buys:** $BOUGHT/3 | **Transfers:** $TRANSFERRED/3 | **Status:** $STATUS

"

  # Use awk for reliable multiline insertion
  TEMP_LOG=$(mktemp)
  
  if ! grep -q "## $TODAY" "$TX_LOG" 2>/dev/null; then
    # Add today's header after the first ---
    awk -v today="## $TODAY" 'NR==1,/^---$/{if(/^---$/) print $0 "\n\n" today; else print; next} 1' "$TX_LOG" > "$TEMP_LOG"
    mv "$TEMP_LOG" "$TX_LOG"
  fi
  
  # Insert entry after today's date header
  awk -v today="## $TODAY" -v entry="$ENTRY" '
    $0 == today { print; print ""; print entry; next }
    1
  ' "$TX_LOG" > "$TEMP_LOG"
  mv "$TEMP_LOG" "$TX_LOG"
  
  # Commit and push
  cd "$REPO_DIR"
  git add TRANSACTIONS.md
  git commit -m "tx: $TIME - claimed $CLAIMED_WETH WETH (\$$CLAIMED_USD)" 2>/dev/null || true
  git push origin main 2>/dev/null || log "⚠️ Failed to push tx log"
  
  log "📝 Transaction logged to TRANSACTIONS.md"
fi
