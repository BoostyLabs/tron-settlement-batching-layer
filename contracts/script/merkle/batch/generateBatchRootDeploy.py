import time
import json
import os
import base58
from web3 import Web3
from typing import List, Dict, Any
from dataclasses import dataclass
from enum import IntEnum

# --- CONFIGURATION ---

TRON_SENDER = "TKWvD71EMFTpFVGZyqqX9fC6MQgcR9H76M"
TRON_RECIPIENT = "TFZMxv9HUzvsL3M7obrvikSQkuvJsopgMU"

BATCH_ID = 40
BATCH_SALT = 1  # Salt used by backend to build merkle root
TOKEN_DECIMALS = 6  # e.g. TRC20 USDT has 6 decimals

# --- TYPES ---

class TxType(IntEnum):
    DELAYED = 0
    INSTANT = 1
    BATCHED = 2
    FREE_TIER = 3

@dataclass
class TransferData:
    # EVM 0x addresses (Tron Base58 converted by stripping 0x41)
    from_address: str
    to_address: str

    # Original Tron Base58 for logs/UI only
    original_tron_from: str
    original_tron_to: str

    amount: int            # uint256
    nonce: int             # uint64
    timestamp: int         # uint48
    recipient_count: int   # uint32
    batch_id: int          # NOT hashed
    tx_type: int           # uint8
    batch_salt: int        # uint64 salt used by backend to build merkle root

# --- HELPERS ---

def tron_to_evm_address(tron_addr: str) -> str:
    """
    Convert Tron Base58Check addr (T...) to EVM 0x address by stripping leading 0x41.
    Returns checksummed 0x address.
    """
    decoded = base58.b58decode_check(tron_addr)
    if len(decoded) < 21 or decoded[0] != 0x41:
        raise ValueError(f"Invalid Tron address: {tron_addr}")
    evm_hex = decoded[1:].hex()
    return Web3.to_checksum_address("0x" + evm_hex)

def ensure_uint_bounds(nonce: int, timestamp: int, recipient_count: int) -> None:
    if not (0 <= nonce <= (2**64 - 1)):
        raise ValueError("nonce exceeds uint64")
    if not (0 <= timestamp <= (2**48 - 1)):
        raise ValueError("timestamp exceeds uint48")
    if not (0 <= recipient_count <= (2**32 - 1)):
        raise ValueError("recipient_count exceeds uint32")

# --- MERKLE LOGIC ---

class MerkleTree:
    def __init__(self, leaves: List[bytes]):
        self.leaves = leaves
        self.tree = self._build_tree(leaves)

    def _build_tree(self, leaves: List[bytes]) -> List[List[bytes]]:
        if not leaves:
            return [[]]
        tree = [leaves]
        current_level = leaves
        while len(current_level) > 1:
            next_level: List[bytes] = []
            for i in range(0, len(current_level), 2):
                if i + 1 < len(current_level):
                    left = current_level[i]
                    right = current_level[i + 1]
                    # Sorted-pair hashing for OZ-compatible proofs
                    if left > right:
                        left, right = right, left
                    combined = Web3.solidity_keccak(['bytes32', 'bytes32'], [left, right])
                else:
                    # Promote odd leaf
                    combined = current_level[i]
                next_level.append(combined)
            tree.append(next_level)
            current_level = next_level
        return tree

    def get_root(self) -> bytes:
        return self.tree[-1][0] if self.tree and self.tree[-1] else b'\x00' * 32

    def get_proof(self, index: int) -> List[bytes]:
        proof: List[bytes] = []
        idx = index
        for level in range(len(self.tree) - 1):
            curr = self.tree[level]
            if idx % 2 == 0:
                if idx + 1 < len(curr):
                    proof.append(curr[idx + 1])
            else:
                proof.append(curr[idx - 1])
            idx //= 2
        return proof

# --- HASHING (matches Settlement._calculateTxHash) ---

def calculate_tx_hash(tx: TransferData) -> bytes:
    """
    keccak256(abi.encodePacked(
        from(address), to(address),
        amount(uint256), nonce(uint64), timestamp(uint48), recipientCount(uint32),
        txType(uint8), batchSalt(uint64)
    ))
    batchId is EXCLUDED from the hash.
    """
    ensure_uint_bounds(tx.nonce, tx.timestamp, tx.recipient_count)
    return Web3.solidity_keccak(
        ['address', 'address', 'uint256', 'uint64', 'uint48', 'uint32', 'uint8', 'uint64'],
        [
            Web3.to_checksum_address(tx.from_address),
            Web3.to_checksum_address(tx.to_address),
            tx.amount,
            tx.nonce,
            tx.timestamp,
            tx.recipient_count,
            tx.tx_type,
            tx.batch_salt
        ]
    )

