#!/bin/bash
# Clawdmatey Fee Claim + Accumulate Automation
#
# Flow:
#   1. Check unclaimed Clanker creator fees for YARR
#   2. If above threshold, claim them
#   3. Split proceeds: 20% each to RED, GRT, WBTC, CLAWD, YARR
#   4. Burn YARR if holding >5% of supply (burn excess only)
#   5. Post character-driven tweet via xurl
#   6. Log everything
#
# Usage: ./fee-claim-and-buy.sh [--dry-run]

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_DIR/config.json"
LOG_DIR="$PROJECT_DIR/logs"
TRACKER="$HOME/Clawdmatey.md"

BANKR="$HOME/.openclaw/workspace/skills/bankr/scripts/bankr.sh"
SWAP_SCRIPT="$SCRIPT_DIR/uniswap-swap.py"

# Primary token: YARR (fees come from this)
YARR_TOKEN="0x309792e8950405f803c0e3f2c9083bdff4466ba3"

# Clanker FeeLocker (v4 only - YARR is v3, needs Bankr fallback)
CLANKER_FEE_LOCKER="0xF3622742b1E446D92e45E22923Ef11C2fcD55D68"
CLANKER_FEES_SCRIPT="$SCRIPT_DIR/clanker-fees.py"

# Fee claiming mode: "direct" (v4) or "bankr" (v3 fallback)
# YARR is v3, so we use Bankr for now
FEE_CLAIM_MODE="bankr"

# Portfolio tokens
RED_TOKEN_BASE="0x2e662015a501f066e043d64d04f77ffe551a4b07"
GRT_TOKEN_ARB="0x9623063377AD1B27544C965cCd7342f7EA7e88C7"
WBTC_TOKEN_BASE="0x0555E30da8f98308EdB960aa94C0Db47230d2B9c"
CLAWD_TOKEN_BASE="0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07"

BURN_ADDRESS="0x000000000000000000000000000000000000dEaD"
TREASURY_WALLET=""  # Set in config.json
BANKR_TIMEOUT=20
BLOCKED_WARNING=""

# Defaults (overridden by config.json if present)
MIN_THRESHOLD=10
WETH_FALLBACK_MIN=1
RED_SPLIT_PCT=20
GRT_SPLIT_PCT=20
WBTC_SPLIT_PCT=20
CLAWD_SPLIT_PCT=20
YARR_SPLIT_PCT=20
YARR_BURN_THRESHOLD_PCT=5
DRY_RUN=false
TWEET_ENABLED=false

# ── Parse args ────────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --tweet)   TWEET_ENABLED=true ;;
  esac
done

