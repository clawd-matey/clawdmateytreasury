#!/bin/bash
# Clawdmatey Treasury Bot — Simplified
#
# Flow:
#   1. Check fees via `bankr fees <wallet>`
#   2. If above threshold, claim via Bankr natural language
#   3. Split into portfolio: 20% each RED/WBTC/CLAWD/YARR + 20% WETH reserve
#   4. Send all tokens to clawd-matey.eth (public treasury)
#
# Usage: ./treasury-bot.sh [--dry-run]

set -euo pipefail

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
# WETH = 20% kept as reserve (no swap needed)

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

# ── Step 2: Threshold check ───────────────────────────────────────────────────
ABOVE_THRESHOLD=$(echo "$CLAIMABLE_USD $MIN_THRESHOLD_USD" | awk '{print ($1 >= $2) ? "yes" : "no"}')

if [ "$ABOVE_THRESHOLD" = "no" ]; then
  log "Below threshold (\$$CLAIMABLE_USD < \$$MIN_THRESHOLD_USD) — skipping"
  log "═══ DONE (below threshold) ═══"
  exit 0
fi

log "Above threshold — proceeding to claim"

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
log "Claimed: \$$CLAIMED_USD"

# ── Step 4: Calculate splits (20% each, 4 tokens + WETH reserve) ──────────────
# 80% swapped to tokens, 20% kept as WETH
SWAP_USD=$(echo "$CLAIMED_USD" | awk '{printf "%.2f", $1 * 0.8}')
SPLIT_USD=$(echo "$CLAIMED_USD" | awk '{printf "%.2f", $1 / 5}')
WETH_RESERVE=$(echo "$CLAIMED_USD" | awk '{printf "%.2f", $1 * 0.2}')
log "Split: \$$SPLIT_USD each to RED, WBTC, CLAWD, YARR | \$$WETH_RESERVE WETH reserve"

# ── Step 5: Buy portfolio tokens (batched single call) ───────────────────────
if [ "$DRY_RUN" = "true" ]; then
  log "[DRY RUN] Would buy \$$SPLIT_USD each of RED, WBTC, CLAWD, YARR"
  log "[DRY RUN] Would keep \$$WETH_RESERVE as WETH reserve"
else
  log "Buying 4 tokens in single batch (keeping 20% WETH)..."
  BUY_RESULT=$(bankr "Execute these 4 buys using WETH on Base. Keep 20% of WETH as reserve (don't swap it).

Swap 80% of available WETH into:
1. Buy \$$SPLIT_USD of RED ($RED_TOKEN) on Base
2. Buy \$$SPLIT_USD of WBTC ($WBTC_TOKEN) on Base  
3. Buy \$$SPLIT_USD of CLAWD ($CLAWD_TOKEN) on Base
4. Buy \$$SPLIT_USD of YARR ($YARR_TOKEN) on Base

Execute all 4 transactions. Use Clanker pools where available. Report results." 2>&1 || true)
  log "Batch buy result: $(echo "$BUY_RESULT" | tail -10)"
fi

# ── Step 6: Transfer tokens to public treasury (clawd-matey.eth) ──────────────
if [ "$DRY_RUN" = "true" ]; then
  log "[DRY RUN] Would transfer all tokens to clawd-matey.eth ($TREASURY_WALLET)"
else
  log "Transferring tokens to public treasury (clawd-matey.eth)..."
  TRANSFER_RESULT=$(bankr "Send all my RED, WBTC, CLAWD, and YARR tokens on Base to $TREASURY_WALLET (clawd-matey.eth). Keep WETH for gas. Execute all transfers." 2>&1 || true)
  log "Transfer result: $(echo "$TRANSFER_RESULT" | tail -10)"
fi

log "═══ TREASURY BOT COMPLETE ═══"
log "Claimed: \$$CLAIMED_USD | Swapped: \$$SWAP_USD | WETH Reserve: \$$WETH_RESERVE"
log "Tokens sent to clawd-matey.eth"