# --- GENERATION ---

def generate_batch() -> Dict[str, Any]:
    sender_evm = tron_to_evm_address(TRON_SENDER)
    recipient_evm = tron_to_evm_address(TRON_RECIPIENT)

    base_ts = int(time.time())
    one_token = 10 ** TOKEN_DECIMALS

    txs: List[TransferData] = []

    # Two transfers to ensure non-empty proofs
    txs.append(TransferData(
        from_address=sender_evm,
        to_address=recipient_evm,
        original_tron_from=TRON_SENDER,
        original_tron_to=TRON_RECIPIENT,
        amount=10 * one_token,
        nonce=1,
        timestamp=base_ts,
        recipient_count=1,
        batch_id=BATCH_ID,
        tx_type=TxType.DELAYED,
        batch_salt=BATCH_SALT
    ))

    txs.append(TransferData(
        from_address=sender_evm,
        to_address=recipient_evm,
        original_tron_from=TRON_SENDER,
        original_tron_to=TRON_RECIPIENT,
        amount=20 * one_token,
        nonce=2,
        timestamp=base_ts + 1,
        recipient_count=1,
        batch_id=BATCH_ID,
        tx_type=TxType.INSTANT,
        batch_salt=BATCH_SALT
    ))

    txs.append(TransferData(
        from_address=sender_evm,
        to_address=recipient_evm,
        original_tron_from=TRON_SENDER,
        original_tron_to=TRON_RECIPIENT,
        amount=30 * one_token,
        nonce=3,
        timestamp=base_ts + 2,
        recipient_count=3,
        batch_id=BATCH_ID,
        tx_type=TxType.BATCHED,
        batch_salt=BATCH_SALT
    ))

    leaves = [calculate_tx_hash(tx) for tx in txs]
    tree = MerkleTree(leaves)
    root = tree.get_root()

    output: Dict[str, Any] = {
        "merkleRoot": "0x" + root.hex(),
        "txCount": len(txs),
        "batchId": BATCH_ID,
        "batchSalt": BATCH_SALT,
        "transactions": []
    }

    print("\n" + "=" * 60)
    print(f"MERKLE ROOT: 0x{root.hex()}")
    print("=" * 60)

    for i, tx in enumerate(txs):
        leaf = leaves[i]
        proof = tree.get_proof(i)
        proof_hex = ["0x" + p.hex() for p in proof]

        tx_data_struct = [
            tx.from_address,        # address (EVM 0x)
            tx.to_address,          # address (EVM 0x)
            str(tx.amount),         # uint256 (string for JSON safety)
            tx.nonce,               # uint64
            tx.timestamp,           # uint48
            tx.recipient_count,     # uint32
            tx.batch_id,            # uint64 (NOT hashed)
            tx.tx_type,             # uint8
            tx.batch_salt           # uint64 (used in hash)
        ]

        entry = {
            "index": i,
            "type": TxType(tx.tx_type).name,
            "txHash": "0x" + leaf.hex(),
            "txDataStruct": tx_data_struct,
            "evmAddresses": {"from": tx.from_address, "to": tx.to_address},
            "tronAddresses": {"from": tx.original_tron_from, "to": tx.original_tron_to},
            "proof": proof_hex
        }
        output["transactions"].append(entry)

        print(f"TX {i} ({TxType(tx.tx_type).name})")
        print(f"  From (Tron/EVM): {tx.original_tron_from} / {tx.from_address}")
        print(f"  To   (Tron/EVM): {tx.original_tron_to} / {tx.to_address}")
        print(f"  Amount: {tx.amount}")
        print(f"  Nonce: {tx.nonce}  Timestamp: {tx.timestamp}  RecipientCount: {tx.recipient_count}")
        print(f"  BatchSalt: {tx.batch_salt}")
        print(f"  Hash: 0x{leaf.hex()}")
        print(f"  Proof: {proof_hex}")

    return output

def save_json(output: Dict[str, Any], filename: str = "merkle_data_deploy.json") -> None:
    script_dir = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(script_dir, filename)
    with open(path, "w") as f:
        json.dump(output, f, indent=2)
    print(f"\nSaved: {path}")

if __name__ == "__main__":
    data = generate_batch()
    save_json(data)