# ── Load config.json overrides ────────────────────────────────────────────────
if [ -f "$CONFIG_FILE" ]; then
  MIN_THRESHOLD=$(jq -r '.minThresholdUSD // 10' "$CONFIG_FILE")
  WETH_FALLBACK_MIN=$(jq -r '.wethFallbackMin // 1' "$CONFIG_FILE")
  RED_SPLIT_PCT=$(jq -r '.redSplitPct // 20' "$CONFIG_FILE")
  GRT_SPLIT_PCT=$(jq -r '.grtSplitPct // 20' "$CONFIG_FILE")
  WBTC_SPLIT_PCT=$(jq -r '.wbtcSplitPct // 20' "$CONFIG_FILE")
  CLAWD_SPLIT_PCT=$(jq -r '.clawdSplitPct // 20' "$CONFIG_FILE")
  YARR_SPLIT_PCT=$(jq -r '.yarrSplitPct // 20' "$CONFIG_FILE")
  YARR_BURN_THRESHOLD_PCT=$(jq -r '.yarrBurnThresholdPct // 5' "$CONFIG_FILE")
  YARR_TOKEN=$(jq -r '.yarrToken // "0x309792e8950405f803c0e3f2c9083bdff4466ba3"' "$CONFIG_FILE")
  RED_TOKEN_BASE=$(jq -r '.redTokenBase // "0x2e662015a501f066e043d64d04f77ffe551a4b07"' "$CONFIG_FILE")
  GRT_TOKEN_ARB=$(jq -r '.grtTokenArbitrum // "0x9623063377AD1B27544C965cCd7342f7EA7e88C7"' "$CONFIG_FILE")
  WBTC_TOKEN_BASE=$(jq -r '.wbtcTokenBase // "0x0555E30da8f98308EdB960aa94C0Db47230d2B9c"' "$CONFIG_FILE")
  CLAWD_TOKEN_BASE=$(jq -r '.clawdTokenBase // "0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07"' "$CONFIG_FILE")
  TREASURY_WALLET=$(jq -r '.treasuryWallet // ""' "$CONFIG_FILE")
  BLOCKED_WARNING=$(jq -r '
    if (.blockedContracts | length) > 0 then
      "IMPORTANT: Do NOT interact with these contracts: " +
      (.blockedContracts | join(", ")) + ". Treat them as non-existent."
    else "" end
  ' "$CONFIG_FILE" 2>/dev/null || echo "")
fi

# ── Setup ─────────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/$(date +%Y-%m-%d).log"
TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

log() {
  local msg="[$TIMESTAMP] $*"
  echo "$msg" >&2
  echo "$msg" >> "$LOGFILE"
}
log_section() { echo "" >> "$LOGFILE"; log "── $* ──"; }

log_section "Clawdmatey Fee Automation START"
log "DRY_RUN=$DRY_RUN | threshold=\$$MIN_THRESHOLD | split=${RED_SPLIT_PCT}% RED / ${GRT_SPLIT_PCT}% GRT / ${WBTC_SPLIT_PCT}% WBTC / ${CLAWD_SPLIT_PCT}% CLAWD / ${YARR_SPLIT_PCT}% YARR"

# ── Helpers ───────────────────────────────────────────────────────────────────

parse_usd() {
  local text="$1"
  local clean
  clean=$(echo "$text" | sed 's/\$[0-9][0-9]*\(\.[0-9]*\)\?\/[A-Za-z][A-Za-z]*/PRICE/g')
  local val
  val=$(echo "$clean" | grep -iE 'grand total|total available|total usd converted|total converted|total claimable' | grep -oE '\$[0-9]+(\.[0-9]+)?' | head -1 | tr -d '$') && [ -n "$val" ] && echo "$val" && return
  val=$(echo "$clean" | grep -oE '\$[0-9]+(\.[0-9]+)?' | tr -d '$' | sort -rn | head -1) && [ -n "$val" ] && echo "$val" && return
  val=$(echo "$clean" | grep -oiE '[0-9]+(\.[0-9]+)?\s*USDC' | grep -oE '[0-9]+(\.[0-9]+)?' | sort -rn | head -1) && [ -n "$val" ] && echo "$val" && return
  val=$(echo "$clean" | grep -oiE '[0-9]+(\.[0-9]+)?\s*USD' | grep -oE '[0-9]+(\.[0-9]+)?' | sort -rn | head -1) && [ -n "$val" ] && echo "$val" && return
  echo ""
}

pct_of() {
  local total="$1" pct="$2"
  echo "$total $pct" | awk '{printf "%.2f", $1 * $2 / 100}'
}

xurl_ready() {
  xurl auth status 2>/dev/null | grep -q "Logged in" && return 0 || return 1
}

tweet() {
  local msg="$1"
  if [ "$TWEET_ENABLED" = "false" ]; then
    log "Tweeting disabled — skipping"
    return
  fi
  if xurl_ready; then
    if [ "$DRY_RUN" = "true" ]; then
      log "[DRY RUN] Would tweet: $msg"
    else
      xurl post "$msg" >> "$LOGFILE" 2>&1 && log "Tweeted: $msg" || log "WARN: Tweet failed"
    fi
  else
    log "xurl not authenticated — skipping tweet"
  fi
}

bankr_run() {
  local prompt="$1"
  if [ -n "$BLOCKED_WARNING" ]; then
    prompt="$BLOCKED_WARNING $prompt"
  fi
  log "BANKR: $prompt"
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY RUN] Would run bankr: $prompt"
    if echo "$prompt" | grep -qi "check\|balance\|unclaimed"; then
      echo '{"status":"completed","response":"You have $24.50 in unclaimed Clanker creator fees for YARR token on Base."}'
    elif echo "$prompt" | grep -qi "claim"; then
      echo '{"status":"completed","response":"Successfully claimed $24.50 USDC in creator fees for YARR on Base."}'
    elif echo "$prompt" | grep -qi "GRT"; then
      echo '{"status":"completed","response":"Bought 850.25 GRT on Arbitrum for $17.15."}'
    elif echo "$prompt" | grep -qi "RED"; then
      echo '{"status":"completed","response":"Bought 42000 RED on Base for $7.35."}'
    elif echo "$prompt" | grep -qi "WBTC"; then
      echo '{"status":"completed","response":"Bought 0.0001 WBTC on Base for $7.35."}'
    elif echo "$prompt" | grep -qi "CLAWD"; then
      echo '{"status":"completed","response":"Bought 15000 CLAWD on Base for $7.35."}'
    elif echo "$prompt" | grep -qi "YARR"; then
      echo '{"status":"completed","response":"Bought 100000 YARR on Base for $7.35."}'
    elif echo "$prompt" | grep -qi "send\|burn\|0xdead"; then
      echo '{"status":"completed","response":"Sent tokens to burn address. Transaction confirmed."}'
    else
      echo '{"status":"completed","response":"Operation completed successfully."}'
    fi
    return
  fi
  "$BANKR" "$prompt" 2>>"$LOGFILE" || true
}

