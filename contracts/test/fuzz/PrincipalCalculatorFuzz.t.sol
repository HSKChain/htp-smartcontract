// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BondPrincipalCalculator} from "src/calculators/BondPrincipalCalculator.sol";
import {FundPrincipalCalculator} from "src/calculators/FundPrincipalCalculator.sol";
import {StockPrincipalCalculator} from "src/calculators/StockPrincipalCalculator.sol";
import {IPrincipalCalculator} from "src/interfaces/IPrincipalCalculator.sol";

contract PrincipalCalculatorFuzzTest is Test {
    IPrincipalCalculator private immutable FUND = IPrincipalCalculator(address(new FundPrincipalCalculator()));
    IPrincipalCalculator private immutable STOCK = IPrincipalCalculator(address(new StockPrincipalCalculator()));
    IPrincipalCalculator private immutable BOND = IPrincipalCalculator(address(new BondPrincipalCalculator()));

    string private vectorsJson;
    uint256 private vectorCount;
    uint256 private invalidVectorCount;

    function setUp() public {
        vectorsJson = vm.readFile(string.concat(vm.projectRoot(), "/../schema/v1/vectors/calculators/all-v1.json"));
        vectorCount = vm.parseJsonUint(vectorsJson, ".fuzzCorpusSize");
        invalidVectorCount = vm.parseJsonUint(vectorsJson, ".invalidCorpusSize");
    }

    function testFuzzCalculatorsMatchIndependentReference(uint256 seed) public {
        _assertVector(bound(seed, 0, vectorCount - 1));
    }

    function testGeneratedCorpusChunk0() public {
        _assertRange(0, 56);
    }

    function testGeneratedCorpusChunk1() public {
        _assertRange(56, 112);
    }

    function testGeneratedCorpusChunk2() public {
        _assertRange(112, 168);
    }

    function testGeneratedCorpusChunk3() public {
        _assertRange(168, 224);
    }

    function testGeneratedCorpusChunk4() public {
        _assertRange(224, 280);
    }

    function testGeneratedCorpusChunk5() public {
        assertEq(vectorCount, 336);
        _assertRange(280, vectorCount);
    }

    function testFuzzInvalidVectorsFailWithReferenceSelector(uint256 seed) public {
        _assertInvalidVector(bound(seed, 0, invalidVectorCount - 1));
    }

    function testAllGeneratedInvalidVectorsFailWithReferenceSelector() public {
        for (uint256 index = 0; index < invalidVectorCount; ++index) {
            _assertInvalidVector(index);
        }
    }

    function _assertVector(uint256 index) private returns (uint256 assetClassId, uint8 assetDecimals) {
        string memory base = string.concat(".fuzzCorpus[", vm.toString(index), "]");
        assetClassId = vm.parseJsonUint(vectorsJson, string.concat(base, ".assetClassId"));
        assetDecimals = uint8(vm.parseJsonUint(vectorsJson, string.concat(base, ".assetDecimals")));
        bytes memory priceData = vm.parseJsonBytes(vectorsJson, string.concat(base, ".priceData"));
        uint256 executedQuantity =
            vm.parseUint(vm.parseJsonString(vectorsJson, string.concat(base, ".executedQuantity")));
        bytes32 expectedHash = vm.parseJsonBytes32(vectorsJson, string.concat(base, ".priceTermsHash"));
        uint256 expectedUnitCashPrice =
            vm.parseUint(vm.parseJsonString(vectorsJson, string.concat(base, ".unitCashPrice")));
        uint256 expectedCashPrincipal =
            vm.parseUint(vm.parseJsonString(vectorsJson, string.concat(base, ".cashPrincipal")));

        (bytes32 actualHash,, uint256 actualUnitCashPrice, uint256 actualCashPrincipal) =
            _calculator(assetClassId).calculate(priceData, executedQuantity, assetDecimals);
        assertEq(actualHash, expectedHash);
        assertEq(actualUnitCashPrice, expectedUnitCashPrice);
        assertEq(actualCashPrincipal, expectedCashPrincipal);
    }

    function _assertRange(uint256 start, uint256 end) private {
        for (uint256 index = start; index < end; ++index) {
            _assertVector(index);
        }
    }

    function _assertInvalidVector(uint256 index) private {
        string memory base = string.concat(".invalidCorpus[", vm.toString(index), "]");
        uint256 assetClassId = vm.parseJsonUint(vectorsJson, string.concat(base, ".assetClassId"));
        bytes memory priceData = vm.parseJsonBytes(vectorsJson, string.concat(base, ".priceData"));
        uint256 executedQuantity =
            vm.parseUint(vm.parseJsonString(vectorsJson, string.concat(base, ".executedQuantity")));
        uint8 assetDecimals = uint8(vm.parseJsonUint(vectorsJson, string.concat(base, ".assetDecimals")));
        bytes4 expectedSelector =
            _selector(vm.parseJsonBytes(vectorsJson, string.concat(base, ".expectedErrorSelector")));

        (bool success, bytes memory returnData) = address(_calculator(assetClassId))
            .staticcall(abi.encodeCall(IPrincipalCalculator.calculate, (priceData, executedQuantity, assetDecimals)));
        assertFalse(success);
        assertEq(_selector(returnData), expectedSelector);
    }

    function _calculator(uint256 assetClassId) private returns (IPrincipalCalculator) {
        if (assetClassId == 1) return STOCK;
        if (assetClassId == 2) return FUND;
        if (assetClassId == 3) return BOND;
        fail();
        return IPrincipalCalculator(address(0));
    }

    function _selector(bytes memory data) private pure returns (bytes4 selector) {
        if (data.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(data, 0x20))
        }
    }
}
