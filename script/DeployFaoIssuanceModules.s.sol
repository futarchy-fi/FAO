// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {FaoGenesisDeployment} from "../src/FaoGenesisDeployment.sol";
import {FaoPriceBeacon, IBeaconPoolFactory, IBeaconVault} from "../src/FaoPriceBeacon.sol";
import {FaoSaleCurve} from "../src/FaoSaleCurve.sol";
import {FaoShortFacility, IShortBeacon, IShortVault} from "../src/FaoShortFacility.sol";
import {FaoTeamOptions, IOptionsBeacon, IOptionsVault} from "../src/FaoTeamOptions.sol";
import {FaoToken} from "../src/FaoToken.sol";

/// @notice Deploys the contracts that the economic genesis names but does not create: the sale
/// curve, the price record, the team options and the short facility.
///
/// Order, all by the same deployer key:
///
/// 1. `run()` here: four creations, then the curve is bound to the vault that step 2 will create.
/// 2. `DeployFaoEconomicGenesis` with `SALE_CURVE`, `OPTION_ISSUER` and `SHORT_ISSUER` set to the
///    addresses printed by step 1. It must be the deployer's next transactions: the vault's
///    address is derived from the deployer's nonce.
/// 3. `bindModules()` here: the price record, options and short facility are bound to the vault.
///    They read the vault's token, so the vault must exist first.
///
/// Until step 3 the options and short facility cannot mint. The deployer can bind each contract
/// once and only to the vault its token names; it keeps no other power.
contract DeployFaoIssuanceModules is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;
    address internal constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant UNISWAP_V3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    uint24 internal constant FEE_TIER = 500;

    /// @dev Transactions `run()` broadcasts before the genesis script starts.
    uint256 internal constant MODULE_TRANSACTIONS = 5;
    /// @dev The genesis script creates its receipt in its third transaction.
    uint256 internal constant GENESIS_RECEIPT_OFFSET = 2;
    /// @dev The receipt creates the vault with its nonce 2.
    uint256 internal constant RECEIPT_VAULT_NONCE = 2;

    error InvalidChain(uint256 chainId);
    error InvalidConfig();
    error UnexpectedNonce(uint256 expected, uint256 actual);
    error WrongIssuer(address expected, address actual);

    struct Modules {
        FaoSaleCurve curve;
        FaoPriceBeacon beacon;
        FaoTeamOptions options;
        FaoShortFacility shorts;
        address predictedReceipt;
        address predictedVault;
    }

    function run() external returns (Modules memory m) {
        if (block.chainid != SEPOLIA_CHAIN_ID) revert InvalidChain(block.chainid);
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        if (privateKey == 0) revert InvalidConfig();

        uint256 fixedPriceDuration = vm.envOr("FIXED_PRICE_DURATION", uint256(0));
        uint256 fixedMinimum = vm.envOr("FIXED_MINIMUM", uint256(0));
        uint256 poolBps = vm.envOr("OPTIONS_POOL_BPS", uint256(3000));
        uint256 strikeBps = vm.envOr("OPTIONS_STRIKE_BPS", uint256(10_000));
        uint256 lockMultipleBps = vm.envOr("SHORT_LOCK_MULTIPLE_BPS", uint256(20_000));
        uint256 feeBpsPer30Days = vm.envOr("SHORT_FEE_BPS_PER_30_DAYS", uint256(100));
        uint256 term = vm.envOr("SHORT_TERM", uint256(180 days));
        uint256 lookbackDays = vm.envOr("SHORT_LOOKBACK_DAYS", uint256(7));
        uint256 maxOpenBps = vm.envOr("SHORT_MAX_OPEN_BPS", uint256(5000));
        if (
            poolBps > type(uint16).max || strikeBps > type(uint16).max
                || lockMultipleBps > type(uint32).max || feeBpsPer30Days > type(uint16).max
                || term > type(uint32).max || lookbackDays > type(uint8).max
                || maxOpenBps > type(uint32).max
                || block.timestamp + fixedPriceDuration > type(uint64).max
        ) revert InvalidConfig();

        uint256 startNonce = vm.getNonce(deployer);
        m.predictedReceipt = vm.computeCreateAddress(
            deployer, startNonce + MODULE_TRANSACTIONS + GENESIS_RECEIPT_OFFSET
        );
        m.predictedVault = vm.computeCreateAddress(m.predictedReceipt, RECEIPT_VAULT_NONCE);

        vm.startBroadcast(privateKey);
        // The same INITIAL_PRICE and SLOPE defaults as the genesis script, which the vault
        // checks against the curve.
        m.curve = new FaoSaleCurve(
            vm.envOr("INITIAL_PRICE", uint256(0.000_01 ether)),
            vm.envOr("SLOPE", uint256(0)),
            fixedMinimum == 0 ? 0 : uint64(block.timestamp + fixedPriceDuration),
            fixedMinimum
        );
        m.beacon = new FaoPriceBeacon(IBeaconPoolFactory(UNISWAP_V3_FACTORY), WETH, FEE_TIER);
        m.options = new FaoTeamOptions(
            IOptionsBeacon(address(m.beacon)),
            vm.envAddress("OPTIONS_HOLDER"),
            uint16(poolBps),
            uint16(strikeBps)
        );
        m.shorts = new FaoShortFacility(
            IShortBeacon(address(m.beacon)),
            uint32(lockMultipleBps),
            uint16(feeBpsPer30Days),
            uint32(term),
            uint8(lookbackDays),
            uint32(maxOpenBps)
        );
        m.curve.bind(m.predictedVault);
        vm.stopBroadcast();

        uint256 endNonce = vm.getNonce(deployer);
        if (endNonce != startNonce + MODULE_TRANSACTIONS) {
            revert UnexpectedNonce(startNonce + MODULE_TRANSACTIONS, endNonce);
        }

        console2.log("=== FAO issuance modules deployed; run the economic genesis next ===");
        console2.log("DEPLOYER=", deployer);
        console2.log("GENESIS_START_NONCE=", endNonce);
        console2.log("SALE_CURVE=", address(m.curve));
        console2.log("PRICE_BEACON=", address(m.beacon));
        console2.log("OPTION_ISSUER=", address(m.options));
        console2.log("SHORT_ISSUER=", address(m.shorts));
        console2.log("PREDICTED_GENESIS_RECEIPT=", m.predictedReceipt);
        console2.log("PREDICTED_VAULT=", m.predictedVault);
    }

    /// @notice After the economic genesis: binds the price record, the options and the short
    /// facility to the vault of `GENESIS_RECEIPT`.
    function bindModules() external {
        if (block.chainid != SEPOLIA_CHAIN_ID) revert InvalidChain(block.chainid);
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        FaoGenesisDeployment receipt = FaoGenesisDeployment(vm.envAddress("GENESIS_RECEIPT"));
        FaoPriceBeacon beacon = FaoPriceBeacon(vm.envAddress("PRICE_BEACON"));
        FaoTeamOptions options = FaoTeamOptions(vm.envAddress("OPTION_ISSUER"));
        FaoShortFacility shorts = FaoShortFacility(vm.envAddress("SHORT_ISSUER"));

        address vault = receipt.vault();
        FaoToken token = FaoToken(receipt.companyToken());
        if (vault == address(0) || token.vault() != vault) revert InvalidConfig();
        if (token.optionIssuer() != address(options)) {
            revert WrongIssuer(token.optionIssuer(), address(options));
        }
        if (token.shortIssuer() != address(shorts)) {
            revert WrongIssuer(token.shortIssuer(), address(shorts));
        }

        vm.startBroadcast(privateKey);
        beacon.bind(IBeaconVault(vault));
        options.bind(IOptionsVault(vault));
        shorts.bind(IShortVault(vault));
        vm.stopBroadcast();

        console2.log("=== FAO issuance modules bound ===");
        console2.log("VAULT=", vault);
        console2.log("FAO_TOKEN=", address(token));
        console2.log("PRICE_BEACON=", address(beacon));
        console2.log("OPTION_ISSUER=", address(options));
        console2.log("SHORT_ISSUER=", address(shorts));
    }
}
