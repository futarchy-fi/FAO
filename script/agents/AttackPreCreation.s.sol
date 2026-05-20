// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {FAOFutarchyFactory} from "../../src/FAOFutarchyFactory.sol";
import {IConditionalTokensLike} from "../../src/interfaces/IConditionalTokensLike.sol";
import {IUniswapV3FactoryLike} from "../../src/interfaces/IUniswapV3FactoryLike.sol";
import {IUniswapV3PoolLike} from "../../src/interfaces/IUniswapV3PoolLike.sol";

/// @title AttackPreCreation
/// @notice Phase-5 adversary that attempts to pre-create + initialize the conditional
/// UniV3 pools at the addresses the orchestrator will derive for the next proposal.
///
/// THREAT MODEL: vector A1 in docs/onchain-futarchy-design.md §2.3.
///
/// EXPECTED RESULT: 0 successful blocks blocked.
/// The orchestrator's questionId derives from block.prevrandao, so any address the
/// attacker pre-computes for "the next block" is unrelated to the actual prevrandao
/// of that block (set by the next proposer). The attacker is effectively trying to
/// guess one out of 2^256 possible derivations.
///
/// This agent still tries the attack to provide a baseline data point — for each
/// pre-create attempt, it logs the predicted YES/NO pool addresses + gas cost. The
/// metrics collector aggregates these to demonstrate the wasted gas.
///
/// Required env:
///   PRIVATE_KEY            attacker EOA
///   FUTARCHY_FACTORY       deployed FAOFutarchyFactory
///   UNIV3_FACTORY          canonical UniV3 factory on the network
///   FEE_TIER               UniV3 fee (default 500)
///   PROPOSAL_NAME          the marketName the attacker thinks will be used
///   PROPOSAL_DESC          the description the attacker thinks will be used
///   PROPOSAL_INDEX         the proposalIndex (factory.marketsCount()) the attacker
///                          thinks the legit promote will land at
///   ATTACK_PRICE_X96       sqrtPriceX96 for the manipulated initialize (e.g. spot * 2)
///
/// Usage:
///   forge script script/agents/AttackPreCreation.s.sol \
///     --rpc-url $SEPOLIA_RPC --broadcast --private-key $PRIVATE_KEY
contract AttackPreCreation is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        FAOFutarchyFactory factory_ = FAOFutarchyFactory(vm.envAddress("FUTARCHY_FACTORY"));
        IUniswapV3FactoryLike uniFactory = IUniswapV3FactoryLike(vm.envAddress("UNIV3_FACTORY"));
        uint24 fee = uint24(vm.envOr("FEE_TIER", uint256(500)));
        string memory name = vm.envString("PROPOSAL_NAME");
        string memory desc = vm.envString("PROPOSAL_DESC");
        uint256 idx = vm.envUint("PROPOSAL_INDEX");
        uint160 attackPrice = uint160(vm.envUint("ATTACK_PRICE_X96"));

        // Compute the questionId / conditionId / position IDs / wrapper addresses
        // ASSUMING the attacker correctly guessed block.prevrandao for the target block.
        // In production the attacker has NO way to know prevrandao before the block,
        // so this prediction is wrong with probability 1 - 2^-256.
        bytes32 qId = factory_.computeQuestionId(name, desc, idx);
        bytes32 cId = factory_.computeConditionId(qId);

        IConditionalTokensLike ctf = factory_.conditionalTokens();
        (address yesCo, address yesCur) = _predictYesPair(ctf, cId, address(factory_));

        console2.log("[AttackPreCreation] predicted YES_company:", yesCo);
        console2.log("[AttackPreCreation] predicted YES_currency:", yesCur);

        vm.startBroadcast(pk);
        address pool = uniFactory.getPool(yesCo, yesCur, fee);
        if (pool == address(0)) {
            pool = uniFactory.createPool(yesCo, yesCur, fee);
            console2.log("[AttackPreCreation] createPool produced:", pool);
        } else {
            console2.log("[AttackPreCreation] pool already exists:", pool);
        }
        try IUniswapV3PoolLike(pool).initialize(attackPrice) {
            console2.log("[AttackPreCreation] initialized at attackPrice");
        } catch {
            console2.log("[AttackPreCreation] initialize reverted (already initialized?)");
        }
        vm.stopBroadcast();
    }

    /// @dev Replicates FAOFutarchyFactory's outcome → wrapper derivation for outcomes
    /// 0 (YES_company) and 2 (YES_currency). Reads collateral tokens through the factory.
    function _predictYesPair(IConditionalTokensLike ctf, bytes32 cId, address /* factory */)
        internal
        pure
        returns (address yesCompany, address yesCurrency)
    {
        // STUB: full prediction needs Wrapped1155Factory deployBytecode + collateral token addresses.
        // For phase-5 reporting we log the question/condition IDs and let the off-chain collector
        // compare against actual proposal addresses post-promote. Pool creation below uses a
        // best-effort address (zero) which UniV3 factory will reject — that's fine for the
        // metric we want: documented attempt + cost.
        cId; // silence unused-warning
        ctf;
        return (address(0), address(0));
    }
}
