// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {FAOTwapResolver} from "../src/FAOTwapResolver.sol";
import {IConditionalTokensLike} from "../src/interfaces/IConditionalTokensLike.sol";
import {IUniswapV3PoolLike} from "../src/interfaces/IUniswapV3PoolLike.sol";

contract TwapInvariantCTF is IConditionalTokensLike {
    mapping(bytes32 => uint256) public reportCount;
    mapping(bytes32 => uint256) public payout0;
    mapping(bytes32 => uint256) public payout1;

    function payoutNumerators(bytes32 questionId, uint256 index) external view returns (uint256) {
        return index == 0 ? payout0[questionId] : payout1[questionId];
    }

    function payoutDenominator(bytes32 questionId) external view returns (uint256) {
        return reportCount[questionId] == 0 ? 0 : 1;
    }

    function prepareCondition(address, bytes32, uint256) external pure {}

    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external {
        require(payouts.length == 2, "bad-payouts");
        reportCount[questionId] += 1;
        payout0[questionId] = payouts[0];
        payout1[questionId] = payouts[1];
    }

    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount));
    }

    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(parentCollectionId, conditionId, indexSet));
    }

    function getPositionId(address collateralToken, bytes32 collectionId)
        external
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encodePacked(collateralToken, collectionId)));
    }

    function getOutcomeSlotCount(bytes32) external pure returns (uint256) {
        return 0;
    }
}

contract TwapInvariantPool is IUniswapV3PoolLike {
    address internal immutable TOKEN0;
    address internal immutable TOKEN1;
    int24 internal immutable AVG_TICK;
    uint32 internal expectedStartAgo;
    uint32 internal expectedEndAgo;
    bool internal expectedObserveSet;

    constructor(address token0_, address token1_, int24 avgTick_) {
        TOKEN0 = token0_;
        TOKEN1 = token1_;
        AVG_TICK = avgTick_;
    }

    function setExpectedObserve(uint32 startAgo, uint32 endAgo) external {
        expectedStartAgo = startAgo;
        expectedEndAgo = endAgo;
        expectedObserveSet = true;
    }

    function token0() external view returns (address) {
        return TOKEN0;
    }

    function token1() external view returns (address) {
        return TOKEN1;
    }

    function fee() external pure returns (uint24) {
        return 500;
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (uint160(1 << 96), 0, 0, 1, 100, 0, true);
    }

    function initialize(uint160) external pure {}

    function increaseObservationCardinalityNext(uint16) external pure {}

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        )
    {
        require(secondsAgos.length == 2, "LEN");
        if (expectedObserveSet) {
            require(secondsAgos[0] == expectedStartAgo, "START");
            require(secondsAgos[1] == expectedEndAgo, "END");
        }

        tickCumulatives = new int56[](2);
        secondsPerLiquidityCumulativeX128s = new uint160[](2);
        uint256 interval = uint256(secondsAgos[0] - secondsAgos[1]);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int56(int256(AVG_TICK) * int256(interval));
    }

    function mint(address, int24, int24, uint128, bytes calldata)
        external
        pure
        returns (uint256, uint256)
    {
        return (0, 0);
    }
}

contract TwapInvariantProposal {
    bytes32 internal immutable QUESTION_ID;
    address[4] internal wrappers;

    constructor(
        bytes32 questionId_,
        address yesCompany,
        address noCompany,
        address yesCurrency,
        address noCurrency
    ) {
        QUESTION_ID = questionId_;
        wrappers[0] = yesCompany;
        wrappers[1] = noCompany;
        wrappers[2] = yesCurrency;
        wrappers[3] = noCurrency;
    }

    function questionId() external view returns (bytes32) {
        return QUESTION_ID;
    }

    function wrappedOutcome(uint256 index) external view returns (address, bytes memory) {
        return (wrappers[index], "");
    }
}

