// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract FlmBundleDependencyMock {}

contract FlmBundleArbitrationMock {
    uint256 public activeEvaluationProposalId;

    function setActiveEvaluationProposalId(uint256 proposalId) external {
        activeEvaluationProposalId = proposalId;
    }
}

contract FlmBundleTokenMock is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }

    receive() external payable {}
}

contract FlmBundlePoolMock {
    address public immutable token0;
    address public immutable token1;
    uint24 public constant fee = 500;

    uint160 public sqrtPriceX96 = uint160(1 << 96);
    int24 public tick;
    int24 public twapTick;
    uint16 public observationCardinality = 120;
    uint16 public observationCardinalityNext = 120;
    bool public historyAvailable = true;

    constructor(address tokenA, address tokenB) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function configure(int24 tick_, uint16 cardinality_, uint16 cardinalityNext_) external {
        tick = tick_;
        observationCardinality = cardinality_;
        observationCardinalityNext = cardinalityNext_;
    }

    function configureTwap(int24 twapTick_, bool historyAvailable_) external {
        twapTick = twapTick_;
        historyAvailable = historyAvailable_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, tick, 0, observationCardinality, observationCardinalityNext, 0, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidity)
    {
        require(
            secondsAgos.length == 2 && secondsAgos[0] == 30 minutes && secondsAgos[1] == 0, "window"
        );
        require(historyAvailable, "history");
        tickCumulatives = new int56[](2);
        secondsPerLiquidity = new uint160[](2);
        tickCumulatives[1] = int56(twapTick) * int56(uint56(30 minutes));
    }
}

contract FlmBundleUniV3FactoryMock {
    mapping(bytes32 => address) private _pool;

    function setPool(address tokenA, address tokenB, uint24 fee_, address pool_) external {
        _pool[_key(tokenA, tokenB, fee_)] = pool_;
    }

    function getPool(address tokenA, address tokenB, uint24 fee_) external view returns (address) {
        return _pool[_key(tokenA, tokenB, fee_)];
    }

    function _key(address tokenA, address tokenB, uint24 fee_) private pure returns (bytes32) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(token0, token1, fee_));
    }
}

contract FlmBundlePipelineMock {
    address public arbitrationContract;
    address public orchestrator;
    address public resolver;
    address public conditionalTokens;
    mapping(uint256 => address) public futarchyProposalOf;

    function wire(address arbitration_, address orchestrator_, address resolver_, address ctf_)
        external
    {
        arbitrationContract = arbitration_;
        orchestrator = orchestrator_;
        resolver = resolver_;
        conditionalTokens = ctf_;
    }
}

contract FlmBundleOrchestratorMock {
    address public ADMIN;
    address public FACTORY;
    address public UNIV3_FACTORY;
    address public SPOT_POOL;
    address public COMPANY_TOKEN;
    address public CURRENCY_TOKEN;
    uint24 public FEE_TIER;
    address public RESOLVER;
    bool public ADAPTER_REPLACEABLE;
    address public adapter;

    function wire(
        address admin,
        address factory,
        address univ3Factory,
        address spotPool,
        address companyToken,
        address currencyToken,
        address resolver
    ) external {
        ADMIN = admin;
        FACTORY = factory;
        UNIV3_FACTORY = univ3Factory;
        SPOT_POOL = spotPool;
        COMPANY_TOKEN = companyToken;
        CURRENCY_TOKEN = currencyToken;
        FEE_TIER = 500;
        RESOLVER = resolver;
    }
}

contract FlmBundleResolverMock {
    address public CTF;
    address public orchestrator;

    function wire(address ctf, address orchestrator_) external {
        CTF = ctf;
        orchestrator = orchestrator_;
    }
}

contract FlmBundleFutarchyFactoryMock {
    address public conditionalTokens;
    address public wrapped1155Factory;
    address public oracle;
    address public proposalImpl;

    function wire(address ctf, address wrapped1155, address oracle_, address proposalImpl_)
        external
    {
        conditionalTokens = ctf;
        wrapped1155Factory = wrapped1155;
        oracle = oracle_;
        proposalImpl = proposalImpl_;
    }
}
