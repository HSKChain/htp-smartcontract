// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IOndoBlocklist, IOndoGmToken, OndoGmTokenAdapter} from "src/adapters/OndoGmTokenAdapter.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {InterfaceVersions} from "src/interfaces/InterfaceVersions.sol";
import {
    IntegrationOndoGmToken,
    OndoComplianceMock,
    OndoComplianceViewMock,
    OndoGmListMock,
    OndoGmPauseManagerMock
} from "test/fixtures/OndoGmMocks.sol";
import {
    AdapterCapabilities,
    Decision,
    PrecheckMethod,
    RestrictionMode,
    TokenStandard,
    TransferLeg
} from "src/types/HTPTypes.sol";

contract OndoGmTokenAdapterTest is Test {
    address private constant DVP = address(0xD0);
    address private constant FROM = address(0x2000);
    address private constant TO = address(0x3000);
    uint256 private constant PROVIDER_CALL_GAS = 100_000;
    address private constant GM_IDENTIFIER = address(uint160(uint256(keccak256("global_markets"))));

    OndoGmListMock private BLOCKLIST;
    OndoGmListMock private SANCTIONS;
    OndoGmPauseManagerMock private PAUSE_MANAGER;
    OndoComplianceMock private COMPLIANCE;
    OndoComplianceViewMock private COMPLIANCE_VIEW;
    IntegrationOndoGmToken private TOKEN;
    IAssetAdapter private ADAPTER;

    function setUp() public {
        BLOCKLIST = new OndoGmListMock();
        SANCTIONS = new OndoGmListMock();
        PAUSE_MANAGER = new OndoGmPauseManagerMock();
        COMPLIANCE = new OndoComplianceMock();
        COMPLIANCE_VIEW = new OndoComplianceViewMock(address(COMPLIANCE), GM_IDENTIFIER);
        TOKEN = new IntegrationOndoGmToken(address(COMPLIANCE_VIEW), address(PAUSE_MANAGER));
        COMPLIANCE.configure(GM_IDENTIFIER, address(BLOCKLIST), address(SANCTIONS));
        ADAPTER = IAssetAdapter(
            address(new OndoGmTokenAdapter(DVP, address(TOKEN), address(TOKEN).codehash, PROVIDER_CALL_GAS))
        );
    }

    function testCompliantTransferPassesWithinDvpGasBudget() public {
        vm.prank(DVP);
        uint256 gasBefore = gasleft();
        (Decision decision, uint256 restrictionCode, bytes32 reasonHash) =
            ADAPTER.preCheck(address(TOKEN), FROM, TO, 100 ether, TransferLeg.ASSET, bytes32(uint256(0x4000)));
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("ondo_gm_precheck_gas", gasUsed);
        if (!vm.envOr("PHASE19_COVERAGE", false)) assertLt(gasUsed, 100_000);

        assertEq(uint8(decision), uint8(Decision.PASS));
        assertEq(restrictionCode, 0);
        assertEq(reasonHash, bytes32(0));
    }

    function testSameRuntimeAndProviderGraphReusesAdapter() public {
        IntegrationOndoGmToken sibling = new IntegrationOndoGmToken(address(COMPLIANCE_VIEW), address(PAUSE_MANAGER));

        (Decision decision, uint256 restrictionCode, bytes32 reasonHash) = _preCheckFor(address(sibling));

        assertEq(uint8(decision), uint8(Decision.PASS));
        assertEq(restrictionCode, 0);
        assertEq(reasonHash, bytes32(0));
    }

    function testSameRuntimeWithDifferentProviderGraphIsUnknown() public {
        OndoComplianceViewMock siblingView = new OndoComplianceViewMock(address(COMPLIANCE), GM_IDENTIFIER);
        IntegrationOndoGmToken sibling = new IntegrationOndoGmToken(address(siblingView), address(PAUSE_MANAGER));

        (Decision decision, uint256 restrictionCode, bytes32 reasonHash) = _preCheckFor(address(sibling));

        assertEq(uint8(decision), uint8(Decision.UNKNOWN));
        assertEq(restrictionCode, 0);
        assertEq(reasonHash, keccak256("HTP_ADAPTER_PROVIDER_MISMATCH"));
    }

    function testDifferentRuntimeIsUnknown() public {
        (Decision decision, uint256 restrictionCode, bytes32 reasonHash) = _preCheckFor(address(COMPLIANCE_VIEW));

        assertEq(uint8(decision), uint8(Decision.UNKNOWN));
        assertEq(restrictionCode, 0);
        assertEq(reasonHash, keccak256("HTP_ADAPTER_PROVIDER_MISMATCH"));
    }

    function testPausedTokenBlocks() public {
        PAUSE_MANAGER.setTokenPaused(address(TOKEN), true);
        _assertBlock(20, 0xaa976125737500f7f14a6a70603bed259d302347244c62ef4c20a7acee865a81);
    }

    function testFromToAndDvpRestrictionsBlock() public {
        BLOCKLIST.setBlocked(FROM, true);
        _assertBlock(21, 0x032fa7d56570a0b0829cacf6c7c72d1c8fcebae33328b0cb1dac8893e6df03fb);
        BLOCKLIST.setBlocked(FROM, false);
        SANCTIONS.setSanctioned(FROM, true);
        _assertBlock(22, 0xdf7bbce5cec559f544c60caab978f5758b4e69658d1d7a26eb9534c20b93949e);
        SANCTIONS.setSanctioned(FROM, false);

        BLOCKLIST.setBlocked(TO, true);
        _assertBlock(23, 0x503240a545c2918deacd77ca7e65c1082eaa5cfb03260279b54db88e9b6d131b);
        BLOCKLIST.setBlocked(TO, false);
        SANCTIONS.setSanctioned(TO, true);
        _assertBlock(24, 0xbbfb055bbdcf779eb9f70bf07916018b862784e95920c0fabfc3a936d5252070);
        SANCTIONS.setSanctioned(TO, false);

        BLOCKLIST.setBlocked(DVP, true);
        _assertBlock(25, 0xad1ec5bbdd9da5ac8a134b80d5acbd6e90b2b92f2aa1cb8fc3850a8da7a3c5dd);
        BLOCKLIST.setBlocked(DVP, false);
        SANCTIONS.setSanctioned(DVP, true);
        _assertBlock(26, 0xb783bb129ad32e4fc6d2165c3a2c7d800c1bce26f21bf79c5901fe8f8b3c1e47);
    }

    function testProviderGraphDriftIsUnknown() public {
        OndoGmListMock replacement = new OndoGmListMock();
        COMPLIANCE.configure(GM_IDENTIFIER, address(replacement), address(SANCTIONS));
        _assertUnknown(keccak256("HTP_ADAPTER_PROVIDER_MISMATCH"));

        COMPLIANCE.configure(GM_IDENTIFIER, address(BLOCKLIST), address(SANCTIONS));
        OndoComplianceViewMock replacementView = new OndoComplianceViewMock(address(COMPLIANCE), GM_IDENTIFIER);
        TOKEN.configureProviders(address(replacementView), address(PAUSE_MANAGER));
        _assertUnknown(keccak256("HTP_ADAPTER_PROVIDER_MISMATCH"));
    }

    function testProviderCodeHashDriftIsUnknown() public {
        vm.etch(address(BLOCKLIST), hex"60006000fd");
        _assertUnknown(keccak256("HTP_ADAPTER_PROVIDER_MISMATCH"));
    }

    function testMalformedProviderResponseIsUnknown() public {
        bytes memory blockedCall = abi.encodeCall(IOndoBlocklist.isBlocked, (FROM));
        vm.mockCall(address(BLOCKLIST), blockedCall, hex"00");
        _assertUnknown(keccak256("HTP_ADAPTER_EXTERNAL_CALL_FAILED"));
        vm.clearMockedCalls();

        bytes memory complianceCall = abi.encodeCall(IOndoGmToken.compliance, ());
        vm.mockCallRevert(address(TOKEN), complianceCall, hex"dead");
        _assertUnknown(keccak256("HTP_ADAPTER_EXTERNAL_CALL_FAILED"));
    }

    function testProviderGasExhaustionIsUnknown() public {
        BLOCKLIST.setExhaustGas(true);
        _assertUnknown(keccak256("HTP_ADAPTER_EXTERNAL_CALL_FAILED"));
    }

    function testCapabilitiesDeclareOnlyTokenSpecificErc20AssetChecks() public view {
        AdapterCapabilities memory capabilities = ADAPTER.capabilities();
        assertEq(ADAPTER.interfaceVersion(), InterfaceVersions.ASSET_ADAPTER_V1);
        assertEq(uint8(capabilities.tokenStandard), uint8(TokenStandard.ERC20));
        assertEq(uint8(capabilities.restrictionMode), uint8(RestrictionMode.TOKEN_ENFORCED));
        assertEq(uint8(capabilities.precheckMethod), uint8(PrecheckMethod.TOKEN_SPECIFIC_CHECK));
        assertEq(capabilities.transferLegMask, uint256(1) << uint8(TransferLeg.ASSET));
        assertEq(ADAPTER.capabilityHash(), 0x63df51d7ce7afbc051e26124274639b57b65a7c685c4f186fda9027d53ca630d);
        assertNotEq(ADAPTER.providerHash(), bytes32(0));
    }

    function testConstructorRejectsWrongGmIdentifier() public {
        COMPLIANCE_VIEW.configure(address(COMPLIANCE), address(0xBAD));
        vm.expectRevert();
        new OndoGmTokenAdapter(DVP, address(TOKEN), address(TOKEN).codehash, PROVIDER_CALL_GAS);
    }

    function testConstructorRejectsFundedAddressWithoutCodeAsProvider() public {
        address noCodeProvider = address(0xBEEF);
        vm.deal(noCodeProvider, 1 ether);
        COMPLIANCE.configure(GM_IDENTIFIER, noCodeProvider, address(SANCTIONS));

        vm.expectRevert(abi.encodeWithSelector(OndoGmTokenAdapter.InvalidOndoGmProvider.selector, noCodeProvider));
        new OndoGmTokenAdapter(DVP, address(TOKEN), address(TOKEN).codehash, PROVIDER_CALL_GAS);
    }

    function testConstructorRejectsInvalidTokenHashOrProviderGas() public {
        vm.expectRevert();
        new OndoGmTokenAdapter(DVP, address(TOKEN), bytes32(uint256(1)), PROVIDER_CALL_GAS);

        vm.expectRevert();
        new OndoGmTokenAdapter(DVP, address(TOKEN), address(TOKEN).codehash, PROVIDER_CALL_GAS + 1);
    }

    function testUnapprovedCallerIsRejectedBeforeProviderCalls() public view {
        (Decision decision, uint256 restrictionCode, bytes32 reasonHash) =
            ADAPTER.preCheck(address(TOKEN), FROM, TO, 100 ether, TransferLeg.ASSET, bytes32(uint256(0x4000)));
        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(restrictionCode, 2);
        assertEq(reasonHash, keccak256("HTP_ADAPTER_UNAPPROVED_CALLER"));
    }

    function _assertBlock(uint256 expectedCode, bytes32 expectedReason) private {
        (Decision decision, uint256 restrictionCode, bytes32 reasonHash) = _preCheck();
        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(restrictionCode, expectedCode);
        assertEq(reasonHash, expectedReason);
    }

    function _assertUnknown(bytes32 expectedReason) private {
        (Decision decision, uint256 restrictionCode, bytes32 reasonHash) = _preCheck();
        assertEq(uint8(decision), uint8(Decision.UNKNOWN));
        assertEq(restrictionCode, 0);
        assertEq(reasonHash, expectedReason);
    }

    function _preCheck() private returns (Decision decision, uint256 restrictionCode, bytes32 reasonHash) {
        return _preCheckFor(address(TOKEN));
    }

    function _preCheckFor(address token)
        private
        returns (Decision decision, uint256 restrictionCode, bytes32 reasonHash)
    {
        vm.prank(DVP);
        return ADAPTER.preCheck(token, FROM, TO, 100 ether, TransferLeg.ASSET, bytes32(uint256(0x4000)));
    }
}
