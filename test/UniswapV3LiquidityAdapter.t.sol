// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {
    UniswapV3LiquidityAdapter,
    IERC20Minimal,
    IUniswapV3MintCallback,
    IConditionalTokensSplitAndTransfer
} from "../src/UniswapV3LiquidityAdapter.sol";
import {FAOFutarchyProposal} from "../src/FAOFutarchyProposal.sol";
import {IConditionalTokensLike} from "../src/interfaces/IConditionalTokensLike.sol";
import {IWrapped1155FactoryLike} from "../src/interfaces/IWrapped1155FactoryLike.sol";
import {IUniswapV3PoolLike} from "../src/interfaces/IUniswapV3PoolLike.sol";
import {IFAOFutarchyOracle} from "../src/interfaces/IFAOFutarchyOracle.sol";
import {UniV3Math} from "../src/libraries/UniV3Math.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Mocks
// ─────────────────────────────────────────────────────────────────────────────

contract MockERC20 is IERC20Minimal {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IMockWrapper {
    function mint(address to, uint256 amount) external;
}

/// @dev Mock Wrapped1155 ERC20 instance that the wrapper-factory mock deploys
/// per-tokenId. Implements `onERC1155Received` so that `CTF.safeTransferFrom`
/// addressed to it triggers the wrap.
contract MockWrapped1155 is IERC20Minimal, IMockWrapper {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    address public ctf;
    uint256 public tokenId;
    bytes public tokenData;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory _name, address _ctf, uint256 _tokenId, bytes memory _tokenData) {
        name = _name;
        symbol = _name;
        ctf = _ctf;
        tokenId = _tokenId;
        tokenData = _tokenData;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) external override {
        require(msg.sender == ctf, "only ctf can mint via callback");
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    /// @notice Called by CTF.safeTransferFrom — wraps 1:1.
    function onERC1155Received(address operator, address, uint256, uint256 value, bytes calldata)
        external
        returns (bytes4)
    {
        require(msg.sender == ctf, "only ctf");
        balanceOf[operator] += value;
        totalSupply += value;
        // ERC1155 magic value
        return bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"));
    }
}

/// @dev Mock CTF with a working splitPosition + safeTransferFrom + balances book.
/// Tracks per-(owner, tokenId) ERC1155 balances; splitPosition mints to caller.
contract MockCTFFull is IConditionalTokensLike, IConditionalTokensSplitAndTransfer {
    mapping(bytes32 => uint256) public slots;
    mapping(bytes32 => uint256[]) internal _payouts;
    mapping(bytes32 => uint256) public payoutDenominator;
    mapping(address => mapping(uint256 => uint256)) public erc1155Balance;

    event SplitPosition(
        address indexed who, address indexed collateral, bytes32 conditionId, uint256[] partition, uint256 amount
    );
    event Erc1155Transfer(address indexed from, address indexed to, uint256 indexed id, uint256 value);

    function payoutNumerators(bytes32 cid, uint256 i) external view returns (uint256) {
        if (_payouts[cid].length <= i) return 0;
        return _payouts[cid][i];
    }

    function prepareCondition(address oracle, bytes32 qId, uint256 n) external {
        bytes32 cid = getConditionId(oracle, qId, n);
        require(slots[cid] == 0);
        slots[cid] = n;
    }

    function reportPayouts(bytes32 qId, uint256[] calldata p) external {
        bytes32 cid = getConditionId(msg.sender, qId, p.length);
        require(payoutDenominator[cid] == 0);
        uint256 s;
        for (uint256 i; i < p.length; i++) s += p[i];
        _payouts[cid] = p;
        payoutDenominator[cid] = s;
    }

    function getConditionId(address oracle, bytes32 qId, uint256 n) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(oracle, qId, n));
    }

    function getCollectionId(bytes32 parent, bytes32 cid, uint256 idx) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(parent, cid, idx));
    }

    function getPositionId(address c, bytes32 col) external pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(c, col)));
    }

    function getOutcomeSlotCount(bytes32 cid) external view returns (uint256) {
        return slots[cid];
    }

    function splitPosition(
        address collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external override {
        // pull collateral from caller (caller approved CTF)
        require(IERC20Minimal(collateralToken).transferFrom(msg.sender, address(this), amount), "xfer-fail");
        // mint 1 ERC1155 per partition element to the caller
        for (uint256 i = 0; i < partition.length; i++) {
            bytes32 collId = keccak256(abi.encodePacked(parentCollectionId, conditionId, partition[i]));
            uint256 tokenId = uint256(keccak256(abi.encodePacked(collateralToken, collId)));
            erc1155Balance[msg.sender][tokenId] += amount;
        }
        emit SplitPosition(msg.sender, collateralToken, conditionId, partition, amount);
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes calldata data)
        external
        override
    {
        require(erc1155Balance[from][id] >= value, "1155-balance");
        erc1155Balance[from][id] -= value;
        erc1155Balance[to][id] += value;
        emit Erc1155Transfer(from, to, id, value);

        // call onERC1155Received on the receiver if it's a contract
        if (_isContract(to)) {
            (bool ok, bytes memory ret) = to.call(
                abi.encodeWithSignature(
                    "onERC1155Received(address,address,uint256,uint256,bytes)", msg.sender, from, id, value, data
                )
            );
            require(ok, "1155-recv-revert");
            require(
                abi.decode(ret, (bytes4))
                    == bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)")),
                "1155-recv-bad-magic"
            );
        }
    }

    function _isContract(address a) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(a)
        }
        return size > 0;
    }
}

