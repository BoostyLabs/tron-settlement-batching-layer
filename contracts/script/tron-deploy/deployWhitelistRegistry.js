const fs = require('fs');
const path = require('path');
const { TronWeb } = require("tronweb");
require('dotenv').config({ quiet: true });

const NETWORKS = {
    nile: { fullHost: 'https://nile.trongrid.io' },
    mainnet: { fullHost: 'https://api.trongrid.io' }
};

const FEE_LIMIT = 500_000_000;

function loadArtifact(name) {
    const p = path.join('out', `${name}.sol`, `${name}.json`);
    const j = JSON.parse(fs.readFileSync(p, 'utf8'));
    return { abi: j.abi, bytecode: j.bytecode?.object || j.bytecode };
}

async function main() {
    const network = process.argv[2] || 'nile';
    const CONTRACT_NAME = 'WhitelistRegistry';
    const pk = process.env.UPDATER_PRIVATE_KEY;
    const updater = process.env.UPDATER_ADDRESS;

    if (!NETWORKS[network]) throw new Error('Network must be nile or mainnet');
    if (!pk) throw new Error('Set UPDATER_PRIVATE_KEY in .env');
    if (!updater) throw new Error('Set UPDATER_ADDRESS in .env');

    const tronWeb = new TronWeb({ fullHost: NETWORKS[network].fullHost, privateKey: pk });

    const { abi, bytecode } = loadArtifact(CONTRACT_NAME);
    const deployed = await tronWeb.contract().new({
        abi,
        bytecode,
        feeLimit: FEE_LIMIT,
        callValue: 0,
        parameters: [updater]
    });

    console.log(`${CONTRACT_NAME} deployed: ${tronWeb.address.fromHex(deployed.address)}`);
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});