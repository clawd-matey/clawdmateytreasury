#!/usr/bin/env python3
"""
clanker-fees.py — Direct Clanker fee claiming without Bankr

Commands:
  check     Check available fees for a token creator
  claim     Claim all available fees for a token

Output: JSON to stdout
"""

import argparse
import json
import os
import sys
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware
from eth_account import Account

# ── Config ────────────────────────────────────────────────────────────────────

def _load_env_file():
    for env_name in ["clawdmatey.env", "redbotster.env"]:
        env_file = os.path.expanduser(f"~/.openclaw/{env_name}")
        if os.path.exists(env_file):
            with open(env_file) as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, v = line.split("=", 1)
                        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))
            break

_load_env_file()

WALLET_MODE = os.environ.get("WALLET_MODE", "vault")
WALLET_ENV_PATH = os.environ.get("WALLET_ENV_PATH", "")

# Clanker contracts on Base mainnet
CLANKER_FEE_LOCKER = "0xF3622742b1E446D92e45E22923Ef11C2fcD55D68"
WETH_BASE = "0x4200000000000000000000000000000000000006"

# Base RPC
BASE_RPC = "https://mainnet.base.org"

# Token addresses
TOKENS = {
    "YARR": "0x309792e8950405f803c0e3f2c9083bdff4466ba3",
    "RED": "0x2e662015a501f066e043d64d04f77ffe551a4b07",
    "WETH": WETH_BASE,
}

# ClankerFeeLocker ABI (only the functions we need)
FEE_LOCKER_ABI = [
    {
        "name": "availableFees",
        "type": "function",
        "inputs": [
            {"name": "feeOwner", "type": "address"},
            {"name": "token", "type": "address"}
        ],
        "outputs": [{"type": "uint256"}],
        "stateMutability": "view"
    },
    {
        "name": "claim",
        "type": "function",
        "inputs": [
            {"name": "feeOwner", "type": "address"},
            {"name": "token", "type": "address"}
        ],
        "outputs": [],
        "stateMutability": "nonpayable"
    }
]

ERC20_ABI = [
    {"name": "decimals", "type": "function", "inputs": [], "outputs": [{"type": "uint8"}], "stateMutability": "view"},
    {"name": "symbol", "type": "function", "inputs": [], "outputs": [{"type": "string"}], "stateMutability": "view"},
]

# ── Helpers ───────────────────────────────────────────────────────────────────

def log(msg):
    print(f"[clanker-fees] {msg}", file=sys.stderr)

def out(status, response, data=None, tx=None):
    d = {"status": status, "response": response}
    if data: d["data"] = data
    if tx: d["tx"] = tx
    print(json.dumps(d))

def fail(msg):
    out("failed", msg)
    sys.exit(1)

def get_private_key():
    """Get private key from local env file."""
    if WALLET_MODE != "local":
        fail("Only local wallet mode supported for direct claiming")
    
    if not WALLET_ENV_PATH or not os.path.exists(WALLET_ENV_PATH):
        fail(f"WALLET_ENV_PATH not found: {WALLET_ENV_PATH}")
    
    env_vars = {}
    with open(WALLET_ENV_PATH) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env_vars[k.strip()] = v.strip().strip('"').strip("'")
    
    if "PRIVATE_KEY" in env_vars:
        return env_vars["PRIVATE_KEY"]
    
    mnemonic = env_vars.get("MNEMONIC") or env_vars.get("WALLET_MNEMONIC") or env_vars.get("SEED_PHRASE")
    if mnemonic:
        Account.enable_unaudited_hdwallet_features()
        acct = Account.from_mnemonic(mnemonic)
        return acct.key.hex()
    
    fail("No PRIVATE_KEY or MNEMONIC found in wallet env file")

def connect():
    """Connect to Base mainnet."""
    w3 = Web3(Web3.HTTPProvider(BASE_RPC, request_kwargs={"timeout": 30}))
    w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
    if not w3.is_connected():
        fail("Cannot connect to Base RPC")
    return w3

def get_eth_price():
    """Get current ETH price in USD."""
    import urllib.request
    try:
        url = "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd"
        req = urllib.request.Request(url, headers={"User-Agent": "Clawdmatey/1.0"})
        resp = urllib.request.urlopen(req, timeout=10)
        data = json.loads(resp.read())
        return float(data["ethereum"]["usd"])
    except:
        return 2000.0  # fallback

def send_tx(w3, account, tx):
    """Sign and send a transaction."""
    tx["nonce"] = w3.eth.get_transaction_count(account.address)
    tx["gas"] = w3.eth.estimate_gas({**tx, "from": account.address})
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    log(f"TX sent: {tx_hash.hex()} — waiting...")
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    if receipt["status"] != 1:
        fail(f"TX reverted: {tx_hash.hex()}")
    log(f"TX confirmed in block {receipt['blockNumber']}")
    return tx_hash.hex()

# ── Commands ──────────────────────────────────────────────────────────────────

