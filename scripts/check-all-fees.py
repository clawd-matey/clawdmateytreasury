#!/usr/bin/env python3
"""
check-all-fees.py — Check BOTH fee systems before claiming

YARR is v3 (Bankr/LpLockerv2), but future tokens might be v4 (ClankerFeeLocker).
Always check both systems and sum totals.

Usage:
  python check-all-fees.py [--json]
"""

import json
import os
import re
import subprocess
import sys
import urllib.request

# Load config
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
CONFIG_FILE = os.path.join(PROJECT_DIR, "config.json")

with open(CONFIG_FILE) as f:
    CONFIG = json.load(f)

CREATOR_WALLET = CONFIG.get("creatorWallet", "0x8b59a7e24386d2265e9dfd6de59b4a6bbd5d1633")
YARR_TOKEN = CONFIG.get("yarrToken", "0x309792e8950405f803c0e3f2c9083bdff4466ba3")

def get_eth_price():
    """Get current ETH price from CoinGecko"""
    try:
        url = "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd"
        req = urllib.request.Request(url, headers={"User-Agent": "ClawdmateyBot/1.0"})
        resp = json.loads(urllib.request.urlopen(req, timeout=10).read())
        return float(resp["ethereum"]["usd"])
    except Exception:
        return 2100.0  # fallback

def check_v4_fees():
    """Check v4 ClankerFeeLocker via clanker-fees.py"""
    try:
        result = subprocess.run(
            ["python", os.path.join(SCRIPT_DIR, "clanker-fees.py"), 
             "check", "--fee-owner", CREATOR_WALLET, "--token", YARR_TOKEN],
            capture_output=True, text=True, timeout=30
        )
        # Parse JSON output
        for line in result.stdout.split("\n"):
            if line.startswith("{"):
                data = json.loads(line)
                if data.get("status") == "completed":
                    return data.get("data", {}).get("total_usd", 0)
        return 0
    except Exception as e:
        print(f"[check-all-fees] v4 check error: {e}", file=sys.stderr)
        return 0

def check_v3_fees():
    """Check v3 LpLockerv2 via Bankr CLI"""
    try:
        # Run bankr fees command
        result = subprocess.run(
            ["bankr", "fees", CREATOR_WALLET],
            capture_output=True, text=True, timeout=60,
            env={**os.environ, "NO_COLOR": "1", "TERM": "dumb"}
        )
        output = result.stdout + result.stderr
        
        # Parse "Claimable: X.XXXX WETH" pattern (most reliable)
        match = re.search(r'Claimable:\s*([\d.]+)\s*WETH', output)
        if match:
            claimable_weth = float(match.group(1))
            eth_price = get_eth_price()
            print(f"[check-all-fees] Found v3 claimable: {claimable_weth} WETH", file=sys.stderr)
            return claimable_weth * eth_price
        
        # Fallback: look for box format "│ 0.021543 │" after CLAIMABLE WETH
        lines = output.split('\n')
        for i, line in enumerate(lines):
            if 'CLAIMABLE WETH' in line.upper():
                if i + 1 < len(lines):
                    # Match unicode box char or pipe
                    val_match = re.search(r'[│|]\s*([\d.]+)\s*[│|]', lines[i + 1])
                    if val_match:
                        claimable_weth = float(val_match.group(1))
                        eth_price = get_eth_price()
                        print(f"[check-all-fees] Found v3 claimable (box): {claimable_weth} WETH", file=sys.stderr)
                        return claimable_weth * eth_price
        
        print(f"[check-all-fees] Could not parse v3 output. Raw:", file=sys.stderr)
        print(output[:500], file=sys.stderr)
        return 0
    except Exception as e:
        print(f"[check-all-fees] v3 check error: {e}", file=sys.stderr)
        return 0

def main():
    json_output = "--json" in sys.argv
    
    eth_price = get_eth_price()
    
    print(f"[check-all-fees] ETH price: ${eth_price:.2f}", file=sys.stderr)
    print(f"[check-all-fees] Creator wallet: {CREATOR_WALLET}", file=sys.stderr)
    print(f"[check-all-fees] YARR token: {YARR_TOKEN}", file=sys.stderr)
    
    # Check both systems
    print(f"[check-all-fees] Checking v4 ClankerFeeLocker...", file=sys.stderr)
    v4_usd = check_v4_fees()
    print(f"[check-all-fees] v4 fees: ${v4_usd:.2f}", file=sys.stderr)
    
    print(f"[check-all-fees] Checking v3 Bankr/LpLockerv2...", file=sys.stderr)
    v3_usd = check_v3_fees()
    print(f"[check-all-fees] v3 fees: ${v3_usd:.2f}", file=sys.stderr)
    
    total_usd = v4_usd + v3_usd
    
    result = {
        "status": "completed",
        "v4_usd": round(v4_usd, 2),
        "v3_usd": round(v3_usd, 2),
        "total_usd": round(total_usd, 2),
        "eth_price": eth_price,
        "creator_wallet": CREATOR_WALLET,
        "yarr_token": YARR_TOKEN
    }
    
    print(f"[check-all-fees] ═══════════════════════════════════════", file=sys.stderr)
    print(f"[check-all-fees] TOTAL CLAIMABLE: ${total_usd:.2f}", file=sys.stderr)
    print(f"[check-all-fees]   v4 (ClankerFeeLocker): ${v4_usd:.2f}", file=sys.stderr)
    print(f"[check-all-fees]   v3 (Bankr/LpLockerv2): ${v3_usd:.2f}", file=sys.stderr)
    print(f"[check-all-fees] ═══════════════════════════════════════", file=sys.stderr)
    
    print(json.dumps(result))

if __name__ == "__main__":
    main()
