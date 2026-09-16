// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {DvPRegistries, DvPRoles, DvPSettlement} from "src/DvPSettlement.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {SettlementParams} from "src/types/HTPTypes.sol";
import {DvPCurrentStateValidatorFactory} from "src/validation/DvPCurrentStateValidatorFactory.sol";
import {SchemaFixtures} from "test/generated/SchemaFixtures.sol";

contract DvPTestMockRegistry {}

abstract contract DvPTestBase is Test {
    uint256 internal constant MAKER_KEY = 0xA11CE;
    uint256 internal constant REQUESTER_KEY = 0xB0B;
    address internal constant GOVERNANCE = address(0x1001);
    address internal constant PAUSER = address(0x2001);
    address internal constant EXECUTOR = address(0x3001);
    uint256 internal constant DEPLOYED_CHAIN_ID = 31_337;
    // 相对 SchemaFixtures 的 createdAt 取偏移，而不是写死绝对时间戳：
    // 后者会在 schema 向量调整 createdAt 时静默失配，产出一份超出
    // MAX_QUOTE_LIFETIME 的 fixture，而失败点会落在毫不相关的用例上。
    uint64 internal constant TRADE_DEADLINE_OFFSET = 2_000;
    uint64 internal constant QUOTE_EXPIRY_OFFSET = 3_000;

    DvPSettlement internal dvp;
    DvPRegistries internal dependencies;
    DvPCurrentStateValidatorFactory internal currentStateValidatorFactory;

    function setUp() public virtual {
        vm.chainId(DEPLOYED_CHAIN_ID);
        dependencies = _newDependencies();
        currentStateValidatorFactory = new DvPCurrentStateValidatorFactory();
        dvp = _deployDvp(
            DvPRoles({defaultAdmin: GOVERNANCE, governance: GOVERNANCE, pauser: PAUSER, executor: EXECUTOR})
        );
    }

    function _deployDvp(DvPRoles memory roles) internal returns (DvPSettlement) {
        return new DvPSettlement(
            roles, dependencies, DEPLOYED_CHAIN_ID, bytes("1.2.3"), address(currentStateValidatorFactory)
        );
    }

    function _newDependencies() internal returns (DvPRegistries memory) {
        return DvPRegistries({
            participant: address(new DvPTestMockRegistry()),
            assetVersion: address(new DvPTestMockRegistry()),
            eligibility: address(new DvPTestMockRegistry()),
            fee: address(new DvPTestMockRegistry()),
            marketRule: address(new DvPTestMockRegistry()),
            settlementToken: address(new DvPTestMockRegistry()),
            adapter: address(new DvPTestMockRegistry()),
            principalCalculator: address(new DvPTestMockRegistry())
        });
    }

    function _validSignedParams() internal view returns (SettlementParams memory) {
        return _validSignedParams(dvp);
    }

    function _validSignedParams(DvPSettlement target) internal view returns (SettlementParams memory params) {
        // HTPHashing is an already-reviewed dependency seam whose outputs are pinned
        // independently by Phase 3 bootstrap literals. These values only construct
        // valid DvP inputs; no expected hash assertion is derived from production code.
        address maker = vm.addr(MAKER_KEY);
        address requester = vm.addr(REQUESTER_KEY);
        params.firmQuote = SchemaFixtures.firmQuote();
        params.tradeIntent = SchemaFixtures.tradeIntent();
        params.snapshot = SchemaFixtures.snapshot();
        params.firmQuote.quotingMaker = maker;
        params.firmQuote.requester = requester;
        params.snapshot.chainId = DEPLOYED_CHAIN_ID;
        params.snapshot.dvpContract = address(target);
        params.snapshot.quotingMaker = maker;
        params.snapshot.requester = requester;
        params.snapshot.buyer = requester;
        params.snapshot.seller = maker;
        // Schema 向量的职责是锁定 EIP-712 编码，其时间值是任意的，并不需要构成
        // 一笔业务上可结算的报价。这里收窄到 MAX_QUOTE_LIFETIME 之内，让这些
        // 用例能越过时间窗检查、走到各自真正要测的阶段。
        uint64 tradeDeadline = params.snapshot.createdAt + TRADE_DEADLINE_OFFSET;
        uint64 quoteExpiresAt = params.snapshot.createdAt + QUOTE_EXPIRY_OFFSET;
        params.firmQuote.expiresAt = quoteExpiresAt;
        params.snapshot.quoteExpiresAt = quoteExpiresAt;
        params.snapshot.tradeDeadline = tradeDeadline;
        params.tradeIntent.deadline = tradeDeadline;

        bytes32 quoteDigest = HTPHashing.hashFirmQuoteDigest(target.domainSeparatorV4(), params.firmQuote);
        params.snapshot.quoteHash = quoteDigest;
        params.tradeIntent.quoteHash = quoteDigest;
        params.tradeIntent.snapshotHash = HTPHashing.hashTradeTermsSnapshot(params.snapshot);
        params.tradeIntent.quotingMaker = maker;
        params.tradeIntent.requester = requester;
        params.tradeIntent.buyer = requester;
        params.tradeIntent.seller = maker;
        params.quotingMakerSignature = _sign(MAKER_KEY, quoteDigest);
        _resignRequester(params, target);
    }

    function _resignRequester(SettlementParams memory params) internal view {
        _resignRequester(params, dvp);
    }

    function _resignRequester(SettlementParams memory params, DvPSettlement target) internal view {
        params.requesterSignature =
            _sign(REQUESTER_KEY, HTPHashing.hashTradeIntentDigest(target.domainSeparatorV4(), params.tradeIntent));
    }

    function _settleAsExecutor(SettlementParams memory params) internal {
        vm.prank(EXECUTOR);
        dvp.settle(params);
    }

    function _callSettleAsExecutor(SettlementParams memory params)
        internal
        returns (bool success, bytes memory returnData)
    {
        vm.prank(EXECUTOR);
        return address(dvp).call(abi.encodeCall(DvPSettlement.settle, (params)));
    }

    function _sign(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
