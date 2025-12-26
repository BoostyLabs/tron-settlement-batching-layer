const fs = require('fs');
const path = require('path');
const { TronWeb } = require('tronweb');
require('dotenv').config({ quiet: true });

const NETWORKS = {
    nile: { fullHost: 'https://nile.trongrid.io' },
    mainnet: { fullHost: 'https://api.trongrid.io' },
};

function loadArtifact(name) {
    const p = path.join(__dirname, '../../out', `${name}.sol`, `${name}.json`);
    const j = JSON.parse(fs.readFileSync(p, 'utf8'));
    return { abi: j.abi };
}

function loadMerkleJson(filename = 'merkle_data_deploy.json') {
    const p = path.join(__dirname, '../merkle/batch', filename);
    return JSON.parse(fs.readFileSync(p, 'utf8'));
}

async function main() {
    try {
        const network = process.argv[2] || 'nile';
        const pk = process.env.UPDATER_PRIVATE_KEY;
        const settlementAddr = process.env.SETTLEMENT_ADDRESS;
        if (!NETWORKS[network]) throw new Error('Network must be nile or mainnet');
        if (!pk) throw new Error('Set UPDATER_PRIVATE_KEY in .env');
        if (!settlementAddr) throw new Error('Set SETTLEMENT_ADDRESS in .env');

        const tronWeb = new TronWeb({ fullHost: NETWORKS[network].fullHost, privateKey: pk });
        const { abi } = loadArtifact('Settlement');
        const settlement = await tronWeb.contract(abi, settlementAddr);

        const merkle = loadMerkleJson('merkle_data_deploy.json');
        let root = merkle.merkleRoot;
        if (!root.startsWith('0x')) {
            root = '0x' + root;
        }
        const txCount = merkle.txCount;
        const batchSalt = merkle.batchSalt || 1;

        console.log('Submitting batch:');
        console.log('  merkleRoot:', root);
        console.log('  txCount:', txCount);
        console.log('  batchSalt:', batchSalt);

        const res = await settlement.submitBatch(root, txCount, batchSalt).send({
            feeLimit: 100_000_000,
            shouldPollResponse: false,
            callValue: 0,
        });

        console.log('Submitted. TX:', res);

        const batchId = await settlement.getBatchIdByRoot(root).call();
        console.log('Assigned batchId:', batchId.toString());

        const batch = await settlement.getBatchById(batchId).call();
        console.log('UnlockTime:', batch.unlockTime.toString());

        console.log('Wait until unlockTime, then execute transfers.');
    } catch (e) {
        console.error('Submit failed:', e.message);
        if (e.output && e.output.contractResult) {
            console.error('Contract error:', e.output.contractResult);
        }
        process.exit(1);
    }
}

main();