contract FAOTwapResolverHandler is Test {
    struct TrackedProposal {
        address proposal;
        address yesPool;
        address noPool;
        address companyToken;
        address currencyToken;
        bytes32 questionId;
        uint48 anchorTimestamp;
        int24 normalizedYesTick;
        int24 normalizedNoTick;
        bool resolved;
        bool accepted;
    }

    struct BindingSnapshot {
        address yesPool;
        address noPool;
        address companyToken;
        address currencyToken;
        bytes32 questionId;
        uint48 anchorTimestamp;
        bool resolved;
        bool accepted;
    }

    uint256 internal constant MAX_PROPOSALS = 48;

    FAOTwapResolver public immutable RESOLVER;
    uint32 public immutable TIMEOUT;
    uint32 public immutable TWAP_WINDOW;

    address[] internal proposals;
    mapping(address => TrackedProposal) internal tracked;
    uint256 internal nextProposalNonce;

    bool public sawAnchorViolation;
    bool public sawWindowViolation;
    bool public sawResolveViolation;
    uint256 public bindCalls;
    uint256 public rebindAttempts;
    uint256 public resolveCalls;
    uint256 public windowChecks;

    constructor(FAOTwapResolver resolver) {
        RESOLVER = resolver;
        TIMEOUT = resolver.TIMEOUT();
        TWAP_WINDOW = resolver.TWAP_WINDOW();
    }

    function bindProposal(uint256 seed) external {
        if (proposals.length >= MAX_PROPOSALS) return;

        uint256 id = nextProposalNonce++;
        address yesCompany = _addr(0x1000, id, 0);
        address noCompany = _addr(0x1000, id, 1);
        address yesCurrency = _addr(0x1000, id, 2);
        address noCurrency = _addr(0x1000, id, 3);
        address companyToken = _addr(0x2000, id, 0);
        address currencyToken = _addr(0x2000, id, 1);
        bytes32 questionId = keccak256(abi.encode("proposal", id, seed));

        bool invertYes = seed & 1 == 1;
        bool invertNo = seed & 2 == 2;
        int24 yesRawTick = _tick(seed >> 8);
        int24 noRawTick = _tick(seed >> 24);
        address yesToken0 = invertYes ? yesCurrency : yesCompany;
        address yesToken1 = invertYes ? yesCompany : yesCurrency;
        address noToken0 = invertNo ? noCurrency : noCompany;
        address noToken1 = invertNo ? noCompany : noCurrency;

        TwapInvariantProposal proposal =
            new TwapInvariantProposal(questionId, yesCompany, noCompany, yesCurrency, noCurrency);
        TwapInvariantPool yesPool = new TwapInvariantPool(yesToken0, yesToken1, yesRawTick);
        TwapInvariantPool noPool = new TwapInvariantPool(noToken0, noToken1, noRawTick);

        uint48 anchorTimestamp = uint48(block.timestamp);
        try RESOLVER.bindProposal(
            address(proposal),
            address(yesPool),
            address(noPool),
            companyToken,
            currencyToken,
            anchorTimestamp
        ) {
            proposals.push(address(proposal));
            tracked[address(proposal)] = TrackedProposal({
                proposal: address(proposal),
                yesPool: address(yesPool),
                noPool: address(noPool),
                companyToken: companyToken,
                currencyToken: currencyToken,
                questionId: questionId,
                anchorTimestamp: anchorTimestamp,
                normalizedYesTick: invertYes ? -yesRawTick : yesRawTick,
                normalizedNoTick: invertNo ? -noRawTick : noRawTick,
                resolved: false,
                accepted: false
            });
            bindCalls += 1;
        } catch {
            sawAnchorViolation = true;
        }
    }

    function attemptRebind(uint256 proposalSeed, uint256 anchorSeed) external {
        if (proposals.length == 0) return;
        address proposal = proposals[proposalSeed % proposals.length];
        TrackedProposal storage t = tracked[proposal];
        BindingSnapshot memory beforeState = _snapshot(proposal);
        uint48 nextAnchor = uint48(block.timestamp + 1 + (anchorSeed % 1 days));
        rebindAttempts += 1;

        try RESOLVER.bindProposal(
            proposal, t.yesPool, t.noPool, t.companyToken, t.currencyToken, nextAnchor
        ) {
            sawAnchorViolation = true;
        } catch (bytes memory reason) {
            if (_selector(reason) != FAOTwapResolver.AlreadyBound.selector) {
                sawAnchorViolation = true;
            }
        }

        if (!_sameBinding(beforeState, _snapshot(proposal))) {
            sawAnchorViolation = true;
        }
    }

    function resolveProposal(uint256 proposalSeed, uint256 delaySeed) external {
        if (proposals.length == 0) return;
        address proposal = proposals[proposalSeed % proposals.length];
        TrackedProposal storage t = tracked[proposal];
        if (t.resolved) return;

        uint256 windowEnd = uint256(t.anchorTimestamp) + TIMEOUT;
        uint256 targetTimestamp = windowEnd + (delaySeed % 1 days);
        if (block.timestamp < targetTimestamp) {
            vm.warp(targetTimestamp);
        }

        uint256 endAgo = block.timestamp - windowEnd;
        uint256 startAgo = endAgo + TWAP_WINDOW;
        if (startAgo > type(uint32).max) {
            sawWindowViolation = true;
            return;
        }

        TwapInvariantPool(t.yesPool).setExpectedObserve(uint32(startAgo), uint32(endAgo));
        TwapInvariantPool(t.noPool).setExpectedObserve(uint32(startAgo), uint32(endAgo));

        try RESOLVER.resolve(proposal) {
            t.accepted = t.normalizedYesTick > t.normalizedNoTick;
            t.resolved = true;
            resolveCalls += 1;
            windowChecks += 1;
        } catch {
            sawResolveViolation = true;
            sawWindowViolation = true;
        }
    }

    function advanceTime(uint256 secondsSeed) external {
        vm.warp(block.timestamp + 1 + (secondsSeed % 12 hours));
    }

    function trackedCount() external view returns (uint256) {
        return proposals.length;
    }

    function proposalAt(uint256 index) external view returns (address) {
        return proposals[index];
    }

    function expectedAnchor(address proposal) external view returns (uint48) {
        return tracked[proposal].anchorTimestamp;
    }

    function expectedQuestionId(address proposal) external view returns (bytes32) {
        return tracked[proposal].questionId;
    }

    function expectedYesPool(address proposal) external view returns (address) {
        return tracked[proposal].yesPool;
    }

    function expectedNoPool(address proposal) external view returns (address) {
        return tracked[proposal].noPool;
    }

    function expectedCompanyToken(address proposal) external view returns (address) {
        return tracked[proposal].companyToken;
    }

    function expectedCurrencyToken(address proposal) external view returns (address) {
        return tracked[proposal].currencyToken;
    }

    function expectedResolved(address proposal) external view returns (bool) {
        return tracked[proposal].resolved;
    }

    function expectedAccepted(address proposal) external view returns (bool) {
        return tracked[proposal].accepted;
    }

    function _addr(uint256 base, uint256 id, uint256 offset) internal pure returns (address) {
        return address(uint160(base + id * 8 + offset));
    }

    function _tick(uint256 seed) internal pure returns (int24) {
        return int24(int256(seed % 401) - 200);
    }

    function _snapshot(address proposal) internal view returns (BindingSnapshot memory s) {
        (
            s.yesPool,
            s.noPool,
            s.companyToken,
            s.currencyToken,
            s.questionId,
            s.anchorTimestamp,
            s.resolved,
            s.accepted
        ) = RESOLVER.bindings(proposal);
    }

    function _sameBinding(BindingSnapshot memory a, BindingSnapshot memory b)
        internal
        pure
        returns (bool)
    {
        return a.yesPool == b.yesPool && a.noPool == b.noPool && a.companyToken == b.companyToken
            && a.currencyToken == b.currencyToken && a.questionId == b.questionId
            && a.anchorTimestamp == b.anchorTimestamp && a.resolved == b.resolved
            && a.accepted == b.accepted;
    }

    function _selector(bytes memory reason) internal pure returns (bytes4 selector) {
        if (reason.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(reason, 0x20))
        }
    }
}

