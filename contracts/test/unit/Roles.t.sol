// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Roles} from "src/libraries/Roles.sol";

contract RolesTest is Test {
    function testRoleHashesMatchReviewedLiterals() public pure {
        assertEq(Roles.DEFAULT_ADMIN_ROLE, bytes32(0));
        assertEq(Roles.GOVERNANCE_ROLE, 0x71840dc4906352362b0cdaf79870196c8e42acafade72d5d5a6d59291253ceb1);
        assertEq(Roles.UPGRADER_ROLE, 0x189ab7a9244df0848122154315af71fe140f3db0fe014031783b0946b8c9d2e3);
        assertEq(Roles.PAUSER_ROLE, 0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a);
        assertEq(Roles.EXECUTOR_ROLE, 0xd8aa0f3194971a2a116679f7c2090f6939c8d4e01a2a8d7e41d55e5351469e63);
        assertEq(Roles.CONFIGURER_ROLE, keccak256(bytes("CONFIGURER_ROLE")));
    }

    // 八个旧 Configurer 角色已合并为唯一 CONFIGURER_ROLE。
    // 这里钉死旧角色的 keccak 值，确保它们不会被误当作新角色复活。
    function testRetiredPerRegistryRolesAreNotTheConfigurerRole() public pure {
        bytes32[8] memory retired = [
            keccak256(bytes("PARTICIPANT_CONFIG_ROLE")),
            keccak256(bytes("ASSET_CONFIG_ROLE")),
            keccak256(bytes("ELIGIBILITY_UPDATER_ROLE")),
            keccak256(bytes("FEE_CONFIG_ROLE")),
            keccak256(bytes("SETTLEMENT_TOKEN_CONFIG_ROLE")),
            keccak256(bytes("ADAPTER_CONFIG_ROLE")),
            keccak256(bytes("PRINCIPAL_CALCULATOR_CONFIG_ROLE")),
            keccak256(bytes("MARKET_RULE_CONFIG_ROLE"))
        ];
        for (uint256 i = 0; i < retired.length; ++i) {
            assertTrue(retired[i] != Roles.CONFIGURER_ROLE);
        }
    }
}
