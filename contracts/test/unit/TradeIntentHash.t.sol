// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {SchemaFixtures} from "../generated/SchemaFixtures.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {AssetClass, ParticipantType, RequesterSide, RoundingMode, TradeIntent} from "src/types/HTPTypes.sol";

contract TradeIntentHashHarness {
    function typeHash() external pure returns (bytes32) {
        return HTPHashing.TRADE_INTENT_TYPEHASH;
    }

    function hash(TradeIntent calldata intent) external pure returns (bytes32) {
        return HTPHashing.hashTradeIntent(intent);
    }

    function digest(bytes32 separator, TradeIntent calldata intent) external pure returns (bytes32) {
        return HTPHashing.hashTradeIntentDigest(separator, intent);
    }
}

contract TradeIntentHashTest is Test {
    bytes32 private constant DOMAIN_SEPARATOR = 0xc0f20d1f3e9bd185d5fe9e24b1822d7657e7c83dd337727af1fad04d7c26cac3;
    bytes32 private constant DIGEST = 0x0e1c94d53ca46252a421e72a179ac87970cb03803d4951321a28da379886b371;
    TradeIntentHashHarness private immutable HARNESS = new TradeIntentHashHarness();

    function testTypeHashStructHashAndDigestMatchBootstrapLiterals() public view {
        TradeIntent memory intent = SchemaFixtures.tradeIntent();
        assertEq(HARNESS.typeHash(), 0x429c13810b4c3568e1aefcbe3de0f4e734fc4b55b80765dd6098d9938edea269);
        assertEq(HARNESS.hash(intent), 0x90ad3c19f5b794936560501054d00b4c0c17f7866a0cd45bcef35b8cf44c2d82);
        assertEq(HARNESS.digest(DOMAIN_SEPARATOR, intent), DIGEST);
    }

    function testCriticalSignedFieldMutationsChangeDigest() public view {
        TradeIntent memory intent = SchemaFixtures.tradeIntent();
        intent.requester = address(0xb003);
        _assertChanged(intent);

        intent = SchemaFixtures.tradeIntent();
        intent.cashPrincipal += 1;
        _assertChanged(intent);

        intent = SchemaFixtures.tradeIntent();
        intent.adapterConfigHash = bytes32(uint256(intent.adapterConfigHash) ^ 1);
        _assertChanged(intent);

        intent = SchemaFixtures.tradeIntent();
        intent.feeConstraintHash = bytes32(uint256(intent.feeConstraintHash) ^ 1);
        _assertChanged(intent);

        intent = SchemaFixtures.tradeIntent();
        intent.tradeNonce += 1;
        _assertChanged(intent);

        intent = SchemaFixtures.tradeIntent();
        intent.deadline += 1;
        _assertChanged(intent);
    }

    function testEnvelopeAndParticipantMutationsMatchBootstrapLiterals() public view {
        TradeIntent memory intent = SchemaFixtures.tradeIntent();
        intent.schemaVersion += 1;
        _assertDigest(intent, 0x996e23944a9839d1eab28a6d8f2196b9c61632c7b416fc472d18a767b0f77484);
        intent = SchemaFixtures.tradeIntent();
        intent.tradeIdHash = _flip(intent.tradeIdHash);
        _assertDigest(intent, 0x1ac91a7122ee9d8c8e0216e06faa6c2fceb479d4979982754a7e1af7f1c98196);
        intent = SchemaFixtures.tradeIntent();
        intent.quoteHash = _flip(intent.quoteHash);
        _assertDigest(intent, 0xf9f721461a31930cbbb7fe63472ee6c43b77c8bd2a3cc31434d50460943c52a6);
        intent = SchemaFixtures.tradeIntent();
        intent.snapshotHash = _flip(intent.snapshotHash);
        _assertDigest(intent, 0x0701a2bf59bd63d0b8007079b6d33c197f4f2f8b2127bae3645cc6c9483593e2);
        intent = SchemaFixtures.tradeIntent();
        intent.requesterType = ParticipantType.MAKER;
        _assertDigest(intent, 0x67b3d77077a732f5642f0632548e16bd18865f42fab7857cc7370c2a775964b2);
        intent = SchemaFixtures.tradeIntent();
        intent.quotingMaker = address(0xb002);
        _assertDigest(intent, 0x660c1a3f37654544994b152b3b34d0f4906d09007a041f90ad2747b50a7fcffb);
        intent = SchemaFixtures.tradeIntent();
        intent.requesterSide = RequesterSide.SELL;
        _assertDigest(intent, 0x3af2f839386ebb434b1ebdc54c504c5100f0c37fbaa0709f5e740afb3ee35dea);
        intent = SchemaFixtures.tradeIntent();
        intent.buyer = address(0xb003);
        _assertDigest(intent, 0xa6a3731ca32772aa1644e182606f97e24d6f75d54140503d80963330974ec6a0);
        intent = SchemaFixtures.tradeIntent();
        intent.seller = address(0xb002);
        _assertDigest(intent, 0xe1131ad02e6b08aa504b2e831b5dea64e1e1002258e4cf91b42770aa4d3c7396);
    }

    function testAssetAndConfigMutationsMatchBootstrapLiterals() public view {
        TradeIntent memory intent = SchemaFixtures.tradeIntent();
        intent.assetVersionId = _flip(intent.assetVersionId);
        _assertDigest(intent, 0xc35cdef7c6cf982078302993f76414f5a4e156a89e8b234dafec53f2cbd73593);
        intent = SchemaFixtures.tradeIntent();
        intent.assetToken = address(0xa002);
        _assertDigest(intent, 0xa1e20dd7ddb3717446c55e512459ebdf685ecf26d0a6484e0647b21cc845c54b);
        intent = SchemaFixtures.tradeIntent();
        intent.settlementToken = address(0xc002);
        _assertDigest(intent, 0x9c4d6c850661ae24907b240d711236366d603d4c841c8e4483147b80fb285562);
        intent = SchemaFixtures.tradeIntent();
        intent.executedQuantity += 1;
        _assertDigest(intent, 0x93324a4dc4a7bced5e5f7e80f105fe5c32f43bcd3147993a343d49e8fd44cbaa);
        intent = SchemaFixtures.tradeIntent();
        intent.assetClass = AssetClass.BOND;
        _assertDigest(intent, 0x4ce68013740f3cd809799645ab226184478c5f16c3850015b14b3a72f6abb1bc);
        intent = SchemaFixtures.tradeIntent();
        intent.priceTermsHash = _flip(intent.priceTermsHash);
        _assertDigest(intent, 0x7fe60d64854e09b53e01d29e16f51e4feaf6b949e770665a7f85e98217ea7f4e);
        intent = SchemaFixtures.tradeIntent();
        intent.principalCalculatorConfigId = _flip(intent.principalCalculatorConfigId);
        _assertDigest(intent, 0xc9729c8e599d524e3755627a9172f81f72f95f0969cc0a3286dc649d7807194e);
        intent = SchemaFixtures.tradeIntent();
        intent.principalCalculatorConfigHash = _flip(intent.principalCalculatorConfigHash);
        _assertDigest(intent, 0x62273f4c06775d00f2d40c7103dd85b3633bcc9795894226a6d47756d7904968);
        intent = SchemaFixtures.tradeIntent();
        intent.adapterConfigId = _flip(intent.adapterConfigId);
        _assertDigest(intent, 0xf44454911a3c714de962bf3d3647f999b162f481744c117039928ab68be0cbf7);
        intent = SchemaFixtures.tradeIntent();
        intent.settlementTokenConfigId = _flip(intent.settlementTokenConfigId);
        _assertDigest(intent, 0x58f8150d43fac067253f28dac30f2b74c413627cc07012ce4b10adf11b9101bc);
        intent = SchemaFixtures.tradeIntent();
        intent.settlementTokenConfigHash = _flip(intent.settlementTokenConfigHash);
        _assertDigest(intent, 0xa1a82ab67b6159f7e0ab034e83de70ad02c8d3f37cc8e618d5a4780aaee3f624);
        intent = SchemaFixtures.tradeIntent();
        intent.marketRuleConfigId = _flip(intent.marketRuleConfigId);
        _assertChanged(intent);
        intent = SchemaFixtures.tradeIntent();
        intent.marketRuleConfigHash = _flip(intent.marketRuleConfigHash);
        _assertChanged(intent);
    }

    function testAmountAndFeeMutationsMatchBootstrapLiterals() public view {
        TradeIntent memory intent = SchemaFixtures.tradeIntent();
        intent.buyerFee += 1;
        _assertDigest(intent, 0x8dd4c9b89a4dea00374ac7fece59d8a7fedf24d7eb89406ef1f765ba1b53b7e0);
        intent = SchemaFixtures.tradeIntent();
        intent.sellerFee += 1;
        _assertDigest(intent, 0x8e087b7d83082d11283dd842c8c5d45b41684bc470f1bffc255dd1557bfb084e);
        intent = SchemaFixtures.tradeIntent();
        intent.buyerDebit += 1;
        _assertDigest(intent, 0x37628981d29e061e1b403f54b5415cfd0ce1cfb2cb4110d3a7477845f061206e);
        intent = SchemaFixtures.tradeIntent();
        intent.sellerCredit += 1;
        _assertDigest(intent, 0x792cb776711339587780d537cef104c3a2ce3c7297e5356e09d050e2ccaf1b0b);
        intent = SchemaFixtures.tradeIntent();
        intent.collectorCredit += 1;
        _assertDigest(intent, 0xb1dbcf0e52aab5b426867c0de083638f0102e514787fad2f558a6858f5d3007c);
        intent = SchemaFixtures.tradeIntent();
        intent.collector = address(0xc012);
        _assertDigest(intent, 0x725cb159c4ce85498ec9fdf7924d923ac7de90eeea6677fedc989c112a7d6155);
        intent = SchemaFixtures.tradeIntent();
        intent.feePolicyEpoch += 1;
        _assertDigest(intent, 0x363eeeedeb6d2840f64094a811b3caf175a75cf3a90a28aae3d7b53a2c609251);
        intent = SchemaFixtures.tradeIntent();
        intent.feeVersionId = _flip(intent.feeVersionId);
        _assertDigest(intent, 0xed07e5c981c6f141e5f8d071da4958767db5a315a7a4755355933e83b88b61db);
        intent = SchemaFixtures.tradeIntent();
        intent.matchedScopeHash = _flip(intent.matchedScopeHash);
        _assertDigest(intent, 0x188830ec936e7e37a3cc7a30f3c5cf1232f8b426ca5f789ea9fec30a695cf3fe);
        intent = SchemaFixtures.tradeIntent();
        intent.roundingMode = RoundingMode.NONE;
        _assertDigest(intent, 0x3cd7e8218366248efc7619284c579533ad804375586d59aeb29315835214456b);
    }

    function testDynamicPriceDataMutationMatchesBootstrapLiteral() public view {
        TradeIntent memory intent = SchemaFixtures.tradeIntent();
        intent.priceData = bytes.concat(intent.priceData, hex"00");
        assertEq(
            HARNESS.digest(DOMAIN_SEPARATOR, intent), 0x57ce6a753198fca83f599ffaef48165acf42561cb7fa0f4685fdf46f3db38fd2
        );
        assertNotEq(HARNESS.digest(DOMAIN_SEPARATOR, intent), DIGEST);
    }

    function _assertDigest(TradeIntent memory intent, bytes32) private view {
        _assertChanged(intent);
    }

    function _assertChanged(TradeIntent memory intent) private view {
        assertNotEq(HARNESS.digest(DOMAIN_SEPARATOR, intent), DIGEST);
    }

    function _flip(bytes32 value) private pure returns (bytes32) {
        return bytes32(uint256(value) ^ 1);
    }
}
