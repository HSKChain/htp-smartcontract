// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1404Adapter} from "src/adapters/ERC1404Adapter.sol";
import {UsdyRestrictedAdapter} from "src/adapters/UsdyRestrictedAdapter.sol";
import {BondPrincipalCalculator} from "src/calculators/BondPrincipalCalculator.sol";
import {StockPrincipalCalculator} from "src/calculators/StockPrincipalCalculator.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {IPrincipalCalculator} from "src/interfaces/IPrincipalCalculator.sol";
import {AddressListMock} from "test/fixtures/AdapterMocks.sol";
import {IntegrationERC1404Token, IntegrationUpgradeableUsdyToken} from "test/fixtures/IntegrationTokens.sol";
import {DvPPreCheckTestBase} from "./DvPPreCheckTestBase.sol";

abstract contract DeployFixture is DvPPreCheckTestBase {
    uint256 internal constant INTEGRATION_PROVIDER_CALL_GAS = 50_000;

    IPrincipalCalculator internal stockCalculator;
    IPrincipalCalculator internal fundCalculator;
    IPrincipalCalculator internal bondCalculator;

    IAssetAdapter internal unrestrictedAdapter;
    IAssetAdapter internal erc1404Adapter;
    IAssetAdapter internal usdyAdapter;

    IntegrationERC1404Token internal erc1404Token;
    IntegrationUpgradeableUsdyToken internal usdyToken;
    address internal usdyTokenImplementation;
    AddressListMock internal usdyBlocklist;
    AddressListMock internal usdyAllowlist;
    AddressListMock internal usdySanctions;

    function setUp() public virtual override {
        super.setUp();
        _deployIntegrationImplementations();
    }

    function _newUsdyImplementation() internal virtual returns (IntegrationUpgradeableUsdyToken) {
        return new IntegrationUpgradeableUsdyToken();
    }

    function _deployIntegrationImplementations() internal {
        stockCalculator = IPrincipalCalculator(address(new StockPrincipalCalculator()));
        fundCalculator = IPrincipalCalculator(address(calculator));
        bondCalculator = IPrincipalCalculator(address(new BondPrincipalCalculator()));
        unrestrictedAdapter = IAssetAdapter(address(adapter));

        erc1404Token = new IntegrationERC1404Token();
        erc1404Adapter = IAssetAdapter(
            address(
                new ERC1404Adapter(
                    address(dvp), address(erc1404Token), address(erc1404Token).codehash, INTEGRATION_PROVIDER_CALL_GAS
                )
            )
        );

        usdyBlocklist = new AddressListMock();
        usdyAllowlist = new AddressListMock();
        usdySanctions = new AddressListMock();
        IntegrationUpgradeableUsdyToken implementation = _newUsdyImplementation();
        usdyTokenImplementation = address(implementation);
        usdyToken = IntegrationUpgradeableUsdyToken(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        IntegrationUpgradeableUsdyToken.initialize,
                        (address(usdyBlocklist), address(usdyAllowlist), address(usdySanctions))
                    )
                )
            )
        );
        usdyAdapter = IAssetAdapter(
            address(
                new UsdyRestrictedAdapter(
                    address(dvp),
                    address(usdyToken),
                    address(usdyToken).codehash,
                    address(usdyBlocklist),
                    address(usdyBlocklist).codehash,
                    address(usdyAllowlist),
                    address(usdyAllowlist).codehash,
                    address(usdySanctions),
                    address(usdySanctions).codehash,
                    INTEGRATION_PROVIDER_CALL_GAS
                )
            )
        );
    }
}