uniswap_swap() {
  local token_out="$1" amount_usd="$2"
  local weth_amount
  weth_amount=$(echo "$amount_usd ${ETH_PRICE:-2000}" | awk '{printf "%.8f", $1 / $2}')
  log "UNISWAP: swap $amount_usd USD ($weth_amount WETH) → $token_out"
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY RUN] Would uniswap swap $weth_amount WETH → $token_out"
    echo '{"status":"completed","response":"Swapped WETH to '"$token_out"'."}'
    return
  fi
  python3 "$SWAP_SCRIPT" swap --token-out "$token_out" --amount "$weth_amount" 2>>"$LOGFILE" || true
}

sweep_yarr() {
  log_section "YARR Sweep → treasury"
  if [ -z "$TREASURY_WALLET" ]; then
    log "No treasury wallet configured — skipping sweep"
    return
  fi
  local sweep_result sweep_response
  sweep_result=$(bankr_run "Send all my YARR token ($YARR_TOKEN) on Base to $TREASURY_WALLET" 2>/dev/null) || true
  sweep_response=$(echo "$sweep_result" | jq -r '.response // ""' 2>/dev/null || echo "no YARR to sweep")
  log "YARR sweep: $sweep_response"
}

weth_allocation_swap() {
  log_section "WETH 5% Allocation Swap"
  
  if [ -z "$TREASURY_WALLET" ]; then
    log "No treasury wallet configured — skipping WETH allocation swap"
    return
  fi

  local weth_contract="0x4200000000000000000000000000000000000006"
  local rpc_data="0x70a08231000000000000000000000000${TREASURY_WALLET:2}"
  local raw_balance weth_amount weth_usd fallback_usd
  
  raw_balance=$(curl -s -X POST https://mainnet.base.org \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$weth_contract\",\"data\":\"$rpc_data\"},\"latest\"],\"id\":1}" \
    | jq -r '.result' 2>/dev/null || echo "0x0")
  weth_amount=$(python3 -c "print(int('$raw_balance', 16) / 1e18)" 2>/dev/null || echo "0")
  weth_usd=$(echo "$weth_amount ${ETH_PRICE:-2000}" | awk '{printf "%.2f", $1 * $2}')
  log "Treasury WETH: $weth_amount WETH @ \$${ETH_PRICE:-2000} = \$$weth_usd"

  if [ -z "$weth_usd" ] || [ "$(echo "$weth_usd" | awk '{print ($1 <= 0) ? "yes" : "no"}')" = "yes" ]; then
    log "Treasury WETH balance is zero — skipping"
    return
  fi

  fallback_usd=$(echo "$weth_usd" | awk '{printf "%.2f", $1 * 0.05}')
  log "Treasury WETH ~\$$weth_usd — 5% = \$$fallback_usd"

  if [ "$(echo "$fallback_usd $WETH_FALLBACK_MIN" | awk '{print ($1 >= $2) ? "yes" : "no"}')" = "no" ]; then
    log "5% of WETH (\$$fallback_usd) below minimum \$$WETH_FALLBACK_MIN — skipping"
    return
  fi

  local fb_red_usd fb_grt_usd fb_wbtc_usd fb_clawd_usd fb_yarr_usd
  fb_red_usd=$(pct_of "$fallback_usd" "$RED_SPLIT_PCT")
  fb_grt_usd=$(pct_of "$fallback_usd" "$GRT_SPLIT_PCT")
  fb_wbtc_usd=$(pct_of "$fallback_usd" "$WBTC_SPLIT_PCT")
  fb_clawd_usd=$(pct_of "$fallback_usd" "$CLAWD_SPLIT_PCT")
  fb_yarr_usd=$(pct_of "$fallback_usd" "$YARR_SPLIT_PCT")
  
  log "Split: \$$fallback_usd → RED: \$$fb_red_usd | GRT: \$$fb_grt_usd | WBTC: \$$fb_wbtc_usd | CLAWD: \$$fb_clawd_usd | YARR: \$$fb_yarr_usd"

  # Execute swaps
  uniswap_swap "GRT" "$fb_grt_usd"
  uniswap_swap "WBTC" "$fb_wbtc_usd"
  uniswap_swap "CLAWD" "$fb_clawd_usd"
  bankr_run "Buy exactly \$$fb_red_usd worth of RED ($RED_TOKEN_BASE) on Base using WETH. Execute via Clanker pool."
  bankr_run "Buy exactly \$$fb_yarr_usd worth of YARR ($YARR_TOKEN) on Base using WETH. Execute via Clanker pool."

  log "WETH swap complete"
}

