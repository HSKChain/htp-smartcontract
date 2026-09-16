// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {AddressListMock} from "test/fixtures/AdapterMocks.sol";
import {OfficialUsdyBehaviorMock} from "test/fixtures/OfficialUsdyBehaviorMock.sol";

contract OfficialUsdyBehaviorMockTest is Test {
    address private constant FROM = address(0x2000);
    address private constant TO = address(0x3000);
    address private constant OPERATOR = address(0x4000);
    address private constant OUTSIDER = address(0xBAD);

    AddressListMock internal blocklist;
    AddressListMock internal allowlist;
    AddressListMock internal sanctions;
    OfficialUsdyBehaviorMock internal token;
    address internal implementation;

    function setUp() public {
        blocklist = new AddressListMock();
        allowlist = new AddressListMock();
        sanctions = new AddressListMock();
        OfficialUsdyBehaviorMock impl = new OfficialUsdyBehaviorMock();
        implementation = address(impl);
        token = OfficialUsdyBehaviorMock(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        OfficialUsdyBehaviorMock.initialize,
                        (address(blocklist), address(allowlist), address(sanctions))
                    )
                )
            )
        );
        allowlist.setAllowed(FROM, true);
        allowlist.setAllowed(TO, true);
        allowlist.setAllowed(OPERATOR, true);
        token.mint(FROM, 10 ether);
        vm.prank(FROM);
        token.approve(OPERATOR, 10 ether);
    }

    function testProxyInitializationExposesProvidersDecimalsAndAdmin() public view {
        assertEq(token.decimals(), 18);
        assertEq(token.admin(), address(this));
        assertEq(token.blocklist(), address(blocklist));
        assertEq(token.allowlist(), address(allowlist));
        assertEq(token.sanctionsList(), address(sanctions));
        assertEq(token.implementationAddress(), implementation);
        assertFalse(token.paused());
    }

    function testApprovedOperatorTransferFromSucceeds() public {
        vm.prank(OPERATOR);
        bool ok = token.transferFrom(FROM, TO, 1 ether);

        assertTrue(ok);
        assertEq(token.balanceOf(FROM), 9 ether);
        assertEq(token.balanceOf(TO), 1 ether);
        assertEq(token.allowance(FROM, OPERATOR), 9 ether);
    }

    function testNonAdminCannotMintPauseOrConfigureProviders() public {
        vm.startPrank(OUTSIDER);
        vm.expectRevert(bytes("NOT_ADMIN"));
        token.mint(OUTSIDER, 1 ether);
        vm.expectRevert(bytes("NOT_ADMIN"));
        token.setPaused(true);
        vm.expectRevert(bytes("NOT_ADMIN"));
        token.configureProviders(address(1), address(2), address(3));
        vm.stopPrank();

        assertEq(token.balanceOf(OUTSIDER), 0);
        assertFalse(token.paused());
        assertEq(token.blocklist(), address(blocklist));
    }

    function testPausedTransferFromLeavesBalancesUnchanged() public {
        token.setPaused(true);

        vm.expectRevert(bytes("USDY: paused"));
        vm.prank(OPERATOR);
        token.transferFrom(FROM, TO, 1 ether);

        assertEq(token.balanceOf(FROM), 10 ether);
        assertEq(token.balanceOf(TO), 0);
        assertEq(token.allowance(FROM, OPERATOR), 10 ether);
    }

    function testBlockedFromCannotTransferFrom() public {
        _assertRestricted(FROM, 0, "USDY: 'from' address blocked");
    }

    function testSanctionedFromCannotTransferFrom() public {
        _assertRestricted(FROM, 1, "USDY: 'from' address sanctioned");
    }

    function testNotAllowedFromCannotTransferFrom() public {
        _assertRestricted(FROM, 2, "USDY: 'from' address not on allowlist");
    }

    function testBlockedToCannotTransferFrom() public {
        _assertRestricted(TO, 0, "USDY: 'to' address blocked");
    }

    function testSanctionedToCannotTransferFrom() public {
        _assertRestricted(TO, 1, "USDY: 'to' address sanctioned");
    }

    function testNotAllowedToCannotTransferFrom() public {
        _assertRestricted(TO, 2, "USDY: 'to' address not on allowlist");
    }

    function testBlockedOperatorCannotTransferFrom() public {
        _assertRestricted(OPERATOR, 0, "USDY: 'sender' address blocked");
    }

    function testSanctionedOperatorCannotTransferFrom() public {
        _assertRestricted(OPERATOR, 1, "USDY: 'sender' address sanctioned");
    }

    function testNotAllowedOperatorCannotTransferFrom() public {
        _assertRestricted(OPERATOR, 2, "USDY: 'sender' address not on allowlist");
    }

    function testCompoundRestrictionPrefersBlockedThenSanctionedThenAllowlist() public {
        blocklist.setBlocked(FROM, true);
        sanctions.setSanctioned(FROM, true);
        allowlist.setAllowed(FROM, false);
        vm.expectRevert(bytes("USDY: 'from' address blocked"));
        vm.prank(OPERATOR);
        token.transferFrom(FROM, TO, 1 ether);

        blocklist.setBlocked(FROM, false);
        vm.expectRevert(bytes("USDY: 'from' address sanctioned"));
        vm.prank(OPERATOR);
        token.transferFrom(FROM, TO, 1 ether);

        sanctions.setSanctioned(FROM, false);
        vm.expectRevert(bytes("USDY: 'from' address not on allowlist"));
        vm.prank(OPERATOR);
        token.transferFrom(FROM, TO, 1 ether);

        assertEq(token.balanceOf(FROM), 10 ether);
        assertEq(token.allowance(FROM, OPERATOR), 10 ether);
    }

    function testPermitIsUnsupportedAndDoesNotGrantAllowance() public {
        vm.prank(FROM);
        token.approve(OPERATOR, 0);

        vm.expectRevert(bytes("USDY: permit unsupported"));
        token.permit(FROM, OPERATOR, 1 ether, type(uint256).max, 27, bytes32(uint256(1)), bytes32(uint256(2)));

        assertEq(token.allowance(FROM, OPERATOR), 0);
    }

    function _assertRestricted(address target, uint8 kind, string memory reason) private {
        if (kind == 0) {
            blocklist.setBlocked(target, true);
        } else if (kind == 1) {
            sanctions.setSanctioned(target, true);
        } else {
            allowlist.setAllowed(target, false);
        }

        vm.expectRevert(bytes(reason));
        vm.prank(OPERATOR);
        token.transferFrom(FROM, TO, 1 ether);

        assertEq(token.balanceOf(FROM), 10 ether);
        assertEq(token.balanceOf(TO), 0);
        assertEq(token.allowance(FROM, OPERATOR), 10 ether);
    }
}
