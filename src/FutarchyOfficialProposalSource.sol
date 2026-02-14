// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IFutarchyOfficialProposalSource} from "./interfaces/IFutarchyOfficialProposalSource.sol";
import {IAlgebraFactoryLike} from "./interfaces/IAlgebraFactoryLike.sol";

interface IFutarchyProposalLike {
    function collateralToken1() external view returns (address);
    function collateralToken2() external view returns (address);
    function wrappedOutcome(uint256 index) external view returns (address, bytes memory);
}

interface IProposalSettlementOracle {
    function isSettled(address proposal) external view returns (bool);
}

/// @notice Owner-managed source of a single official proposal with optional oracle-based
/// settlement. @dev This enforces "one live official proposal" at a time.
contract FutarchyOfficialProposalSource is IFutarchyOfficialProposalSource, Ownable2Step {
    struct OfficialProposal {
        uint256 id;
        address proposal;
        address creator;
        bool exists;
        bool manualSettled;
    }

    struct ProposalView {
        uint256 proposalId;
        address proposal;
        address creator;
        bool exists;
        bool settled;
        address proposalToken;
        address collateralToken;
        address yesCompanyToken;
        address noCompanyToken;
        address yesCurrencyToken;
        address noCurrencyToken;
        address yesPool;
        address noPool;
    }

    IAlgebraFactoryLike public immutable ALGEBRA_FACTORY;
    address public officialProposer;
    address public settlementOracle;

    OfficialProposal private _official;

    error ZeroAddress();
    error ActiveOfficialProposalExists();
    error NotOfficialProposer();

    event OfficialProposerUpdated(address indexed oldProposer, address indexed newProposer);
    event SettlementOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event OfficialProposalSet(
        uint256 indexed proposalId, address indexed proposal, address indexed creator
    );
    event OfficialProposalCleared();
    event OfficialProposalManualSettlementUpdated(bool settled);

    constructor(
        address initialOwner,
        address initialOfficialProposer,
        IAlgebraFactoryLike algebraFactory
    ) Ownable(initialOwner) {
        if (
            initialOwner == address(0) || initialOfficialProposer == address(0)
                || address(algebraFactory) == address(0)
        ) {
            revert ZeroAddress();
        }

        officialProposer = initialOfficialProposer;
        ALGEBRA_FACTORY = algebraFactory;
    }

    function setOfficialProposer(address newOfficialProposer) external onlyOwner {
        if (newOfficialProposer == address(0)) revert ZeroAddress();
        address old = officialProposer;
        officialProposer = newOfficialProposer;
        emit OfficialProposerUpdated(old, newOfficialProposer);
    }

    function setSettlementOracle(address newOracle) external onlyOwner {
        address old = settlementOracle;
        settlementOracle = newOracle;
        emit SettlementOracleUpdated(old, newOracle);
    }

    /// @notice Sets a new official proposal, callable only by the configured official proposer.
    /// @dev This is intended for an "atomic proposer/orchestrator" contract. It prevents any
    /// other address from creating an official proposal outside that structure.
    function setOfficialProposalFromOfficialProposer(uint256 proposalId, address proposal)
        external
    {
        if (msg.sender != officialProposer) revert NotOfficialProposer();
        if (proposal == address(0)) revert ZeroAddress();
        if (_official.exists && !_isSettled(_official)) revert ActiveOfficialProposalExists();

        _official.id = proposalId;
        _official.proposal = proposal;
        _official.creator = msg.sender;
        _official.exists = true;
        _official.manualSettled = false;

        emit OfficialProposalSet(proposalId, proposal, msg.sender);
    }

    function clearOfficialProposal() external onlyOwner {
        delete _official;
        emit OfficialProposalCleared();
    }

    function setManualSettled(bool settled) external onlyOwner {
        _official.manualSettled = settled;
        emit OfficialProposalManualSettlementUpdated(settled);
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
        ProposalView memory p = _resolveOfficialProposalView();
        proposalId = p.proposalId;
        creator = p.creator;
        exists = p.exists;
        settled = p.settled;
        proposalToken = p.proposalToken;
        collateralToken = p.collateralToken;
        yesPool = p.yesPool;
        noPool = p.noPool;
    }

    function officialProposalExtended()
        external
        view
        returns (IFutarchyOfficialProposalSource.OfficialProposalData memory proposalData)
    {
        ProposalView memory p = _resolveOfficialProposalView();
        proposalData.proposalId = p.proposalId;
        proposalData.proposal = p.proposal;
        proposalData.creator = p.creator;
        proposalData.exists = p.exists;
        proposalData.settled = p.settled;
        proposalData.proposalToken = p.proposalToken;
        proposalData.collateralToken = p.collateralToken;
        proposalData.yesCompanyToken = p.yesCompanyToken;
        proposalData.noCompanyToken = p.noCompanyToken;
        proposalData.yesCurrencyToken = p.yesCurrencyToken;
        proposalData.noCurrencyToken = p.noCurrencyToken;
        proposalData.yesPool = p.yesPool;
        proposalData.noPool = p.noPool;
    }

    function currentOfficialProposal() external view returns (OfficialProposal memory) {
        return _official;
    }

    function _isSettled(OfficialProposal memory p) internal view returns (bool settled) {
        if (!p.exists || p.proposal == address(0)) return false;

        if (settlementOracle != address(0)) {
            settled = IProposalSettlementOracle(settlementOracle).isSettled(p.proposal);
            return settled;
        }

        return p.manualSettled;
    }

    function _resolveOfficialProposalView() internal view returns (ProposalView memory p) {
        OfficialProposal memory official = _official;
        p.proposalId = official.id;
        p.proposal = official.proposal;
        p.creator = official.creator;
        p.exists = official.exists;
        p.settled = _isSettled(official);

        if (!p.exists || p.proposal == address(0)) {
            return p;
        }

        IFutarchyProposalLike proposal = IFutarchyProposalLike(p.proposal);
        p.proposalToken = proposal.collateralToken1();
        p.collateralToken = proposal.collateralToken2();

        (p.yesCompanyToken,) = proposal.wrappedOutcome(0);
        (p.noCompanyToken,) = proposal.wrappedOutcome(1);
        (p.yesCurrencyToken,) = proposal.wrappedOutcome(2);
        (p.noCurrencyToken,) = proposal.wrappedOutcome(3);

        p.yesPool = ALGEBRA_FACTORY.poolByPair(p.yesCompanyToken, p.yesCurrencyToken);
        p.noPool = ALGEBRA_FACTORY.poolByPair(p.noCompanyToken, p.noCurrencyToken);
    }
}
