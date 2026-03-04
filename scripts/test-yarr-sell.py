#!/usr/bin/env python3
"""Quick test: sell small amount of YARR for WETH via Uniswap v3"""

import os
import sys
from web3 import Web3
from eth_account import Account

# Load wallet env
def load_env():
    for env_name in ["clawdmatey.env", "redbotster.env"]:
        env_file = os.path.expanduser(f"~/.openclaw/{env_name}")
        if os.path.exists(env_file):
            with open(env_file) as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, v = line.split("=", 1)
                        os.environ.setdefault(k.strip(), v.strip())
            break

load_env()

# Config
RPC = "https://base-rpc.publicnode.com"
YARR = "0x309792e8950405f803c0e3f2c9083bdff4466ba3"
WETH = "0x4200000000000000000000000000000000000006"
ROUTER = "0x2626664c2603336E57B271c5C0b26F421741e481"  # SwapRouter02 on Base

# Amount to sell (1000 YARR ~ very small test)
AMOUNT_YARR = 1000
DRY_RUN = "--dry-run" in sys.argv

ERC20_ABI = [
    {"name": "approve", "type": "function", "inputs": [{"name": "spender", "type": "address"}, {"name": "amount", "type": "uint256"}], "outputs": [{"type": "bool"}], "stateMutability": "nonpayable"},
    {"name": "allowance", "type": "function", "inputs": [{"name": "owner", "type": "address"}, {"name": "spender", "type": "address"}], "outputs": [{"type": "uint256"}], "stateMutability": "view"},
    {"name": "balanceOf", "type": "function", "inputs": [{"name": "account", "type": "address"}], "outputs": [{"type": "uint256"}], "stateMutability": "view"},
]

ROUTER_ABI = [{
    "name": "exactInputSingle",
    "type": "function",
    "inputs": [{"name": "params", "type": "tuple", "components": [
        {"name": "tokenIn", "type": "address"},
        {"name": "tokenOut", "type": "address"},
        {"name": "fee", "type": "uint24"},
        {"name": "recipient", "type": "address"},
        {"name": "amountIn", "type": "uint256"},
        {"name": "amountOutMinimum", "type": "uint256"},
        {"name": "sqrtPriceLimitX96", "type": "uint160"},
    ]}],
    "outputs": [{"name": "amountOut", "type": "uint256"}],
    "stateMutability": "payable",
}]

def get_private_key():
    """Get wallet private key from local file (same as uniswap-swap.py)"""
    wallet_path = os.environ.get("WALLET_ENV_PATH", "")
    if not wallet_path or not os.path.exists(wallet_path):
        raise ValueError(f"WALLET_ENV_PATH not found: {wallet_path}")
    
    env_vars = {}
    with open(wallet_path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env_vars[k.strip()] = v.strip().strip('"').strip("'")
    
    if "PRIVATE_KEY" in env_vars:
        return env_vars["PRIVATE_KEY"]
    
    # Derive from mnemonic
    mnemonic = env_vars.get("MNEMONIC") or env_vars.get("WALLET_MNEMONIC") or env_vars.get("SEED_PHRASE")
    if mnemonic:
        Account.enable_unaudited_hdwallet_features()
        acct = Account.from_mnemonic(mnemonic)
        return acct.key.hex()
    
    raise ValueError("No PRIVATE_KEY or MNEMONIC found in wallet env")

def main():
    w3 = Web3(Web3.HTTPProvider(RPC))
    pk = get_private_key()
    account = Account.from_key(pk)
    
    print(f"Wallet: {account.address}")
    print(f"Selling: {AMOUNT_YARR} YARR → WETH")
    print(f"Dry run: {DRY_RUN}")
    
    yarr = w3.eth.contract(address=Web3.to_checksum_address(YARR), abi=ERC20_ABI)
    balance = yarr.functions.balanceOf(account.address).call()
    print(f"YARR balance: {balance / 1e18:,.0f}")
    
    amount_in = int(AMOUNT_YARR * 1e18)
    if balance < amount_in:
        print(f"ERROR: Insufficient YARR")
        return
    
    if DRY_RUN:
        print("\n=== DRY RUN — would execute: ===")
        print(f"1. Approve {AMOUNT_YARR} YARR to router {ROUTER}")
        print(f"2. Call exactInputSingle: {AMOUNT_YARR} YARR → WETH (fee tier 3000)")
        print("=== End dry run ===")
        return
    
    # Approve
    router_addr = Web3.to_checksum_address(ROUTER)
    allowance = yarr.functions.allowance(account.address, router_addr).call()
    if allowance < amount_in:
        print("Approving YARR...")
        approve_tx = yarr.functions.approve(router_addr, amount_in * 10).build_transaction({
            "chainId": 8453,
            "from": account.address,
            "nonce": w3.eth.get_transaction_count(account.address),
            "maxFeePerGas": w3.eth.gas_price * 2,
            "maxPriorityFeePerGas": w3.eth.gas_price,
        })
        signed = account.sign_transaction(approve_tx)
        tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
        print(f"Approve TX: {tx_hash.hex()}")
        w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
        print("Approved ✓")
    
    # Swap
    router = w3.eth.contract(address=router_addr, abi=ROUTER_ABI)
    
    for fee_tier in [10000, 3000, 500]:  # Try 1%, 0.3%, 0.05%
        print(f"Trying fee tier {fee_tier}...")
        try:
            params = (
                Web3.to_checksum_address(YARR),
                Web3.to_checksum_address(WETH),
                fee_tier,
                account.address,
                amount_in,
                0,  # amountOutMinimum (accept any)
                0,  # sqrtPriceLimitX96
            )
            swap_tx = router.functions.exactInputSingle(params).build_transaction({
                "chainId": 8453,
                "from": account.address,
                "nonce": w3.eth.get_transaction_count(account.address),
                "value": 0,
                "maxFeePerGas": w3.eth.gas_price * 2,
                "maxPriorityFeePerGas": w3.eth.gas_price,
            })
            signed = account.sign_transaction(swap_tx)
            tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
            print(f"Swap TX: {tx_hash.hex()}")
            receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
            if receipt.status == 1:
                print(f"✅ SUCCESS! Sold {AMOUNT_YARR} YARR for WETH")
                print(f"TX: https://basescan.org/tx/{tx_hash.hex()}")
                return
            else:
                print(f"TX reverted")
        except Exception as e:
            print(f"Fee tier {fee_tier} failed: {e}")
    
    print("❌ All fee tiers failed")

if __name__ == "__main__":
    main()
