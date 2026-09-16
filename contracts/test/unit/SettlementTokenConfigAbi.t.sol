// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ISettlementTokenRegistry} from "src/interfaces/ISettlementTokenRegistry.sol";
import {ReasonCode, SettlementTokenConfig, SettlementTokenRecord, TokenDeploymentKind} from "src/types/HTPTypes.sol";
import {abiSelector} from "test/helpers/AbiAssertions.sol";

contract SettlementTokenConfigAbiTest is Test {
    bytes4 private constant REGISTER = 0x304b0699;
    bytes4 private constant ACTIVATE = 0x243a24d7;
    bytes4 private constant PAUSE = 0x7f549033;
    bytes4 private constant UNPAUSE = 0x92280dc8;
    bytes4 private constant DEPRECATE = 0x0e50b25a;
    bytes4 private constant GET = 0x58298414;
    bytes4 private constant GET_CURRENT = 0x51023e08;
    bytes4 private constant IS_ACTIVE = 0x16179be5;
    bytes4 private constant REGISTER_DEPENDENT = 0x03f8d147;
    bytes4 private constant EXEMPT_RETIRED = 0xd74df627;
    bytes4 private constant GET_DEPENDENT_COUNT = 0xbafdbeba;
    bytes4 private constant GET_DEPENDENT = 0x9816d4b9;
    bytes4 private constant UPGRADE = 0x4f1ef286;

    function testSettlementTokenConfigAbiShape() public pure {
        SettlementTokenConfig memory config;
        config.schemaVersion = 1;
        config.settlementToken = address(0xB0B);
        config.tokenDeploymentKind = TokenDeploymentKind.ERC1967_PROXY;
        config.settlementTokenDecimals = 6;
        config.implementation = address(0xCA1C);
        config.implementationCodeHash = bytes32(uint256(9));
        assertEq(abi.encode(config).length, 15 * 32);
        bytes memory callData = abi.encodeCall(ISettlementTokenRegistry.registerSettlementToken, (config));
        assertEq(abiSelector(callData), REGISTER);
        assertEq(callData.length, 4 + 15 * 32);
        assertEq(config.settlementToken, address(0xB0B));
        assertEq(config.settlementTokenDecimals, 6);
    }

    function testSettlementTokenRecordOwnsStatusAndExistence() public pure {
        SettlementTokenRecord memory record;
        record.exists = true;
        assertEq(abi.encode(record).length, 17 * 32);
    }

    function testSettlementTokenRegistryCompletePublicSelectors() public pure {
        assertEq(
            abiSelector(abi.encodeCall(ISettlementTokenRegistry.activateSettlementToken, (bytes32(0), bytes32(0)))),
            ACTIVATE
        );
        assertEq(
            abiSelector(
                abi.encodeCall(
                    ISettlementTokenRegistry.pauseSettlementToken,
                    (bytes32(0), ReasonCode.SECURITY_INCIDENT, bytes32(uint256(1)))
                )
            ),
            PAUSE
        );
        assertEq(
            abiSelector(
                abi.encodeCall(
                    ISettlementTokenRegistry.unpauseSettlementToken,
                    (bytes32(0), bytes32(0), ReasonCode.GOVERNANCE_ACTION, bytes32(uint256(1)))
                )
            ),
            UNPAUSE
        );
        assertEq(
            abiSelector(
                abi.encodeCall(
                    ISettlementTokenRegistry.deprecateSettlementToken,
                    (bytes32(0), ReasonCode.PLANNED_MIGRATION, bytes32(uint256(1)))
                )
            ),
            DEPRECATE
        );
        assertEq(
            abiSelector(abi.encodeCall(ISettlementTokenRegistry.getCurrentSettlementToken, (address(0)))), GET_CURRENT
        );
        assertEq(
            abiSelector(
                abi.encodeCall(ISettlementTokenRegistry.isSettlementTokenConfigActive, (bytes32(0), bytes32(0)))
            ),
            IS_ACTIVE
        );
        assertEq(
            abiSelector(
                abi.encodeCall(ISettlementTokenRegistry.registerDependentDvp, (address(0), bytes32(uint256(1))))
            ),
            REGISTER_DEPENDENT
        );
        assertEq(
            abiSelector(
                abi.encodeCall(ISettlementTokenRegistry.exemptRetiredDependentDvp, (address(0), bytes32(uint256(1))))
            ),
            EXEMPT_RETIRED
        );
        assertEq(abiSelector(abi.encodeCall(ISettlementTokenRegistry.getDependentDvpCount, ())), GET_DEPENDENT_COUNT);
        assertEq(abiSelector(abi.encodeCall(ISettlementTokenRegistry.getDependentDvp, (0))), GET_DEPENDENT);
        assertEq(
            abiSelector(abi.encodeCall(ISettlementTokenRegistry.upgradeToAndCall, (address(0), bytes("")))), UPGRADE
        );
        assertEq(abiSelector(abi.encodeCall(ISettlementTokenRegistry.getSettlementToken, (bytes32(0)))), GET);
    }
}
