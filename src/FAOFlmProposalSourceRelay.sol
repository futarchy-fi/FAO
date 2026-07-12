// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFutarchyOfficialProposalSource} from "flm/interfaces/IFutarchyOfficialProposalSource.sol";

import {IConditionalTokensLike} from "./interfaces/IConditionalTokensLike.sol";
import {IUniswapV3FactoryLike} from "./interfaces/IUniswapV3FactoryLike.sol";

interface IFAOFlmArbitrationView {
    function activeEvaluationProposalId() external view returns (uint256);
}

interface IFAOFlmPipelineView {
    function arbitrationContract() external view returns (address);
    function futarchyProposalOf(uint256 proposalId) external view returns (address);
}

interface IFAOFlmProposalView {
    function collateralToken1() external view returns (address);
    function collateralToken2() external view returns (address);
    function conditionId() external view returns (bytes32);
    function wrappedOutcome(uint256 index) external view returns (address, bytes memory);
}

interface IFAOFlmManagerView {
    function COMPANY_TOKEN() external view returns (address);
    function WRAPPED_NATIVE() external view returns (address);
    function OFFICIAL_PROPOSER() external view returns (address);
    function PROPOSAL_SOURCE() external view returns (address);
    function inConditionalMode() external view returns (bool);
    function activeProposalId() external view returns (uint256);
    function activeProposal() external view returns (address);
    function activeYesCompanyToken() external view returns (address);
    function activeNoCompanyToken() external view returns (address);
    function activeYesCurrencyToken() external view returns (address);
    function activeNoCurrencyToken() external view returns (address);
}

/// @notice Stateless proposal-source view joining the canonical FAO evaluator to one FLM.
/// @dev While liquidity is conditional, identity is read from the manager itself. A newer
/// arbitration evaluation can therefore never replace and strand the market being restored.
contract FAOFlmProposalSourceRelay is IFutarchyOfficialProposalSource {
    IFAOFlmArbitrationView public immutable ARBITRATION;
    IFAOFlmPipelineView public immutable PIPELINE;
    IUniswapV3FactoryLike public immutable UNIV3_FACTORY;
    IConditionalTokensLike public immutable CTF;
    uint24 public immutable FEE_TIER;
    address public immutable COMPANY_TOKEN;
    address public immutable CURRENCY_TOKEN;

    IFAOFlmManagerView public MANAGER;
    address private immutable _bindingAuthority;

    error InvalidConfig();
    error ManagerAlreadyBound();
    error UnauthorizedBindingAuthority();
    error InvalidProposal();

    event ManagerBound(address indexed manager);

    constructor(
        IFAOFlmArbitrationView arbitration,
        IFAOFlmPipelineView pipeline,
        IUniswapV3FactoryLike univ3Factory,
        IConditionalTokensLike ctf,
        uint24 feeTier,
        address companyToken,
        address currencyToken
    ) {
        if (
            address(arbitration).code.length == 0 || address(pipeline).code.length == 0
                || address(univ3Factory).code.length == 0 || address(ctf).code.length == 0
                || feeTier == 0 || companyToken.code.length == 0 || currencyToken.code.length == 0
                || pipeline.arbitrationContract() != address(arbitration)
        ) revert InvalidConfig();

        ARBITRATION = arbitration;
        PIPELINE = pipeline;
        UNIV3_FACTORY = univ3Factory;
        CTF = ctf;
        FEE_TIER = feeTier;
        COMPANY_TOKEN = companyToken;
        CURRENCY_TOKEN = currencyToken;
        _bindingAuthority = msg.sender;
    }

    /// @notice Irreversibly binds the relay after the manager is deployed around its address.
    function bindManager(IFAOFlmManagerView manager) external {
        if (msg.sender != _bindingAuthority) revert UnauthorizedBindingAuthority();
        if (address(MANAGER) != address(0)) revert ManagerAlreadyBound();
        if (
            address(manager).code.length == 0 || manager.COMPANY_TOKEN() != COMPANY_TOKEN
                || manager.WRAPPED_NATIVE() != CURRENCY_TOKEN
                || manager.OFFICIAL_PROPOSER() != address(this)
                || manager.PROPOSAL_SOURCE() != address(this)
        ) revert InvalidConfig();

        MANAGER = manager;
        emit ManagerBound(address(manager));
    }

    function officialProposal()
        external
        view
        returns (
            uint256 proposalId,
            address creator,
            bool exists,
            bool settled,
            address proposalToken,
            address collateralToken,
            address yesPool,
            address noPool
        )
    {
        OfficialProposalData memory p = _officialProposalExtended();
        return (
            p.proposalId,
            p.creator,
            p.exists,
            p.settled,
            p.proposalToken,
            p.collateralToken,
            p.yesPool,
            p.noPool
        );
    }

    function officialProposalExtended()
        external
        view
        returns (OfficialProposalData memory proposalData)
    {
        return _officialProposalExtended();
    }

    function _officialProposalExtended() private view returns (OfficialProposalData memory p) {
        IFAOFlmManagerView manager = MANAGER;
        if (address(manager) == address(0)) return p;

        if (manager.inConditionalMode()) {
            p.proposalId = manager.activeProposalId();
            p.proposal = manager.activeProposal();
            p.yesCompanyToken = manager.activeYesCompanyToken();
            p.noCompanyToken = manager.activeNoCompanyToken();
            p.yesCurrencyToken = manager.activeYesCurrencyToken();
            p.noCurrencyToken = manager.activeNoCurrencyToken();
        } else {
            p.proposalId = ARBITRATION.activeEvaluationProposalId();
            if (p.proposalId == 0) return p;
            p.proposal = PIPELINE.futarchyProposalOf(p.proposalId);
            if (p.proposal == address(0)) return p;

            IFAOFlmProposalView proposal = IFAOFlmProposalView(p.proposal);
            if (
                proposal.collateralToken1() != COMPANY_TOKEN
                    || proposal.collateralToken2() != CURRENCY_TOKEN
            ) revert InvalidProposal();
            (p.yesCompanyToken,) = proposal.wrappedOutcome(0);
            (p.noCompanyToken,) = proposal.wrappedOutcome(1);
            (p.yesCurrencyToken,) = proposal.wrappedOutcome(2);
            (p.noCurrencyToken,) = proposal.wrappedOutcome(3);
        }

        if (
            p.proposal == address(0) || p.yesCompanyToken == address(0)
                || p.noCompanyToken == address(0) || p.yesCurrencyToken == address(0)
                || p.noCurrencyToken == address(0)
        ) revert InvalidProposal();

        p.creator = address(this);
        p.exists = true;
        p.proposalToken = COMPANY_TOKEN;
        p.collateralToken = CURRENCY_TOKEN;
        p.yesPool = UNIV3_FACTORY.getPool(p.yesCompanyToken, p.yesCurrencyToken, FEE_TIER);
        p.noPool = UNIV3_FACTORY.getPool(p.noCompanyToken, p.noCurrencyToken, FEE_TIER);
        p.settled = CTF.payoutDenominator(IFAOFlmProposalView(p.proposal).conditionId()) != 0;
    }
}
