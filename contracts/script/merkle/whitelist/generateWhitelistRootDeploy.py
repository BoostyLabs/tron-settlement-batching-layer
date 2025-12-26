import base58
from eth_utils import keccak

def tron_to_evm_bytes32(tron_addr: str) -> bytes:
    raw = base58.b58decode_check(tron_addr)
    addr20 = raw[1:]  # 20 bytes
    return b'\x00' * 12 + addr20  # pad left to 32 bytes like Solidity assembly

def merkle_tree(leaves):
    tree = [leaves]
    while len(tree[-1]) > 1:
        layer = tree[-1]
        next_layer = []
        for i in range(0, len(layer), 2):
            left = layer[i]
            right = layer[i+1] if i+1 < len(layer) else layer[i]
            # Sort the pair to ensure consistency with Solidity assembly logic
            if left > right:
                left, right = right, left
            combined = keccak(left + right)
            next_layer.append(combined)
        tree.append(next_layer)
    return tree

def merkle_root(tree):
    return tree[-1][0] if tree else None

def merkle_proof(tree, index):
    proof = []
    for layer in tree[:-1]:
        pair_index = index ^ 1
        if pair_index < len(layer):
            sibling = layer[pair_index]
            node = layer[index]
            # Sort the pair to ensure consistency with Solidity assembly logic
            # The proof always includes the sibling hash
            proof.append(sibling)
        index //= 2
    return proof

def verify_proof(leaf, proof, root):
    computed_hash = leaf
    for sibling in proof:
        if computed_hash > sibling:
            computed_hash = keccak(sibling + computed_hash)
        else:
            computed_hash = keccak(computed_hash + sibling)
    return computed_hash == root

# List of whitelisted TRON addresses
whitelist = [
    "TKWvD71EMFTpFVGZyqqX9fC6MQgcR9H76M",
    "TVKAAcqpQxz3J4waayePr8dQjSQ2XHkdbF",
]

# Compute leaves as keccak256 of 32 bytes (12 zeros + 20-byte address)
leaves = [keccak(tron_to_evm_bytes32(addr)) for addr in whitelist]

# Build Merkle tree
tree = merkle_tree(leaves)

# Get Merkle root
root = merkle_root(tree)

def get_proof_for_address(tron_addr):
    leaf = keccak(tron_to_evm_bytes32(tron_addr))
    try:
        index = leaves.index(leaf)
    except ValueError:
        return None, None
    proof = merkle_proof(tree, index)
    return leaf, proof

if __name__ == "__main__":
    test_addresses = [
        "TKWvD71EMFTpFVGZyqqX9fC6MQgcR9H76M",  # whitelisted
        "TVKAAcqpQxz3J4waayePr8dQjSQ2XHkdbF",  # whitelisted
    ]

    print("Merkle Root:", root.hex())
    for addr in test_addresses:
        leaf, proof = get_proof_for_address(addr)
        if leaf is None:
            print(f"Address {addr} is NOT in the whitelist.")
            continue
        is_valid = verify_proof(leaf, proof, root)
        print(f"Address {addr} is whitelisted: {is_valid}")
        print("Proof:", "[" + ", ".join(f"0x{p.hex()}" for p in proof) + "]")