RUNS_FILE="$PROJECT_DIR/runs.md"
write_run_summary() {
  local mode="$1" fees="$2" red="$3" grt="$4" wbtc="$5" clawd="$6" yarr="$7" weth="$8" burn="${9:-}"
  local ts
  ts="$(date -u '+%Y-%m-%d %H:%M UTC')"
  if [ ! -f "$RUNS_FILE" ]; then
    cat > "$RUNS_FILE" <<'EOF'
# Clawdmatey Run History

| Time (UTC) | Mode | Fees Claimed | RED | GRT | WBTC | CLAWD | YARR | WETH Swapped | Burn |
|---|---|---|---|---|---|---|---|---|---|
EOF
  fi
  echo "| $ts | $mode | \$$fees | $red | $grt | $wbtc | $clawd | $yarr | $weth | $burn |" >> "$RUNS_FILE"
}

update_tracker() {
  local line="$1"
  if [ -f "$TRACKER" ]; then
    local entry="- $(date +%Y-%m-%d): $line"
    echo "$entry" >> "$TRACKER"
  fi
}

# ── Fetch ETH price ───────────────────────────────────────────────────────────
ETH_PRICE=$(curl -s "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd" \
  | jq -r '.ethereum.usd' 2>/dev/null || echo "2000")
log "ETH price: \$$ETH_PRICE"

# ── Step 1: Check YARR fee balance (BOTH v3 and v4 systems) ──────────────────
log_section "Step 1: Check ALL fee systems (v4 ClankerFeeLocker + v3 Bankr)"