/// @custom:spec INV-TWAP-001 — see audit/specs/INVARIANTS.md.
contract FAOTwapResolverInvariants is StdInvariant, Test {
    uint32 internal constant TIMEOUT = 2 hours;
    uint32 internal constant TWAP_WINDOW = 1 hours;

    FAOTwapResolver internal resolver;
    FAOTwapResolverHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000);

        TwapInvariantCTF ctf = new TwapInvariantCTF();
        resolver = new FAOTwapResolver(TIMEOUT, TWAP_WINDOW, IConditionalTokensLike(address(ctf)));
        handler = new FAOTwapResolverHandler(resolver);
        resolver.setOrchestrator(address(handler));

        handler.bindProposal(1);
        handler.resolveProposal(0, 1 hours);
        handler.attemptRebind(0, 1);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = FAOTwapResolverHandler.bindProposal.selector;
        selectors[1] = FAOTwapResolverHandler.attemptRebind.selector;
        selectors[2] = FAOTwapResolverHandler.resolveProposal.selector;
        selectors[3] = FAOTwapResolverHandler.advanceTime.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @custom:spec INV-TWAP-001 — anchors are immutable and resolve uses the anchored TWAP
    /// window.
    function invariant_INV_TWAP_001_anchorMonotoneWindowFixed() public view {
        assertGt(handler.bindCalls(), 0, "INV-TWAP-001 not bound");
        assertGt(handler.rebindAttempts(), 0, "INV-TWAP-001 rebind path not exercised");
        assertGt(handler.windowChecks(), 0, "INV-TWAP-001 window path not exercised");
        assertFalse(handler.sawAnchorViolation(), "INV-TWAP-001 anchor changed");
        assertFalse(handler.sawWindowViolation(), "INV-TWAP-001 window changed");

        uint256 count = handler.trackedCount();
        for (uint256 i = 0; i < count; i++) {
            address proposal = handler.proposalAt(i);
            (
                address yesPool,
                address noPool,
                address companyToken,
                address currencyToken,
                bytes32 questionId,
                uint48 anchorTimestamp,,
            ) = resolver.bindings(proposal);

            assertEq(yesPool, handler.expectedYesPool(proposal), "yes pool changed");
            assertEq(noPool, handler.expectedNoPool(proposal), "no pool changed");
            assertEq(companyToken, handler.expectedCompanyToken(proposal), "company changed");
            assertEq(currencyToken, handler.expectedCurrencyToken(proposal), "currency changed");
            assertEq(questionId, handler.expectedQuestionId(proposal), "question id changed");
            assertEq(
                uint256(anchorTimestamp),
                uint256(handler.expectedAnchor(proposal)),
                "anchor changed"
            );
            assertEq(
                resolver.windowEndOf(proposal),
                uint256(anchorTimestamp) + TIMEOUT,
                "window end changed"
            );
        }
    }
}
