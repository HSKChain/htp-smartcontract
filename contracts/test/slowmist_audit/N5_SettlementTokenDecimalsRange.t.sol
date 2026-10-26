// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {ConfigId} from "src/libraries/ConfigId.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {PermitCapability, SettlementTokenConfig, TokenDeploymentKind} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

contract SlowMistN5Token {
    uint8 private immutable TOKEN_DECIMALS;

    constructor(uint8 decimals_) {
        TOKEN_DECIMALS = decimals_;
    }

    function decimals() external view returns (uint8) {
        return TOKEN_DECIMALS;
    }
}

/// @notice SlowMist N5: settlement-token admission matches the market-rule precision range.
contract SlowMistN5SettlementTokenDecimalsRangeTest is DvPPreCheckTestBase {
    function test_N5_RegisterRejectsZeroAndAboveMaximumDecimals() public {
        _expectRangeRevert(0);
        _expectRangeRevert(37);
    }

    function test_N5_RegisterAcceptsSupportedBoundaryDecimals() public {
        _register(1);
        _register(36);
    }

    function _expectRangeRevert(uint8 decimals) private {
        SettlementTokenConfig memory config = _config(new SlowMistN5Token(decimals), decimals);
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.SettlementTokenDecimalsOutOfRange.selector, decimals));
        vm.prank(CONFIGURER);
        settlementTokenRegistry.registerSettlementToken(config);
        assertFalse(settlementTokenRegistry.getSettlementToken(config.configId).exists);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function _register(uint8 decimals) private {
        SettlementTokenConfig memory config = _config(new SlowMistN5Token(decimals), decimals);
        vm.prank(CONFIGURER);
        settlementTokenRegistry.registerSettlementToken(config);
        assertTrue(settlementTokenRegistry.getSettlementToken(config.configId).exists);
    }

    function _config(SlowMistN5Token token, uint8 decimals) private view returns (SettlementTokenConfig memory config) {
        config = SettlementTokenConfig({
            schemaVersion: 1,
            configId: ConfigId.derive(
                ConfigId.SETTLEMENT_TOKEN_NAMESPACE, 1, block.chainid, bytes32(uint256(uint160(address(token)))), 1
            ),
            revision: 1,
            chainId: block.chainid,
            settlementToken: address(token),
            tokenDeploymentKind: TokenDeploymentKind.DIRECT,
            settlementTokenDecimals: decimals,
            tokenCodeHash: address(token).codehash,
            implementation: address(0),
            implementationCodeHash: bytes32(0),
            adapterConfigId: adapterConfig.adapterConfigId,
            adapterConfigHash: adapterConfig.configHash,
            permitCapability: PermitCapability.EIP2612,
            replacesConfigId: bytes32(0),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashSettlementTokenConfig(config);
    }
}
