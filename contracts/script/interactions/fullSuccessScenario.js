const { execSync } = require('child_process');
const path = require('path');
const fs = require('fs');

const SCRIPTS_DIR = path.join(__dirname);
const PROJECT_ROOT = path.join(__dirname, '..', '..');
const COLOR_GREEN = '\x1b[32m';
const COLOR_BLUE = '\x1b[34m';
const COLOR_YELLOW = '\x1b[33m';
const COLOR_RED = '\x1b[31m';
const COLOR_RESET = '\x1b[0m';

function log(message, color = COLOR_RESET) {
    console.log(`${color}${message}${COLOR_RESET}`);
}

function runScript(scriptName, args = []) {
    const scriptPath = path.join(SCRIPTS_DIR, scriptName);
    const command = `node "${scriptPath}" ${args.join(' ')}`;

    log(`\n${'='.repeat(80)}`, COLOR_BLUE);
    log(`Running: ${scriptName} ${args.join(' ')}`, COLOR_BLUE);
    log('='.repeat(80), COLOR_BLUE);

    try {
        execSync(command, { stdio: 'inherit', cwd: PROJECT_ROOT });
        log(`✅ ${scriptName} completed successfully\n`, COLOR_GREEN);
        return true;
    } catch (error) {
        log(`❌ ${scriptName} failed!`, COLOR_RED);
        throw error;
    }
}

async function waitForUnlockTime(network) {
    const { TronWeb } = require('tronweb');
    require('dotenv').config({ quiet: true });

    const NETWORKS = {
        nile: { fullHost: 'https://nile.trongrid.io' },
        mainnet: { fullHost: 'https://api.trongrid.io' }
    };

    const pk = process.env.UPDATER_PRIVATE_KEY;
    const settlementAddress = process.env.SETTLEMENT_ADDRESS;

    if (!pk || !settlementAddress) {
        throw new Error('Missing UPDATER_PRIVATE_KEY or SETTLEMENT_ADDRESS in .env');
    }

    const tronWeb = new TronWeb({
        fullHost: NETWORKS[network].fullHost,
        privateKey: pk
    });

    function loadArtifact(name) {
        const p = path.join(__dirname, '../../out', `${name}.sol`, `${name}.json`);
        const j = JSON.parse(fs.readFileSync(p, 'utf8'));
        return { abi: j.abi };
    }

    const { abi } = loadArtifact('Settlement');
    const settlement = await tronWeb.contract(abi, settlementAddress);

    // Load batch data to get batchId
    const batchFilePath = path.join(__dirname, '../merkle/batch/merkle_data_deploy.json');
    const batchData = JSON.parse(fs.readFileSync(batchFilePath, 'utf8'));
    const batchId = batchData.batchId || 1;

    const batch = await settlement.getBatchById(batchId).call();
    const unlockTime = parseInt(batch.unlockTime.toString());
    const currentTime = Math.floor(Date.now() / 1000);
    const waitSeconds = unlockTime - currentTime;

    if (waitSeconds > 0) {
        log(`\n⏳ Batch is locked. Waiting ${waitSeconds} seconds for unlock time...`, COLOR_YELLOW);
        log(`   Current time: ${currentTime}`, COLOR_YELLOW);
        log(`   Unlock time:  ${unlockTime}`, COLOR_YELLOW);

        // Wait with countdown
        for (let i = waitSeconds; i > 0; i--) {
            if (i % 10 === 0 || i <= 5) {
                process.stdout.write(`\r   ⏳ ${i} seconds remaining...`);
            }
            await new Promise(resolve => setTimeout(resolve, 1000));
        }
        process.stdout.write('\r');
        log('\n✅ Batch is now unlocked!', COLOR_GREEN);
    } else {
        log('\n✅ Batch is already unlocked!', COLOR_GREEN);
    }
}

async function main() {
    const network = process.argv[2] || 'nile';

    if (!['nile', 'mainnet'].includes(network)) {
        throw new Error('Network must be nile or mainnet');
    }

    log('\n' + '='.repeat(80), COLOR_BLUE);
    log('🚀 FULL SUCCESS PASS SCENARIO - 3 TRANSFERS', COLOR_BLUE);
    log('='.repeat(80), COLOR_BLUE);
    log(`Network: ${network}\n`, COLOR_BLUE);

    try {
        // Step 1: Sign the whitelist root
        log('📝 STEP 1/6: Sign Whitelist Root', COLOR_YELLOW);
        runScript('2_signRoot.js', [network]);

        // Step 2: Update the whitelist root on-chain
        log('📤 STEP 2/6: Update Whitelist Root On-Chain', COLOR_YELLOW);
        runScript('3_updateRoot.js', [network]);

        // Step 4: Submit the batch
        log('📦 STEP 3/6: Submit Batch', COLOR_YELLOW);
        runScript('4_submitBatch.js', [network]);

        // Step 5: Wait for unlock time
        log('⏰ STEP 4/6: Wait for Batch Unlock Time', COLOR_YELLOW);
        await waitForUnlockTime(network);

        // Step 6: Approve tokens
        log('✅ STEP 5/6: Approve Tokens for Settlement Contract', COLOR_YELLOW);
        runScript('5_approveToken.js', [network]);

        // Step 7: Execute all 3 transfers
        log('💸 STEP 6/6: Execute All 3 Transfers', COLOR_YELLOW);

        for (let i = 0; i < 3; i++) {
            log(`\n  Transfer ${i + 1}/3:`, COLOR_YELLOW);
            runScript('6_executeTransfer.js', [network, i.toString()]);
        }

        // Wait for transactions to be processed on-chain
        log('\n⏳ Waiting for transactions to be processed...', COLOR_YELLOW);
        await new Promise(resolve => setTimeout(resolve, 2000));

        // Success summary
        log('\n' + '='.repeat(80), COLOR_GREEN);
        log('🎉 SUCCESS! All steps completed successfully!', COLOR_GREEN);
        log('='.repeat(80), COLOR_GREEN);
        log('\nSummary:', COLOR_GREEN);
        log('  ✅ Whitelist root signed and updated', COLOR_GREEN);
        log('  ✅ Aggregator approved', COLOR_GREEN);
        log('  ✅ Batch submitted and unlocked', COLOR_GREEN);
        log('  ✅ Tokens approved', COLOR_GREEN);
        log('  ✅ Transfer #0 executed (DELAYED)', COLOR_GREEN);
        log('  ✅ Transfer #1 executed (INSTANT)', COLOR_GREEN);
        log('  ✅ Transfer #2 executed (BATCHED)', COLOR_GREEN);
        log('\n' + '='.repeat(80), COLOR_GREEN);

    } catch (error) {
        log('\n' + '='.repeat(80), COLOR_RED);
        log('❌ SCENARIO FAILED!', COLOR_RED);
        log('='.repeat(80), COLOR_RED);
        log(`\nError: ${error.message}`, COLOR_RED);
        process.exit(1);
    }
}

main().catch((error) => {
    console.error(error);
    process.exit(1);
});