/// @dev Wrapped1155 factory that lazily deploys per-(tokenId,data) wrapper ERC20s.
contract MockW1155Factory is IWrapped1155FactoryLike {
    mapping(bytes32 => address) public wrapped;

    function requireWrapped1155(address mt, uint256 id, bytes calldata data) external returns (address) {
        bytes32 s = keccak256(abi.encodePacked(mt, id, data));
        address w = wrapped[s];
        if (w == address(0)) {
            string memory n = _decodeName(data);
            w = address(new MockWrapped1155(n, mt, id, data));
            wrapped[s] = w;
        }
        return w;
    }

    function _decodeName(bytes calldata data) internal pure returns (string memory) {
        // data is name32||symbol32||uint8 -> take name32 and strip the 1-byte length suffix (matches FAOFutarchyFactory metadata)
        bytes32 name32;
        assembly {
            name32 := calldataload(data.offset)
        }
        uint256 len = uint256(uint8(uint256(name32) & 0xff)) >> 1;
        bytes memory out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = name32[i];
        }
        return string(out);
    }
}

/// @dev UniV3 pool mock that actually invokes the mint callback and tracks pulled
/// token amounts. Honours `LiquidityAmounts.getAmountsForLiquidity` approximation
/// for full-range positions: it requests `liquidity` of token0 and token1 each.
/// That's overly simplified but enough to validate the callback wiring; the math
/// itself is unit-tested separately.
contract MockUniV3PoolFull is IUniswapV3PoolLike {
    uint160 public sqrtPriceX96;
    address public token0Addr;
    address public token1Addr;
    uint24 internal _fee;
    uint16 public cardinality;
    int24 public twapTick;

    uint128 public lastLiquidity;
    int24 public lastTickLower;
    int24 public lastTickUpper;
    uint256 public received0;
    uint256 public received1;

    /// @dev Per-mint owed amounts. The adapter's stage amounts come in as
    /// (companyAmt, currencyAmt) and the test selects which is which for token0/1.
    uint256 public expectedAmount0;
    uint256 public expectedAmount1;

    constructor(address a, address b, uint24 f) {
        (token0Addr, token1Addr) = a < b ? (a, b) : (b, a);
        _fee = f;
    }

    function token0() external view returns (address) {
        return token0Addr;
    }

    function token1() external view returns (address) {
        return token1Addr;
    }

    function fee() external view returns (uint24) {
        return _fee;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, twapTick, 0, 1, cardinality, 0, true);
    }

    function initialize(uint160 s) external {
        require(sqrtPriceX96 == 0);
        sqrtPriceX96 = s;
    }

    function increaseObservationCardinalityNext(uint16 n) external {
        cardinality = n;
    }

    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory tc, uint160[] memory lc) {
        tc = new int56[](secondsAgos.length);
        lc = new uint160[](secondsAgos.length);
    }

    function setExpected(uint256 a0, uint256 a1) external {
        expectedAmount0 = a0;
        expectedAmount1 = a1;
    }

    function mint(address, int24 tickLower, int24 tickUpper, uint128 liquidity, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        lastLiquidity = liquidity;
        lastTickLower = tickLower;
        lastTickUpper = tickUpper;
        amount0 = expectedAmount0;
        amount1 = expectedAmount1;

        // Invoke the mint callback on caller; caller must transfer tokens to this pool.
        uint256 bal0Before = IERC20Minimal(token0Addr).balanceOf(address(this));
        uint256 bal1Before = IERC20Minimal(token1Addr).balanceOf(address(this));
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);
        uint256 bal0After = IERC20Minimal(token0Addr).balanceOf(address(this));
        uint256 bal1After = IERC20Minimal(token1Addr).balanceOf(address(this));
        require(bal0After - bal0Before == amount0, "M0");
        require(bal1After - bal1Before == amount1, "M1");
        received0 += amount0;
        received1 += amount1;
    }
}

