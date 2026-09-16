// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IAssetVersionRegistry} from "src/interfaces/IAssetVersionRegistry.sol";
import {AssetVersionConfig, AssetVersionRecord, ReasonCode, TokenDeploymentKind} from "src/types/HTPTypes.sol";
import {abiSelector} from "test/helpers/AbiAssertions.sol";

contract AssetVersionConfigAbiTest is Test {
    bytes4 private constant REGISTER = 0x75ed60b2;
    bytes4 private constant ACTIVATE = 0x83cb3114;
    bytes4 private constant PAUSE = 0xac8b9de3;
    bytes4 private constant UNPAUSE = 0xa5974673;
    bytes4 private constant DEPRECATE = 0xb8f75284;
    bytes4 private constant GET = 0xfc144a72;
    bytes4 private constant GET_CURRENT = 0xdd2cf8a0;
    bytes4 private constant GET_ECONOMIC_ASSET_ID = 0x545ac5e8;
    bytes4 private constant REGISTER_DEPENDENT = 0x03f8d147;
    bytes4 private constant EXEMPT_RETIRED = 0xd74df627;
    bytes4 private constant GET_DEPENDENT_COUNT = 0xbafdbeba;
    bytes4 private constant GET_DEPENDENT = 0x9816d4b9;
    bytes4 private constant UPGRADE = 0x4f1ef286;

    function testAssetVersionConfigAbiShape() public pure {
        AssetVersionConfig memory config;
        config.schemaVersion = 1;
        config.tokenDeploymentKind = TokenDeploymentKind.DIRECT;
        config.tokenCodeHash = bytes32(uint256(9));
        config.implementation = address(0);
        config.implementationCodeHash = bytes32(0);
        config.settlementToken = address(0xB0B);
        assertEq(abi.encode(config).length, 26 * 32);
        bytes memory callData = abi.encodeCall(IAssetVersionRegistry.registerAssetVersion, (config));
        assertEq(abiSelector(callData), REGISTER);
        assertEq(callData.length, 4 + 26 * 32);
        assertEq(uint8(config.tokenDeploymentKind), uint8(TokenDeploymentKind.DIRECT));
        assertEq(config.implementation, address(0));
        assertEq(config.implementationCodeHash, bytes32(0));
        assertEq(config.settlementToken, address(0xB0B));
    }

    function testAssetVersionRecordOwnsStatusAndExistence() public pure {
        AssetVersionRecord memory record;
        record.exists = true;
        assertTrue(record.exists);
        assertEq(abi.encode(record).length, 28 * 32);
    }

    function testProxyShapeCarriesImplementationBaseline() public pure {
        AssetVersionConfig memory config;
        config.tokenDeploymentKind = TokenDeploymentKind.ERC1967_PROXY;
        config.tokenCodeHash = bytes32(uint256(1));
        config.implementation = address(0xCA1C);
        config.implementationCodeHash = bytes32(uint256(3));
        assertEq(config.implementation, address(0xCA1C));
        assertTrue(config.tokenCodeHash != bytes32(0));
        assertTrue(config.implementationCodeHash != bytes32(0));
    }

    function testAssetVersionRegistryCompletePublicSelectors() public pure {
        assertEq(
            abiSelector(abi.encodeCall(IAssetVersionRegistry.activateAssetVersion, (bytes32(0), bytes32(0)))), ACTIVATE
        );
        assertEq(
            abiSelector(
                abi.encodeCall(
                    IAssetVersionRegistry.pauseAssetVersion,
                    (bytes32(0), ReasonCode.SECURITY_INCIDENT, bytes32(uint256(1)))
                )
            ),
            PAUSE
        );
        assertEq(
            abiSelector(
                abi.encodeCall(
                    IAssetVersionRegistry.unpauseAssetVersion,
                    (bytes32(0), bytes32(0), ReasonCode.GOVERNANCE_ACTION, bytes32(uint256(1)))
                )
            ),
            UNPAUSE
        );
        assertEq(
            abiSelector(
                abi.encodeCall(
                    IAssetVersionRegistry.deprecateAssetVersion,
                    (bytes32(0), ReasonCode.PLANNED_MIGRATION, bytes32(uint256(1)))
                )
            ),
            DEPRECATE
        );
        assertEq(abiSelector(abi.encodeCall(IAssetVersionRegistry.getCurrentAssetVersion, (address(0)))), GET_CURRENT);
        assertEq(
            abiSelector(abi.encodeCall(IAssetVersionRegistry.getEconomicAssetIdHash, (address(0)))),
            GET_ECONOMIC_ASSET_ID
        );
        assertEq(
            abiSelector(abi.encodeCall(IAssetVersionRegistry.registerDependentDvp, (address(0), bytes32(uint256(1))))),
            REGISTER_DEPENDENT
        );
        assertEq(
            abiSelector(
                abi.encodeCall(IAssetVersionRegistry.exemptRetiredDependentDvp, (address(0), bytes32(uint256(1))))
            ),
            EXEMPT_RETIRED
        );
        assertEq(abiSelector(abi.encodeCall(IAssetVersionRegistry.getDependentDvpCount, ())), GET_DEPENDENT_COUNT);
        assertEq(abiSelector(abi.encodeCall(IAssetVersionRegistry.getDependentDvp, (0))), GET_DEPENDENT);
        assertEq(abiSelector(abi.encodeCall(IAssetVersionRegistry.upgradeToAndCall, (address(0), bytes("")))), UPGRADE);
        assertEq(abiSelector(abi.encodeCall(IAssetVersionRegistry.getAssetVersion, (bytes32(0)))), GET);
    }
}
