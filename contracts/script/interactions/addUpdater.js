const fs = require('fs');
const path = require('path');
const { TronWeb } = require('tronweb');
require('dotenv').config({ quiet: true });

const NETWORKS = {
    nile: { fullHost: 'https://nile.trongrid.io' },
    mainnet: { fullHost: 'https://api.trongrid.io' }
};

const FEE_LIMIT = 500_000_000;

function loadArtifact(name) {
    const p = path.join(__dirname, '../../out', `${name}.sol`, `${name}.json`);
    const j = JSON.parse(fs.readFileSync(p, 'utf8'));
    return { abi: j.abi, bytecode: j.bytecode?.object || j.bytecode };
}

async function main() {
    try {
        const network = process.argv[2] || 'nile';
        const pk = process.env.UPDATER_PRIVATE_KEY;
        const registryAddress = process.env.WHITELIST_REGISTRY_ADDRESS;
        const updater = process.argv[3] || process.env.WL_UPDATER_ADDRESS;

        if (!NETWORKS[network]) throw new Error('Network must be nile or mainnet');
        if (!pk) throw new Error('Set UPDATER_PRIVATE_KEY in .env');
        if (!registryAddress) throw new Error('Set WL_REGISTRY_ADDRESS in .env');
        if (!updater) throw new Error('Provide updater address as arg3 or set WL_UPDATER_ADDRESS in .env');

        const tronWeb = new TronWeb({ fullHost: NETWORKS[network].fullHost, privateKey: pk });

        const { abi: wlAbi } = loadArtifact('WhitelistRegistry');
        const wl = await tronWeb.contract(wlAbi, registryAddress);

        const zeroAddr = 'T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb';
        if (updater === zeroAddr) throw new Error('Updater cannot be zero address');

        const tx = await wl.addAuthorizedUpdater(updater).send({ feeLimit: FEE_LIMIT });
        console.log('Authorized updater added:', tx);
    } catch (error) {
        console.error(error);
        process.exit(1);
    }
}

main();
