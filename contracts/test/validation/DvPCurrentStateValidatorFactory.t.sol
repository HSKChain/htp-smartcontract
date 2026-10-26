// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IDvPCurrentStateValidator} from "../../src/interfaces/IDvPCurrentStateValidator.sol";
import {HTPErrors} from "../../src/types/HTPErrors.sol";
import {DvPCurrentStateValidatorFactory} from "../../src/validation/DvPCurrentStateValidatorFactory.sol";

contract DvPCurrentStateValidatorFactoryTest is Test {
    bytes32 private constant FACTORY_CODE_HASH = 0x890fee98fba1a49d554379f71bf4711d00d0caf2e46974ec9a428c6d9d43f17b;
    bytes32 private constant REFERENCE_INTEGRITY_CODE_HASH =
        0x114181354ab1dd58bcb5cde1665da547d659d177215e42cfacaa8f1eeb1608bf;
    bytes32 private constant STRICT_FAILURE_MAPPER_CODE_HASH =
        0x8b5e04167aa4e9ff9669108e0423144f56f57cc988c3b134b73fe53307a88a4e;

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
