// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UsdyRestrictedAdapter} from "src/adapters/UsdyRestrictedAdapter.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {PermitData, SettlementParams, TransferLeg} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

// Minimal USDY-shaped token implementation deployed behind an ERC1967 proxy, to model
// the production deployment kind (TokenDeploymentKind.ERC1967_PROXY).
contract AuditUsdyImpl {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool internal pausedValue;
    address internal blocklistValue;
    address internal allowlistValue;
    address internal sanctionsListValue;

    function initialize(address b, address a, address s) external {
        blocklistValue = b;
        allowlistValue = a;
        sanctionsListValue = s;
    }

    function paused() external view returns (bool) {
        return pausedValue;
    }

    function blocklist() external view returns (address) {
        return blocklistValue;
    }

    function allowlist() external view returns (address) {
        return allowlistValue;
    }

    function sanctionsList() external view returns (address) {
        return sanctionsListValue;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

// Restriction-list implementation behind a proxy. `extraSlots` models real-world lists
// that read more than one storage slot per query (status structs, role checks, versioned
// entries), which is how Ondo-style allow/block lists are actually built.
contract AuditListImpl {
    mapping(address => bool) internal flags;
    uint256 internal extraSlots;
    mapping(uint256 => uint256) internal padding;

    function set(address account, bool value) external {
        flags[account] = value;
    }

    function setExtraSlots(uint256 count) external {
        extraSlots = count;
    }

    function _touchExtra(address account) internal view returns (uint256 acc) {
        uint256 n = extraSlots;
        for (uint256 i; i < n; ++i) {
            acc += padding[uint256(uint160(account)) + i];
        }
    }

    function isBlocked(address account) external view returns (bool) {
        return flags[account] || _touchExtra(account) == 1;
    }

    function isAllowed(address account) external view returns (bool) {
        return flags[account] || _touchExtra(account) == 1;
    }

    function isSanctioned(address account) external view returns (bool) {
        return flags[account] || _touchExtra(account) == 1;
    }
}

contract TmpAuditModuleATest is DvPPreCheckTestBase {
    AuditPermitToken internal permitToken;

    function setUp() public virtual override {
        super.setUp();
        _prepareColdStack();
        permitToken = new AuditPermitToken();
    }

    // ---------------------------------------------------------------
    // Point 1: is permit.value forced to equal the exact leg amount?
    // ---------------------------------------------------------------

    function testPermitValueMustBeExact_MaxUintRejected() public {
        SettlementParams memory params = _validPreCheckParams();
        settlementToken.setAllowance(params.snapshot.buyer, address(dvp), 0);
        params.settlementPermit = PermitData({
            usePermit: true,
            owner: params.snapshot.buyer,
            token: params.snapshot.settlementToken,
            value: type(uint256).max, // attacker/Executor tries to leave residual allowance
            deadline: params.snapshot.tradeDeadline,
            v: 27,
            r: bytes32(uint256(1)),
            s: bytes32(uint256(2))
        });
        vm.prank(EXECUTOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.PermitFieldMismatch.selector, params.snapshot.settlementToken, bytes32("value")
            )
        );
        dvp.settle(params);
    }

    function testPermitDeadlineMustEqualTradeDeadline() public {
        SettlementParams memory params = _validPreCheckParams();
        settlementToken.setAllowance(params.snapshot.buyer, address(dvp), 0);
        params.settlementPermit = PermitData({
            usePermit: true,
            owner: params.snapshot.buyer,
            token: params.snapshot.settlementToken,
            value: params.snapshot.buyerDebit,
            deadline: uint256(params.snapshot.tradeDeadline) + 1,
            v: 27,
            r: bytes32(uint256(1)),
            s: bytes32(uint256(2))
        });
        vm.prank(EXECUTOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.PermitFieldMismatch.selector, params.snapshot.settlementToken, bytes32("deadline")
            )
        );
        dvp.settle(params);
    }

    // After a permit-funded settlement, zero allowance must remain parked on the DvP.
    function testNoResidualAllowanceAfterPermitSettlement() public {
        SettlementParams memory params = _validPreCheckParams();
        assetToken.setAllowance(params.snapshot.seller, address(dvp), 0);
        settlementToken.setAllowance(params.snapshot.buyer, address(dvp), 0);
        params.assetPermit = PermitData({
            usePermit: true,
            owner: params.snapshot.seller,
            token: params.snapshot.assetToken,
            value: params.snapshot.executedQuantity,
            deadline: params.snapshot.tradeDeadline,
            v: 27,
            r: bytes32(uint256(1)),
            s: bytes32(uint256(2))
        });
        params.settlementPermit = PermitData({
            usePermit: true,
            owner: params.snapshot.buyer,
            token: params.snapshot.settlementToken,
            value: params.snapshot.buyerDebit,
            deadline: params.snapshot.tradeDeadline,
            v: 28,
            r: bytes32(uint256(3)),
            s: bytes32(uint256(4))
        });

        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertEq(assetToken.allowance(params.snapshot.seller, address(dvp)), 0, "asset residual allowance");
        assertEq(settlementToken.allowance(params.snapshot.buyer, address(dvp)), 0, "settlement residual allowance");
        assertEq(
            params.snapshot.buyerDebit,
            params.snapshot.sellerCredit + params.snapshot.collectorCredit,
            "cash conservation"
        );
    }

    // preCheck vs settle divergence: a permit-funded trade that settle() executes
    // successfully is reported by preCheck() as UNKNOWN, which the design tells every
    // caller to treat as failure.
    function testPreCheckReportsUnknownForTradeThatSettleAccepts() public {
        SettlementParams memory params = _validPreCheckParams();
        assetToken.setAllowance(params.snapshot.seller, address(dvp), 0);
        params.assetPermit = PermitData({
            usePermit: true,
            owner: params.snapshot.seller,
            token: params.snapshot.assetToken,
            value: params.snapshot.executedQuantity,
            deadline: params.snapshot.tradeDeadline,
            v: 27,
            r: bytes32(uint256(1)),
            s: bytes32(uint256(2))
        });

        (uint8 decision, bytes4 reason) = _preCheck(params);
        emit log_named_uint("preCheck decision (1=PASS,2=BLOCK,3=UNKNOWN)", decision);
        emit log_named_bytes32("preCheck reason selector", bytes32(reason));
        assertEq(decision, 3, "expected UNKNOWN from preCheck");
        assertEq(reason, HTPErrors.PermitSimulationRequired.selector, "expected PermitSimulationRequired");

        // Same params, same block, same state: settle succeeds.
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertEq(assetToken.balanceOf(params.snapshot.buyer), params.snapshot.executedQuantity);
    }

    function _preCheck(SettlementParams memory params) private view returns (uint8, bytes4) {
        (bool ok, bytes memory out) = address(dvp).staticcall(abi.encodeCall(dvp.preCheck, (params)));
        require(ok, "preCheck reverted");
        (uint8 d, bytes4 r) = abi.decode(out, (uint8, bytes4));
        return (d, r);
    }

    // ---------------------------------------------------------------
    // Point 2: address-collision scenarios around the 7 delta observations
    // ---------------------------------------------------------------

    function testBuyerEqualsSellerRejected() public {
        SettlementParams memory params = _validPreCheckParams();
        address maker = params.snapshot.quotingMaker;
        params.firmQuote.requester = maker;
        params.tradeIntent.requester = maker;
        params.snapshot.requester = maker;
        params.tradeIntent.buyer = maker;
        params.snapshot.buyer = maker;
        _resign(params);
        vm.prank(EXECUTOR);
        vm.expectRevert();
        dvp.settle(params);
    }

    function testCollectorEqualsBuyerRejected() public {
        SettlementParams memory params = _validPreCheckParams();
        params.tradeIntent.collector = params.snapshot.buyer;
        params.snapshot.collector = params.snapshot.buyer;
        _resign(params);
        vm.prank(EXECUTOR);
        vm.expectRevert();
        dvp.settle(params);
    }

    function testCollectorEqualsSellerRejected() public {
        SettlementParams memory params = _validPreCheckParams();
        params.tradeIntent.collector = params.snapshot.seller;
        params.snapshot.collector = params.snapshot.seller;
        _resign(params);
        vm.prank(EXECUTOR);
        vm.expectRevert();
        dvp.settle(params);
    }

    function testCollectorEqualsDvpRejected() public {
        SettlementParams memory params = _validPreCheckParams();
        params.tradeIntent.collector = address(dvp);
        params.snapshot.collector = address(dvp);
        _resign(params);
        vm.prank(EXECUTOR);
        vm.expectRevert();
        dvp.settle(params);
    }

    // ---------------------------------------------------------------
    // Point 6: preCheck raw calldata forwarding with trailing garbage
    // ---------------------------------------------------------------

    function testPreCheckToleratesTrailingCalldata() public view {
        SettlementParams memory params = _validPreCheckParams();
        bytes memory clean = abi.encodeCall(dvp.preCheck, (params));
        bytes memory dirty = bytes.concat(clean, hex"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef");

        (bool okClean, bytes memory outClean) = address(dvp).staticcall(clean);
        (bool okDirty, bytes memory outDirty) = address(dvp).staticcall(dirty);
        assertTrue(okClean, "clean preCheck reverted");
        assertTrue(okDirty, "dirty preCheck reverted");
        assertEq(keccak256(outClean), keccak256(outDirty), "trailing bytes changed preCheck verdict");
    }

    // ---------------------------------------------------------------
    // Points 4/5: gas + atomicity under a gas-burning malicious token leg
    // ---------------------------------------------------------------

    function testGasBurningFirstLegRevertsWholeSettlement() public {
        SettlementParams memory params = _validPreCheckParams();
        GasBurner burner = new GasBurner();
        assetToken.configureCallback(address(burner), abi.encodeCall(GasBurner.burn, (60_000)));

        uint256 buyerAssetBefore = assetToken.balanceOf(params.snapshot.buyer);
        uint256 sellerCashBefore = settlementToken.balanceOf(params.snapshot.seller);

        vm.prank(EXECUTOR);
        // Deliberately starve the outer call so the burn strands the later legs.
        (bool ok,) = address(dvp).call{gas: 900_000}(abi.encodeCall(dvp.settle, (params)));
        assertFalse(ok, "starved settle unexpectedly succeeded");
        // No partial execution: neither leg moved, locks not persisted.
        assertEq(assetToken.balanceOf(params.snapshot.buyer), buyerAssetBefore, "asset leg partially executed");
        assertEq(settlementToken.balanceOf(params.snapshot.seller), sellerCashBefore, "cash leg partially executed");
        assertFalse(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash), "trade lock persisted after revert");
    }

    // ---------------------------------------------------------------
    // Adapter gas budget: DvPSettlement._callAdapter hardcodes 100_000 while
    // ProtocolSecurityLimits lets a UsdyRestrictedAdapter be deployed with
    // PROVIDER_CALL_GAS up to 100_000 across 13 nested staticcalls.
    // ---------------------------------------------------------------

    IAssetAdapter private coldAdapter;
    address private coldToken;
    address private coldBuyer;
    address private coldSeller;

    IAssetAdapter[] private sweepAdapters;
    address[] private sweepTokens;
    IAssetAdapter[] private sweepAdaptersCold;
    address[] private sweepTokensCold;

    // Deploying in setUp() puts every account and storage slot in the COLD access set
    // for the test transaction, which is the realistic first-touch cost inside settle().
    // Two independent stacks per sweep step: one spent on the pass/fail verdict, one on
    // the gas measurement, so neither observation warms the other.
    function _prepareColdStack() internal {
        (coldAdapter, coldToken, coldBuyer, coldSeller) = _deployProxiedUsdyStack(100_000);
        for (uint256 extra; extra <= 4; ++extra) {
            (IAssetAdapter a, address t,,) = _deployProxiedUsdyStack(100_000);
            _applyExtraSlots(extra);
            sweepAdapters.push(a);
            sweepTokens.push(t);

            (IAssetAdapter a2, address t2,,) = _deployProxiedUsdyStack(100_000);
            _applyExtraSlots(extra);
            sweepAdaptersCold.push(a2);
            sweepTokensCold.push(t2);
        }
    }

    function _applyExtraSlots(uint256 extra) private {
        AuditListImpl(auditBlocklist).setExtraSlots(extra);
        AuditListImpl(auditAllowlist).setExtraSlots(extra);
        AuditListImpl(auditSanctions).setExtraSlots(extra);
    }

    // DvPSettlement._tryPermit caps the ERC-2612 call at TOKEN_WRITE_GAS_LIMIT = 100_000
    // and discards the result, so an under-budget permit degrades into InsufficientAllowance.
    function testErc2612PermitFitsInTokenWriteGasLimit() public {
        uint256 ownerKey = 0xF00D;
        address owner = vm.addr(ownerKey);
        address spender = address(dvp);
        uint256 value = 12_345;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = permitToken.permitDigest(owner, spender, value, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        uint256 before = gasleft();
        permitToken.permit(owner, spender, value, deadline, v, r, s);
        uint256 consumed = before - gasleft();
        emit log_named_uint("ERC-2612 permit gas, cold first touch", consumed);
        emit log_named_uint("_tryPermit TOKEN_WRITE_GAS_LIMIT", 100_000);
        assertEq(permitToken.allowance(owner, spender), value, "permit did not land");
        assertLt(consumed, 100_000, "permit exceeds the 100k _tryPermit budget");
    }

    function testUsdyAdapterGasColdStart() public {
        bytes32 ctx = keccak256("ctx");
        // Warm-up pass first so we can report the delta attributable to cold access.
        uint256 cold = _measureAdapterGas(coldAdapter, coldToken, coldSeller, coldBuyer, ctx);
        uint256 warm = _measureAdapterGas(coldAdapter, coldToken, coldSeller, coldBuyer, ctx);
        emit log_named_uint("adapter preCheck gas, cold first touch", cold);
        emit log_named_uint("adapter preCheck gas, warm repeat", warm);
        emit log_named_uint("_callAdapter hard budget", 100_000);
        assertLt(cold, 100_000, "cold adapter preCheck exceeds the 100k _callAdapter budget");
    }

    // Reproduces the exact frame _callAdapter creates: staticcall(100000, adapter, ...).
    // Each sweep step uses its OWN stack, deployed in setUp(), so every step pays real
    // cold-access costs instead of inheriting warm slots from the previous iteration.
    function testCallAdapterBudgetBreakingPoint() public {
        bytes32 ctx = keccak256("ctx");
        // Mirror settle(): by the time _callAdapter runs the asset token and its
        // implementation are already warm from readDecimals()/codehash baseline checks.
        for (uint256 i; i < sweepAdapters.length; ++i) {
            AuditUsdyImpl(sweepTokens[i]).decimals();
            // Verdict first, on a fully cold frame: this is exactly what _callAdapter sees.
            bool pass = _passesWithGas(sweepAdapters[i], sweepTokens[i], coldSeller, coldBuyer, ctx, 100_000);
            uint256 used = _measureAdapterGas(sweepAdaptersCold[i], sweepTokensCold[i], coldSeller, coldBuyer, ctx);
            emit log_named_uint("extra account-keyed cold SLOADs per list query", i);
            emit log_named_uint("  adapter preCheck gas (cold)", used);
            emit log_named_string(
                "  verdict inside the 100k _callAdapter budget", pass ? "PASS" : "UNKNOWN -> settle reverts"
            );
        }
    }

    function testUsdyAdapterGasBudgetAgainstCallAdapterCeiling() public {
        (IAssetAdapter proxiedAdapter, address token, address buyer, address seller) = _deployProxiedUsdyStack(100_000);
        bytes32 ctx = keccak256("ctx");

        uint256 consumed = _measureAdapterGas(proxiedAdapter, token, seller, buyer, ctx);
        emit log_named_uint("UsdyRestrictedAdapter.preCheck gas consumed (proxied providers)", consumed);
        emit log_named_uint("DvPSettlement._callAdapter budget", 100_000);

        uint256 minimum = _minimumGasForPass(proxiedAdapter, token, seller, buyer, ctx);
        emit log_named_uint("minimum gas for PASS", minimum);
        assertLt(minimum, 100_000, "adapter cannot complete inside the 100k _callAdapter budget");
    }

    function _measureAdapterGas(IAssetAdapter a, address token, address from, address to, bytes32 ctx)
        private
        returns (uint256)
    {
        vm.prank(address(dvp));
        uint256 before = gasleft();
        a.preCheck(token, from, to, 1 ether, TransferLeg.ASSET, ctx);
        return before - gasleft();
    }

    // Binary-search the smallest gas stipend that still yields PASS, mirroring how
    // _callAdapter caps the adapter frame.
    function _minimumGasForPass(IAssetAdapter a, address token, address from, address to, bytes32 ctx)
        private
        returns (uint256)
    {
        uint256 low = 1;
        uint256 high = 400_000;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (_passesWithGas(a, token, from, to, ctx, mid)) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        return low;
    }

    function _passesWithGas(IAssetAdapter a, address token, address from, address to, bytes32 ctx, uint256 stipend)
        private
        returns (bool)
    {
        vm.prank(address(dvp));
        (bool ok, bytes memory data) = address(a).staticcall{gas: stipend}(
            abi.encodeCall(IAssetAdapter.preCheck, (token, from, to, 1 ether, TransferLeg.ASSET, ctx))
        );
        if (!ok || data.length != 96) return false;
        (uint256 decision,,) = abi.decode(data, (uint256, uint256, bytes32));
        return decision == 1; // Decision.PASS
    }

    address private auditBlocklist;
    address private auditAllowlist;
    address private auditSanctions;

    function _deployProxiedUsdyStack(uint256 providerCallGas)
        private
        returns (IAssetAdapter proxiedAdapter, address token, address buyer, address seller)
    {
        AuditListImpl listImpl = new AuditListImpl();
        bytes memory init = abi.encodeCall(AuditListImpl.set, (address(0), false));
        auditBlocklist = address(new ERC1967Proxy(address(listImpl), init));
        auditAllowlist = address(new ERC1967Proxy(address(listImpl), init));
        auditSanctions = address(new ERC1967Proxy(address(listImpl), init));

        AuditUsdyImpl tokenImpl = new AuditUsdyImpl();
        token = address(
            new ERC1967Proxy(
                address(tokenImpl),
                abi.encodeCall(AuditUsdyImpl.initialize, (auditBlocklist, auditAllowlist, auditSanctions))
            )
        );

        buyer = address(0xB111);
        seller = address(0x5E11);
        AuditListImpl(auditAllowlist).set(buyer, true);
        AuditListImpl(auditAllowlist).set(seller, true);
        AuditListImpl(auditAllowlist).set(address(dvp), true);

        proxiedAdapter = _deployAdapter(token, providerCallGas);
    }

    function _deployAdapter(address token, uint256 providerCallGas) private returns (IAssetAdapter) {
        return IAssetAdapter(
            address(
                new UsdyRestrictedAdapter(
                    address(dvp),
                    token,
                    token.codehash,
                    auditBlocklist,
                    auditBlocklist.codehash,
                    auditAllowlist,
                    auditAllowlist.codehash,
                    auditSanctions,
                    auditSanctions.codehash,
                    providerCallGas
                )
            )
        );
    }
}

// Textbook ERC-2612 implementation, used only to price the permit call.
contract AuditPermitToken {
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private immutable DOMAIN_SEPARATOR;

    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public nonces;

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Audit"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function permitDigest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        external
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline))
            )
        );
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        require(block.timestamp <= deadline, "EXPIRED");
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        require(ecrecover(digest, v, r, s) == owner, "BAD_SIG");
        allowance[owner][spender] = value;
    }
}

contract GasBurner {
    uint256 private sink;

    function burn(uint256 target) external {
        uint256 start = gasleft();
        while (start - gasleft() < target) {
            sink = sink + 1;
        }
    }
}