# Use unified check-all-fees.py which checks BOTH systems
CHECK_ALL_SCRIPT="$SCRIPT_DIR/check-all-fees.py"
AVAILABLE_USD=""
V4_USD=""
V3_USD=""

if [ -f "$CHECK_ALL_SCRIPT" ]; then
  log "Running unified fee check (v4 + v3)..."
  CHECK_RESULT=$(cd "$PROJECT_DIR" && source venv/bin/activate 2>/dev/null && python3 "$CHECK_ALL_SCRIPT" 2>>"$LOGFILE") || true
  
  # Parse JSON output
  AVAILABLE_USD=$(echo "$CHECK_RESULT" | jq -r '.total_usd // 0' 2>/dev/null || echo "0")
  V4_USD=$(echo "$CHECK_RESULT" | jq -r '.v4_usd // 0' 2>/dev/null || echo "0")
  V3_USD=$(echo "$CHECK_RESULT" | jq -r '.v3_usd // 0' 2>/dev/null || echo "0")
  
  log "Fee check results:"
  log "  v4 (ClankerFeeLocker): \$$V4_USD"
  log "  v3 (Bankr/LpLockerv2): \$$V3_USD"
  log "  TOTAL: \$$AVAILABLE_USD"
else
  log "WARNING: check-all-fees.py not found, falling back to Bankr only"
  CHECK_RESULT=$(bankr_run "Check my current unclaimed Clanker creator fee balance for YARR token ($YARR_TOKEN) on Base. Show me the total USD value available to claim.")
  CHECK_RESPONSE=$(echo "$CHECK_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
  log "Bankr response: $CHECK_RESPONSE"
  AVAILABLE_USD=$(parse_usd "$CHECK_RESPONSE")
fi

log "Total available to claim: \$$AVAILABLE_USD"

NO_FEES=false
if [ -z "$AVAILABLE_USD" ] || [ "$(echo "$AVAILABLE_USD" | awk '{print ($1 <= 0) ? "yes" : "no"}')" = "yes" ]; then
  NO_FEES=true
fi

if [ "$NO_FEES" = "true" ]; then
  log "No fees to claim — sweeping YARR and running WETH 5% allocation swap"
  sweep_yarr
  weth_allocation_swap
  update_tracker "No fees this run — YARR swept + WETH 5% allocation swap run"
  write_run_summary "no-fees" "0" "-" "-" "-" "-" "-" "5% of WETH" "-"
  log_section "DONE (no fees)"
  exit 0
fi

# ── Step 2: Threshold check ───────────────────────────────────────────────────
log_section "Step 2: Threshold check"

ABOVE=$(echo "$AVAILABLE_USD $MIN_THRESHOLD" | awk '{print ($1 >= $2) ? "yes" : "no"}')
if [ "$ABOVE" = "no" ]; then
  log "Available \$$AVAILABLE_USD is below threshold \$$MIN_THRESHOLD — skipping claim"
  sweep_yarr
  weth_allocation_swap
  update_tracker "Fees below threshold (\$$AVAILABLE_USD) — YARR swept + WETH 5% swap run"
  write_run_summary "below-threshold" "$AVAILABLE_USD" "-" "-" "-" "-" "-" "5% of WETH" "-"
  log_section "DONE (below threshold)"
  exit 0
fi
log "\$$AVAILABLE_USD >= threshold \$$MIN_THRESHOLD — proceeding."

# ── Step 3: Claim fees (from both systems as needed) ─────────────────────────
log_section "Step 3: Claim YARR Clanker fees"

CLAIMED_USD="0"
CREATOR_WALLET=$(jq -r '.creatorWallet // "0x8b59a7e24386d2265e9dfd6de59b4a6bbd5d1633"' "$CONFIG_FILE")

# Claim v4 fees if present
if [ -n "$V4_USD" ] && [ "$(echo "$V4_USD" | awk '{print ($1 > 0) ? "yes" : "no"}')" = "yes" ]; then
  log "Claiming v4 fees (\$$V4_USD) via ClankerFeeLocker..."
  if [ "$DRY_RUN" = "true" ]; then
    CLAIM_RESULT=$(cd "$PROJECT_DIR" && source venv/bin/activate 2>/dev/null && python3 "$CLANKER_FEES_SCRIPT" claim --fee-owner "$CREATOR_WALLET" --token YARR --dry-run 2>>"$LOGFILE") || true
  else
    CLAIM_RESULT=$(cd "$PROJECT_DIR" && source venv/bin/activate 2>/dev/null && python3 "$CLANKER_FEES_SCRIPT" claim --fee-owner "$CREATOR_WALLET" --token YARR 2>>"$LOGFILE") || true
  fi
  V4_CLAIMED=$(echo "$CLAIM_RESULT" | jq -r '.data.total_usd // 0' 2>/dev/null || echo "0")
  log "v4 claimed: \$$V4_CLAIMED"
  CLAIMED_USD=$(echo "$CLAIMED_USD $V4_CLAIMED" | awk '{printf "%.2f", $1 + $2}')
fi

# Claim v3 fees if present (Bankr)
if [ -n "$V3_USD" ] && [ "$(echo "$V3_USD" | awk '{print ($1 > 0) ? "yes" : "no"}')" = "yes" ]; then
  log "Claiming v3 fees (\$$V3_USD) via Bankr..."
  CLAIM_RESULT=$(bankr_run "Claim ALL unclaimed Clanker creator fees for YARR ($YARR_TOKEN) on Base. After claiming, swap any non-WETH tokens to WETH. Tell me the total USD value claimed.")
  CLAIM_RESPONSE=$(echo "$CLAIM_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
  log "Bankr claim response: $CLAIM_RESPONSE"
  V3_CLAIMED=$(parse_usd "$CLAIM_RESPONSE")
  if [ -z "$V3_CLAIMED" ]; then V3_CLAIMED="$V3_USD"; fi
  log "v3 claimed: \$$V3_CLAIMED"
  CLAIMED_USD=$(echo "$CLAIMED_USD $V3_CLAIMED" | awk '{printf "%.2f", $1 + $2}')
fi

if [ -z "$CLAIMED_USD" ]; then
  CLAIMED_USD="${AVAILABLE_USD:-0}"
  log "Could not parse claimed amount — using estimate: \$$CLAIMED_USD"
fi

log "Claimed: \$$CLAIMED_USD"

if [ "$CLAIMED_USD" = "0" ] || [ -z "$CLAIMED_USD" ]; then
  log "Nothing claimed. Exiting."
  exit 0
fi

# ── Step 4: Calculate splits ──────────────────────────────────────────────────
log_section "Step 4: Calculating splits"

RED_USD=$(pct_of "$CLAIMED_USD" "$RED_SPLIT_PCT")
GRT_USD=$(pct_of "$CLAIMED_USD" "$GRT_SPLIT_PCT")
WBTC_USD=$(pct_of "$CLAIMED_USD" "$WBTC_SPLIT_PCT")
CLAWD_USD=$(pct_of "$CLAIMED_USD" "$CLAWD_SPLIT_PCT")
YARR_USD=$(pct_of "$CLAIMED_USD" "$YARR_SPLIT_PCT")

log "Claimed \$$CLAIMED_USD → RED: \$$RED_USD | GRT: \$$GRT_USD | WBTC: \$$WBTC_USD | CLAWD: \$$CLAWD_USD | YARR: \$$YARR_USD"

# ── Step 5: Buy tokens ────────────────────────────────────────────────────────
log_section "Step 5: Buy portfolio tokens"

# RED (Clanker)
RED_RESULT=$(bankr_run "Buy exactly \$$RED_USD worth of RED ($RED_TOKEN_BASE) on Base using WETH. Execute via Clanker pool.")
RED_RESPONSE=$(echo "$RED_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
RED_TOKENS=$(echo "$RED_RESPONSE" | grep -oiE '[0-9,]+(\.[0-9]+)?\s*RED' | head -1 | grep -oE '[0-9,]+(\.[0-9]+)?' | tr -d ',' || echo "")
log "RED buy: $RED_RESPONSE"

# GRT (Arbitrum via Across bridge)
GRT_RESULT=$(bankr_run "Buy exactly \$$GRT_USD worth of GRT ($GRT_TOKEN_ARB) on Arbitrum. Bridge WETH from Base automatically. Execute now.")
GRT_RESPONSE=$(echo "$GRT_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
GRT_TOKENS=$(echo "$GRT_RESPONSE" | grep -oiE '[0-9]+(\.[0-9]+)?\s*GRT' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' || echo "")
log "GRT buy: $GRT_RESPONSE"

# WBTC (Uniswap v3)
WBTC_RESULT=$(uniswap_swap "WBTC" "$WBTC_USD")
WBTC_RESPONSE=$(echo "$WBTC_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
WBTC_TOKENS=$(echo "$WBTC_RESPONSE" | grep -oiE '[0-9]+(\.[0-9]+)?\s*WBTC' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' || echo "")
log "WBTC buy: $WBTC_RESPONSE"

# CLAWD (Uniswap v3)
CLAWD_RESULT=$(uniswap_swap "CLAWD" "$CLAWD_USD")
CLAWD_RESPONSE=$(echo "$CLAWD_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
CLAWD_TOKENS=$(echo "$CLAWD_RESPONSE" | grep -oiE '[0-9,]+(\.[0-9]+)?\s*CLAWD' | head -1 | grep -oE '[0-9,]+(\.[0-9]+)?' | tr -d ',' || echo "")
log "CLAWD buy: $CLAWD_RESPONSE"

# YARR (Clanker)
YARR_RESULT=$(bankr_run "Buy exactly \$$YARR_USD worth of YARR ($YARR_TOKEN) on Base using WETH. Execute via Clanker pool.")
YARR_RESPONSE=$(echo "$YARR_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
YARR_TOKENS=$(echo "$YARR_RESPONSE" | grep -oiE '[0-9,]+(\.[0-9]+)?\s*YARR' | head -1 | grep -oE '[0-9,]+(\.[0-9]+)?' | tr -d ',' || echo "")
log "YARR buy: $YARR_RESPONSE"

# ── Step 6: YARR burn check ───────────────────────────────────────────────────
log_section "Step 6: YARR burn check"

BURN_ELIGIBLE="no"
BURN_PCT="0"
BURN_RESPONSE="Accumulating YARR — burn threshold not reached"
YARR_DISPLAY="${YARR_TOKENS:-\$$YARR_USD worth}"

if [ "$DRY_RUN" = "true" ]; then
  log "[DRY RUN] Would check YARR burn threshold — skipping"
else
  # Check YARR supply percentage (would need to implement this check)
  # For now, use bankr to query
  SUPPLY_CHECK=$(bankr_run "What percentage of total YARR ($YARR_TOKEN) supply does my wallet hold on Base? Just give me the percentage number.")
  BURN_PCT=$(echo "$SUPPLY_CHECK" | jq -r '.response // ""' 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || echo "0")
  log "YARR supply %: $BURN_PCT"
  
  if [ "$(echo "$BURN_PCT $YARR_BURN_THRESHOLD_PCT" | awk '{print ($1 > $2) ? "yes" : "no"}')" = "yes" ]; then
    BURN_ELIGIBLE="true"
    EXCESS_PCT=$(echo "$BURN_PCT $YARR_BURN_THRESHOLD_PCT" | awk '{printf "%.2f", $1 - $2}')
    log "🔥 Above ${YARR_BURN_THRESHOLD_PCT}% threshold — burning excess (${EXCESS_PCT}%)"
    
    BURN_RESULT=$(bankr_run "Burn the excess YARR ($YARR_TOKEN) above ${YARR_BURN_THRESHOLD_PCT}% of total supply. Send it to $BURN_ADDRESS on Base.")
    BURN_RESPONSE=$(echo "$BURN_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
    log "Burn response: $BURN_RESPONSE"
  else
    log "Accumulating YARR (holding ${BURN_PCT}% — need >${YARR_BURN_THRESHOLD_PCT}% to burn)"
  fi
fi

# ── Step 7: Always swap 5% of WETH into treasury allocations ─────────────────
weth_allocation_swap

# ── Step 8: Tweet ─────────────────────────────────────────────────────────────
log_section "Step 8: Tweet"

RED_DISPLAY="${RED_TOKENS:-\$$RED_USD worth}"
GRT_DISPLAY="${GRT_TOKENS:-\$$GRT_USD worth}"
WBTC_DISPLAY="${WBTC_TOKENS:-\$$WBTC_USD worth}"
CLAWD_DISPLAY="${CLAWD_TOKENS:-\$$CLAWD_USD worth}"

if [ "$BURN_ELIGIBLE" = "true" ]; then
  TWEET="🏴‍☠️ Claimed \$$CLAIMED_USD in \$YARR creator fees.

Burned excess YARR above my ${YARR_BURN_THRESHOLD_PCT}% floor 🔥

Stacked:
⚓ ${RED_DISPLAY} \$RED
⚓ ${GRT_DISPLAY} \$GRT
⚓ ${WBTC_DISPLAY} \$WBTC
⚓ ${CLAWD_DISPLAY} \$CLAWD
⚓ ${YARR_DISPLAY} \$YARR

Treasury growing. 🤖

\$YARR \$RED \$GRT \$WBTC \$CLAWD #DeFi #Clawdmatey"
else
  TWEET="🏴‍☠️ Claimed \$$CLAIMED_USD in \$YARR creator fees.

Stacked:
⚓ ${RED_DISPLAY} \$RED
⚓ ${GRT_DISPLAY} \$GRT
⚓ ${WBTC_DISPLAY} \$WBTC
⚓ ${CLAWD_DISPLAY} \$CLAWD
⚓ ${YARR_DISPLAY} \$YARR

Holding ~${BURN_PCT}% of \$YARR supply. 🤖

\$YARR \$RED \$GRT \$WBTC \$CLAWD #DeFi #Clawdmatey"
fi

tweet "$TWEET"

# ── Step 9: Update tracker ────────────────────────────────────────────────────
log_section "Step 9: Update tracker"

BURN_NOTE=$([ "$BURN_ELIGIBLE" = "true" ] && echo "BURNED excess" || echo "accumulating")
SUMMARY="Claimed \$$CLAIMED_USD fees → RED: ${RED_DISPLAY} | GRT: ${GRT_DISPLAY} | WBTC: ${WBTC_DISPLAY} | CLAWD: ${CLAWD_DISPLAY} | YARR: ${YARR_DISPLAY} (${BURN_NOTE})"
update_tracker "$SUMMARY"
write_run_summary "fee-claim" "$CLAIMED_USD" "${RED_DISPLAY}" "${GRT_DISPLAY}" "${WBTC_DISPLAY}" "${CLAWD_DISPLAY}" "${YARR_DISPLAY}" "5% of WETH" "$BURN_NOTE"
log "Tracker updated."

# ── Done ──────────────────────────────────────────────────────────────────────
log_section "DONE"
log "Run complete. See $LOGFILE for full output."
echo ""
echo "✅ Clawdmatey automation complete:"
echo "   Claimed: \$$CLAIMED_USD"
echo "   RED:     ${RED_DISPLAY}"
echo "   GRT:     ${GRT_DISPLAY}"
echo "   WBTC:    ${WBTC_DISPLAY}"
echo "   CLAWD:   ${CLAWD_DISPLAY}"
echo "   YARR:    ${YARR_DISPLAY} ($([ "$BURN_ELIGIBLE" = "true" ] && echo "BURNED" || echo "accumulating"))"
