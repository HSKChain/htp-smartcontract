// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IDvPCurrentStateValidator} from "../../src/interfaces/IDvPCurrentStateValidator.sol";
import {HTPErrors} from "../../src/types/HTPErrors.sol";
import {DvPCurrentStateValidatorFactory} from "../../src/validation/DvPCurrentStateValidatorFactory.sol";

contract DvPCurrentStateValidatorFactoryTest is Test {
    bytes32 private constant FACTORY_CODE_HASH = 0xb5516aff06a7a9f303f8b8e53314e1f1256047747d728155f4733c779c902127;
    bytes32 private constant REFERENCE_INTEGRITY_CODE_HASH =
        0x620b98f11361a4bacd813d365d250f021b27568c8094e39bdf0fd3a17a284e9c;
    bytes32 private constant STRICT_FAILURE_MAPPER_CODE_HASH =
        0xa3edd3c270dafc75bf98d1e7e53fe1e03cae42e5bbc655328f922447ae8ef583;

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
