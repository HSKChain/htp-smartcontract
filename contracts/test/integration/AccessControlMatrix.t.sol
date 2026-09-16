// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAdapterRegistry} from "src/interfaces/IAdapterRegistry.sol";
import {IAssetVersionRegistry} from "src/interfaces/IAssetVersionRegistry.sol";
import {IEligibilityRegistry} from "src/interfaces/IEligibilityRegistry.sol";
import {IFeeRegistry} from "src/interfaces/IFeeRegistry.sol";
import {IParticipantRegistry} from "src/interfaces/IParticipantRegistry.sol";
import {IPrincipalCalculatorRegistry} from "src/interfaces/IPrincipalCalculatorRegistry.sol";
import {ISettlementTokenRegistry} from "src/interfaces/ISettlementTokenRegistry.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {Roles} from "src/libraries/Roles.sol";
import {
    AdapterConfig,
    AssetVersionConfig,
    EligibilityInput,
    FeeConfig,
    NonceCancellation,
    NonceStatus,
    NonceType,
    ParticipantInput,
    PrincipalCalculatorConfig,
    ReasonCode,
    SettlementParams,
    SettlementTokenConfig
} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

contract AccessControlMatrixTest is DvPPreCheckTestBase {
    address private constant OUTSIDER = address(0xBAD);

    function testDvpWriteAndPublicReadMatrix() public {
        SettlementParams memory params = _validPreCheckParams();
        _assertUnauthorized(address(dvp), abi.encodeCall(dvp.settle, (params)), Roles.EXECUTOR_ROLE);
        _assertUnauthorized(
            address(dvp),
            abi.encodeCall(dvp.pauseGlobal, (ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH)),
            Roles.PAUSER_ROLE
        );
        _assertUnauthorized(
            address(dvp),
            abi.encodeCall(dvp.unpauseGlobal, (ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH)),
            Roles.GOVERNANCE_ROLE
        );
        _assertUnauthorized(
            address(dvp),
            abi.encodeCall(dvp.retire, (ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH)),
            Roles.GOVERNANCE_ROLE
        );

        vm.prank(OUTSIDER);
        dvp.cancelNonce(NonceType.MAKER_QUOTE, 999);
        assertEq(uint8(dvp.getNonceStatus(OUTSIDER, NonceType.MAKER_QUOTE, 999)), uint8(NonceStatus.CANCELLED));

        NonceCancellation memory cancellation = NonceCancellation({
            signer: vm.addr(MAKER_KEY), nonceType: NonceType.REQUESTER_TRADE, nonce: 1_001, deadline: type(uint64).max
        });
        bytes32 digest = HTPHashing.hashNonceCancellationDigest(dvp.domainSeparatorV4(), cancellation);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_KEY, digest);
        vm.prank(OUTSIDER);
        dvp.cancelNonceBySig(cancellation, abi.encodePacked(r, s, v));
        assertEq(
            uint8(dvp.getNonceStatus(cancellation.signer, cancellation.nonceType, cancellation.nonce)),
            uint8(NonceStatus.CANCELLED)
        );

        vm.prank(OUTSIDER);
        dvp.preCheck(params);
        assertEq(address(dvp.participantRegistry()), address(participantRegistry));
        assertEq(address(dvp.assetVersionRegistry()), address(assetVersionRegistry));
        assertEq(address(dvp.eligibilityRegistry()), address(eligibilityRegistry));
    }

    function testOperationalRegistryWriteMatrixDefaultsToDeny() public {
        AdapterConfig memory adapterInput;
        AssetVersionConfig memory assetInput;
        SettlementTokenConfig memory settlementInput;
        PrincipalCalculatorConfig memory calculatorInput;
        FeeConfig memory feeInput;
        ParticipantInput memory participantInput;
        EligibilityInput memory eligibilityInput;

        _assertUnauthorized(
            address(adapterRegistry),
            abi.encodeCall(IAdapterRegistry.registerAdapter, (adapterInput)),
            Roles.CONFIGURER_ROLE
        );
        _assertUnauthorized(
            address(assetVersionRegistry),
            abi.encodeCall(IAssetVersionRegistry.registerAssetVersion, (assetInput)),
            Roles.CONFIGURER_ROLE
        );
        _assertUnauthorized(
            address(settlementTokenRegistry),
            abi.encodeCall(ISettlementTokenRegistry.registerSettlementToken, (settlementInput)),
            Roles.CONFIGURER_ROLE
        );
        _assertUnauthorized(
            address(calculatorRegistry),
            abi.encodeCall(IPrincipalCalculatorRegistry.registerPrincipalCalculator, (calculatorInput)),
            Roles.CONFIGURER_ROLE
        );
        _assertUnauthorized(
            address(feeRegistry), abi.encodeCall(IFeeRegistry.registerFeeVersion, (feeInput)), Roles.CONFIGURER_ROLE
        );
        _assertUnauthorized(
            address(participantRegistry),
            abi.encodeCall(IParticipantRegistry.setParticipant, (participantInput, uint64(0))),
            Roles.CONFIGURER_ROLE
        );
        _assertUnauthorized(
            address(eligibilityRegistry),
            abi.encodeCall(IEligibilityRegistry.setEligibility, (eligibilityInput, uint64(0))),
            Roles.CONFIGURER_ROLE
        );
    }

    function testGovernanceTransitionsAndEligibilityUpdatesDefaultToDeny() public {
        _assertUnauthorized(
            address(adapterRegistry),
            abi.encodeCall(IAdapterRegistry.activateAdapter, (bytes32(0), bytes32(0))),
            Roles.GOVERNANCE_ROLE
        );
        _assertUnauthorized(
            address(assetVersionRegistry),
            abi.encodeCall(IAssetVersionRegistry.activateAssetVersion, (bytes32(0), bytes32(0))),
            Roles.GOVERNANCE_ROLE
        );
        _assertUnauthorized(
            address(settlementTokenRegistry),
            abi.encodeCall(ISettlementTokenRegistry.activateSettlementToken, (bytes32(0), bytes32(0))),
            Roles.GOVERNANCE_ROLE
        );
        _assertUnauthorized(
            address(calculatorRegistry),
            abi.encodeCall(IPrincipalCalculatorRegistry.activatePrincipalCalculator, (bytes32(0), bytes32(0))),
            Roles.GOVERNANCE_ROLE
        );
        _assertUnauthorized(
            address(feeRegistry),
            abi.encodeCall(IFeeRegistry.activateFeeVersion, (bytes32(0), bytes32(0))),
            Roles.GOVERNANCE_ROLE
        );
    }

    function testAllConfigRegistryAdministrativeClassesDefaultToDeny() public {
        _assertConfigAdminMatrix(
            address(adapterRegistry),
            abi.encodeCall(IAdapterRegistry.pauseAdapter, (bytes32(0), ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH)),
            abi.encodeCall(
                IAdapterRegistry.unpauseAdapter, (bytes32(0), bytes32(0), ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH)
            ),
            abi.encodeCall(IAdapterRegistry.deprecateAdapter, (bytes32(0), ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH))
        );
        _assertConfigAdminMatrix(
            address(assetVersionRegistry),
            abi.encodeCall(
                IAssetVersionRegistry.pauseAssetVersion, (bytes32(0), ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH)
            ),
            abi.encodeCall(
                IAssetVersionRegistry.unpauseAssetVersion,
                (bytes32(0), bytes32(0), ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH)
            ),
            abi.encodeCall(
                IAssetVersionRegistry.deprecateAssetVersion, (bytes32(0), ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH)
            )
        );
        _assertConfigAdminMatrix(
            address(settlementTokenRegistry),
            abi.encodeCall(
                ISettlementTokenRegistry.pauseSettlementToken, (bytes32(0), ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH)
            ),
            abi.encodeCall(
                ISettlementTokenRegistry.unpauseSettlementToken,
                (bytes32(0), bytes32(0), ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH)
            ),
            abi.encodeCall(
                ISettlementTokenRegistry.deprecateSettlementToken,
                (bytes32(0), ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH)
            )
        );
        _assertConfigAdminMatrix(
            address(calculatorRegistry),
            abi.encodeCall(
                IPrincipalCalculatorRegistry.pausePrincipalCalculator,
                (bytes32(0), ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH)
            ),
            abi.encodeCall(
                IPrincipalCalculatorRegistry.unpausePrincipalCalculator,
                (bytes32(0), bytes32(0), ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH)
            ),
            abi.encodeCall(
                IPrincipalCalculatorRegistry.deprecatePrincipalCalculator,
                (bytes32(0), ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH)
            )
        );
        _assertConfigAdminMatrix(
            address(feeRegistry),
            abi.encodeCall(IFeeRegistry.pauseFeeVersion, (bytes32(0), ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH)),
            abi.encodeCall(
                IFeeRegistry.unpauseFeeVersion, (bytes32(0), bytes32(0), ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH)
            ),
            abi.encodeCall(IFeeRegistry.deprecateFeeVersion, (bytes32(0), ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH))
        );
    }

    function testParticipantAndEligibilityAdministrativeClassesDefaultToDeny() public {
        _assertUnauthorized(
            address(participantRegistry),
            abi.encodeCall(
                IParticipantRegistry.pauseParticipant,
                (OUTSIDER, uint64(0), ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH)
            ),
            Roles.PAUSER_ROLE
        );
        _assertUnauthorized(
            address(participantRegistry),
            abi.encodeCall(
                IParticipantRegistry.unpauseParticipant,
                (OUTSIDER, uint64(0), ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH)
            ),
            Roles.GOVERNANCE_ROLE
        );
        _assertUnauthorized(
            address(participantRegistry),
            abi.encodeCall(IParticipantRegistry.revokeParticipant, (OUTSIDER, uint64(0), EVIDENCE_HASH)),
            Roles.GOVERNANCE_ROLE
        );
        _assertUnauthorized(
            address(eligibilityRegistry),
            abi.encodeCall(
                IEligibilityRegistry.pauseEligibility,
                (bytes32(0), uint64(0), ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH)
            ),
            Roles.PAUSER_ROLE
        );
        _assertUnauthorized(
            address(eligibilityRegistry),
            abi.encodeCall(
                IEligibilityRegistry.unpauseEligibility,
                (bytes32(0), uint64(0), ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH)
            ),
            Roles.GOVERNANCE_ROLE
        );
        _assertUnauthorized(
            address(eligibilityRegistry),
            abi.encodeCall(IEligibilityRegistry.revokeEligibility, (bytes32(0), uint64(0), EVIDENCE_HASH)),
            Roles.GOVERNANCE_ROLE
        );
    }

    function _assertConfigAdminMatrix(
        address target,
        bytes memory pauseData,
        bytes memory unpauseData,
        bytes memory deprecateData
    ) private {
        _assertUnauthorized(target, pauseData, Roles.PAUSER_ROLE);
        _assertUnauthorized(target, unpauseData, Roles.GOVERNANCE_ROLE);
        _assertUnauthorized(target, deprecateData, Roles.GOVERNANCE_ROLE);
        _assertUnauthorized(
            target,
            abi.encodeWithSignature("registerDependentDvp(address,bytes32)", address(dvp), EVIDENCE_HASH),
            Roles.GOVERNANCE_ROLE
        );
        _assertUnauthorized(
            target,
            abi.encodeWithSignature("exemptRetiredDependentDvp(address,bytes32)", address(dvp), EVIDENCE_HASH),
            Roles.GOVERNANCE_ROLE
        );
        _assertUnauthorized(
            target,
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(1), bytes("")),
            Roles.UPGRADER_ROLE
        );
    }

    function _assertUnauthorized(address target, bytes memory callData, bytes32 role) private {
        vm.prank(OUTSIDER);
        (bool success, bytes memory returnData) = target.call(callData);
        assertFalse(success);
        assertEq(
            returnData, abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, OUTSIDER, role)
        );
    }
}
