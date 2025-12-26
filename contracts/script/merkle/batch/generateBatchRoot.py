from web3 import Web3
from enum import IntEnum
from dataclasses import dataclass
from typing import List, Dict, Any
import json
import time

class TxType(IntEnum):
    DELAYED = 0
    INSTANT = 1
    BATCHED = 2
    FREE_TIER = 3

@dataclass
class TransferData:
    from_address: str
    to_address: str
    amount: int
    nonce: int
    timestamp: int
    recipient_count: int
    batch_id: int       # keep for off-chain grouping and on-chain params, but not hashed
    tx_type: int
    batch_salt: int     # uint64 salt used by backend to build merkle root

def calculate_tx_hash(tx: TransferData) -> bytes:
    """
    Match Settlement._calculateTxHash:
    keccak256(abi.encodePacked(
        from, to, amount, nonce(uint64), timestamp(uint48), recipientCount(uint32), txType(uint8), batchSalt(uint64)
    ))
    IMPORTANT: batchId is NOT included.
    """
    return Web3.solidity_keccak(
        ['address', 'address', 'uint256', 'uint64', 'uint48', 'uint32', 'uint8', 'uint64'],
        [
            Web3.to_checksum_address(tx.from_address),
            Web3.to_checksum_address(tx.to_address),
            tx.amount,
            tx.nonce,             # uint64
            tx.timestamp,         # uint48
            tx.recipient_count,   # uint32
            tx.tx_type,           # uint8
            tx.batch_salt         # uint64
        ]
    )

class MerkleTree:
    def __init__(self, leaves: List[bytes]):
        self.leaves = leaves
        self.tree = self._build_tree(leaves)

    def _build_tree(self, leaves: List[bytes]) -> List[List[bytes]]:
        if not leaves:
            return [[]]
        tree = [leaves]
        current = leaves
        while len(current) > 1:
            nxt = []
            for i in range(0, len(current), 2):
                if i + 1 < len(current):
                    left = current[i]
                    right = current[i + 1]
                    # sorted pair hashing to match OpenZeppelin's MerkleProof standard pattern
                    if left > right:
                        left, right = right, left
                    combined = Web3.solidity_keccak(['bytes32', 'bytes32'], [left, right])
                else:
                    combined = current[i]
                nxt.append(combined)
            tree.append(nxt)
            current = nxt
        return tree

    def get_root(self) -> bytes:
        return self.tree[-1][0] if self.tree and self.tree[-1] else b'\x00' * 32

    def get_proof(self, index: int) -> List[bytes]:
        proof = []
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

    def verify_proof(self, leaf: bytes, proof: List[bytes], root: bytes) -> bool:
        computed = leaf
        for p in proof:
            if computed <= p:
                computed = Web3.solidity_keccak(['bytes32', 'bytes32'], [computed, p])
            else:
                computed = Web3.solidity_keccak(['bytes32', 'bytes32'], [p, computed])
        return computed == root

def generate_test_transactions() -> List[TransferData]:
    SENDER = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    RECIPIENT_1 = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
    RECIPIENT_2 = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
    RECIPIENT_3 = "0x90F79bf6EB2c4f870365E785982E1f101E93b906"
    RANDOM_ADDR = "0x1234567890123456789012345678901234567890"
    ZERO_ADDR = "0x0000000000000000000000000000000000000000"

    BATCH_ID = 1
    BATCH_SALT = 1  # Salt used by backend to build merkle root
    base_timestamp = int(time.time())
    ONE_TRX = 1_000_000

    txs: List[TransferData] = []

    for i in range(10):
        txs.append(TransferData(
            from_address=SENDER,
            to_address=RECIPIENT_1,
            amount=100 * ONE_TRX,
            nonce=i + 1,
            timestamp=base_timestamp + i,
            recipient_count=1,
            batch_id=BATCH_ID,
            tx_type=TxType.DELAYED,
            batch_salt=BATCH_SALT
        ))

    txs.append(TransferData(SENDER, RECIPIENT_1, 50 * ONE_TRX, 11, base_timestamp + 10, 1, BATCH_ID, TxType.FREE_TIER, BATCH_SALT))
    txs.append(TransferData(SENDER, RECIPIENT_1, 200 * ONE_TRX, 12, base_timestamp + 11, 1, BATCH_ID, TxType.INSTANT, BATCH_SALT))
    txs.append(TransferData(SENDER, RECIPIENT_1, 300 * ONE_TRX, 13, base_timestamp + 12, 3, BATCH_ID, TxType.INSTANT, BATCH_SALT))
    txs.append(TransferData(SENDER, RECIPIENT_2, 500 * ONE_TRX, 14, base_timestamp + 13, 5, BATCH_ID, TxType.BATCHED, BATCH_SALT))
    txs.append(TransferData(RANDOM_ADDR, RECIPIENT_3, 150 * ONE_TRX, 15, base_timestamp + 14, 3, BATCH_ID, TxType.BATCHED, BATCH_SALT))
    txs.append(TransferData(SENDER, RECIPIENT_1, 100 * ONE_TRX, 16, base_timestamp + 15, 1, BATCH_ID, TxType.BATCHED, BATCH_SALT))
    txs.append(TransferData(SENDER, RECIPIENT_1, 1_000_000_000 * ONE_TRX, 17, base_timestamp + 16, 1, BATCH_ID, TxType.INSTANT, BATCH_SALT))
    txs.append(TransferData(ZERO_ADDR, RECIPIENT_1, 100 * ONE_TRX, 18, base_timestamp + 17, 1, BATCH_ID, TxType.DELAYED, BATCH_SALT))
    txs.append(TransferData(SENDER, ZERO_ADDR, 100 * ONE_TRX, 19, base_timestamp + 18, 1, BATCH_ID, TxType.DELAYED, BATCH_SALT))

    return txs