/// @dev Minimal proposal that returns a pre-set conditionId + 4 wrappers.
contract MockProposal {
    bytes32 internal _conditionId;
    address[4] internal _wrappers;
    bytes[4] internal _data;

    function set(bytes32 cId, address[4] memory w, bytes[4] memory d) external {
        _conditionId = cId;
        _wrappers = w;
        _data = d;
    }

    function conditionId() external view returns (bytes32) {
        return _conditionId;
    }

    function wrappedOutcome(uint256 idx) external view returns (address, bytes memory) {
        return (_wrappers[idx], _data[idx]);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

contract UniswapV3LiquidityAdapterTest is Test {
    uint160 internal constant SQRT_1 = 79228162514264337593543950336; // sqrt(1) in X96
    uint24 internal constant FEE = 500;

    UniswapV3LiquidityAdapter adapter;
    MockCTFFull ctf;
    MockW1155Factory w1155;
    MockERC20 fao;
    MockERC20 weth;
    address orchestrator = address(0xCC0CC0);
    address user = address(0xBEEF);

    // ─── shared setup ──────────────────────────────────────────────────────

    function setUp() public {
        ctf = new MockCTFFull();
        w1155 = new MockW1155Factory();
        fao = new MockERC20("FAO");
        weth = new MockERC20("WETH");

        adapter = new UniswapV3LiquidityAdapter(
            IConditionalTokensLike(address(ctf)),
            IWrapped1155FactoryLike(address(w1155)),
            orchestrator,
            address(fao),
            address(weth)
        );
    }

    function _setupProposalAndPools(uint256 companyAmt, uint256 currencyAmt)
        internal
        returns (MockProposal proposal, MockUniV3PoolFull yesPool, MockUniV3PoolFull noPool, bytes32 conditionId)
    {
        // Generate a deterministic conditionId for the test.
        conditionId = keccak256(abi.encodePacked("test-condition", block.timestamp));

        // Deploy the 4 wrappers via the W1155 factory using the same metadata pattern
        // FAOFutarchyFactory uses. Names: "YES_FAO", "NO_FAO", "YES_WETH", "NO_WETH".
        address[4] memory wrappers;
        bytes[4] memory datas;
        string[4] memory names = ["YES_FAO", "NO_FAO", "YES_WETH", "NO_WETH"];
        address[4] memory collaterals = [address(fao), address(fao), address(weth), address(weth)];
        for (uint256 j = 0; j < 4; j++) {
            uint256 indexSet = j == 0 || j == 2 ? 1 : 2; // YES=1, NO=2
            bytes32 collectionId = ctf.getCollectionId(bytes32(0), conditionId, indexSet);
            uint256 tokenId = ctf.getPositionId(collaterals[j], collectionId);
            bytes memory data = _encodeWrapperMetadata(names[j]);
            wrappers[j] = w1155.requireWrapped1155(address(ctf), tokenId, data);
            datas[j] = data;
        }

        proposal = new MockProposal();
        proposal.set(conditionId, wrappers, datas);

        // Deploy pools (token ordering set in constructor).
        yesPool = new MockUniV3PoolFull(wrappers[0], wrappers[2], FEE);
        yesPool.initialize(SQRT_1);
        noPool = new MockUniV3PoolFull(wrappers[1], wrappers[3], FEE);
        noPool.initialize(SQRT_1);

        // The adapter passes liquidity to mint(). Our mock pool returns
        // expectedAmount0/1 from setExpected. We pre-compute these:
        // For full range + current sqrt = SQRT_1, getLiquidityForAmounts will yield
        // a liquidity number L; the equivalent amounts at the in-range mint should
        // approximately equal what we staged. We just demand the adapter sends EXACTLY
        // the amounts the pool requests; the pool requests amounts equal to what the
        // adapter holds (set via setExpected to companyAmt/currencyAmt mapped to t0/t1).
        // forge-lint: disable-next-line(unsafe-typecast)
        (uint256 e0, uint256 e1) = yesPool.token0() == wrappers[0]
            ? (companyAmt, currencyAmt)
            : (currencyAmt, companyAmt);
        yesPool.setExpected(e0, e1);
        (uint256 n0, uint256 n1) = noPool.token0() == wrappers[1]
            ? (companyAmt, currencyAmt)
            : (currencyAmt, companyAmt);
        noPool.setExpected(n0, n1);
    }

    function _encodeWrapperMetadata(string memory name) internal pure returns (bytes memory) {
        bytes32 n = _toString31(name);
        return abi.encodePacked(n, n, uint8(18));
    }

    function _toString31(string memory v) internal pure returns (bytes32 e) {
        uint256 len = bytes(v).length;
        assembly {
            e := mload(add(v, 0x20))
        }
        bytes32 mask = bytes32(type(uint256).max << ((32 - len) << 3));
        e = (e & mask) | bytes32(len << 1);
    }

    function _seedAndApprove(uint256 companyAmt, uint256 currencyAmt) internal {
        fao.mint(user, companyAmt);
        weth.mint(user, currencyAmt);
        vm.startPrank(user);
        fao.approve(address(adapter), type(uint256).max);
        weth.approve(address(adapter), type(uint256).max);
        vm.stopPrank();
    }

    // ─── stage ─────────────────────────────────────────────────────────────

    function test_stage_storesAmounts() public {
        vm.prank(user);
        adapter.stage(1_000 ether, 5 ether);
        (uint128 c, uint128 cu) = adapter.stagedFor(user);
        assertEq(c, 1_000 ether);
        assertEq(cu, 5 ether);
    }

    function test_stage_zeroReverts() public {
        vm.expectRevert(UniswapV3LiquidityAdapter.ZeroAmount.selector);
        vm.prank(user);
        adapter.stage(0, 1 ether);
    }

    // ─── migrate: pull tokens ───────────────────────────────────────────────

    function test_migrate_pullsTokensFromTxOrigin() public {
        uint256 companyAmt = 1_000 ether;
        uint256 currencyAmt = 5 ether;
        _seedAndApprove(companyAmt, currencyAmt);
        vm.prank(user);
        adapter.stage(companyAmt, currencyAmt);

        (MockProposal proposal,, MockUniV3PoolFull yesPool, MockUniV3PoolFull noPool, bytes32 cId) =
            _runMigrate(companyAmt, currencyAmt);
        proposal;
        yesPool;
        noPool;
        cId;

        // user fully drained
        assertEq(fao.balanceOf(user), 0, "user FAO drained");
        assertEq(weth.balanceOf(user), 0, "user WETH drained");
    }

    // wrapper because tuple unpacking in the assertion test
    function _runMigrate(uint256 companyAmt, uint256 currencyAmt)
        internal
        returns (MockProposal, bytes32, MockUniV3PoolFull, MockUniV3PoolFull, bytes32)
    {
        (MockProposal proposal, MockUniV3PoolFull yp, MockUniV3PoolFull np, bytes32 cId) =
            _setupProposalAndPools(companyAmt, currencyAmt);

        vm.prank(orchestrator, user); // msg.sender=orchestrator, tx.origin=user
        adapter.migrate(address(proposal), address(yp), address(np), address(0), SQRT_1);

        return (proposal, cId, yp, np, cId);
    }

    // ─── migrate: split ─────────────────────────────────────────────────────

    function test_migrate_splitsPositionForBothCollaterals() public {
        uint256 companyAmt = 1_000 ether;
        uint256 currencyAmt = 5 ether;
        _seedAndApprove(companyAmt, currencyAmt);
        vm.prank(user);
        adapter.stage(companyAmt, currencyAmt);

        (, bytes32 cId,,,) = _runMigrate(companyAmt, currencyAmt);

        // CTF should now hold both collaterals (transferred in during splitPosition).
        assertEq(fao.balanceOf(address(ctf)), companyAmt, "ctf holds company");
        assertEq(weth.balanceOf(address(ctf)), currencyAmt, "ctf holds currency");
        cId;
    }

    // ─── migrate: wrap ──────────────────────────────────────────────────────

    function test_migrate_wrapsErc1155ToErc20() public {
        uint256 companyAmt = 1_000 ether;
        uint256 currencyAmt = 5 ether;
        _seedAndApprove(companyAmt, currencyAmt);
        vm.prank(user);
        adapter.stage(companyAmt, currencyAmt);

        (MockProposal proposal,,,,) = _runMigrate(companyAmt, currencyAmt);

        // Read wrappers from proposal (same order as adapter does it: 0=YES_co, 1=NO_co, 2=YES_cur, 3=NO_cur)
        (address yesCo,) = proposal.wrappedOutcome(0);
        (address noCo,) = proposal.wrappedOutcome(1);
        (address yesCur,) = proposal.wrappedOutcome(2);
        (address noCur,) = proposal.wrappedOutcome(3);

        // After wrap, adapter holds 0 ERC1155 (all sent to wrappers).
        // and the wrappers should have minted ERC20 to the adapter. But the adapter then
        // forwards to pools, so the wrappers should now show pool balances.
        // Just assert wrapper totalSupply equals what we expect.
        assertEq(MockWrapped1155(yesCo).totalSupply(), companyAmt, "YES_co supply");
        assertEq(MockWrapped1155(noCo).totalSupply(), companyAmt, "NO_co supply");
        assertEq(MockWrapped1155(yesCur).totalSupply(), currencyAmt, "YES_cur supply");
        assertEq(MockWrapped1155(noCur).totalSupply(), currencyAmt, "NO_cur supply");
    }

    // ─── migrate: liquidity into both pools ─────────────────────────────────

    function test_migrate_mintsLiquidityIntoYesPoolAndNoPool() public {
        uint256 companyAmt = 1_000 ether;
        uint256 currencyAmt = 5 ether;
        _seedAndApprove(companyAmt, currencyAmt);
        vm.prank(user);
        adapter.stage(companyAmt, currencyAmt);

        (,, MockUniV3PoolFull yp, MockUniV3PoolFull np,) = _runMigrate(companyAmt, currencyAmt);

        assertGt(yp.lastLiquidity(), 0, "yes liquidity");
        assertGt(np.lastLiquidity(), 0, "no liquidity");

        // Full-range ticks: ±887270 for fee 500 (MAX_TICK / 10 * 10).
        assertEq(yp.lastTickLower(), UniV3Math.minUsableTick(10));
        assertEq(yp.lastTickUpper(), UniV3Math.maxUsableTick(10));
        assertEq(np.lastTickLower(), UniV3Math.minUsableTick(10));
        assertEq(np.lastTickUpper(), UniV3Math.maxUsableTick(10));
    }

    // ─── migrate: callback transfers tokens ─────────────────────────────────

    function test_migrate_callbackTransfersTokens() public {
        uint256 companyAmt = 1_000 ether;
        uint256 currencyAmt = 5 ether;
        _seedAndApprove(companyAmt, currencyAmt);
        vm.prank(user);
        adapter.stage(companyAmt, currencyAmt);

        (,, MockUniV3PoolFull yp, MockUniV3PoolFull np,) = _runMigrate(companyAmt, currencyAmt);

        // The pool's `received0/1` accumulators should match what they requested.
        assertEq(yp.received0(), yp.expectedAmount0());
        assertEq(yp.received1(), yp.expectedAmount1());
        assertEq(np.received0(), np.expectedAmount0());
        assertEq(np.received1(), np.expectedAmount1());
    }

    function test_callback_rejectsNonPoolCaller() public {
        // Direct callback attempt without pool guard should revert.
        UniswapV3LiquidityAdapter.MintCallbackData memory cb =
            UniswapV3LiquidityAdapter.MintCallbackData({pool: address(0xDEAD), token0: address(fao), token1: address(weth)});
        bytes memory data = abi.encode(cb);
        vm.expectRevert(UniswapV3LiquidityAdapter.CallbackUnauthorized.selector);
        adapter.uniswapV3MintCallback(1 ether, 1 ether, data);
    }

    // ─── revert: not staged ─────────────────────────────────────────────────

    function test_migrate_revertsIfNotStaged() public {
        (MockProposal proposal, MockUniV3PoolFull yp, MockUniV3PoolFull np,) = _setupProposalAndPools(1, 1);
        vm.expectRevert(UniswapV3LiquidityAdapter.NothingStaged.selector);
        vm.prank(orchestrator, user);
        adapter.migrate(address(proposal), address(yp), address(np), address(0), SQRT_1);
    }

    // ─── stage cleared after success ────────────────────────────────────────

    function test_migrate_clearsStagedAfterSuccess() public {
        uint256 companyAmt = 1_000 ether;
        uint256 currencyAmt = 5 ether;
        _seedAndApprove(companyAmt, currencyAmt);
        vm.prank(user);
        adapter.stage(companyAmt, currencyAmt);

        _runMigrate(companyAmt, currencyAmt);

        (uint128 c, uint128 cu) = adapter.stagedFor(user);
        assertEq(c, 0, "company cleared");
        assertEq(cu, 0, "currency cleared");
    }

    // ─── access control: only orchestrator can call migrate ─────────────────

    function test_migrate_onlyCallableByOrchestrator() public {
        uint256 companyAmt = 1_000 ether;
        uint256 currencyAmt = 5 ether;
        _seedAndApprove(companyAmt, currencyAmt);
        vm.prank(user);
        adapter.stage(companyAmt, currencyAmt);

        (MockProposal proposal, MockUniV3PoolFull yp, MockUniV3PoolFull np,) = _setupProposalAndPools(companyAmt, currencyAmt);

        // Attempted call from non-orchestrator account.
        vm.expectRevert(UniswapV3LiquidityAdapter.OnlyOrchestrator.selector);
        vm.prank(user);
        adapter.migrate(address(proposal), address(yp), address(np), address(0), SQRT_1);
    }

    // ─── gas snapshot ────────────────────────────────────────────────────────

    function test_migrate_gas_snapshot() public {
        uint256 companyAmt = 1_000 ether;
        uint256 currencyAmt = 5 ether;
        _seedAndApprove(companyAmt, currencyAmt);
        vm.prank(user);
        adapter.stage(companyAmt, currencyAmt);

        (MockProposal proposal, MockUniV3PoolFull yp, MockUniV3PoolFull np,) =
            _setupProposalAndPools(companyAmt, currencyAmt);

        vm.prank(orchestrator, user);
        uint256 gasBefore = gasleft();
        adapter.migrate(address(proposal), address(yp), address(np), address(0), SQRT_1);
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("migrate() gas used:", gasUsed);
        // Sanity bound — actual production with real CTF + wrappers + pools will be higher,
        // but it should fit in a 5M-gas block envelope.
        assertLt(gasUsed, 5_000_000, "gas envelope");
    }
}
