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
        if (!NETWORKS[network]) throw new Error('Network must be nile or mainnet');
        if (!pk) throw new Error('Set UPDATER_PRIVATE_KEY in .env');

        const tronWeb = new TronWeb({ fullHost: NETWORKS[network].fullHost, privateKey: pk });

        const { abi: feeAbi } = loadArtifact('FeeModule');
        const { abi: settlementAbi } = loadArtifact('Settlement');
        const { abi: whitelistAbi } = loadArtifact('WhitelistRegistry');

        const feeModule = await tronWeb.contract(feeAbi, process.env.FEE_MODULE_ADDRESS);
        const settlement = await tronWeb.contract(settlementAbi, process.env.SETTLEMENT_ADDRESS);

        let tx = await feeModule.setSettlement(process.env.SETTLEMENT_ADDRESS).send({ feeLimit: FEE_LIMIT });
        console.log('FeeModule setSettlement txID:', tx);

        tx = await settlement.setFeeModule(process.env.FEE_MODULE_ADDRESS).send({ feeLimit: FEE_LIMIT });
        console.log('Settlement setFeeModule txID:', tx);

        tx = await settlement.setWhitelistRegistry(process.env.WHITELIST_REGISTRY_ADDRESS).send({ feeLimit: FEE_LIMIT });
        console.log('Settlement setWhitelistRegistry txID:', tx);

        tx = await settlement.setMaxTxPerBatch(process.env.MAX_TX_PER_BATCH).send({ feeLimit: FEE_LIMIT });
        console.log('Settlement setMaxTxPerBatch txID:', tx);

        tx = await settlement.setTimelockDuration(process.env.TIMELOCK_DURATION).send({ feeLimit: FEE_LIMIT });
        console.log('Settlement setTimelockDuration txID:', tx);

        tx = await settlement.setToken(process.env.TOKEN_ADDRESS).send({ feeLimit: FEE_LIMIT });
        console.log('Settlement setToken txID:', tx);

    } catch (error) {
        console.error(error);
        process.exit(1);
    }
}

main();