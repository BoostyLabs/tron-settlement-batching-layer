// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {IWhitelistRegistry} from "../../src/interfaces/IWhitelistRegistry.sol";
import {MaliciousReceiver} from "../mocks/MaliciousReceiver.sol";

import {IntegrationDeployHelpers} from "../utils/IntegrationDeployHelpers.sol";
import {TestConstants as TC} from "../utils/TestConstants.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract RegistryIntegrationTest is Test, IntegrationDeployHelpers {
    using MessageHashUtils for bytes32;

    address updater = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    uint256 updaterPrivKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    address user1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    // ------------------ Whitelist Merkle Test Data ------------------

    bytes32 MERKLE_ROOT = 0x813e418bccb26456db980833fb3f2d171569401dca4ddd31ba78b99f5d99e242;

    bytes32[] private PROOF_USER1;
    bytes32[] private PROOF_USER2;
    bytes32[] private PROOF_USER3;

    function setUp() public {
        _initRegistry();
        _initUser();

        PROOF_USER1 = new bytes32[](2);
        PROOF_USER1[0] = 0x6a65260b54e189b9d496c6e25ab6e91aef04672387dc6e4b559dd6f6335197a6;
        PROOF_USER1[1] = 0x4044ec0d82f345979063e37b899875d71b453c276b360523e82b432c04ea3f17;

        PROOF_USER2 = new bytes32[](2);
        PROOF_USER2[0] = 0x7ceb58780fb137bb02223b79c88bc6404f736f8bb4d1f0895d9884122804fb73;
        PROOF_USER2[1] = 0x4044ec0d82f345979063e37b899875d71b453c276b360523e82b432c04ea3f17;

        PROOF_USER3 = new bytes32[](1);
        PROOF_USER3[0] = 0x1a5324f5a19c274c2f9bfcfcdefcefc0ec65fef7db5a54fe78fca8007b4fe93a;
    }

    function _sign(bytes32 mesHash, uint256 privKey) internal pure returns (bytes memory signature) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, mesHash);
        signature = abi.encodePacked(r, s, v);
    }

    function _signMerkleRoot(uint256 privKey, uint64 nonce) public view returns (bytes memory signature) {
        bytes32 messageHash = keccak256(abi.encodePacked(MERKLE_ROOT, nonce, block.chainid, address(registry)));
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        signature = _sign(ethSignedMessageHash, privKey);
    }

    /* -------------------------------------------------------------------------- */
    /*                           INITIAL STATE                                    */
    /* -------------------------------------------------------------------------- */

    function test_Constructor_InitialValues() public view {
        assertTrue(registry.hasRole(TC.DEFAULT_ADMIN_ROLE, updater));
        assertTrue(registry.hasRole(TC.WITHDRAW_ROLE, updater));
        assertTrue(registry.isAuthorizedUpdater(updater));

        uint256 fee = registry.getRequestFee();
        assertEq(fee, TC.REQUEST_FEE);

        uint256 cooldown = registry.getRequestCooldown();
        assertEq(cooldown, TC.REQUEST_COOLDOWN);
    }

    /* -------------------------------------------------------------------------- */
    /*                           updateMerkleRoot                                 */
    /* -------------------------------------------------------------------------- */

    function test_UpdateMerkleRoot() public {
        uint64 currentNonce = registry.getCurrentNonce();
        bytes32 oldRoot = registry.getCurrentMerkleRoot();

        vm.prank(updater);
        bytes memory signature = _signMerkleRoot(updaterPrivKey, currentNonce);

        vm.expectEmit(false, false, false, true);
        emit IWhitelistRegistry.WhitelistUpdated(oldRoot, MERKLE_ROOT, currentNonce);
        registry.updateMerkleRoot(MERKLE_ROOT, currentNonce, signature);

        bytes32 currentRoot = registry.getCurrentMerkleRoot();
        uint48 lastUpdate = uint48(registry.getLastUpdateTime());
        assertEq(currentRoot, MERKLE_ROOT);
        assertEq(lastUpdate, uint48(block.timestamp));
    }

    function test_UpdateMerkleRoot_DuplicateUpdate() public {
        uint64 currentNonce = registry.getCurrentNonce();

        vm.startPrank(updater);
        bytes memory signature = _signMerkleRoot(updaterPrivKey, currentNonce);

        registry.updateMerkleRoot(MERKLE_ROOT, uint64(currentNonce), signature);

        uint64 newNonce = registry.getCurrentNonce();
        bytes memory newSignature = _signMerkleRoot(updaterPrivKey, newNonce);

        vm.expectRevert(Errors.WhitelistRegistry__DuplicateUpdate.selector);
        registry.updateMerkleRoot(MERKLE_ROOT, newNonce, newSignature);
        vm.stopPrank();
    }

    function test_UpdateMerkleRoot_InvalidNonce() public {
        uint256 currentNonce = registry.getCurrentNonce();
        uint64 randomNonce = 2131;
        assertNotEq(currentNonce, randomNonce);

        vm.startPrank(updater);
        bytes memory signature = _signMerkleRoot(updaterPrivKey, randomNonce);

        vm.expectRevert(Errors.WhitelistRegistry__InvalidNonce.selector);
        registry.updateMerkleRoot(MERKLE_ROOT, randomNonce, signature);
        vm.stopPrank();
    }

    function test_UpdateMerkleRoot_InvalidUpdater() public {
        uint64 currentNonce = registry.getCurrentNonce();

        bytes memory signature = _signMerkleRoot(userPrivKey, currentNonce);

        vm.prank(user);
        vm.expectRevert(Errors.WhitelistRegistry__NotAuthorized.selector);
        registry.updateMerkleRoot(MERKLE_ROOT, currentNonce, signature);
    }

    function test_UpdateMerkleRoot_RightKeyRandomUpdater() public {
        uint64 currentNonce = registry.getCurrentNonce();

        bytes memory signature = _signMerkleRoot(updaterPrivKey, currentNonce);

        vm.prank(user);
        registry.updateMerkleRoot(MERKLE_ROOT, currentNonce, signature);
    }

    // replay attack
    function test_UpdateMerkleRoot_OldSignatureWithCurrentNonce() public {
        // set the root1
        uint64 currentNonce = registry.getCurrentNonce();
        bytes memory signature = _signMerkleRoot(updaterPrivKey, currentNonce);
        vm.prank(updater);
        registry.updateMerkleRoot(MERKLE_ROOT, currentNonce, signature);
        bytes32 currentRoot = registry.getCurrentMerkleRoot();
        assertEq(currentRoot, MERKLE_ROOT);
        // set another root2

        bytes32 newRoot = keccak256(abi.encodePacked("another merkle root"));
        uint64 newNonce = registry.getCurrentNonce();
        bytes32 messageHash = keccak256(abi.encodePacked(newRoot, newNonce, block.chainid, address(registry)));
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        bytes memory signatureTwo = _sign(ethSignedMessageHash, updaterPrivKey);

        vm.prank(updater);
        registry.updateMerkleRoot(newRoot, newNonce, signatureTwo);
        bytes32 updatedRoot = registry.getCurrentMerkleRoot();
        assertEq(updatedRoot, newRoot);

        // try to use old sig from root1 to update it one more time
        uint64 finalNonce = registry.getCurrentNonce();
        vm.prank(updater);
        vm.expectRevert(Errors.WhitelistRegistry__NotAuthorized.selector);
        registry.updateMerkleRoot(MERKLE_ROOT, finalNonce, signature);
        assertEq(registry.getCurrentMerkleRoot(), newRoot);
    }

    function test_UpdateRoot_InvalidNonce_OldNonce() public {
        test_UpdateMerkleRoot();

        bytes32 newRoot = keccak256(abi.encodePacked("attempted replay root"));
        uint64 oldNonce = 0;

        bytes32 hash = keccak256(abi.encodePacked(newRoot, oldNonce, block.chainid, address(registry)));
        bytes32 signedHash = hash.toEthSignedMessageHash();
        bytes memory signature = _sign(signedHash, updaterPrivKey);

        vm.prank(updater);
        vm.expectRevert(Errors.WhitelistRegistry__InvalidNonce.selector);
        registry.updateMerkleRoot(newRoot, oldNonce, signature);
    }

    function test_UpdateRoot_InvalidNonce_FutureNonce() public {
        uint64 currentNonce = registry.getCurrentNonce();

        bytes32 newRoot = keccak256(abi.encodePacked("future nonce root"));
        uint64 futureNonce = currentNonce + 1;

        bytes32 hash = keccak256(abi.encodePacked(newRoot, futureNonce, block.chainid, address(registry)));
        bytes32 signedHash = hash.toEthSignedMessageHash();
        bytes memory signature = _sign(signedHash, updaterPrivKey);

        vm.prank(updater);
        vm.expectRevert(Errors.WhitelistRegistry__InvalidNonce.selector);
        registry.updateMerkleRoot(newRoot, futureNonce, signature);
    }

    function test_UpdateMerkleRoot_WhitelistVerification() public {
        uint64 currentNonce = registry.getCurrentNonce();
        bytes memory signature = _signMerkleRoot(updaterPrivKey, currentNonce);

        registry.updateMerkleRoot(MERKLE_ROOT, currentNonce, signature);

        bool isValidBefore = registry.verifyWhitelist(PROOF_USER1, user1);
        assertTrue(isValidBefore);

        bytes32 newRoot = 0x5e287fa07343625f048462384a5432c590d780ed2c5f765210ef0e2e3ebddcfe;
        uint64 newNonce = registry.getCurrentNonce();
        bytes32 hash = keccak256(abi.encodePacked(newRoot, newNonce, block.chainid, address(registry)));
        bytes memory newSig = _sign(hash.toEthSignedMessageHash(), updaterPrivKey);

        registry.updateMerkleRoot(newRoot, newNonce, newSig);

        bool isValidAfter = registry.verifyWhitelist(PROOF_USER1, user1);
        assertFalse(isValidAfter);
    }

    /* -------------------------------------------------------------------------- */
    /*                           requestWhitelist                                 */
    /* -------------------------------------------------------------------------- */

    function test_RequestWhitelist_Lifecycle() public {
        vm.deal(user, 100 ether);

        vm.startPrank(user);
        registry.requestWhitelist{value: TC.REQUEST_FEE}();
        uint256 firstRequestTime = registry.getLastRequestedTime(user);
        assertEq(firstRequestTime, block.timestamp);
        vm.stopPrank();

        vm.warp(block.timestamp + TC.REQUEST_COOLDOWN - 1 seconds);
        vm.startPrank(user);
        vm.expectRevert(Errors.WhitelistRegistry__RequestTooFrequent.selector);
        registry.requestWhitelist{value: TC.REQUEST_FEE}();
        vm.stopPrank();

        vm.warp(block.timestamp + 2 seconds);

        vm.startPrank(user);
        registry.requestWhitelist{value: TC.REQUEST_FEE}();
        uint256 secondRequestTime = registry.getLastRequestedTime(user);
        assertEq(secondRequestTime, block.timestamp);
        assertTrue(secondRequestTime > firstRequestTime);
        vm.stopPrank();

        assertEq(registry.getTotalCollectedFees(), TC.REQUEST_FEE * 2);
    }

    function test_RequestWhitelist_CooldownResetSuccess() public {
        uint256 requestFee = registry.getRequestFee();

        vm.deal(user, requestFee * 2);

        vm.prank(user);
        registry.requestWhitelist{value: requestFee}();

        uint256 cooldown = registry.getRequestCooldown();
        vm.warp(block.timestamp + cooldown + 1);

        uint256 totalCollectedFeesBefore = registry.getTotalCollectedFees();

        uint256 blockTimestampBefore = block.timestamp;

        vm.prank(user);
        registry.requestWhitelist{value: requestFee}();

        assertEq(registry.getLastRequestedTime(user), blockTimestampBefore);
        assertEq(registry.getTotalCollectedFees(), totalCollectedFeesBefore + requestFee);
    }

    function test_RequestWhitelist_EconomicFlow() public {
        address user2 = makeAddr("user2");
        vm.deal(user, 10 ether);
        vm.deal(user2, 10 ether);

        vm.prank(user);
        registry.requestWhitelist{value: TC.REQUEST_FEE}();

        uint256 overpayment = TC.REQUEST_FEE * 2;
        vm.prank(user2);
        registry.requestWhitelist{value: overpayment}();

        uint256 expectedTotal = TC.REQUEST_FEE + overpayment;
        assertEq(registry.getTotalCollectedFees(), expectedTotal);
        assertEq(address(registry).balance, expectedTotal);

        uint256 adminBalanceBefore = updater.balance;

        vm.prank(updater);
        registry.withdraw();

        assertEq(address(registry).balance, 0);
        assertEq(updater.balance, adminBalanceBefore + expectedTotal);
        assertEq(registry.getTotalCollectedFees(), 0);
    }

    function test_RequestWhitelist_IndependentCooldowns() public {
        address user2 = makeAddr("user2");
        vm.deal(user, 10 ether);
        vm.deal(user2, 10 ether);

        vm.prank(user);
        registry.requestWhitelist{value: TC.REQUEST_FEE}();

        vm.warp(block.timestamp + 1);

        vm.prank(user);
        vm.expectRevert(Errors.WhitelistRegistry__RequestTooFrequent.selector);
        registry.requestWhitelist{value: TC.REQUEST_FEE}();

        vm.prank(user2);
        bool success = registry.requestWhitelist{value: TC.REQUEST_FEE}();
        assertTrue(success);

        assertEq(registry.getLastRequestedTime(user2), block.timestamp);
        assertEq(registry.getLastRequestedTime(user), block.timestamp - 1);
    }

    /* -------------------------------------------------------------------------- */
    /*                              withdraw                                      */
    /* -------------------------------------------------------------------------- */

    function test_Withdraw_FailsIfRecipientCannotReceive() public {
        MaliciousReceiver malReceiver = new MaliciousReceiver();

        vm.startPrank(updater);
        registry.grantRole(TC.WITHDRAW_ROLE, address(malReceiver));
        vm.stopPrank();

        vm.deal(user, 10 ether);
        vm.prank(user);
        registry.requestWhitelist{value: TC.REQUEST_FEE}();

        vm.prank(address(malReceiver));
        vm.expectRevert(Errors.WhitelistRegistry__WithdrawFailed.selector);
        registry.withdraw();
    }

    function test_Withdraw_MultipleCycles() public {
        vm.deal(user, 50 ether);
        address user2 = makeAddr("user2");
        vm.deal(user2, 50 ether);

        vm.prank(user);
        registry.requestWhitelist{value: TC.REQUEST_FEE}();

        uint256 balBefore1 = updater.balance;
        vm.prank(updater);
        registry.withdraw();
        assertEq(updater.balance, balBefore1 + TC.REQUEST_FEE);
        assertEq(registry.getTotalCollectedFees(), 0);

        vm.warp(block.timestamp + 25 hours);
        vm.prank(user);
        registry.requestWhitelist{value: TC.REQUEST_FEE}();

        vm.prank(user2);
        registry.requestWhitelist{value: TC.REQUEST_FEE}();

        assertEq(registry.getTotalCollectedFees(), TC.REQUEST_FEE * 2);

        uint256 balBefore2 = updater.balance;
        vm.prank(updater);
        registry.withdraw();

        assertEq(updater.balance, balBefore2 + (TC.REQUEST_FEE * 2));
        assertEq(address(registry).balance, 0);
    }

    function test_Withdraw_RoleRotation() public {
        address newManager = makeAddr("newManager");
        vm.deal(user, 10 ether);

        vm.prank(user);
        registry.requestWhitelist{value: TC.REQUEST_FEE}();

        vm.prank(newManager);
        vm.expectRevert(Errors.WhitelistRegistry__NotAuthorized.selector);
        registry.withdraw();

        vm.startPrank(updater);

        registry.grantRole(TC.WITHDRAW_ROLE, newManager);
        registry.revokeRole(TC.WITHDRAW_ROLE, updater);

        vm.stopPrank();

        vm.prank(updater);
        vm.expectRevert(Errors.WhitelistRegistry__NotAuthorized.selector);
        registry.withdraw();

        uint256 managerBalanceBefore = newManager.balance;

        vm.prank(newManager);
        registry.withdraw();

        assertEq(newManager.balance, managerBalanceBefore + TC.REQUEST_FEE);
        assertEq(registry.getTotalCollectedFees(), 0);

        assertTrue(registry.hasRole(TC.WITHDRAW_ROLE, newManager));
        assertFalse(registry.hasRole(TC.WITHDRAW_ROLE, updater));
    }

    /* -------------------------------------------------------------------------- */
    /*                          authorizedUpdater                                 */
    /* -------------------------------------------------------------------------- */

    function test_AddAuthorizedUpdater_CanSignUpdates() public {
        (address newUpdater, uint256 newUpdaterPrivKey) = makeAddrAndKey("newUpdater");

        vm.prank(updater);
        registry.addAuthorizedUpdater(newUpdater);

        assertTrue(registry.isAuthorizedUpdater(newUpdater));

        uint64 nonce = registry.getCurrentNonce();
        bytes32 messageHash = keccak256(abi.encodePacked(MERKLE_ROOT, nonce, block.chainid, address(registry)));
        bytes memory signature = _sign(messageHash.toEthSignedMessageHash(), newUpdaterPrivKey);

        registry.updateMerkleRoot(MERKLE_ROOT, nonce, signature);

        assertEq(registry.getCurrentMerkleRoot(), MERKLE_ROOT);
    }

    function test_AddAuthorizedUpdater_DoesNotGrantAdminOrWithdraw() public {
        address newUpdater = makeAddr("newUpdater");

        vm.prank(updater);
        registry.addAuthorizedUpdater(newUpdater);

        assertFalse(registry.hasRole(TC.DEFAULT_ADMIN_ROLE, newUpdater));
        assertFalse(registry.hasRole(TC.WITHDRAW_ROLE, newUpdater));

        vm.deal(address(registry), 1 ether);

        vm.prank(newUpdater);
        vm.expectRevert(Errors.WhitelistRegistry__NotAuthorized.selector);
        registry.withdraw();

        address anotherGuy = makeAddr("anotherGuy");
        vm.prank(newUpdater);
        vm.expectRevert(Errors.WhitelistRegistry__NotAuthorized.selector);
        registry.addAuthorizedUpdater(anotherGuy);
    }

    function test_AddAuthorizedUpdater_BothKeysWork() public {
        (address newUpdater, uint256 newUpdaterPrivKey) = makeAddrAndKey("newUpdater");

        vm.prank(updater);
        registry.addAuthorizedUpdater(newUpdater);

        uint64 nonce1 = registry.getCurrentNonce();
        bytes32 root1 = keccak256(abi.encodePacked("root1"));

        bytes32 messageHash1 = keccak256(abi.encodePacked(root1, nonce1, block.chainid, address(registry)));
        bytes memory sig1 = _sign(messageHash1.toEthSignedMessageHash(), updaterPrivKey);

        registry.updateMerkleRoot(root1, nonce1, sig1);
        assertEq(registry.getCurrentMerkleRoot(), root1);

        uint64 nonce2 = registry.getCurrentNonce();
        bytes32 root2 = keccak256(abi.encodePacked("root2"));

        bytes32 messageHash2 = keccak256(abi.encodePacked(root2, nonce2, block.chainid, address(registry)));
        bytes memory sig2 = _sign(messageHash2.toEthSignedMessageHash(), newUpdaterPrivKey);

        registry.updateMerkleRoot(root2, nonce2, sig2);
        assertEq(registry.getCurrentMerkleRoot(), root2);
    }

    function test_AuthorizedUpdater_Workflow() public {
        assertEq(registry.getCurrentMerkleRoot(), bytes32(0));
        (address newUpdater, uint256 newUpdaterPrivKey) = makeAddrAndKey("newUpdater");

        vm.prank(updater);
        registry.addAuthorizedUpdater(newUpdater);

        uint64 nonce = registry.getCurrentNonce();
        bytes32 messageHash = keccak256(abi.encodePacked(MERKLE_ROOT, nonce, block.chainid, address(registry)));
        bytes memory signature = _sign(messageHash.toEthSignedMessageHash(), newUpdaterPrivKey);

        vm.prank(newUpdater);
        registry.updateMerkleRoot(MERKLE_ROOT, nonce, signature);
        assertEq(registry.getCurrentMerkleRoot(), MERKLE_ROOT);

        vm.prank(TC.UPDATER);
        registry.removeAuthorizedUpdater(newUpdater);
        assertFalse(registry.isAuthorizedUpdater(newUpdater));

        uint64 newNonce = registry.getCurrentNonce();
        bytes32 newRoot = keccak256(abi.encodePacked("new root"));
        bytes32 newMessageHash = keccak256(abi.encodePacked(newRoot, newNonce, block.chainid, address(registry)));
        bytes memory newSignature = _sign(newMessageHash.toEthSignedMessageHash(), newUpdaterPrivKey);

        vm.prank(newUpdater);
        vm.expectRevert(Errors.WhitelistRegistry__NotAuthorized.selector);
        registry.updateMerkleRoot(newRoot, newNonce, newSignature);
        assertNotEq(registry.getCurrentMerkleRoot(), newRoot);

        vm.prank(TC.UPDATER);
        registry.addAuthorizedUpdater(newUpdater);
        assertTrue(registry.isAuthorizedUpdater(newUpdater));

        uint64 finalNonce = registry.getCurrentNonce();
        bytes32 finalMessageHash = keccak256(abi.encodePacked(newRoot, finalNonce, block.chainid, address(registry)));
        bytes memory finalSignature = _sign(finalMessageHash.toEthSignedMessageHash(), newUpdaterPrivKey);

        vm.prank(newUpdater);
        registry.updateMerkleRoot(newRoot, finalNonce, finalSignature);
        assertEq(registry.getCurrentMerkleRoot(), newRoot);
    }

    /* -------------------------------------------------------------------------- */
    /*                             pause/unpause                                  */
    /* -------------------------------------------------------------------------- */

    function test_PauseUnpause_Workflow() public {
        uint64 currentNonce = registry.getCurrentNonce();
        uint256 fee = registry.getRequestFee();
        vm.deal(user, 10 ether);

        vm.startPrank(updater);
        registry.pause();

        bytes memory signature = _signMerkleRoot(updaterPrivKey, currentNonce);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.updateMerkleRoot(MERKLE_ROOT, uint64(currentNonce), signature);
        vm.stopPrank();

        vm.prank(user);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.requestWhitelist{value: fee}();

        vm.startPrank(updater);
        registry.unpause();
        registry.updateMerkleRoot(MERKLE_ROOT, uint64(currentNonce), signature);
        vm.stopPrank();

        vm.prank(user);
        registry.requestWhitelist{value: fee}();
    }
}
