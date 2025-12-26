// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {WhitelistRegistry} from "../../src/WhitelistRegistry.sol";
import {IWhitelistRegistry} from "../../src/interfaces/IWhitelistRegistry.sol";

import {MaliciousReceiver} from "../mocks/MaliciousReceiver.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract WhitelistRegistryUnitTest is Test {
    using MessageHashUtils for bytes32;

    WhitelistRegistry registry;

    address updater;
    address randomUser;
    uint256 updaterPk;
    uint256 randomUserPk;

    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;

    function setUp() public {
        (updater, updaterPk) = makeAddrAndKey("updater");
        (randomUser, randomUserPk) = makeAddrAndKey("randomUser");
        vm.deal(randomUser, 10 ether);

        registry = new WhitelistRegistry(updater);
    }

    /* -------------------------------------------------------------------------- */
    /*                              HELPERS                                       */
    /* -------------------------------------------------------------------------- */

    function _sign(bytes32 hash, uint256 privKey) internal pure returns (bytes memory signature) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, hash);
        signature = abi.encodePacked(r, s, v);
    }

    function _updateRoot() internal {
        uint64 currentNonce = registry.getCurrentNonce();
        bytes32 root = keccak256(abi.encodePacked("new merkle root"));

        bytes32 hash = keccak256(abi.encodePacked(root, currentNonce, block.chainid, address(registry)));
        bytes32 signedHash = hash.toEthSignedMessageHash();
        bytes memory sig = _sign(signedHash, updaterPk);
        vm.prank(updater);
        registry.updateMerkleRoot(root, currentNonce, sig);
    }

    /* -------------------------------------------------------------------------- */
    /*                            INITIAL STATE                                   */
    /* -------------------------------------------------------------------------- */

    function test_Constructor_InitialValues() public view {
        assertTrue(registry.hasRole(registry.getWithdrawRole(), updater));
        assertTrue(registry.hasRole(0x00, updater));
        assertTrue(registry.isAuthorizedUpdater(updater));
        assertFalse(registry.isAuthorizedUpdater(randomUser));
    }

    function test_Constructor_InvalidInput() public {
        vm.expectRevert(Errors.WhitelistRegistry__InvalidInput.selector);
        new WhitelistRegistry(address(0));
    }

    /* -------------------------------------------------------------------------- */
    /*                         updateMerkleRoot                                   */
    /* -------------------------------------------------------------------------- */

    function test_UpdateRoot_InvalidInput() public {
        _updateRoot();

        // invalid root
        bytes32 invalidRoot = bytes32(0);
        bytes memory signature = _sign("randomInput", updaterPk);
        uint256 currentNonce = registry.getCurrentNonce();

        vm.startPrank(updater);

        vm.expectRevert(Errors.WhitelistRegistry__InvalidInput.selector);
        registry.updateMerkleRoot(invalidRoot, uint64(currentNonce), signature);

        // invalid signature length
        bytes32 newRoot = keccak256(abi.encodePacked("new new merkle root"));
        bytes memory invalidSignature = hex"1234";
        vm.expectRevert();
        registry.updateMerkleRoot(newRoot, uint64(currentNonce), invalidSignature);

        bytes memory emptySig = "";
        vm.expectRevert(Errors.WhitelistRegistry__InvalidInput.selector);
        registry.updateMerkleRoot(newRoot, uint64(currentNonce), emptySig);

        // zero signature
        bytes memory zeroSig = new bytes(65);
        vm.expectRevert(); // без селектора
        registry.updateMerkleRoot(newRoot, uint64(currentNonce), zeroSig);

        // invalid both
        vm.expectRevert(Errors.WhitelistRegistry__InvalidInput.selector);
        registry.updateMerkleRoot(invalidRoot, uint64(currentNonce), invalidSignature);

        vm.stopPrank();
    }

    function test_UpdateRoot_NonAuthorizedCaller() public {
        bytes32 currentRoot = registry.getCurrentMerkleRoot();
        uint256 currentNonce = registry.getCurrentNonce();

        vm.startPrank(randomUser);
        bytes32 newRoot = keccak256(abi.encodePacked("new merkle root"));

        bytes32 hash = keccak256(abi.encodePacked(newRoot, currentNonce, block.chainid, address(registry)));
        bytes32 signedHash = hash.toEthSignedMessageHash();
        bytes memory signature = _sign(signedHash, randomUserPk);
        vm.stopPrank();

        vm.prank(updater);
        vm.expectRevert(Errors.WhitelistRegistry__NotAuthorized.selector);
        registry.updateMerkleRoot(newRoot, uint64(currentNonce), signature);

        bytes32 rootAfter = registry.getCurrentMerkleRoot();
        assertEq(currentRoot, rootAfter);
    }

    // random address with correct signature can update
    function test_UpdateRoot_CorrectSignature() public {
        bytes32 newRoot = keccak256(abi.encodePacked("new merkle root"));
        uint64 currentNonce = registry.getCurrentNonce();

        bytes32 hash = keccak256(abi.encodePacked(newRoot, currentNonce, block.chainid, address(registry)));
        bytes32 signedHash = hash.toEthSignedMessageHash();
        bytes memory signature = _sign(signedHash, updaterPk);

        assertFalse(registry.isAuthorizedUpdater(randomUser));

        vm.prank(randomUser);
        registry.updateMerkleRoot(newRoot, currentNonce, signature);

        // verify that the root was not updated
        bytes32 updatedRoot = registry.getCurrentMerkleRoot();
        assertEq(updatedRoot, registry.getCurrentMerkleRoot());
    }

    function test_UpdateRoot_DuplicateUpdate() public {
        bytes32 sameRoot = bytes32(0);
        uint64 currentNonce = registry.getCurrentNonce();

        bytes memory signatureOne = _sign("randomInput", updaterPk);

        vm.prank(updater);
        vm.expectRevert(Errors.WhitelistRegistry__DuplicateUpdate.selector);
        registry.updateMerkleRoot(sameRoot, currentNonce, signatureOne);

        _updateRoot();

        bytes32 currentRoot = registry.getCurrentMerkleRoot();
        uint64 currentNonceAfter = registry.getCurrentNonce();

        // try to update with the same root
        bytes32 hash = keccak256(abi.encodePacked(currentRoot, currentNonceAfter, block.chainid, address(registry)));
        bytes32 signedHash = hash.toEthSignedMessageHash();
        bytes memory signatureTwo = _sign(signedHash, updaterPk);

        vm.prank(updater);
        vm.expectRevert(Errors.WhitelistRegistry__DuplicateUpdate.selector);
        registry.updateMerkleRoot(currentRoot, currentNonceAfter, signatureTwo);

        bytes32 rootAfter = registry.getCurrentMerkleRoot();
        assertEq(currentRoot, rootAfter);
    }

    function test_UpdateRoot_Success() public {
        assertTrue(registry.isAuthorizedUpdater(updater));
        bytes32 notUpdatedRoot = registry.getCurrentMerkleRoot();
        uint256 before = registry.getLastUpdateTime();
        uint64 currentNonce = registry.getCurrentNonce();
        bytes32 oldRoot = registry.getCurrentMerkleRoot();

        vm.expectEmit(false, false, false, true);
        emit IWhitelistRegistry.WhitelistUpdated(oldRoot, keccak256(abi.encodePacked("new merkle root")), currentNonce);
        _updateRoot();

        uint256 afterTime = registry.getLastUpdateTime();
        bytes32 updatedRoot = registry.getCurrentMerkleRoot();
        assertNotEq(updatedRoot, notUpdatedRoot);
        assertTrue(afterTime != before);
        assertEq(afterTime, block.timestamp);
    }

    function test_UpdateRoot_SigByNewAuthorizedUpdater_Success() public {
        uint64 currentNonce = registry.getCurrentNonce();

        vm.prank(updater);
        registry.addAuthorizedUpdater(randomUser);

        bytes32 newRoot = keccak256(abi.encodePacked("authorized new merkle root"));

        bytes32 hash = keccak256(abi.encodePacked(newRoot, currentNonce, block.chainid, address(registry)));
        bytes32 signedHash = hash.toEthSignedMessageHash();
        bytes memory signature = _sign(signedHash, randomUserPk);

        registry.updateMerkleRoot(newRoot, currentNonce, signature);

        assertEq(registry.getCurrentMerkleRoot(), newRoot);
    }

    /* -------------------------------------------------------------------------- */
    /*                         requestWhitelist                                   */
    /* -------------------------------------------------------------------------- */

    function test_RequestWhitelist_InsufficientFee() public {
        uint256 requestFee = registry.getRequestFee();

        vm.prank(randomUser);
        vm.expectRevert(Errors.WhitelistRegistry__InsufficientFee.selector);
        registry.requestWhitelist{value: requestFee - 1}();
    }

    function test_RequestWhitelist_RequestToFrequent() public {
        uint256 requestFee = registry.getRequestFee();

        vm.prank(randomUser);
        registry.requestWhitelist{value: requestFee}();

        vm.prank(randomUser);
        vm.expectRevert(Errors.WhitelistRegistry__RequestTooFrequent.selector);
        registry.requestWhitelist{value: requestFee}();
    }

    function test_RequestWhitelist_Success() public {
        uint256 requestFee = registry.getRequestFee();

        uint256 lastRequestedTimeBefore = registry.getLastRequestedTime(randomUser);
        assertEq(lastRequestedTimeBefore, 0);
        uint256 totalCollectedFeesBefore = registry.getTotalCollectedFees();

        vm.prank(randomUser);
        vm.expectEmit(true, false, false, false);
        emit IWhitelistRegistry.WhitelistRequested(randomUser);

        uint256 blockTimestampBefore = block.timestamp;

        bool success = registry.requestWhitelist{value: requestFee}();
        assertTrue(success);

        uint256 lastRequestedTimeAfter = registry.getLastRequestedTime(randomUser);
        uint256 totalCollectedFeesAfter = registry.getTotalCollectedFees();

        assertEq(lastRequestedTimeAfter, blockTimestampBefore);
        assertEq(totalCollectedFeesAfter, totalCollectedFeesBefore + requestFee);
    }

    /* -------------------------------------------------------------------------- */
    /*                              withdraw                                      */
    /* -------------------------------------------------------------------------- */

    function test_Withdraw_NotAuthorized() public {
        vm.prank(randomUser);
        vm.expectRevert(Errors.WhitelistRegistry__NotAuthorized.selector);
        registry.withdraw();
    }

    function test_Withdraw_TransferFailed() public {
        vm.deal(address(registry), 1 ether);

        address maliciousReceiver = address(new MaliciousReceiver());

        vm.startPrank(updater);
        registry.grantRole(registry.getWithdrawRole(), maliciousReceiver);
        vm.stopPrank();

        vm.prank(maliciousReceiver);
        vm.expectRevert(Errors.WhitelistRegistry__NothingToWithdraw.selector);
        registry.withdraw();

        vm.deal(randomUser, 10 ether);
        vm.prank(randomUser);
        registry.requestWhitelist{value: registry.getRequestFee()}();

        vm.prank(maliciousReceiver);
        vm.expectRevert(Errors.WhitelistRegistry__WithdrawFailed.selector);
        registry.withdraw();
        assertEq(registry.getTotalCollectedFees(), registry.getRequestFee());
        assertEq(maliciousReceiver.balance, 0);
    }

    function test_Withdraw_Success() public {
        uint256 requestFee = registry.getRequestFee();

        vm.prank(randomUser);
        (bool success) = registry.requestWhitelist{value: requestFee}();
        assertTrue(success);
        assertEq(registry.getTotalCollectedFees(), requestFee);

        uint256 updaterBalanceBefore = updater.balance;

        // Expect event
        vm.prank(updater);
        vm.expectEmit(true, false, false, true);
        emit IWhitelistRegistry.WithdrawSuccess(updater, requestFee);

        registry.withdraw();

        uint256 updaterBalanceAfter = updater.balance;
        assertEq(updaterBalanceAfter, updaterBalanceBefore + requestFee);
        assertEq(registry.getTotalCollectedFees(), 0);
    }

    /* -------------------------------------------------------------------------- */
    /*                            addAuthorizedUpdater                            */
    /* -------------------------------------------------------------------------- */

    function test_AddAuthorizedUpdater_NotAuthorized() public {
        vm.prank(randomUser);
        vm.expectRevert(Errors.WhitelistRegistry__NotAuthorized.selector);
        registry.addAuthorizedUpdater(randomUser);
    }

    function test_AddAuthorizedUpdater_InvalidInput() public {
        vm.prank(updater);
        vm.expectRevert(Errors.WhitelistRegistry__InvalidInput.selector);
        registry.addAuthorizedUpdater(address(0));
    }

    function test_AddAuthorizedUpdater_AlreadyAuthorized() public {
        assertTrue(registry.isAuthorizedUpdater(updater));

        vm.prank(updater);
        vm.expectRevert(Errors.WhitelistRegistry__AlreadyAuthorized.selector);
        registry.addAuthorizedUpdater(updater);
    }

    function test_AddAuthorizedUpdater_Success() public {
        assertFalse(registry.isAuthorizedUpdater(randomUser));

        vm.prank(updater);
        vm.expectEmit(true, false, false, false);
        emit IWhitelistRegistry.AuthorizedUpdaterAdded(randomUser);
        registry.addAuthorizedUpdater(randomUser);

        assertTrue(registry.isAuthorizedUpdater(randomUser));
    }

    /* -------------------------------------------------------------------------- */
    /*                         removeAuthorizedUpdater                             */
    /* -------------------------------------------------------------------------- */

    function test_RemoveAuthorizedUpdater_NotAuthorized() public {
        vm.prank(randomUser);
        vm.expectRevert(Errors.WhitelistRegistry__NotAuthorized.selector);
        registry.removeAuthorizedUpdater(updater);
    }

    function test_RemoveAuthorizedUpdater_InvalidInput() public {
        vm.prank(updater);
        vm.expectRevert(Errors.WhitelistRegistry__InvalidInput.selector);
        registry.removeAuthorizedUpdater(address(0));
    }

    function test_RemoveAuthorizedUpdater_NotAuthorizedUpdater() public {
        assertFalse(registry.isAuthorizedUpdater(randomUser));

        vm.prank(updater);
        vm.expectRevert(Errors.WhitelistRegistry__NotAuthorized.selector);
        registry.removeAuthorizedUpdater(randomUser);
    }

    function test_RemoveAuthorizedUpdater_Success() public {
        assertTrue(registry.isAuthorizedUpdater(updater));

        vm.prank(updater);
        vm.expectEmit(true, false, false, false);
        emit IWhitelistRegistry.AuthorizedUpdaterRemoved(updater);
        registry.removeAuthorizedUpdater(updater);

        assertFalse(registry.isAuthorizedUpdater(updater));
    }

    /* -------------------------------------------------------------------------- */
    /*                              pause/unpause                                 */
    /* -------------------------------------------------------------------------- */

    function test_PauseUnpause_NotAuthorized() public {
        vm.startPrank(randomUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, registry.getDefaultAdminRole()
            )
        );
        registry.pause();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, registry.getDefaultAdminRole()
            )
        );
        registry.unpause();
        vm.stopPrank();
    }

    function test_PauseUnpause_Success() public {
        vm.prank(updater);
        registry.pause();
        assertTrue(registry.paused());

        vm.prank(updater);
        registry.unpause();
        assertFalse(registry.paused());
    }

    function test_UpdateMerkleRoot_RevertsWhenPaused() public {
        vm.prank(updater);
        registry.pause();
        assertTrue(registry.paused());

        bytes32 newRoot = keccak256(abi.encodePacked("new merkle root"));
        uint256 currentNonce = registry.getCurrentNonce();

        bytes32 hash = keccak256(abi.encodePacked(newRoot, currentNonce, block.chainid, address(registry)));
        bytes32 signedHash = hash.toEthSignedMessageHash();
        bytes memory signature = _sign(signedHash, updaterPk);

        vm.prank(randomUser);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.updateMerkleRoot(newRoot, uint64(currentNonce), signature);
    }

    function test_RequestWhitelist_RevertsWhenPaused() public {
        vm.prank(updater);
        registry.pause();
        uint256 fee = registry.getRequestFee();

        vm.prank(randomUser);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.requestWhitelist{value: fee}();
    }

    /* -------------------------------------------------------------------------- */
    /*                                  GETTERS                                   */
    /* -------------------------------------------------------------------------- */

    function test_Getters_InitialValues() public view {
        // initial merkle root and timestamps
        assertEq(registry.getCurrentMerkleRoot(), bytes32(0));
        assertEq(registry.getTotalCollectedFees(), 0);
        assertEq(registry.getLastUpdateTime(), 0);

        // authorized updater checks

        assertTrue(registry.isAuthorizedUpdater(updater));
        assertFalse(registry.isAuthorizedUpdater(randomUser));

        // request-related getters
        assertEq(registry.getLastRequestedTime(randomUser), 0);
        assertEq(registry.getRequestCooldown(), 24 hours);
        assertEq(registry.getRequestFee(), 10e6);

        // roles
        assertEq(registry.getDefaultAdminRole(), DEFAULT_ADMIN_ROLE);
        assertTrue(registry.isAdmin(updater));
        assertFalse(registry.isAdmin(randomUser));
        assertTrue(registry.isWithdrawer(updater));
        assertFalse(registry.isWithdrawer(randomUser));

        bytes32 expectedWithdrawRole = keccak256(abi.encodePacked("WITHDRAW_ROLE"));
        assertEq(registry.getWithdrawRole(), expectedWithdrawRole);
    }

    function test_VerifyWhitelist_InvalidInputs() public {
        bytes32[] memory emptyProof = new bytes32[](0);

        vm.expectRevert(Errors.WhitelistRegistry__InvalidInput.selector);
        registry.verifyWhitelist(emptyProof, randomUser);

        bytes32[] memory someProof = new bytes32[](1);
        someProof[0] = keccak256(abi.encodePacked("some"));

        vm.expectRevert(Errors.WhitelistRegistry__InvalidInput.selector);
        registry.verifyWhitelist(someProof, address(0));
    }
}