def generate_merkle_data(transactions: List[TransferData]) -> Dict[str, Any]:
    leaves = [calculate_tx_hash(tx) for tx in transactions]
    tree = MerkleTree(leaves)
    root = tree.get_root()

    proofs_data = []
    for i, tx in enumerate(transactions):
        leaf = leaves[i]
        proof = tree.get_proof(i)
        is_valid = tree.verify_proof(leaf, proof, root)
        proofs_data.append({
            'index': i,
            'transaction': tx,
            'tx_hash': '0x' + leaf.hex(),
            'proof': ['0x' + p.hex() for p in proof],
            'valid': is_valid
        })

    return {
        'merkle_root': '0x' + root.hex(),
        'tx_count': len(transactions),
        'transactions': transactions,
        'leaves': ['0x' + l.hex() for l in leaves],
        'proofs_data': proofs_data
    }

def print_results(data: Dict[str, Any]):
    print("=" * 80)
    print("MERKLE ROOT FOR BATCH")
    print("=" * 80)
    print(f"Merkle Root: {data['merkle_root']}")
    print(f"Transaction Count: {data['tx_count']}")
    print()
    print("=" * 80)
    print("TRANSACTIONS & PROOFS")
    print("=" * 80)

    for item in data['proofs_data']:
        tx = item['transaction']
        print(f"\n--- Transaction {item['index']} ---")
        print(f"Type: {TxType(tx.tx_type).name}")
        print(f"From: {tx.from_address}")
        print(f"To: {tx.to_address}")
        print(f"Amount: {tx.amount}")
        print(f"Nonce: {tx.nonce}")
        print(f"Timestamp: {tx.timestamp}")
        print(f"Recipient Count: {tx.recipient_count}")
        print(f"Batch ID (not hashed): {tx.batch_id}")
        print(f"Batch Salt: {tx.batch_salt}")
        print(f"TX Hash: {item['tx_hash']}")
        print(f"Proof Valid: {item['valid']}")
        print(f"Proof: [{', '.join(item['proof'])}]")

def save_json(data: Dict[str, Any], filename: str = 'merkle_data.json'):
    json_data = {
        'merkleRoot': data['merkle_root'],
        'txCount': data['tx_count'],
        'transactions': []
    }
    for item in data['proofs_data']:
        tx = item['transaction']
        json_data['transactions'].append({
            'index': item['index'],
            'type': TxType(tx.tx_type).name,
            'from': tx.from_address,
            'to': tx.to_address,
            'amount': str(tx.amount),
            'nonce': tx.nonce,
            'timestamp': tx.timestamp,
            'recipientCount': tx.recipient_count,
            'batchId': tx.batch_id,  # present for contract calls, not part of tx hash
            'batchSalt': tx.batch_salt,  # used in tx hash for merkle root generation
            'txHash': item['tx_hash'],
            'proof': item['proof'],
            'valid': item['valid']
        })
    with open(filename, 'w') as f:
        json.dump(json_data, f, indent=2)
    print(f"\nData saved to: {filename}")

if __name__ == "__main__":
    transactions = generate_test_transactions()
    merkle_data = generate_merkle_data(transactions)
    print_results(merkle_data)
    save_json(merkle_data)