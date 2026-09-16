// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {DvPRoles, DvPSettlement} from "src/DvPSettlement.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {NonceCancellation, NonceType, SettlementParams} from "src/types/HTPTypes.sol";
import {DvPTestBase} from "test/helpers/DvPTestBase.sol";

contract DvPChainReplayProtectionTest is DvPTestBase {
    function testRuntimeChainIdChangeRejectsPreviouslyValidSignatures() public {
        SettlementParams memory params = _validSignedParams(dvp);
        NonceCancellation memory cancellation = NonceCancellation({
            signer: vm.addr(MAKER_KEY), nonceType: NonceType.MAKER_QUOTE, nonce: 71, deadline: type(uint64).max
        });
        bytes memory cancellationSignature =
            _sign(MAKER_KEY, HTPHashing.hashNonceCancellationDigest(dvp.domainSeparatorV4(), cancellation));
        vm.chainId(DEPLOYED_CHAIN_ID + 1);

        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.InvalidChainOrContract.selector, DEPLOYED_CHAIN_ID + 1, address(dvp))
        );
        _settleAsExecutor(params);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidSignature.selector, cancellation.signer));
        dvp.cancelNonceBySig(cancellation, cancellationSignature);
    }

    function testVerifyingContractDomainAndAssetVersionReplaysFailClosed() public {
        DvPSettlement otherDvp = _deployDvp(
            DvPRoles({defaultAdmin: GOVERNANCE, governance: GOVERNANCE, pauser: PAUSER, executor: EXECUTOR})
        );
        SettlementParams memory params = _validSignedParams(otherDvp);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.InvalidChainOrContract.selector, DEPLOYED_CHAIN_ID, address(otherDvp))
        );
        _settleAsExecutor(params);

        params = _validSignedParams(dvp);
        bytes32 wrongVerifyingContractDomain =
            HTPHashing.domainSeparator(bytes("1.2.3"), DEPLOYED_CHAIN_ID, address(otherDvp));
        params.quotingMakerSignature =
            _sign(MAKER_KEY, HTPHashing.hashFirmQuoteDigest(wrongVerifyingContractDomain, params.firmQuote));
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidSignature.selector, params.firmQuote.quotingMaker));
        _settleAsExecutor(params);

        params = _validSignedParams(dvp);
        bytes32 wrongDomain = HTPHashing.domainSeparator(bytes("1.2.3"), DEPLOYED_CHAIN_ID + 1, address(dvp));
        params.quotingMakerSignature = _sign(MAKER_KEY, HTPHashing.hashFirmQuoteDigest(wrongDomain, params.firmQuote));
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidSignature.selector, params.firmQuote.quotingMaker));
        _settleAsExecutor(params);

        params = _validSignedParams(dvp);
        bytes32 replacementAssetVersion = bytes32(uint256(0xA55E7));
        params.firmQuote.assetVersionId = replacementAssetVersion;
        params.tradeIntent.assetVersionId = replacementAssetVersion;
        params.snapshot.assetVersionId = replacementAssetVersion;
        vm.expectPartialRevert(HTPErrors.QuoteHashMismatch.selector);
        _settleAsExecutor(params);
    }
}
