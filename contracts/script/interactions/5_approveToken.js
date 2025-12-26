const { TronWeb } = require('tronweb');
require('dotenv').config({ quiet: true });

const NETWORKS = {
    nile: { fullHost: 'https://nile.trongrid.io' },
    mainnet: { fullHost: 'https://api.trongrid.io' },
};

const FEE_LIMIT = 500_000_000;
const MAX_UINT256 = '0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';

const TRC20_ABI = [
    { type: 'function', name: 'approve', inputs: [{ type: 'address', name: 'spender' }, { type: 'uint256', name: 'amount' }], outputs: [{ type: 'bool', name: '' }], stateMutability: 'nonpayable' },
    { type: 'function', name: 'allowance', inputs: [{ type: 'address', name: 'owner' }, { type: 'address', name: 'spender' }], outputs: [{ type: 'uint256', name: '' }], stateMutability: 'view' },
    { type: 'function', name: 'balanceOf', inputs: [{ type: 'address', name: 'owner' }], outputs: [{ type: 'uint256', name: '' }], stateMutability: 'view' },
];

function parseArgs() {
    const network = process.argv[2] || 'nile';
    const amount = process.argv[3] || MAX_UINT256;
    return { network, amount };
}

async function main() {
    try {
        const { network, amount } = parseArgs();

        const pk = process.env.UPDATER_PRIVATE_KEY;
        const tokenAddr = process.env.TOKEN_ADDRESS;
        const settlementAddr = process.env.SETTLEMENT_ADDRESS;

        if (!NETWORKS[network]) throw new Error('Network must be nile or mainnet');
        if (!pk) throw new Error('Set UPDATER_PRIVATE_KEY in .env (must be the sender account that owns tokens)');
        if (!tokenAddr) throw new Error('Set TOKEN_ADDRESS in .env (the token configured in Settlement)');
        if (!settlementAddr) throw new Error('Set SETTLEMENT_ADDRESS in .env');

        const tronWeb = new TronWeb({ fullHost: NETWORKS[network].fullHost, privateKey: pk });
        const token = await tronWeb.contract(TRC20_ABI, tokenAddr);

        const ownerBase58 = tronWeb.address.fromPrivateKey(pk); // sender address (T-addr)

        console.log('Approving token allowance...');
        console.log(`Network: ${network}`);
        console.log(`Token:   ${tokenAddr}`);
        console.log(`Owner:   ${ownerBase58}`);
        console.log(`Spender (Settlement): ${settlementAddr}`);
        console.log(`Amount:  ${amount}`);

        const tx = await token.approve(settlementAddr, String(amount)).send({ feeLimit: FEE_LIMIT });
        console.log('approve txID:', tx);

        const allowance = await token.allowance(ownerBase58, settlementAddr).call();
        const balance = await token.balanceOf(ownerBase58).call();

        console.log('allowance(owner, Settlement):', allowance.toString());
        console.log('balanceOf(owner):', balance.toString());
        console.log('Done.');
    } catch (error) {
        console.error(error);
        process.exit(1);
    }
}

main();
