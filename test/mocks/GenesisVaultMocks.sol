// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IGenesisArbitration} from "../../src/GenesisVault.sol";

contract GenesisWethMock is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);
    }

    receive() external payable {}
}

contract GenesisAssetMock is ERC20 {
    constructor(string memory symbol_) ERC20(symbol_, symbol_) {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract GenesisFeeAssetMock is GenesisAssetMock {
    constructor() GenesisAssetMock("FEE") {}

    function _transfer(address sender, address recipient, uint256 amount) internal override {
        super._transfer(sender, recipient, amount - 1);
        _burn(sender, 1);
    }
}

contract GenesisArbitrationMock {
    mapping(uint256 proposalId => IGenesisArbitration.Proposal proposal) internal proposals;

    function setOutcome(uint256 proposalId, bool settled, bool accepted) external {
        _setOutcome(proposalId, settled, accepted, true);
    }

    function setOutcome(uint256 proposalId, bool settled, bool accepted, bool evaluated) external {
        _setOutcome(proposalId, settled, accepted, evaluated);
    }

    function isSettled(uint256 proposalId) external view returns (bool) {
        return proposals[proposalId].settled;
    }

    function isAccepted(uint256 proposalId) external view returns (bool) {
        IGenesisArbitration.Proposal memory proposal = proposals[proposalId];
        return proposal.settled && proposal.accepted;
    }

    function getProposal(uint256 proposalId)
        external
        view
        returns (IGenesisArbitration.Proposal memory)
    {
        require(proposals[proposalId].exists);
        return proposals[proposalId];
    }

    function _setOutcome(uint256 proposalId, bool settled, bool accepted, bool evaluated) private {
        IGenesisArbitration.Proposal storage proposal = proposals[proposalId];
        proposal.state = settled
            ? IGenesisArbitration.ProposalState.SETTLED
            : IGenesisArbitration.ProposalState.YES;
        proposal.lastStateChangeAt = uint64(block.timestamp);
        proposal.settled = settled;
        proposal.accepted = accepted;
        proposal.queuePosition = evaluated ? 1 : 0;
        proposal.exists = true;
    }
}

contract GenesisManagerMock is ERC20 {
    using SafeERC20 for IERC20;

    address public immutable BOOTSTRAP_RECIPIENT;
    address public immutable COMPANY_TOKEN;
    address public immutable WRAPPED_NATIVE;
    address public constant owner = address(0xdead);

    bool public initializedFromBootstrap;
    bool public revertBootstrap;
    bool public inConditionalMode;
    uint16 public companyUsageBps = 8000;
    uint16 public collateralUsageBps = 8000;

    constructor(address vault, address companyToken, address weth) ERC20("FLM Share", "FLM") {
        BOOTSTRAP_RECIPIENT = vault;
        COMPANY_TOKEN = companyToken;
        WRAPPED_NATIVE = weth;
    }

    function setRevertBootstrap(bool value) external {
        revertBootstrap = value;
    }

    function setUsage(uint16 companyBps, uint16 collateralBps) external {
        require(companyBps <= 10_000 && collateralBps <= 10_000);
        companyUsageBps = companyBps;
        collateralUsageBps = collateralBps;
    }

    function setConditionalMode(bool value) external {
        inConditionalMode = value;
    }

    function initializeFromBootstrap(uint256 companyAmount, uint256 collateralAmount)
        external
        returns (uint128 liquidityMinted)
    {
        require(msg.sender == BOOTSTRAP_RECIPIENT);
        require(!initializedFromBootstrap);
        if (revertBootstrap) revert("POOL_NOT_READY");
        initializedFromBootstrap = true;

        uint256 companyUsed = companyAmount * companyUsageBps / 10_000;
        uint256 collateralUsed = collateralAmount * collateralUsageBps / 10_000;
        IERC20(COMPANY_TOKEN).safeTransferFrom(msg.sender, address(this), companyUsed);
        IERC20(WRAPPED_NATIVE).safeTransferFrom(msg.sender, address(this), collateralUsed);
        uint256 shares = companyUsed < collateralUsed ? companyUsed : collateralUsed;
        require(shares != 0 && shares <= type(uint128).max);
        liquidityMinted = uint128(shares);
        _mint(msg.sender, shares);
    }
}

contract GenesisBootstrapHookMock {
    bool public shouldRevert;
    uint256 public calls;
    uint256 public lastTerminalPrice;

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function prepareAndAssert(uint256 terminalPrice) external {
        if (shouldRevert) revert("POOL_PRICE_MISMATCH");
        ++calls;
        lastTerminalPrice = terminalPrice;
    }
}

contract GenesisNativeForwarder {
    address payable public immutable sink;

    constructor(address payable sink_) {
        sink = sink_;
    }

    receive() external payable {
        (bool ok,) = sink.call{value: msg.value}("");
        require(ok);
    }
}

contract GenesisTreasuryTargetMock {
    uint256 public calls;
    uint256 public value;
    bytes32 public payload;
    address public caller;

    function perform(bytes32 payload_) external payable returns (uint256) {
        ++calls;
        value += msg.value;
        payload = payload_;
        caller = msg.sender;
        return calls;
    }
}
