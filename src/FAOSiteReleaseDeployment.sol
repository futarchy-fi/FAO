// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Space} from "sx/Space.sol";
import {
    VanillaProposalValidationStrategy
} from "sx/proposal-validation-strategies/VanillaProposalValidationStrategy.sol";

import {AlwaysZeroVotingStrategy} from "./AlwaysZeroVotingStrategy.sol";
import {EvaluationPipeline} from "./EvaluationPipeline.sol";
import {FutarchyArbitration} from "./FutarchyArbitration.sol";
import {FutarchyLiquidityManager} from "./FutarchyLiquidityManager.sol";
import {
    FutarchyOfficialProposalOrchestrator,
    IFutarchyFactoryLike
} from "./FutarchyOfficialProposalOrchestrator.sol";
import {FutarchyOfficialProposalSource} from "./FutarchyOfficialProposalSource.sol";
import {FutarchyTWAPOracle} from "./FutarchyTWAPOracle.sol";
import {SXArbitrationExecutionStrategy} from "./SXArbitrationExecutionStrategy.sol";
import {SXProposalGateway} from "./SXProposalGateway.sol";
import {IAlgebraFactoryLike} from "./interfaces/IAlgebraFactoryLike.sol";
import {ISwaprAlgebraPositionManager} from "./interfaces/ISwaprAlgebraPositionManager.sol";
import {InitializeCalldata, Strategy} from "./types.sol";

interface ICtfSettlementOracleLike {
    function ROUTER() external view returns (address);
}

