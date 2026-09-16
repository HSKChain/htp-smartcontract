// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {UUPSRegistryBase} from "../../src/registry/UUPSRegistryBase.sol";
import {MockDvP} from "../fixtures/MockDvP.sol";

abstract contract RegistryTestBase is Test {
    error EmptyInitializationData();

    uint256 internal constant TIMELOCK_DELAY = 1 days;
    address internal constant GOVERNANCE = address(0x1001);
    bytes32 internal constant UPGRADE_GATE_EVIDENCE = bytes32(uint256(0x11FE));
    bytes32 internal constant DEPLOYMENT_VERSION_HASH =
        0x51c5fe1d20ac02d40c1a23e4c9231429cf03867d0158f3cb9ecc7277cb8cef42;

    TimelockController internal timelock;
    MockDvP internal dependentDvp;

    function setUp() public virtual {
        address[] memory proposers = new address[](1);
        proposers[0] = GOVERNANCE;
        address[] memory executors = new address[](1);
        executors[0] = GOVERNANCE;

        timelock = new TimelockController(TIMELOCK_DELAY, proposers, executors, address(0));
        dependentDvp = new MockDvP(DEPLOYMENT_VERSION_HASH);
    }

    function _deployProxy(address implementation, bytes memory initializationData) internal returns (address proxy) {
        if (initializationData.length == 0) revert EmptyInitializationData();
        proxy = address(new ERC1967Proxy(implementation, initializationData));
    }

    // 升级门禁对空依赖集合 fail-closed。凡是把「升级后的行为」当作被测对象的用例，
    // 都要先登记一台已暂停的依赖 DvP，让升级本身成为一个合法的前置步骤。
    function _satisfyUpgradeGate(address registry) internal {
        dependentDvp.setGlobalPaused(true);
        vm.prank(address(timelock));
        UUPSRegistryBase(registry).registerDependentDvp(address(dependentDvp), UPGRADE_GATE_EVIDENCE);
    }
}
