// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPErrors} from "src/types/HTPErrors.sol";
import {SettlementParams} from "src/types/HTPTypes.sol";
import {DvPTestBase} from "test/helpers/DvPTestBase.sol";
import {SchemaFixtures} from "test/generated/SchemaFixtures.sol";

contract DvPValidationSurfaceTest is DvPTestBase {
    function testSettlementPublicValidationRejectsWrongChainAndContract() public {
        SettlementParams memory params = _params();
        params.snapshot.chainId = DEPLOYED_CHAIN_ID + 1;
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.InvalidChainOrContract.selector, DEPLOYED_CHAIN_ID + 1, address(dvp))
        );
        _settleAsExecutor(params);

        params.snapshot.chainId = DEPLOYED_CHAIN_ID;
        params.snapshot.dvpContract = address(0xD002);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.InvalidChainOrContract.selector, DEPLOYED_CHAIN_ID, address(0xD002))
        );
        _settleAsExecutor(params);
    }

    function testNoInitializerUpgradeFallbackReceiveSweepOrDebugEntryPoint() public {
        _assertRejected(abi.encodeWithSignature("initialize()"), 0);
        _assertRejected(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(0xBEEF), bytes("")), 0);
        _assertRejected(abi.encodeWithSignature("sweep(address,address,uint256)", address(1), address(2), 3), 0);
        _assertRejected(abi.encodeWithSignature("debug(bytes)", hex"deadbeef"), 0);
        _assertRejected(abi.encodeWithSignature("DVP_DEFAULT_ADMIN_DELAY()"), 0);
        _assertRejected(hex"deadbeef", 0);
        _assertRejected(bytes(""), 0);
        _assertRejected(bytes(""), 1 wei);
    }

    function _params() private view returns (SettlementParams memory params) {
        params.firmQuote = SchemaFixtures.firmQuote();
        params.tradeIntent = SchemaFixtures.tradeIntent();
        params.snapshot = SchemaFixtures.snapshot();
        params.snapshot.chainId = DEPLOYED_CHAIN_ID;
        params.snapshot.dvpContract = address(dvp);
    }

    function _assertRejected(bytes memory callData, uint256 value) private {
        (bool success,) = address(dvp).call{value: value}(callData);
        assertFalse(success);
    }
}