/// @notice One-transaction deployment receipt for the ownerless FAO site-release stack.
contract FAOSiteReleaseDeployment {
    struct Dependency {
        address target;
        bytes32 codehash;
    }

    struct Config {
        bytes32 spaceImplementationCodehash;
        Dependency bondToken;
        uint256 graduationThreshold;
        uint256 arbitrationTimeout;
        uint256 minActivationBond;
        Dependency futarchyFactory;
        Dependency algebraFactory;
        Dependency positionManager;
        Dependency manager;
        Dependency proposalSource;
        Dependency settlementOracle;
        Dependency faoToken;
        Dependency wrappedNative;
        Dependency sale;
        Dependency spotAdapter;
        Dependency conditionalAdapter;
        Dependency conditionalRouter;
        Dependency spotPool;
        uint32 tradingPeriod;
        uint32 twapWindow;
        int24 thresholdTicks;
        uint256 evaluationMinBond;
        uint32 marketOpeningDelay;
        string daoURI;
        string metadataURI;
    }

    struct EvaluatorStack {
        address evaluator;
        address orchestrator;
        address twapOracle;
    }

    error InvalidCodehash(address target, bytes32 expected, bytes32 actual);
    error InvalidDependency(address dependency);
    error InvalidDownstreamWiring();
    error UnexpectedDeploymentAddress(address expected, address actual);

    event SiteReleaseStackDeployed(
        address indexed space,
        address indexed arbitration,
        address indexed proposalGateway,
        address releaseStrategy,
        address votingStrategy,
        address proposalValidationStrategy
    );
    event EvaluatorStackDeployed(
        address indexed evaluator, address indexed orchestrator, address indexed twapOracle
    );

    address public immutable spaceImplementation;
    address public immutable space;
    address public immutable arbitration;
    address public immutable proposalGateway;
    address public immutable releaseStrategy;
    address public immutable votingStrategy;
    address public immutable proposalValidationStrategy;
    address public immutable evaluator;
    address public immutable orchestrator;
    address public immutable twapOracle;

    /// @param config Pins the external futarchy dependencies and all market parameters.
    /// The evaluator stack is deployed and wired before ownership is permanently renounced.
    constructor(address spaceImplementation_, Config memory config) {
        bytes32 implementationCodehash = spaceImplementation_.codehash;
        if (
            spaceImplementation_.code.length == 0
                || implementationCodehash != config.spaceImplementationCodehash
        ) {
            revert InvalidCodehash(
                spaceImplementation_, config.spaceImplementationCodehash, implementationCodehash
            );
        }
        _validateDependencies(config);

        FutarchyArbitration arbitration_ = new FutarchyArbitration(
            IERC20(config.bondToken.target), config.graduationThreshold, config.arbitrationTimeout
        );
        Space space_ = Space(address(new ERC1967Proxy(spaceImplementation_, "")));
        SXArbitrationExecutionStrategy releaseStrategy_ =
            new SXArbitrationExecutionStrategy(address(space_), address(arbitration_));
        AlwaysZeroVotingStrategy votingStrategy_ = new AlwaysZeroVotingStrategy();
        SXProposalGateway proposalGateway_ = new SXProposalGateway(
            address(space_),
            address(releaseStrategy_),
            address(arbitration_),
            config.minActivationBond
        );
        VanillaProposalValidationStrategy proposalValidationStrategy_ =
            new VanillaProposalValidationStrategy();

        EvaluatorStack memory evaluatorStack = _deployEvaluatorStack(arbitration_, config);

        arbitration_.setProposalGateway(address(proposalGateway_));
        arbitration_.setEvaluator(evaluatorStack.evaluator);

        Strategy[] memory votingStrategies = new Strategy[](1);
        votingStrategies[0] = Strategy({addr: address(votingStrategy_), params: ""});

        string[] memory votingStrategyMetadataURIs = new string[](1);
        votingStrategyMetadataURIs[0] = "AlwaysZeroVotingStrategy";

        address[] memory authenticators = new address[](1);
        authenticators[0] = address(proposalGateway_);

        space_.initialize(
            InitializeCalldata({
                owner: address(this),
                votingDelay: 0,
                minVotingDuration: 0,
                maxVotingDuration: 0,
                proposalValidationStrategy: Strategy({
                    addr: address(proposalValidationStrategy_), params: ""
                }),
                proposalValidationStrategyMetadataURI: "VanillaProposalValidationStrategy",
                daoURI: config.daoURI,
                metadataURI: config.metadataURI,
                votingStrategies: votingStrategies,
                votingStrategyMetadataURIs: votingStrategyMetadataURIs,
                authenticators: authenticators
            })
        );

        space_.renounceOwnership();
        arbitration_.renounceOwnership();

        spaceImplementation = spaceImplementation_;
        space = address(space_);
        arbitration = address(arbitration_);
        proposalGateway = address(proposalGateway_);
        releaseStrategy = address(releaseStrategy_);
        votingStrategy = address(votingStrategy_);
        proposalValidationStrategy = address(proposalValidationStrategy_);
        evaluator = evaluatorStack.evaluator;
        orchestrator = evaluatorStack.orchestrator;
        twapOracle = evaluatorStack.twapOracle;

        emit SiteReleaseStackDeployed(
            address(space_),
            address(arbitration_),
            address(proposalGateway_),
            address(releaseStrategy_),
            address(votingStrategy_),
            address(proposalValidationStrategy_)
        );
        emit EvaluatorStackDeployed(
            evaluatorStack.evaluator, evaluatorStack.orchestrator, evaluatorStack.twapOracle
        );
    }

    function _deployEvaluatorStack(FutarchyArbitration arbitration_, Config memory config)
        private
        returns (EvaluatorStack memory stack)
    {
        address expectedOrchestrator = _createAddress(7);
        address expectedEvaluator = _createAddress(9);
        _validateDownstream(config, expectedOrchestrator);

        FutarchyOfficialProposalOrchestrator orchestrator_ = new FutarchyOfficialProposalOrchestrator(
            expectedEvaluator,
            IFutarchyFactoryLike(config.futarchyFactory.target),
            IAlgebraFactoryLike(config.algebraFactory.target),
            ISwaprAlgebraPositionManager(config.positionManager.target)
        );
        if (address(orchestrator_) != expectedOrchestrator) {
            revert UnexpectedDeploymentAddress(expectedOrchestrator, address(orchestrator_));
        }

        FutarchyTWAPOracle twapOracle_ = new FutarchyTWAPOracle(
            expectedEvaluator, config.tradingPeriod, config.twapWindow, config.thresholdTicks
        );
        EvaluationPipeline evaluator_ = new EvaluationPipeline(
            address(arbitration_),
            address(orchestrator_),
            address(twapOracle_),
            config.algebraFactory.target,
            config.manager.target,
            config.proposalSource.target,
            config.evaluationMinBond,
            config.marketOpeningDelay
        );
        if (address(evaluator_) != expectedEvaluator) {
            revert UnexpectedDeploymentAddress(expectedEvaluator, address(evaluator_));
        }
        if (
            orchestrator_.ADMIN() != address(evaluator_) || !orchestrator_.wired()
                || address(orchestrator_.FUTARCHY_FACTORY()) != config.futarchyFactory.target
                || address(orchestrator_.ALGEBRA_FACTORY()) != config.algebraFactory.target
                || address(orchestrator_.POSITION_MANAGER()) != config.positionManager.target
                || address(orchestrator_.manager()) != config.manager.target
                || address(orchestrator_.proposalSource()) != config.proposalSource.target
                || twapOracle_.binder() != address(evaluator_)
                || twapOracle_.tradingPeriod() != config.tradingPeriod
                || twapOracle_.twapWindow() != config.twapWindow
                || twapOracle_.thresholdTicks() != config.thresholdTicks
                || evaluator_.arbitration() != address(arbitration_)
                || address(evaluator_.orchestrator()) != address(orchestrator_)
                || address(evaluator_.twapOracle()) != address(twapOracle_)
                || address(evaluator_.algebraFactory()) != config.algebraFactory.target
                || evaluator_.evaluationMinBond() != config.evaluationMinBond
                || evaluator_.marketOpeningDelay() != config.marketOpeningDelay
        ) revert InvalidDownstreamWiring();

        stack = EvaluatorStack({
            evaluator: address(evaluator_),
            orchestrator: address(orchestrator_),
            twapOracle: address(twapOracle_)
        });
    }

    function _validateDependencies(Config memory config) private view {
        _requireDependency(config.bondToken);
        _requireDependency(config.futarchyFactory);
        _requireDependency(config.algebraFactory);
        _requireDependency(config.positionManager);
        _requireDependency(config.manager);
        _requireDependency(config.proposalSource);
        _requireDependency(config.settlementOracle);
        _requireDependency(config.faoToken);
        _requireDependency(config.wrappedNative);
        _requireDependency(config.sale);
        _requireDependency(config.spotAdapter);
        _requireDependency(config.conditionalAdapter);
        _requireDependency(config.conditionalRouter);
        _requireDependency(config.spotPool);
    }

    function _validateDownstream(Config memory config, address expectedOrchestrator) private view {
        FutarchyLiquidityManager manager_ = FutarchyLiquidityManager(payable(config.manager.target));
        FutarchyOfficialProposalSource source_ =
            FutarchyOfficialProposalSource(config.proposalSource.target);
        FutarchyOfficialProposalSource.OfficialProposal memory official =
            source_.currentOfficialProposal();

        if (
            manager_.OFFICIAL_PROPOSER() != expectedOrchestrator
                || address(manager_.PROPOSAL_SOURCE()) != config.proposalSource.target
                || address(manager_.FAO_TOKEN()) != config.faoToken.target
                || address(manager_.WRAPPED_NATIVE()) != config.wrappedNative.target
                || manager_.SALE() != config.sale.target
                || address(manager_.SPOT_ADAPTER()) != config.spotAdapter.target
                || address(manager_.CONDITIONAL_ADAPTER()) != config.conditionalAdapter.target
                || address(manager_.CONDITIONAL_ROUTER()) != config.conditionalRouter.target
                || manager_.owner() != address(0) || manager_.pendingOwner() != address(0)
                || manager_.emergencyExitArmedAt() != 0 || manager_.emergencyExitExecuted()
                || manager_.inConditionalMode() || manager_.activeProposalId() != 0
                || manager_.activeProposal() != address(0)
                || source_.officialProposer() != expectedOrchestrator
                || address(source_.ALGEBRA_FACTORY()) != config.algebraFactory.target
                || source_.settlementOracle() != config.settlementOracle.target
                || source_.owner() != address(0) || source_.pendingOwner() != address(0)
                || official.exists
                || ICtfSettlementOracleLike(config.settlementOracle.target).ROUTER()
                    != config.conditionalRouter.target
                || IAlgebraFactoryLike(config.algebraFactory.target)
                        .poolByPair(config.faoToken.target, config.wrappedNative.target)
                    != config.spotPool.target
        ) revert InvalidDownstreamWiring();
    }

    function _requireDependency(Dependency memory dependency) private view {
        bytes32 actual = dependency.target.codehash;
        if (dependency.target.code.length == 0) revert InvalidDependency(dependency.target);
        if (actual != dependency.codehash) {
            revert InvalidCodehash(dependency.target, dependency.codehash, actual);
        }
    }

    function _createAddress(uint8 nonce) private view returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(this), bytes1(nonce)))))
        );
    }
}
