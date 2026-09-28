// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IDvPCurrentStateValidator} from "../../src/interfaces/IDvPCurrentStateValidator.sol";
import {HTPErrors} from "../../src/types/HTPErrors.sol";
import {DvPCurrentStateValidatorFactory} from "../../src/validation/DvPCurrentStateValidatorFactory.sol";

contract DvPCurrentStateValidatorFactoryTest is Test {
    bytes32 private constant FACTORY_CODE_HASH = 0xce284db0d0ff97364fb3455f66c07ce33efa22d454b92d5a85fcc4d6a9ec32f9;
    bytes32 private constant REFERENCE_INTEGRITY_CODE_HASH =
        0xde202537a4ce39d21eb536c4d61dfca34da1ea3ac747b3a1a381a6862061cce5;
    bytes32 private constant STRICT_FAILURE_MAPPER_CODE_HASH =
        0xf5d19d60dd027bef3ab96820bd9f00cbcfe26aa8821314b5b501d42d63db60ee;

    DvPCurrentStateValidatorFactory private factory;

    function setUp() public {
        factory = new DvPCurrentStateValidatorFactory();
    }

    function testConstructorDeploysReviewedDependencies() public view {
        assertEq(address(factory).codehash, FACTORY_CODE_HASH);
        assertEq(vm.computeCreateAddress(address(factory), 1).codehash, REFERENCE_INTEGRITY_CODE_HASH);
        assertEq(vm.computeCreateAddress(address(factory), 2).codehash, STRICT_FAILURE_MAPPER_CODE_HASH);
    }

    function testDeployValidatorOnlyAllowsClaimedDvpCaller() public {
        address claimedDvp = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidChainOrContract.selector, block.chainid, claimedDvp));
        factory.deployValidator(claimedDvp);

        vm.prank(claimedDvp);
        IDvPCurrentStateValidator validator = factory.deployValidator(claimedDvp);
        assertEq(address(validator), vm.computeCreateAddress(address(factory), 3));
        assertGt(address(validator).code.length, 0);
    }

    function testDeployValidatorRejectsChangedReferenceIntegrityCode() public {
        address integrity = vm.computeCreateAddress(address(factory), 1);
        vm.etch(integrity, hex"00");

        address claimedDvp = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidDvpValidator.selector, integrity));
        vm.prank(claimedDvp);
        factory.deployValidator(claimedDvp);
    }

    function testDeployValidatorRejectsChangedStrictFailureMapperCode() public {
        address mapper = vm.computeCreateAddress(address(factory), 2);
        vm.etch(mapper, hex"00");

        address claimedDvp = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidDvpValidator.selector, mapper));
        vm.prank(claimedDvp);
        factory.deployValidator(claimedDvp);
    }
}
