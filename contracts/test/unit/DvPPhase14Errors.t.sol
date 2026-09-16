// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";

contract DvPPhase14ErrorsTest is Test {
    function testPhase14ErrorSelectorsMatchReviewedLiterals() public pure {
        assertEq(bytes32(HTPErrors.QuoteAlreadyExecuted.selector), bytes32(bytes4(0x75dc6cf6)));
        assertEq(bytes32(HTPErrors.SnapshotAlreadyExecuted.selector), bytes32(bytes4(0x0ef7c78f)));
        assertEq(bytes32(HTPErrors.TradeAlreadyExecuted.selector), bytes32(bytes4(0xd8f6883f)));
        assertEq(bytes32(HTPErrors.InsufficientBalance.selector), bytes32(bytes4(0x861da4bd)));
        assertEq(bytes32(HTPErrors.UnsupportedTokenBehavior.selector), bytes32(bytes4(0x1afdd5c5)));
        assertEq(bytes32(HTPErrors.BalanceDeltaMismatch.selector), bytes32(bytes4(0xa85d8b3a)));
        assertEq(bytes32(HTPErrors.PermitUnsupported.selector), bytes32(bytes4(0xf5eff427)));
        assertEq(bytes32(HTPErrors.PermitFieldMismatch.selector), bytes32(bytes4(0x70a87a6c)));
    }

    function testRegistryConfigAndTokenErrorSelectorsMatchReviewedLiterals() public pure {
        assertEq(bytes32(HTPErrors.ConfigAlreadyExists.selector), bytes32(bytes4(0x8a4075b3)));
        assertEq(bytes32(HTPErrors.ConfigHashMismatch.selector), bytes32(bytes4(0xe9e3909f)));
        assertEq(bytes32(HTPErrors.ConfigNotFound.selector), bytes32(bytes4(0x24abf045)));
        assertEq(bytes32(HTPErrors.ConfigReferenceMismatch.selector), bytes32(bytes4(0x231c19ee)));
        assertEq(bytes32(HTPErrors.ConfigIdMismatch.selector), bytes32(bytes4(0x48993d10)));
        assertEq(bytes32(HTPErrors.UnauthorizedStateTransition.selector), bytes32(bytes4(0x797ae61e)));
        assertEq(bytes32(HTPErrors.TokenCodeHashMismatch.selector), bytes32(bytes4(0xdb03a16e)));
        assertEq(bytes32(HTPErrors.AssetDecimalsMismatch.selector), bytes32(bytes4(0x8e3054e6)));
        assertEq(bytes32(HTPErrors.SettlementTokenDecimalsMismatch.selector), bytes32(bytes4(0xd23275cf)));
        assertEq(bytes32(HTPErrors.TokenImplementationBaselineInvalid.selector), bytes32(bytes4(0x21dd509c)));
        assertEq(bytes32(HTPErrors.AssetVersionImplementationChanged.selector), bytes32(bytes4(0xd0e7c4e0)));
        assertEq(bytes32(HTPErrors.SettlementTokenImplementationChanged.selector), bytes32(bytes4(0x76b8511a)));
        assertEq(bytes32(HTPErrors.AdapterCodeHashMismatch.selector), bytes32(bytes4(0xd2be4e63)));
        assertEq(bytes32(HTPErrors.AdapterReturnMalformed.selector), bytes32(bytes4(0xeefb8fa9)));
        assertEq(bytes32(HTPErrors.CalculatorCodeHashMismatch.selector), bytes32(bytes4(0x47657b33)));
        assertEq(bytes32(HTPErrors.CalculatorStaticCallFailed.selector), bytes32(bytes4(0xfc8875d7)));
        assertEq(bytes32(HTPErrors.CalculatorReturnMalformed.selector), bytes32(bytes4(0xc5898939)));
        assertEq(bytes32(HTPErrors.InvalidImplementation.selector), bytes32(bytes4(0x0c760937)));
        assertEq(bytes32(HTPErrors.UpgradeableImplementationForbidden.selector), bytes32(bytes4(0x55a99f94)));
        assertEq(bytes32(HTPErrors.DependentDvpAlreadyRegistered.selector), bytes32(bytes4(0xc490df7a)));
        assertEq(bytes32(HTPErrors.DependentDvpNotPaused.selector), bytes32(bytes4(0xa0dcd45b)));
        assertEq(bytes32(HTPErrors.DependentDvpStatusMalformed.selector), bytes32(bytes4(0xf1c28ea9)));
        assertEq(bytes32(HTPErrors.DependentDvpNotRetired.selector), bytes32(bytes4(0x83b54524)));
        assertEq(bytes32(HTPErrors.InvalidRegistryDependency.selector), bytes32(bytes4(0x8d0ba3a1)));
    }
}
