// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {ParticipantType, SettlementParams} from "src/types/HTPTypes.sol";
import {DvPTestBase} from "test/helpers/DvPTestBase.sol";

contract DvPSignedPayloadValidationTest is DvPTestBase {
    function testSettlementRejectsUnsupportedSchemaVersion() public {
        SettlementParams memory params = _validSignedParams();
        params.snapshot.schemaVersion = 2;

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidSettlementParams.selector, bytes32("required")));
        _settleAsExecutor(params);
    }

    function testQuoteAndSnapshotHashesAreRecomputedFromCompletePreimages() public {
        SettlementParams memory params = _validSignedParams();
        bytes32 computedQuote = HTPHashing.hashFirmQuoteDigest(dvp.domainSeparatorV4(), params.firmQuote);
        params.tradeIntent.quoteHash = bytes32(uint256(0xBAD1));
        _resignRequester(params);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.QuoteHashMismatch.selector, computedQuote, bytes32(uint256(0xBAD1)))
        );
        _settleAsExecutor(params);

        params = _validSignedParams();
        bytes32 computedSnapshot = HTPHashing.hashTradeTermsSnapshot(params.snapshot);
        params.tradeIntent.snapshotHash = bytes32(uint256(0xBAD2));
        _resignRequester(params);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.SnapshotHashMismatch.selector, computedSnapshot, bytes32(uint256(0xBAD2)))
        );
        _settleAsExecutor(params);

        params = _validSignedParams();
        ++params.snapshot.createdAt;
        vm.expectPartialRevert(HTPErrors.SnapshotHashMismatch.selector);
        _settleAsExecutor(params);
    }

    function testQuoteAndTradeDeadlinesMustMatchSnapshotExactly() public {
        SettlementParams memory params = _validSignedParams();
        ++params.snapshot.quoteExpiresAt;
        params.tradeIntent.snapshotHash = HTPHashing.hashTradeTermsSnapshot(params.snapshot);
        _resignRequester(params);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidSettlementParams.selector, bytes32("quoteExpiresAt")));
        _settleAsExecutor(params);

        params = _validSignedParams();
        ++params.snapshot.tradeDeadline;
        params.tradeIntent.snapshotHash = HTPHashing.hashTradeTermsSnapshot(params.snapshot);
        _resignRequester(params);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidSettlementParams.selector, bytes32("tradeDeadline")));
        _settleAsExecutor(params);
    }

    function testRepeatedRolesPriceConfigFeeAmountsAndNoncesMustMatch() public {
        SettlementParams memory params = _validSignedParams();
        params.tradeIntent.requesterType = ParticipantType.MAKER;
        _resignRequester(params);
        _expectFieldMismatch(params, bytes32("requesterType"));

        params = _validSignedParams();
        params.tradeIntent.priceData = bytes.concat(params.tradeIntent.priceData, hex"00");
        _resignRequester(params);
        _expectFieldMismatch(params, bytes32("priceData"));

        params = _validSignedParams();
        params.tradeIntent.principalCalculatorConfigHash = bytes32(uint256(0xBAD));
        _resignRequester(params);
        _expectFieldMismatch(params, bytes32("principalCalculatorConfigHash"));

        params = _validSignedParams();
        ++params.tradeIntent.cashPrincipal;
        _resignRequester(params);
        _expectFieldMismatch(params, bytes32("cashPrincipal"));

        params = _validSignedParams();
        ++params.tradeIntent.feePolicyEpoch;
        _resignRequester(params);
        _expectFieldMismatch(params, bytes32("feePolicyEpoch"));

        params = _validSignedParams();
        ++params.tradeIntent.tradeNonce;
        _resignRequester(params);
        _expectFieldMismatch(params, bytes32("tradeNonce"));
    }

    function _expectFieldMismatch(SettlementParams memory params, bytes32 field) private {
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidSettlementParams.selector, field));
        _settleAsExecutor(params);
    }
}
