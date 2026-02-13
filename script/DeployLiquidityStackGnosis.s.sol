// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FutarchyLiquidityManager, IWrappedNative} from "../src/FutarchyLiquidityManager.sol";
import {FutarchyOfficialProposalSource} from "../src/FutarchyOfficialProposalSource.sol";
import {SwaprAlgebraLiquidityAdapter} from "../src/SwaprAlgebraLiquidityAdapter.sol";
import {ISwaprAlgebraPositionManager} from "../src/interfaces/ISwaprAlgebraPositionManager.sol";
import {IAlgebraFactoryLike} from "../src/interfaces/IAlgebraFactoryLike.sol";
import {IFutarchyConditionalRouter} from "../src/interfaces/IFutarchyConditionalRouter.sol";

contract DeployLiquidityStackGnosis is Script {
    struct DeployConfig {
        address sale;
        address faoToken;
        address officialProposer;
        address owner;
        address wrappedNative;
        address positionManager;
        address algebraFactory;
        address futarchyRouter;
        int24 tickLower;
        int24 tickUpper;
    }

    address internal constant DEFAULT_WXDAI = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;
    address internal constant DEFAULT_SWAPR_POSITION_MANAGER =
        0x91fD594c46D8B01E62dBDeBed2401dde01817834;
    address internal constant DEFAULT_ALGEBRA_FACTORY = 0xA0864cCA6E114013AB0e27cbd5B6f4c8947da766;
    address internal constant DEFAULT_FUTARCHY_ROUTER = 0x7495a583ba85875d59407781b4958ED6e0E1228f;

    int24 internal constant DEFAULT_TICK_LOWER = -887_220;
    int24 internal constant DEFAULT_TICK_UPPER = 887_220;

    function _readConfig(address deployer) internal view returns (DeployConfig memory cfg) {
        cfg.sale = vm.envAddress("SALE_ADDRESS");
        cfg.faoToken = vm.envAddress("FAO_TOKEN_ADDRESS");
        cfg.officialProposer = vm.envAddress("OFFICIAL_PROPOSER");
        cfg.owner = vm.envOr("STACK_OWNER", deployer);
        cfg.wrappedNative = vm.envOr("WRAPPED_NATIVE", DEFAULT_WXDAI);
        cfg.positionManager = vm.envOr("SWAPR_POSITION_MANAGER", DEFAULT_SWAPR_POSITION_MANAGER);
        cfg.algebraFactory = vm.envOr("ALGEBRA_FACTORY", DEFAULT_ALGEBRA_FACTORY);
        cfg.futarchyRouter = vm.envOr("FUTARCHY_ROUTER", DEFAULT_FUTARCHY_ROUTER);
        cfg.tickLower = int24(vm.envOr("DEFAULT_TICK_LOWER", int256(DEFAULT_TICK_LOWER)));
        cfg.tickUpper = int24(vm.envOr("DEFAULT_TICK_UPPER", int256(DEFAULT_TICK_UPPER)));
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        DeployConfig memory cfg = _readConfig(deployer);

        vm.startBroadcast(deployerPrivateKey);

        FutarchyOfficialProposalSource proposalSource = new FutarchyOfficialProposalSource(
            cfg.owner, cfg.officialProposer, IAlgebraFactoryLike(cfg.algebraFactory)
        );

        SwaprAlgebraLiquidityAdapter spotAdapter = new SwaprAlgebraLiquidityAdapter(
            ISwaprAlgebraPositionManager(cfg.positionManager), cfg.tickLower, cfg.tickUpper
        );
        SwaprAlgebraLiquidityAdapter conditionalAdapter = new SwaprAlgebraLiquidityAdapter(
            ISwaprAlgebraPositionManager(cfg.positionManager), cfg.tickLower, cfg.tickUpper
        );

        FutarchyLiquidityManager manager = new FutarchyLiquidityManager(
            cfg.sale,
            IERC20(cfg.faoToken),
            IWrappedNative(cfg.wrappedNative),
            cfg.officialProposer,
            proposalSource,
            spotAdapter,
            conditionalAdapter,
            IFutarchyConditionalRouter(cfg.futarchyRouter),
            cfg.owner
        );

        vm.stopBroadcast();

        console2.log("Deployer:", deployer);
        console2.log("Owner:", cfg.owner);
        console2.log("Sale:", cfg.sale);
        console2.log("FAO token:", cfg.faoToken);
        console2.log("Wrapped native:", cfg.wrappedNative);
        console2.log("Official proposer:", cfg.officialProposer);
        console2.log("Algebra factory:", cfg.algebraFactory);
        console2.log("Futarchy router:", cfg.futarchyRouter);
        console2.log("Swapr position manager:", cfg.positionManager);
        console2.log("Proposal source:", address(proposalSource));
        console2.log("Spot adapter:", address(spotAdapter));
        console2.log("Conditional adapter:", address(conditionalAdapter));
        console2.log("Liquidity manager (fLP):", address(manager));
    }
}
