// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAssetVersionRegistry} from "src/interfaces/IAssetVersionRegistry.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    AssetVersionRecord,
    EligibilityRecord,
    PermitCapability,
    PermitData,
    SettlementParams
} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

contract DvPPermitTest is DvPPreCheckTestBase {
    function testUnusedPermitMustHaveCanonicalZeroFields() public {
        SettlementParams memory params = _validPreCheckParams();
        params.assetPermit.owner = params.snapshot.seller;

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidSettlementParams.selector, bytes32("currentState")));
        vm.prank(EXECUTOR);
        dvp.settle(params);
    }

    function testAssetAndSettlementPermitFieldsMustMatchExactDerivedLegs() public {
        SettlementParams memory params = _validPreCheckParams();
        params.assetPermit = _permit(
            params.snapshot.buyer,
            params.snapshot.assetToken,
            params.snapshot.executedQuantity,
            params.snapshot.tradeDeadline
        );

        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.PermitFieldMismatch.selector, params.snapshot.assetToken, bytes32("owner"))
        );
        vm.prank(EXECUTOR);
        dvp.settle(params);

        params = _validPreCheckParams();
        params.settlementPermit = _permit(
            params.snapshot.buyer,
            params.snapshot.settlementToken,
            params.snapshot.buyerDebit + 1,
            params.snapshot.tradeDeadline
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.PermitFieldMismatch.selector, params.snapshot.settlementToken, bytes32("value")
            )
        );
        vm.prank(EXECUTOR);
        dvp.settle(params);
    }

    function testPermitRequiresCapabilityFromExactAssetVersion() public {
        SettlementParams memory params = _validPreCheckParams();
        params.assetPermit = _permit(
            params.snapshot.seller,
            params.snapshot.assetToken,
            params.snapshot.executedQuantity,
            params.snapshot.tradeDeadline
        );
        AssetVersionRecord memory record = assetVersionRegistry.getAssetVersion(params.snapshot.assetVersionId);
        record.config.assetPermitCapability = PermitCapability.UNSUPPORTED;
        vm.mockCall(
            address(assetVersionRegistry),
            abi.encodeWithSelector(IAssetVersionRegistry.getAssetVersion.selector, params.snapshot.assetVersionId),
            abi.encode(record)
        );

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.PermitUnsupported.selector, params.snapshot.assetToken));
        vm.prank(EXECUTOR);
        dvp.settle(params);
    }

    function testPermitsCanCreateAllowancesAndRunAssetBeforeSettlement() public {
        SettlementParams memory params = _validPreCheckParams();
        assetToken.setAllowance(params.snapshot.seller, address(dvp), 0);
        settlementToken.setAllowance(params.snapshot.buyer, address(dvp), 0);
        params.assetPermit = _permit(
            params.snapshot.seller,
            params.snapshot.assetToken,
            params.snapshot.executedQuantity,
            params.snapshot.tradeDeadline
        );
        params.settlementPermit = _permit(
            params.snapshot.buyer,
            params.snapshot.settlementToken,
            params.snapshot.buyerDebit,
            params.snapshot.tradeDeadline
        );

        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertEq(assetToken.permitCalls(), 1);
        assertEq(settlementToken.permitCalls(), 1);
    }

    function testFrontRunOrRevertingPermitStillSucceedsWhenAllowanceIsSufficient() public {
        SettlementParams memory params = _validPreCheckParams();
        params.assetPermit = _permit(
            params.snapshot.seller,
            params.snapshot.assetToken,
            params.snapshot.executedQuantity,
            params.snapshot.tradeDeadline
        );
        vm.mockCallRevert(
            params.snapshot.assetToken,
            abi.encodeWithSelector(
                bytes4(0xd505accf),
                params.assetPermit.owner,
                address(dvp),
                params.assetPermit.value,
                params.assetPermit.deadline,
                params.assetPermit.v,
                params.assetPermit.r,
                params.assetPermit.s
            ),
            bytes("PERMIT_ALREADY_USED")
        );

        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertEq(assetToken.balanceOf(params.snapshot.buyer), params.snapshot.executedQuantity);
    }

    function testPermitFailureWithInsufficientAllowanceRollsBack() public {
        SettlementParams memory params = _validPreCheckParams();
        assetToken.setAllowance(params.snapshot.seller, address(dvp), 0);
        params.assetPermit = _permit(
            params.snapshot.seller,
            params.snapshot.assetToken,
            params.snapshot.executedQuantity,
            params.snapshot.tradeDeadline
        );
        vm.mockCallRevert(
            params.snapshot.assetToken,
            abi.encodeWithSelector(
                bytes4(0xd505accf),
                params.assetPermit.owner,
                address(dvp),
                params.assetPermit.value,
                params.assetPermit.deadline,
                params.assetPermit.v,
                params.assetPermit.r,
                params.assetPermit.s
            ),
            bytes("PERMIT_FAILURE")
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.InsufficientAllowance.selector,
                params.snapshot.assetToken,
                params.snapshot.seller,
                params.snapshot.executedQuantity,
                uint256(0)
            )
        );
        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertEq(assetToken.balanceOf(params.snapshot.seller), 100 ether);
        EligibilityRecord memory sender = eligibilityRegistry.getEligibility(
            keccak256(abi.encode(block.chainid, params.snapshot.seller, params.snapshot.assetVersionId))
        );
        EligibilityRecord memory receiver = eligibilityRegistry.getEligibility(
            keccak256(abi.encode(block.chainid, params.snapshot.buyer, params.snapshot.assetVersionId))
        );
        assertEq(sender.recordVersion, 1);
        assertEq(receiver.recordVersion, 1);
    }

    function _permit(address owner, address token, uint256 value, uint64 deadline)
        private
        pure
        returns (PermitData memory permit)
    {
        permit = PermitData({
            usePermit: true,
            owner: owner,
            token: token,
            value: value,
            deadline: deadline,
            v: 27,
            r: bytes32(uint256(1)),
            s: bytes32(uint256(2))
        });
    }
}
