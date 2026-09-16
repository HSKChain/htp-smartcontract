// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {DvPRegistries, DvPRoles, DvPSettlement} from "src/DvPSettlement.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {DvPCurrentStateValidatorFactory} from "src/validation/DvPCurrentStateValidatorFactory.sol";

contract MockRegistry {}

contract DvPConstructorTest is Test {
    address private constant GOVERNANCE = address(0x1001);
    address private constant PAUSER = address(0x2001);
    address private constant EXECUTOR = address(0x3001);
    uint256 private constant DEPLOYED_CHAIN_ID = 31_337;
    bytes32 private constant DEPLOYMENT_VERSION_HASH =
        0x51c5fe1d20ac02d40c1a23e4c9231429cf03867d0158f3cb9ecc7277cb8cef42;

    address[7] private registries;
    DvPCurrentStateValidatorFactory private currentStateValidatorFactory;

    function setUp() public {
        vm.chainId(DEPLOYED_CHAIN_ID);
        for (uint256 i; i < registries.length; ++i) {
            registries[i] = address(new MockRegistry());
        }
        currentStateValidatorFactory = new DvPCurrentStateValidatorFactory();
    }

    function testConstructorFixesValidatedRegistriesChainAndDeploymentVersion() public {
        DvPSettlement dvp = _deploy(registries, DEPLOYED_CHAIN_ID, bytes("1.2.3"));

        assertEq(address(dvp.participantRegistry()), registries[0]);
        assertEq(address(dvp.assetVersionRegistry()), registries[1]);
        assertEq(address(dvp.eligibilityRegistry()), registries[2]);
        assertEq(address(dvp.feeRegistry()), registries[3]);
        assertEq(address(dvp.marketRuleRegistry()), registries[3]);
        assertEq(address(dvp.settlementTokenRegistry()), registries[4]);
        assertEq(address(dvp.adapterRegistry()), registries[5]);
        assertEq(address(dvp.principalCalculatorRegistry()), registries[6]);
        assertEq(dvp.deploymentVersionHash(), DEPLOYMENT_VERSION_HASH);
        assertTrue(dvp.domainSeparatorV4() != bytes32(0));
        assertFalse(dvp.globalPaused());
        assertFalse(dvp.retired());
    }

    function testValidatorConstructorErrorSelectorsMatchReviewedLiterals() public pure {
        assertEq(bytes32(HTPErrors.InvalidDvpValidatorFactory.selector), bytes32(bytes4(0x306abad9)));
        assertEq(bytes32(HTPErrors.InvalidDvpValidator.selector), bytes32(bytes4(0x71eb0836)));
    }

    function testValidatorFactoryCodeHashMatchesReviewedLiteral() public view {
        assertEq(
            address(currentStateValidatorFactory).codehash,
            0xb5516aff06a7a9f303f8b8e53314e1f1256047747d728155f4733c779c902127
        );
    }

    function testReferenceIntegrityCodeHashMatchesReviewedLiteral() public view {
        assertEq(
            vm.computeCreateAddress(address(currentStateValidatorFactory), 1).codehash,
            0x620b98f11361a4bacd813d365d250f021b27568c8094e39bdf0fd3a17a284e9c
        );
    }

    function testStrictFailureMapperCodeHashMatchesReviewedLiteral() public view {
        assertEq(
            vm.computeCreateAddress(address(currentStateValidatorFactory), 2).codehash,
            0xa3edd3c270dafc75bf98d1e7e53fe1e03cae42e5bbc655328f922447ae8ef583
        );
    }

    function testConstructorRejectsEveryInvalidRegistryAddress() public {
        for (uint256 i; i < registries.length; ++i) {
            address[7] memory invalid = registries;
            invalid[i] = address(0);
            vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidDvpRegistry.selector, address(0)));
            _deploy(invalid, DEPLOYED_CHAIN_ID, bytes("1.2.3"));
        }

        address[7] memory noCode = registries;
        noCode[6] = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidDvpRegistry.selector, address(0xBEEF)));
        _deploy(noCode, DEPLOYED_CHAIN_ID, bytes("1.2.3"));
    }

    function testConstructorRejectsWrongChainAndNonCanonicalDeploymentVersion() public {
        vm.expectPartialRevert(HTPErrors.InvalidChainOrContract.selector);
        _deploy(registries, DEPLOYED_CHAIN_ID + 1, bytes("1.2.3"));

        vm.expectRevert(HTPErrors.InvalidDeploymentVersion.selector);
        _deploy(registries, DEPLOYED_CHAIN_ID, bytes("v1.2.3"));
    }

    function testConstructorRejectsInvalidValidatorFactory() public {
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidDvpValidatorFactory.selector, address(0)));
        _deployWithFactory(registries, DEPLOYED_CHAIN_ID, bytes("1.2.3"), address(0));

        address nonFactory = address(new MockRegistry());
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidDvpValidatorFactory.selector, nonFactory));
        _deployWithFactory(registries, DEPLOYED_CHAIN_ID, bytes("1.2.3"), nonFactory);
    }

    function testValidatorFactoryRejectsNonDvpCaller() public {
        address claimedDvp = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidChainOrContract.selector, block.chainid, claimedDvp));
        currentStateValidatorFactory.deployValidator(claimedDvp);
    }

    function testValidatorFactoryRejectsChangedStrictFailureMapperCode() public {
        address mapper = vm.computeCreateAddress(address(currentStateValidatorFactory), 2);
        vm.etch(mapper, hex"00");

        address claimedDvp = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidDvpValidator.selector, mapper));
        vm.prank(claimedDvp);
        currentStateValidatorFactory.deployValidator(claimedDvp);
    }

    function _deploy(address[7] memory registryAddresses, uint256 chainId, bytes memory deploymentVersion)
        private
        returns (DvPSettlement)
    {
        return _deployWithFactory(registryAddresses, chainId, deploymentVersion, address(currentStateValidatorFactory));
    }

    function _deployWithFactory(
        address[7] memory registryAddresses,
        uint256 chainId,
        bytes memory deploymentVersion,
        address factory
    ) private returns (DvPSettlement) {
        DvPRoles memory roles = DvPRoles({
            defaultAdmin: GOVERNANCE, governance: GOVERNANCE, pauser: PAUSER, executor: EXECUTOR
        });
        DvPRegistries memory dependencies = DvPRegistries({
            participant: registryAddresses[0],
            assetVersion: registryAddresses[1],
            eligibility: registryAddresses[2],
            fee: registryAddresses[3],
            marketRule: registryAddresses[3],
            settlementToken: registryAddresses[4],
            adapter: registryAddresses[5],
            principalCalculator: registryAddresses[6]
        });
        return new DvPSettlement(roles, dependencies, chainId, deploymentVersion, factory);
    }
}
