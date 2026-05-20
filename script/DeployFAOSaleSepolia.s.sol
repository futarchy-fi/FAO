// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {FAOToken} from "../src/FAOToken.sol";
import {FAOSale} from "../src/FAOSale.sol";

/// @notice Sepolia testnet deploy for FAOSale only.
///
/// The FAOToken is already deployed on Sepolia at
/// 0x43915f98Ce38116a8C93484Dc8c1ba568Cf13E65 (deployer/admin =
/// 0x693E3FB46Bb36eE43C702FE94f9463df0691b43d). This script:
///   1. Deploys FAOSale wired to the existing FAOToken.
///   2. Grants the sale contract MINTER_ROLE on the token.
///   3. Calls startSale() to open the initial fixed-price phase.
///
/// Testnet config:
///   - INITIAL_PRICE_WEI_PER_TOKEN is hard-coded in FAOSale at 1e14 wei
///     (0.0001 ETH per whole FAO).
///   - minInitialPhaseSold  = 100 FAO  (caps initial-phase mint cost at 0.01 ETH).
///   - initialPhaseDuration = 1 hour   (vs 14 days on mainnet).
///   - incentive / insider  = address(0). FAOSale skips those mints when zero
///     (see _mintToPools), and the FAOSale itself is the treasury bucket
///     (token.mint(address(this), …)). Admin = deployer EOA.
///
/// Required env:
///   PRIVATE_KEY  uint256 hex of deployer key (must already hold MINTER_ROLE-
///                granting power on FAO_TOKEN, i.e. DEFAULT_ADMIN_ROLE)
///   FAO_TOKEN    address of the deployed FAOToken; defaults to the Sepolia
///                deployment if unset.
///
/// Recommended invocation:
///   forge script script/DeployFAOSaleSepolia.s.sol:DeployFAOSaleSepolia \
///       --rpc-url $SEPOLIA_RPC_URL \
///       --broadcast \
///       --legacy --gas-price 1100000000
contract DeployFAOSaleSepolia is Script {
    address constant DEFAULT_FAO_TOKEN = 0x43915f98Ce38116a8C93484Dc8c1ba568Cf13E65;

    // Testnet sale-config knobs (small numbers so the whole flow runs in minutes
    // and costs ~0.01 ETH to fully cap).
    uint256 constant MIN_INITIAL_PHASE_SOLD = 100;       // whole FAO
    uint256 constant INITIAL_PHASE_DURATION = 1 hours;   // vs 14 days mainnet

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(deployerPrivateKey);

        address tokenAddr = vm.envOr("FAO_TOKEN", DEFAULT_FAO_TOKEN);
        FAOToken token = FAOToken(tokenAddr);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy the sale contract against the pre-deployed token.
        FAOSale sale = new FAOSale(
            token,
            MIN_INITIAL_PHASE_SOLD,
            INITIAL_PHASE_DURATION,
            admin,         // admin (deployer EOA on testnet)
            address(0),    // incentive contract — skipped at mint time
            address(0)     // insider vesting contract — skipped at mint time
        );

        // 2. Grant MINTER_ROLE so the sale can mint FAO on buy().
        token.grantRole(token.MINTER_ROLE(), address(sale));

        // 3. Open the sale (initial fixed-price phase begins now).
        sale.startSale();

        vm.stopBroadcast();

        console2.log("FAOToken (existing)     ", address(token));
        console2.log("FAOSale deployed at     ", address(sale));
        console2.log("Admin (deployer)        ", admin);
        console2.log("minInitialPhaseSold     ", MIN_INITIAL_PHASE_SOLD);
        console2.log("initialPhaseDuration (s)", INITIAL_PHASE_DURATION);
    }
}
