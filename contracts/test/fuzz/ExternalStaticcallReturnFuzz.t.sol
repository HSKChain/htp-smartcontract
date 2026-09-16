// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IPrincipalCalculator} from "src/interfaces/IPrincipalCalculator.sol";
import {IDvPGovernanceView} from "src/interfaces/IDvPGovernanceView.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {AssetVersionRegistry} from "src/registry/AssetVersionRegistry.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {Decision, SettlementParams} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

contract StaticcallFuzz1271Wallet {
    fallback() external {}
}

contract ExternalStaticcallReturnFuzzTest is DvPPreCheckTestBase {
    function testFuzzCalculatorShortLongAndMalformedReturnsNeverPass(bytes calldata returnData) public {
        vm.assume(returnData.length <= 4096);
        SettlementParams memory params = _validPreCheckParams();
        vm.assume(!_calculatorReturnWouldPass(params, returnData));
        vm.mockCall(
            address(calculator),
            abi.encodeWithSelector(
                IPrincipalCalculator.calculate.selector,
                params.snapshot.priceData,
                params.snapshot.executedQuantity,
                params.snapshot.assetDecimals
            ),
            returnData
        );

        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertNotEq(uint8(decision), uint8(Decision.PASS));
        if (returnData.length != 96) {
            assertEq(uint8(decision), uint8(Decision.UNKNOWN));
            assertEq(reason, HTPErrors.ExternalCallFailed.selector);
        }
    }

    function testFuzzEip1271ShortLongAndMalformedReturnsNeverPass(bytes calldata signature, bytes calldata returnData)
        public
    {
        vm.assume(signature.length <= 256 && returnData.length <= 4096);
        vm.assume(!_eip1271ReturnWouldPass(returnData));
        StaticcallFuzz1271Wallet wallet = new StaticcallFuzz1271Wallet();
        SettlementParams memory params = _paramsForMakerWallet(address(wallet), signature);
        bytes32 digest = HTPHashing.hashFirmQuoteDigest(dvp.domainSeparatorV4(), params.firmQuote);
        vm.mockCall(
            address(wallet), abi.encodeWithSelector(IERC1271.isValidSignature.selector, digest, signature), returnData
        );

        (Decision decision,) = dvp.preCheck(params);
        assertNotEq(uint8(decision), uint8(Decision.PASS));
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
    }

    function testFuzzDependentDvpMalformedBoolReturnBlocksRegistryUpgrade(bytes calldata returnData) public {
        vm.assume(returnData.length <= 4096);
        vm.assume(!_canonicalBool(returnData));
        AssetVersionRegistry nextImplementation = new AssetVersionRegistry();
        vm.mockCall(address(dvp), abi.encodeWithSelector(IDvPGovernanceView.globalPaused.selector), returnData);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.DependentDvpStatusMalformed.selector, address(dvp)));
        vm.prank(address(timelock));
        assetVersionRegistry.upgradeToAndCall(address(nextImplementation), bytes(""));
    }

    function testOversizedStaticcallReturnsFailClosedWithoutCopyingPayload() public {
        bytes memory oversized = new bytes(65_536);
        SettlementParams memory params = _validPreCheckParams();
        vm.mockCall(
            address(calculator),
            abi.encodeWithSelector(
                IPrincipalCalculator.calculate.selector,
                params.snapshot.priceData,
                params.snapshot.executedQuantity,
                params.snapshot.assetDecimals
            ),
            oversized
        );
        (Decision calculatorDecision,) = dvp.preCheck(params);
        assertEq(uint8(calculatorDecision), uint8(Decision.UNKNOWN));
        vm.clearMockedCalls();

        StaticcallFuzz1271Wallet wallet = new StaticcallFuzz1271Wallet();
        bytes memory signature = hex"010203";
        params = _paramsForMakerWallet(address(wallet), signature);
        bytes32 digest = HTPHashing.hashFirmQuoteDigest(dvp.domainSeparatorV4(), params.firmQuote);
        vm.mockCall(
            address(wallet), abi.encodeWithSelector(IERC1271.isValidSignature.selector, digest, signature), oversized
        );
        (Decision signatureDecision,) = dvp.preCheck(params);
        assertEq(uint8(signatureDecision), uint8(Decision.UNKNOWN));
        vm.clearMockedCalls();

        AssetVersionRegistry nextImplementation = new AssetVersionRegistry();
        vm.mockCall(address(dvp), abi.encodeWithSelector(IDvPGovernanceView.globalPaused.selector), oversized);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.DependentDvpStatusMalformed.selector, address(dvp)));
        vm.prank(address(timelock));
        assetVersionRegistry.upgradeToAndCall(address(nextImplementation), bytes(""));
    }

    function _paramsForMakerWallet(address wallet, bytes memory signature)
        private
        view
        returns (SettlementParams memory params)
    {
        params = _validPreCheckParams();
        params.firmQuote.quotingMaker = wallet;
        params.tradeIntent.quotingMaker = wallet;
        params.snapshot.quotingMaker = wallet;
        params.tradeIntent.seller = wallet;
        params.snapshot.seller = wallet;
        _resign(params);
        params.quotingMakerSignature = signature;
    }

    function _calculatorReturnWouldPass(SettlementParams memory params, bytes calldata returnData)
        private
        pure
        returns (bool)
    {
        if (returnData.length != 96) return false;
        bytes32 priceTermsHash;
        uint256 unitCashPrice;
        uint256 cashPrincipal;
        assembly ("memory-safe") {
            priceTermsHash := calldataload(returnData.offset)
            unitCashPrice := calldataload(add(returnData.offset, 0x20))
            cashPrincipal := calldataload(add(returnData.offset, 0x40))
        }
        return priceTermsHash == params.snapshot.priceTermsHash && unitCashPrice != 0
            && cashPrincipal == params.snapshot.cashPrincipal;
    }

    function _eip1271ReturnWouldPass(bytes calldata returnData) private pure returns (bool) {
        if (returnData.length != 32) return false;
        bytes32 word;
        assembly ("memory-safe") {
            word := calldataload(returnData.offset)
        }
        return bytes4(word) == IERC1271.isValidSignature.selector;
    }

    function _canonicalBool(bytes calldata returnData) private pure returns (bool) {
        if (returnData.length != 32) return false;
        uint256 word;
        assembly ("memory-safe") {
            word := calldataload(returnData.offset)
        }
        return word <= 1;
    }
}
