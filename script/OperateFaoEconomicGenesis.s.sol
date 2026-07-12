// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FaoGenesisDeployment} from "../src/FaoGenesisDeployment.sol";
import {GenesisVault} from "../src/GenesisVault.sol";

interface IGenesisWeth is IERC20 {
    function deposit() external payable;
}

/// @notice Permissionlessly advances a staged economic FAO through funding, LIVE, and claim.
contract OperateFaoEconomicGenesis is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;
    address internal constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    error InvalidChain(uint256 chainId);
    error InvalidManifest();
    error InvalidOperator();
    error SpendLimitExceeded(uint256 cost, uint256 limit);
    error TokenOperationFailed();

    function run() external {
        if (block.chainid != SEPOLIA_CHAIN_ID) revert InvalidChain(block.chainid);
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address operator = vm.addr(privateKey);
        if (privateKey == 0 || operator == address(0)) revert InvalidOperator();

        string memory manifestPath = vm.envOr(
            "ECONOMIC_GENESIS_MANIFEST", string("deployments/sepolia-economic-genesis.json")
        );
        (FaoGenesisDeployment receipt, GenesisVault vault) = _loadManifest(manifestPath);
        uint256 maxSpend = vm.envOr("MAX_GENESIS_COST", uint256(0.002 ether));

        if (vault.phase() == GenesisVault.Phase.FUNDING) {
            if (block.timestamp < vault.SALE_END()) {
                _fillSale(privateKey, operator, vault, maxSpend);
            } else {
                vm.broadcast(privateKey);
                vault.seal();
            }
        }
        if (vault.phase() == GenesisVault.Phase.SEALING) {
            vm.broadcast(privateKey);
            vault.finalize();
        }
        if (vault.phase() == GenesisVault.Phase.LIVE && vault.purchased(operator) != 0) {
            vm.broadcast(privateKey);
            vault.claim(operator);
        }
        if (vault.phase() != GenesisVault.Phase.LIVE) revert InvalidManifest();

        console2.log("=== Economic FAO is LIVE ===");
        console2.log("MANIFEST=", manifestPath);
        console2.log("OPERATOR=", operator);
        console2.log("RECEIPT=", address(receipt));
        console2.log("VAULT=", address(vault));
        console2.log("FAO_TOKEN=", receipt.companyToken());
        console2.log("SPOT_POOL=", receipt.spotPool());
        console2.log("FLM_MANAGER=", receipt.manager());
        console2.log("TOTAL_SOLD=", vault.totalSold());
        console2.log("TOTAL_RAISED=", vault.totalRaised());
    }

    function _fillSale(uint256 privateKey, address operator, GenesisVault vault, uint256 maxSpend)
        private
    {
        uint256 sold = vault.totalSold();
        uint256 cap = vault.SALE_CAP();
        if (sold >= cap) revert InvalidManifest();
        uint256 tokenOut = cap - sold;
        uint256 cost = vault.reserveAt(cap) - vault.reserveAt(sold);
        if (cost == 0 || cost > maxSpend) revert SpendLimitExceeded(cost, maxSpend);

        IGenesisWeth weth = IGenesisWeth(address(vault.WETH()));
        uint256 balance = weth.balanceOf(operator);
        if (balance < cost) {
            vm.broadcast(privateKey);
            weth.deposit{value: cost - balance}();
        }
        vm.broadcast(privateKey);
        if (!weth.approve(address(vault), cost)) revert TokenOperationFailed();
        vm.broadcast(privateKey);
        vault.buy(tokenOut, cost, block.timestamp + 10 minutes);
    }

    function _loadManifest(string memory path)
        private
        view
        returns (FaoGenesisDeployment receipt, GenesisVault vault)
    {
        string memory json = vm.readFile(path);
        bytes32 status = keccak256(bytes(vm.parseJsonString(json, ".status")));
        if (
            vm.parseJsonUint(json, ".schemaVersion") != 1
                || vm.parseJsonUint(json, ".chainId") != SEPOLIA_CHAIN_ID
                || keccak256(bytes(vm.parseJsonString(json, ".network")))
                    != keccak256(bytes("sepolia"))
                || (status != keccak256(bytes("sealed")) && status != keccak256(bytes("live")))
                || vm.parseJsonAddress(json, ".coreConfig.weth.target") != WETH
        ) revert InvalidManifest();

        receipt = FaoGenesisDeployment(vm.parseJsonAddress(json, ".receipt.address"));
        vault = GenesisVault(payable(vm.parseJsonAddress(json, ".contracts.vault")));
        if (
            address(receipt).code.length == 0 || address(vault).code.length == 0
                || receipt.vault() != address(vault)
                || receipt.companyToken() != vm.parseJsonAddress(json, ".contracts.companyToken")
                || receipt.manager() != vm.parseJsonAddress(json, ".contracts.manager")
                || receipt.spotPool() != vm.parseJsonAddress(json, ".contracts.spotPool")
                || address(vault.WETH()) != WETH || !receipt.coreSealed() || !receipt.flmSealed()
        ) revert InvalidManifest();
    }
}
