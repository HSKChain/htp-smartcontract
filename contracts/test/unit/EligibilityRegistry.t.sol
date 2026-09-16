// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Roles} from "src/libraries/Roles.sol";
import {EligibilityRegistry} from "src/registry/EligibilityRegistry.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {Decision, EligibilityInput, EligibilityRecord, ReasonCode} from "src/types/HTPTypes.sol";
import {RegistryTestBase} from "test/helpers/RegistryTestBase.sol";

contract EligibilityRegistryTest is RegistryTestBase {
    address private constant PAUSER = address(0x2001);
    address private constant UPDATER = address(0x3001);
    address private constant WALLET = address(0xA11CE);
    bytes32 private constant ASSET_VERSION_ID = bytes32(uint256(0xA55E7));
    bytes32 private constant EVIDENCE_HASH = bytes32(uint256(0xE11D));
    uint64 private constant VALID_FROM = 1_800_000_000;
    uint64 private constant VALID_UNTIL = 1_900_000_000;

    EligibilityRegistry private registry;

    function setUp() public override {
        super.setUp();
        registry = EligibilityRegistry(
            _deployProxy(
                address(new EligibilityRegistry()),
                abi.encodeCall(
                    EligibilityRegistry.initialize,
                    (address(timelock), address(timelock), address(timelock), PAUSER, UPDATER)
                )
            )
        );
        vm.warp(VALID_FROM);
    }

    function testSetAndReadSingleCanTradePermission() public {
        vm.prank(UPDATER);
        registry.setEligibility(_input(Decision.PASS), 0);

        bytes32 key = _key(WALLET, ASSET_VERSION_ID);
        EligibilityRecord memory record = registry.getEligibility(key);
        assertEq(record.eligibilityKey, key);
        assertEq(record.wallet, WALLET);
        assertEq(record.assetVersionId, ASSET_VERSION_ID);
        assertEq(uint8(record.decision), uint8(Decision.PASS));
        assertEq(record.recordVersion, 1);
        (bool eligible, bytes4 reason) = registry.isEligible(WALLET, ASSET_VERSION_ID);
        assertTrue(eligible);
        assertEq(reason, bytes4(0));
    }

    function testKeyUsesChainWalletAndAssetVersionOnly() public view {
        assertEq(_key(WALLET, ASSET_VERSION_ID), keccak256(abi.encode(block.chainid, WALLET, ASSET_VERSION_ID)));
    }

    function testIsEligibleReturnsReasonForMissingBlockedPausedAndExpired() public {
        (bool eligible, bytes4 reason) = registry.isEligible(WALLET, ASSET_VERSION_ID);
        assertFalse(eligible);
        assertEq(reason, HTPErrors.EligibilityNotFound.selector);

        vm.prank(UPDATER);
        registry.setEligibility(_input(Decision.BLOCK), 0);
        (eligible, reason) = registry.isEligible(WALLET, ASSET_VERSION_ID);
        assertFalse(eligible);
        assertEq(reason, HTPErrors.EligibilityNotPassed.selector);

        vm.prank(UPDATER);
        registry.setEligibility(_input(Decision.PASS), 1);
        vm.prank(PAUSER);
        registry.pauseEligibility(_key(WALLET, ASSET_VERSION_ID), 2, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
        (eligible, reason) = registry.isEligible(WALLET, ASSET_VERSION_ID);
        assertFalse(eligible);
        assertEq(reason, HTPErrors.EligibilityPausedOrRevoked.selector);

        vm.prank(address(timelock));
        registry.unpauseEligibility(_key(WALLET, ASSET_VERSION_ID), 3, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH);
        vm.warp(VALID_UNTIL + 1);
        (eligible, reason) = registry.isEligible(WALLET, ASSET_VERSION_ID);
        assertFalse(eligible);
        assertEq(reason, HTPErrors.EligibilityExpired.selector);
    }

    function testRevokeIsPermanent() public {
        vm.prank(UPDATER);
        registry.setEligibility(_input(Decision.PASS), 0);
        // 永久吊销归 GOVERNANCE，与 unpauseEligibility 同级。
        vm.prank(address(timelock));
        registry.revokeEligibility(_key(WALLET, ASSET_VERSION_ID), 1, EVIDENCE_HASH);

        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.EligibilityPausedOrRevoked.selector, _key(WALLET, ASSET_VERSION_ID))
        );
        vm.prank(UPDATER);
        registry.setEligibility(_input(Decision.PASS), 2);
    }

    function testExpectedVersionAndRoleAreEnforced() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), Roles.CONFIGURER_ROLE
            )
        );
        registry.setEligibility(_input(Decision.PASS), 0);

        vm.prank(UPDATER);
        registry.setEligibility(_input(Decision.PASS), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.EligibilityVersionConflict.selector, _key(WALLET, ASSET_VERSION_ID), uint64(0), uint64(1)
            )
        );
        vm.prank(UPDATER);
        registry.setEligibility(_input(Decision.PASS), 0);
    }

    function _input(Decision decision) private pure returns (EligibilityInput memory) {
        return EligibilityInput({
            wallet: WALLET,
            assetVersionId: ASSET_VERSION_ID,
            decision: decision,
            validFrom: VALID_FROM,
            validUntil: VALID_UNTIL,
            kycDecisionVersion: bytes32(uint256(0xD100)),
            permissionVersion: bytes32(uint256(0xD101)),
            evidenceHash: EVIDENCE_HASH
        });
    }

    function _key(address wallet, bytes32 assetVersionId) private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, wallet, assetVersionId));
    }
}
