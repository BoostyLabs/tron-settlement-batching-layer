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

function formatAmount(amount, decimals = 6) {
    return (BigInt(amount) / BigInt(10 ** decimals)).toString();
}

async function main() {
    try {
        const network = process.argv[2] || 'nile';
        const txIndex = parseInt(process.argv[3]) || 0;
        const pk = process.env.EXECUTOR_PRIVATE_KEY || process.env.UPDATER_PRIVATE_KEY;
        const settlementAddr = process.env.SETTLEMENT_ADDRESS;

        if (!NETWORKS[network]) throw new Error('Network must be nile or mainnet');
        if (!pk) throw new Error('Set EXECUTOR_PRIVATE_KEY or UPDATER_PRIVATE_KEY in .env');
        if (!settlementAddr) throw new Error('Set SETTLEMENT_ADDRESS in .env');

        const tronWeb = new TronWeb({ fullHost: NETWORKS[network].fullHost, privateKey: pk });

        // Load Settlement contract
        const settlementAbi = loadArtifact('Settlement').abi;
        const settlement = tronWeb.contract(settlementAbi, settlementAddr);

        // Load Merkle data
        const merkle = loadMerkleJson('merkle_data_deploy.json');

        if (txIndex >= merkle.transactions.length) {
            throw new Error(`Transaction index ${txIndex} out of range (max: ${merkle.transactions.length - 1})`);
        }

        const tx = merkle.transactions[txIndex];

        console.log(`\n  Executing Transfer #${txIndex} (${tx.type})`);
        console.log(`  From: ${tx.tronAddresses.from}`);
        console.log(`  To:   ${tx.tronAddresses.to}`);
        console.log(`  Amount: ${formatAmount(tx.txDataStruct[2])} tokens`);

        // Look up the REAL batch ID from the contract using the Merkle root
        const realBatchIdRaw = await settlement.getBatchIdByRoot(merkle.merkleRoot).call();
        const realBatchId = BigInt(realBatchIdRaw).toString();
        const batchId = realBatchId;

        // Prepare transaction data struct as ARRAY (not object)
        // Order: [from, to, amount, nonce, timestamp, recipientCount, batchId, txType]
        const txData = [
            tx.txDataStruct[0],     // from
            tx.txDataStruct[1],     // to
            tx.txDataStruct[2],     // amount
            tx.txDataStruct[3],     // nonce
            tx.txDataStruct[4],     // timestamp
            tx.txDataStruct[5],     // recipientCount
            batchId,                // batchId (from contract)
            tx.txDataStruct[7]      // txType
        ];

        // Validate contract state
        const tokenAddr = await settlement.getToken().call();
        const feeModuleAddr = await settlement.getFeeModule().call();
        const isPaused = await settlement.paused().call();

        if (isPaused) {
            throw new Error('Settlement contract is PAUSED!');
        }

        // Validate batch status
        const batch = await settlement.getBatchById(batchId).call();
        const unlockTime = batch.unlockTime.toString();
        const currentTime = Math.floor(Date.now() / 1000);

        if (currentTime < parseInt(unlockTime)) {
            const waitTime = parseInt(unlockTime) - currentTime;
            throw new Error(`Batch is still LOCKED! Wait ${waitTime} seconds`);
        }

        // Check if already executed
        const isExecuted = await settlement.isExecutedTransfer(tx.txHash).call();
        if (isExecuted) {
            throw new Error('Transfer has already been EXECUTED!');
        }

        // Validate token balances and allowances
        const tokenAbi = [
            { "constant": true, "inputs": [], "name": "symbol", "outputs": [{ "name": "", "type": "string" }], "type": "function" },
            { "constant": true, "inputs": [], "name": "decimals", "outputs": [{ "name": "", "type": "uint8" }], "type": "function" },
            { "constant": true, "inputs": [{ "name": "who", "type": "address" }], "name": "balanceOf", "outputs": [{ "name": "", "type": "uint256" }], "type": "function" },
            { "constant": true, "inputs": [{ "name": "owner", "type": "address" }, { "name": "spender", "type": "address" }], "name": "allowance", "outputs": [{ "name": "", "type": "uint256" }], "type": "function" }
        ];
        const token = tronWeb.contract(tokenAbi, tronWeb.address.fromHex(tokenAddr));

        const tokenSymbol = await token.symbol().call();
        const tokenDecimals = await token.decimals().call();
        const senderBalance = await token.balanceOf(tx.evmAddresses.from).call();
        const allowance = await token.allowance(tx.evmAddresses.from, settlementAddr).call();

        if (BigInt(senderBalance.toString()) < BigInt(tx.txDataStruct[2])) {
            throw new Error(`Insufficient balance! Has ${senderBalance.toString()}, needs ${tx.txDataStruct[2]}`);
        }

        if (BigInt(allowance.toString()) < BigInt(tx.txDataStruct[2])) {
            throw new Error(`Insufficient allowance! Has ${allowance.toString()}, needs ${tx.txDataStruct[2]}`);
        }

        // Calculate fees

        let feeModuleAbi;
        try {
            feeModuleAbi = loadArtifact('FeeModule').abi;
        } catch (e) {
            feeModuleAbi = [
                { "inputs": [{ "name": "sender", "type": "address" }, { "name": "txType", "type": "uint8" }, { "name": "volume", "type": "uint256" }, { "name": "recipientCount", "type": "uint256" }], "name": "calculateFee", "outputs": [{ "components": [{ "name": "fee", "type": "uint256" }, { "name": "txType", "type": "uint8" }], "name": "info", "type": "tuple" }], "stateMutability": "view", "type": "function" }
            ];
        }
        const feeModule = tronWeb.contract(feeModuleAbi, tronWeb.address.fromHex(feeModuleAddr));

        let feeAmount = '0';
        try {
            const feeInfo = await feeModule.calculateFee(
                tx.evmAddresses.from,
                txData[7],  // txType
                txData[2],  // amount
                txData[5]   // recipientCount
            ).call();

            const feeAmountRaw = feeInfo.fee || feeInfo[0] || '0';
            feeAmount = BigInt(feeAmountRaw).toString();

            const totalRequired = BigInt(tx.txDataStruct[2]) + BigInt(feeAmount);
            if (BigInt(senderBalance.toString()) < totalRequired) {
                throw new Error(`Insufficient balance for amount + fee!`);
            }
        } catch (e) {
            // Continue without fee validation
        }

        // Execute the transfer
        const txProof = tx.proof;
        const whitelistProof = ['0x2c27f532fe88e4b25c84c1d9e51fb97002414c2ed55927eeb815cfa1733c688e'];

        const res = await settlement.executeTransfer(txProof, whitelistProof, txData).send({
            feeLimit: 150_000_000,
            shouldPollResponse: false,
            callValue: 0,
        });

        // Success output
        console.log(`  ✓ Transfer executed successfully`);
        console.log(`  TX Hash: ${res}`);
        if (feeAmount && feeAmount !== '0') {
            console.log(`  Fee: ${formatAmount(feeAmount, parseInt(tokenDecimals))} ${tokenSymbol}`);
        }

    } catch (e) {
        console.error(`  ✗ Execution failed: ${e.message}`);
        process.exit(1);
    }
}

main();