def cmd_check(args):
    """Check available fees for a token creator."""
    w3 = connect()
    fee_locker = w3.eth.contract(
        address=Web3.to_checksum_address(CLANKER_FEE_LOCKER),
        abi=FEE_LOCKER_ABI
    )
    
    fee_owner = Web3.to_checksum_address(args.fee_owner)
    eth_price = get_eth_price()
    
    results = {}
    total_usd = 0
    
    # Check WETH fees (main fee token)
    weth_fees = fee_locker.functions.availableFees(fee_owner, Web3.to_checksum_address(WETH_BASE)).call()
    weth_amount = weth_fees / 1e18
    weth_usd = weth_amount * eth_price
    results["WETH"] = {"amount": weth_amount, "usd": weth_usd}
    total_usd += weth_usd
    log(f"WETH fees: {weth_amount:.6f} (~${weth_usd:.2f})")
    
    # Check token fees (YARR in the creator's case)
    if args.token:
        token_addr = TOKENS.get(args.token.upper(), args.token)
        token_fees = fee_locker.functions.availableFees(fee_owner, Web3.to_checksum_address(token_addr)).call()
        token_amount = token_fees / 1e18  # assuming 18 decimals
        results[args.token.upper()] = {"amount": token_amount, "usd": 0}  # no USD price for token
        log(f"{args.token.upper()} fees: {token_amount:,.0f}")
    
    msg = f"Available fees for {fee_owner[:10]}...: {weth_amount:.6f} WETH (~${weth_usd:.2f})"
    out("completed", msg, data={"fees": results, "total_usd": total_usd, "eth_price": eth_price})

def cmd_claim(args):
    """Claim available fees."""
    w3 = connect()
    
    # Get wallet
    log("Loading wallet...")
    pk = get_private_key()
    account = Account.from_key(pk)
    log(f"Claiming from wallet: {account.address}")
    
    fee_locker = w3.eth.contract(
        address=Web3.to_checksum_address(CLANKER_FEE_LOCKER),
        abi=FEE_LOCKER_ABI
    )
    
    fee_owner = Web3.to_checksum_address(args.fee_owner)
    eth_price = get_eth_price()
    
    claimed = {}
    tx_hashes = []
    
    # Claim WETH fees
    weth_fees = fee_locker.functions.availableFees(fee_owner, Web3.to_checksum_address(WETH_BASE)).call()
    if weth_fees > 0:
        weth_amount = weth_fees / 1e18
        weth_usd = weth_amount * eth_price
        log(f"Claiming {weth_amount:.6f} WETH (~${weth_usd:.2f})...")
        
        if args.dry_run:
            log("[DRY RUN] Would claim WETH fees")
            claimed["WETH"] = {"amount": weth_amount, "usd": weth_usd}
        else:
            gas_price = w3.eth.gas_price
            tx = fee_locker.functions.claim(
                fee_owner,
                Web3.to_checksum_address(WETH_BASE)
            ).build_transaction({
                "chainId": 8453,
                "from": account.address,
                "maxFeePerGas": gas_price * 2,
                "maxPriorityFeePerGas": gas_price,
            })
            tx_hash = send_tx(w3, account, tx)
            tx_hashes.append(tx_hash)
            claimed["WETH"] = {"amount": weth_amount, "usd": weth_usd, "tx": tx_hash}
    else:
        log("No WETH fees to claim")
    
    # Claim token fees if specified
    if args.token:
        token_addr = TOKENS.get(args.token.upper(), args.token)
        token_fees = fee_locker.functions.availableFees(fee_owner, Web3.to_checksum_address(token_addr)).call()
        if token_fees > 0:
            token_amount = token_fees / 1e18
            log(f"Claiming {token_amount:,.0f} {args.token.upper()}...")
            
            if args.dry_run:
                log(f"[DRY RUN] Would claim {args.token.upper()} fees")
                claimed[args.token.upper()] = {"amount": token_amount}
            else:
                gas_price = w3.eth.gas_price
                tx = fee_locker.functions.claim(
                    fee_owner,
                    Web3.to_checksum_address(token_addr)
                ).build_transaction({
                    "chainId": 8453,
                    "from": account.address,
                    "maxFeePerGas": gas_price * 2,
                    "maxPriorityFeePerGas": gas_price,
                })
                tx_hash = send_tx(w3, account, tx)
                tx_hashes.append(tx_hash)
                claimed[args.token.upper()] = {"amount": token_amount, "tx": tx_hash}
        else:
            log(f"No {args.token.upper()} fees to claim")
    
    if claimed:
        total_weth = claimed.get("WETH", {}).get("amount", 0)
        total_usd = claimed.get("WETH", {}).get("usd", 0)
        msg = f"Claimed {total_weth:.6f} WETH (~${total_usd:.2f})"
        out("completed", msg, data={"claimed": claimed, "total_usd": total_usd}, tx=tx_hashes[0] if tx_hashes else None)
    else:
        out("completed", "No fees to claim", data={"claimed": {}})

# ── CLI ───────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Direct Clanker fee claiming")
    sub = parser.add_subparsers(dest="command", required=True)
    
    p_check = sub.add_parser("check", help="Check available fees")
    p_check.add_argument("--fee-owner", required=True, help="Fee recipient address (token creator)")
    p_check.add_argument("--token", help="Token to check fees for (e.g., YARR)")
    
    p_claim = sub.add_parser("claim", help="Claim available fees")
    p_claim.add_argument("--fee-owner", required=True, help="Fee recipient address (token creator)")
    p_claim.add_argument("--token", help="Token to claim fees for (e.g., YARR)")
    p_claim.add_argument("--dry-run", action="store_true", help="Simulate without executing")
    
    args = parser.parse_args()
    
    if args.command == "check":
        cmd_check(args)
    elif args.command == "claim":
        cmd_claim(args)

if __name__ == "__main__":
    main()
