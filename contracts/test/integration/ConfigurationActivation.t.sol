// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {
    AdapterStatus,
    AssetVersionStatus,
    CalculatorStatus,
    FeePolicyEpochStatus,
    FeeVersionStatus,
    SettlementTokenStatus
} from "src/types/HTPTypes.sol";
import {DeployFixture} from "test/helpers/DeployFixture.sol";

contract ConfigurationActivationTest is DeployFixture {
    function testDeploysRealCrossModuleGraphAndActivatesConfiguration() public view {
        assertEq(address(dvp.participantRegistry()), address(participantRegistry));
        assertEq(address(dvp.assetVersionRegistry()), address(assetVersionRegistry));
        assertEq(address(dvp.eligibilityRegistry()), address(eligibilityRegistry));
        assertEq(address(dvp.feeRegistry()), address(feeRegistry));
        assertEq(address(dvp.settlementTokenRegistry()), address(settlementTokenRegistry));
        assertEq(address(dvp.adapterRegistry()), address(adapterRegistry));
        assertEq(address(dvp.principalCalculatorRegistry()), address(calculatorRegistry));

        _assertOnlyRealDvpDependent(address(participantRegistry));
        _assertOnlyRealDvpDependent(address(assetVersionRegistry));
        _assertOnlyRealDvpDependent(address(eligibilityRegistry));
        _assertOnlyRealDvpDependent(address(feeRegistry));
        _assertOnlyRealDvpDependent(address(settlementTokenRegistry));
        _assertOnlyRealDvpDependent(address(adapterRegistry));
        _assertOnlyRealDvpDependent(address(calculatorRegistry));

        assertEq(uint8(adapterRegistry.getAdapter(adapterConfig.adapterConfigId).status), uint8(AdapterStatus.ACTIVE));
        assertEq(
            uint8(calculatorRegistry.getPrincipalCalculator(calculatorConfig.calculatorConfigId).status),
            uint8(CalculatorStatus.ACTIVE)
        );
        assertEq(
            uint8(settlementTokenRegistry.getSettlementToken(settlementTokenConfig.configId).status),
            uint8(SettlementTokenStatus.ACTIVE)
        );
        assertEq(
            uint8(assetVersionRegistry.getAssetVersion(assetVersionConfig.assetVersionId).status),
            uint8(AssetVersionStatus.ACTIVE)
        );
        assertEq(uint8(feeRegistry.getFeeVersion(feeConfig.feeVersionId).status), uint8(FeeVersionStatus.ACTIVE));
        assertEq(uint8(feeRegistry.getFeePolicyEpoch(FEE_EPOCH).status), uint8(FeePolicyEpochStatus.ACTIVE));

        assertTrue(address(stockCalculator).code.length != 0);
        assertTrue(address(fundCalculator).code.length != 0);
        assertTrue(address(bondCalculator).code.length != 0);
        assertTrue(address(unrestrictedAdapter).code.length != 0);
        assertTrue(address(erc1404Adapter).code.length != 0);
        assertTrue(address(usdyAdapter).code.length != 0);
    }

    function _assertOnlyRealDvpDependent(address registry) private view {
        (bool countOk, bytes memory countData) = registry.staticcall(abi.encodeWithSignature("getDependentDvpCount()"));
        assertTrue(countOk);
        assertEq(abi.decode(countData, (uint256)), 1);

        (bool entryOk, bytes memory entryData) =
            registry.staticcall(abi.encodeWithSignature("getDependentDvp(uint256)", 0));
        assertTrue(entryOk);
        (address storedDvp, bool retiredExempt) = abi.decode(entryData, (address, bool));
        assertEq(storedDvp, address(dvp));
        assertFalse(retiredExempt);
    }
}
