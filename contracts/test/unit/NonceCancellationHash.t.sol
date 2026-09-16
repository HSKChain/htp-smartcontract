// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {SchemaFixtures} from "../generated/SchemaFixtures.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {NonceCancellation, NonceType} from "src/types/HTPTypes.sol";

contract NonceCancellationHashHarness {
    function typeHash() external pure returns (bytes32) {
        return HTPHashing.NONCE_CANCELLATION_TYPEHASH;
    }

    function hash(NonceCancellation calldata cancellation) external pure returns (bytes32) {
        return HTPHashing.hashNonceCancellation(cancellation);
    }

    function digest(bytes32 separator, NonceCancellation calldata cancellation) external pure returns (bytes32) {
        return HTPHashing.hashNonceCancellationDigest(separator, cancellation);
    }
}

contract NonceCancellationHashTest is Test {
    bytes32 private constant DOMAIN_SEPARATOR = 0xc0f20d1f3e9bd185d5fe9e24b1822d7657e7c83dd337727af1fad04d7c26cac3;
    NonceCancellationHashHarness private immutable HARNESS = new NonceCancellationHashHarness();

    function testTypeHashStructHashAndDigestMatchBootstrapLiterals() public view {
        NonceCancellation memory cancellation = SchemaFixtures.nonceCancellation();
        assertEq(HARNESS.typeHash(), 0x44a03a985507f64ac9f00742e8c5297127bec731fe64b299f3bee7edd1a5e9eb);
        assertEq(HARNESS.hash(cancellation), 0x459473fda80f3a27d265efbdf5aaa8975c96920e63e4e01f168654ee6a364eff);
        assertEq(
            HARNESS.digest(DOMAIN_SEPARATOR, cancellation),
            0xff1bdd9b8f184d4f15256922bbf2b14893a3e4dc7c934315550f7d9fd0dc6b23
        );
    }

    function testSignerTypeNonceDeadlineAndDomainMutationsMatchBootstrap() public view {
        NonceCancellation memory cancellation = SchemaFixtures.nonceCancellation();
        cancellation.signer = address(0xb002);
        assertEq(
            HARNESS.digest(DOMAIN_SEPARATOR, cancellation),
            0xd9ff2a6b2c45f156eaa715c1fe0b9e444e02b2611685ad31a1dd5198a8abff04
        );

        cancellation = SchemaFixtures.nonceCancellation();
        cancellation.nonceType = NonceType.REQUESTER_TRADE;
        assertEq(
            HARNESS.digest(DOMAIN_SEPARATOR, cancellation),
            0x2744839a88004a91c3bae05a3ecfadded963b34c3ee77ee68ce42bd940e6fd52
        );

        cancellation = SchemaFixtures.nonceCancellation();
        cancellation.nonce += 1;
        assertEq(
            HARNESS.digest(DOMAIN_SEPARATOR, cancellation),
            0xba598b82e95197ef02d33862f7a30ec8112e25b62d28176ebf3552e61be79597
        );

        cancellation = SchemaFixtures.nonceCancellation();
        cancellation.deadline += 1;
        assertEq(
            HARNESS.digest(DOMAIN_SEPARATOR, cancellation),
            0x4ff3f15a40bf765c804fd063689ff5273607748e389ca630099a48ab8ec05e39
        );

        cancellation = SchemaFixtures.nonceCancellation();
        assertEq(
            HARNESS.digest(0xaea4c8ce81af46ecfbfdd3f104b74a22f4e89d8eec0d9e390bd93280994c8e67, cancellation),
            0x164b9ecaa7de04169ce357a41077fef68de0eeb2af384de7dec9cf1d4e9c2c6f
        );
        assertEq(
            HARNESS.digest(0xf07df2743e3a62948c545efdb92620421348e8e7aa5bf07bf8ea121e40a8cc70, cancellation),
            0x674a973d9a4a06787069652a74f4aac5f74831a5e4fb2f03963e8e6e26c79952
        );
        assertEq(
            HARNESS.digest(0x94a0ee3661a4adfabf64501d34598f16bd8f3295a97ba3d10988ae12267905bd, cancellation),
            0xab79c4c60833e36b50c10ccfd852ddf2e5a796c76c9b3a9fcabcd977c0fea16f
        );
    }
}
