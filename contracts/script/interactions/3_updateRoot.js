const fs = require('fs');
const path = require('path');
const { TronWeb } = require('tronweb');
require('dotenv').config({ quiet: true });

const NETWORKS = {
    nile: { fullHost: 'https://nile.trongrid.io' },
    mainnet: { fullHost: 'https://api.trongrid.io' }
};
const FEE_LIMIT = 500_000_000;

function requireEnv(name) {
    const v = process.env[name];
    if (!v) throw new Error(`Missing env: ${name}`);
    return v.trim();
}

function loadArtifact(name) {
    const p = path.join(__dirname, '../../out', `${name}.sol`, `${name}.json`);
    const j = JSON.parse(fs.readFileSync(p, 'utf8'));
    return { abi: j.abi };
}

async function waitReceipt(tronWeb, txId, tries = 10, delayMs = 1500) {
    for (let i = 0; i < tries; i++) {
        const r = await tronWeb.trx.getTransactionInfo(txId);
        const status = r?.receipt?.result || r?.result;
        if (status) return { status, receipt: r };
        await new Promise(res => setTimeout(res, delayMs));
    }
    return { status: 'UNKNOWN', receipt: {} };
}

function normalizeHex32(h) {
    if (!h) return h;
    const s = h.toLowerCase();
    return s.startsWith('0x') ? s : `0x${s}`;
}

async function main() {
    const network = process.argv[2] || 'nile';
    if (!NETWORKS[network]) throw new Error('Network must be nile or mainnet');

    const TX_PK = requireEnv('UPDATER_PRIVATE_KEY'); // same signer
    const REGISTRY_BASE58 = requireEnv('WHITELIST_REGISTRY_ADDRESS');

    const sigPath = path.join(__dirname, 'signature.json');
    if (!fs.existsSync(sigPath)) throw new Error('Missing signature.json');
    const sig = JSON.parse(fs.readFileSync(sigPath, 'utf8'));
    const { root, nonce, signature, network: signedNetwork } = sig;

    if (signedNetwork && signedNetwork !== network) {
        throw new Error(`Network mismatch: signature.json was created for ${signedNetwork}, you are submitting to ${network}. Re-sign or switch network.`);
    }

    const expectedRoot = normalizeHex32(root);

    const tronWeb = new TronWeb({
        fullHost: NETWORKS[network].fullHost,
        privateKey: TX_PK
    });

    const { abi: registryAbi } = loadArtifact('WhitelistRegistry');
    const registry = await tronWeb.contract(registryAbi, REGISTRY_BASE58);

    const preRoot = normalizeHex32(await registry.getCurrentMerkleRoot().call());
    const preNonceBN = await registry.getCurrentNonce().call();
    const preNonce = BigInt(preNonceBN.toString());

    console.log('Submitting updateMerkleRoot...');
    const txId = await registry.updateMerkleRoot(root, nonce, signature).send({ feeLimit: FEE_LIMIT });
    console.log('updateMerkleRoot txID:', txId);

    const { status, receipt } = await waitReceipt(tronWeb, txId);
    console.log('Receipt status:', status);
    if (status !== 'SUCCESS') console.log('Receipt (full):', receipt);

    const postRoot = normalizeHex32(await registry.getCurrentMerkleRoot().call());
    const postNonceBN = await registry.getCurrentNonce().call();
    const postNonce = BigInt(postNonceBN.toString());

    console.log('current root:', postRoot);
    console.log('current nonce:', postNonce.toString());

    const nonceOk = postNonce === preNonce + 1n;
    const rootOk = postRoot === expectedRoot;

    if (nonceOk && rootOk) {
        console.log('Success: merkle root updated and nonce incremented.');
    } else if (nonceOk && !rootOk) {
        console.log('Partial success: nonce incremented, but root != expected. Check that WL_NEW_ROOT matches what was signed.');
    } else {
        console.log('Update did not apply. Check nonce (must sign with current s_nonce), chainId, authorization, duplicate root, and pause state.');
    }
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
