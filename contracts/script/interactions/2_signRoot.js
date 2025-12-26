const fs = require('fs');
const path = require('path');
const { TronWeb } = require('tronweb');
const { ethers } = require('ethers');
require('dotenv').config({ quiet: true });

const NETWORKS = {
    nile: { fullHost: 'https://nile.trongrid.io' },
    mainnet: { fullHost: 'https://api.trongrid.io' }
};

function requireEnv(name) {
    const v = process.env[name];
    if (!v) throw new Error(`Missing env: ${name}`);
    return v.trim();
}

function tronBase58ToEvm0x(base58) {
    const hex = TronWeb.address.toHex(base58);
    const hexNo0x = hex.startsWith('0x') ? hex.slice(2) : hex;
    if (!hexNo0x.toLowerCase().startsWith('41')) throw new Error(`Unexpected TRON hex: ${hex}`);
    const evmHexNo0x = hexNo0x.slice(2);
    if (evmHexNo0x.length !== 40) throw new Error(`Invalid EVM address length`);
    return ethers.getAddress('0x' + evmHexNo0x);
}

function ensureBytes32(hex) {
    const h = ethers.hexlify(hex);
    const b = ethers.getBytes(h);
    if (b.length !== 32) throw new Error('Expected bytes32');
    return h;
}

function loadArtifact(name) {
    const p = path.join(__dirname, '../../out', `${name}.sol`, `${name}.json`);
    const j = JSON.parse(fs.readFileSync(p, 'utf8'));
    return { abi: j.abi };
}

async function main() {
    const network = process.argv[2] || 'nile';
    if (!NETWORKS[network]) throw new Error('Network must be nile or mainnet');

    const UPDATER_PK = requireEnv('UPDATER_PRIVATE_KEY');
    const REGISTRY_BASE58 = requireEnv('WHITELIST_REGISTRY_ADDRESS');
    const WL_NEW_ROOT = requireEnv('WL_NEW_ROOT');
    const CHAIN_ID = requireEnv('CHAIN_ID');

    const wallet = new ethers.Wallet(UPDATER_PK.startsWith('0x') ? UPDATER_PK : `0x${UPDATER_PK}`);

    const tronWeb = new TronWeb({
        fullHost: NETWORKS[network].fullHost,
        privateKey: UPDATER_PK
    });

    const { abi: registryAbi } = loadArtifact('WhitelistRegistry');
    const registry = await tronWeb.contract(registryAbi, REGISTRY_BASE58);

    const preNonceEnv = requireEnv('WL_NONCE');
    const preNonce = BigInt(preNonceEnv);

    const updaterBase58 = TronWeb.address.fromPrivateKey(UPDATER_PK);
    const isAuth = await registry.isAuthorizedUpdater(updaterBase58).call();
    if (!isAuth) throw new Error('Updater is NOT authorized. Call addAuthorizedUpdater(updaterBase58) from an admin.');

    const root32 = ensureBytes32(WL_NEW_ROOT);
    const chainIdBig = ethers.toBigInt(CHAIN_ID);
    const registry0x = tronBase58ToEvm0x(REGISTRY_BASE58);

    const packed = ethers.solidityPacked(
        ['bytes32', 'uint64', 'uint256', 'address'],
        [root32, preNonce, chainIdBig, registry0x]
    );
    const digest = ethers.keccak256(packed);
    const signature = await wallet.signMessage(ethers.getBytes(digest));

    const recovered = ethers.verifyMessage(ethers.getBytes(digest), signature);
    if (ethers.getAddress(recovered) !== ethers.getAddress(wallet.address)) {
        throw new Error(`Signature mismatch: recovered ${recovered} != wallet ${wallet.address}`);
    }

    const out = {
        root: root32,
        nonce: preNonce.toString(),
        chainId: chainIdBig.toString(),
        registry0x,
        signature
    };
    fs.writeFileSync(path.join(__dirname, 'signature.json'), JSON.stringify(out, null, 2));

    console.log('On-chain nonce:', preNonce.toString());
    console.log('Updater authorized:', isAuth);
    console.log('CHAIN_ID:', CHAIN_ID);
    console.log('Signature generated and saved to signature.json');
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});