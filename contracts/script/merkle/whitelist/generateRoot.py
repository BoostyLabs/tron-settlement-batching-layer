# filename: generate_root_evm_sorted.py
from eth_utils import keccak, is_hex_address, to_checksum_address

def normalize(addr: str) -> str:
    addr = addr.strip()
    if not addr.startswith("0x"):
        addr = "0x" + addr
    if not is_hex_address(addr):
        raise ValueError(f"Invalid address: {addr}")
    return addr.lower()

def leaf_hash(addr: str) -> bytes:
    a = normalize(addr)
    b20 = bytes.fromhex(a[2:])
    return keccak(b"\x00" * 12 + b20)

def hash_pair(a: bytes, b: bytes) -> bytes:
    if a < b:
        return keccak(a + b)
    else:
        return keccak(b + a)

def build_leaves(addrs):
    addrs_sorted = sorted([normalize(a) for a in addrs])
    leaves = [leaf_hash(a) for a in addrs_sorted]
    return leaves, addrs_sorted

def build_tree(leaves):
    layers = [leaves[:]]
    while len(layers[-1]) > 1:
        cur = layers[-1]
        nxt = []
        for i in range(0, len(cur), 2):
            l = cur[i]
            r = cur[i+1] if i+1 < len(cur) else cur[i]
            nxt.append(hash_pair(l, r))
        layers.append(nxt)
    return layers

def proof(layers, idx):
    pf = []
    for layer in layers[:-1]:
        sib = idx ^ 1
        if sib < len(layer):
            pf.append(layer[sib])
        idx //= 2
    return pf

def verify_sorted(leaf, pf, rt):
    h = leaf
    for p in pf:
        if h < p:
            h = keccak(h + p)
        else:
            h = keccak(p + h)
    return h == rt

if __name__ == "__main__":
    user1 = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
    user2 = "0xBD26367c4B23A6D3713A1e1a50B2D67E8748cB98"
    user3 = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

    whitelist = [user1, user2, user3]

    leaves, addrs_sorted = build_leaves(whitelist)
    layers = build_tree(leaves)
    rt = layers[-1][0]
    print(f"Merkle Root: 0x{rt.hex()}")

    for addr in addrs_sorted:
        lf = leaf_hash(addr)
        idx = leaves.index(lf)
        pf = proof(layers, idx)

        ok = verify_sorted(lf, pf, rt)
        print(f"\nAddress {to_checksum_address(addr)} is whitelisted: {ok}")

        pf_hex = ["0x" + x.hex() for x in pf]
        print("Proof:", "[" + ", ".join(pf_hex) + "]")

        name = to_checksum_address(addr).replace("0x","").upper()
        print("\n// Solidity")
        print(f"PROOF_{name} = new bytes32[]({len(pf_hex)});")
        for i, p in enumerate(pf_hex):
            print(f"PROOF_{name}[{i}] = {p};")