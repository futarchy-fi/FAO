// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title InsiderVesting
/// @notice
/// Tranche-based vesting for FAO, gated by on-chain bonds at price milestones.
/// - 10 tranches, each 10% of all FAO ever received.
/// - Tranche i unlocks linearly over 365 "active" days when there is a bond at
///   price level >= i.
/// - Vesting rate for each interval is computed from totalReceived (A+B) as of
///   the *previous* poke; new FAO minted/transferred in between pokes only
///   affects the next interval.
/// - One bond per tranche; bonds are 0.1 ETH standing bids to buy FAO.
contract InsiderVesting is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ----------------------------------------------------------------------
    // Constants and types
    // ----------------------------------------------------------------------

    uint256 public constant NUM_TRANCHES = 10;
    uint256 public constant ONE = 1e18;
    uint256 public constant YEAR = 365 days;
    uint256 public constant BOND_SIZE = 0.1 ether;

    struct Tranche {
        uint256 unlocked; // cumulative FAO unlocked
        uint256 withdrawn; // cumulative FAO withdrawn
        uint256 lastUpdate; // last time this tranche was synced
        bool active; // whether this tranche was active after lastUpdate
    }

    struct Bond {
        address provider;
        uint256 remainingEth;
        bool active;
    }

    // ----------------------------------------------------------------------
    // Immutable + mutable config
    // ----------------------------------------------------------------------

    IERC20 public immutable TOKEN;

    /// @notice Address that receives vested FAO. Can self-update.
    address public beneficiary;

    /// @notice 10% share per tranche (hardcoded to 1e17 each).
    uint256[NUM_TRANCHES] public trancheShares;

    /// @notice Hardcoded price levels (wei per FAO).
    uint256[NUM_TRANCHES] public tranchePrices;

    // ----------------------------------------------------------------------
    // Mutable state
    // ----------------------------------------------------------------------

    Tranche[NUM_TRANCHES] public tranches;
    Bond[NUM_TRANCHES] public bonds;

    /// @notice Sum of all tokens withdrawn from all tranches.
    uint256 public totalWithdrawnAll;

    /// @notice Highest index i with bonds[i].active == true, or NUM_TRANCHES if none.
    uint256 public highestActiveTranche;

    /// @notice Total FAO ever received at the time of the last poke.
    uint256 public lastTotalReceived;

    // ----------------------------------------------------------------------
    // Events
    // ----------------------------------------------------------------------

    event Poked(uint256 timestamp, uint256 totalReceived);
    event Withdrawn(uint256 indexed tranche, uint256 amount);

    event BondCreated(uint256 indexed tranche, address indexed provider, uint256 amountEth);
    event BondCancelled(uint256 indexed tranche, address indexed provider, uint256 refundEth);
    event BondFilled(
        uint256 indexed tranche, address indexed seller, uint256 faoSold, uint256 ethPaid
    );

    event BeneficiaryUpdated(address indexed oldBeneficiary, address indexed newBeneficiary);

    // ----------------------------------------------------------------------
    // Modifiers
    // ----------------------------------------------------------------------

    modifier onlyBeneficiary() {
        _onlyBeneficiary();
        _;
    }

    function _onlyBeneficiary() internal view {
        require(msg.sender == beneficiary, "not beneficiary");
    }

    // ----------------------------------------------------------------------
    // Constructor (hardcoded shares and prices)
    // ----------------------------------------------------------------------

    constructor(IERC20 _token, address _beneficiary) {
        require(address(_token) != address(0), "token=0");
        require(_beneficiary != address(0), "beneficiary=0");

        TOKEN = _token;
        beneficiary = _beneficiary;

        uint256 nowTs = block.timestamp;

        // 10% each tranche
        for (uint256 i = 0; i < NUM_TRANCHES; i++) {
            trancheShares[i] = 1e17; // 10%
            tranches[i].lastUpdate = nowTs;
            tranches[i].active = false;
        }

        // Hardcoded price levels (ETH per FAO, wei)
        // base = 0.0001 ETH; we start at 2x = 0.0002 ETH
        tranchePrices[0] = 200_000_000_000_000; // 0.0002 ETH = 2×
        tranchePrices[1] = 400_000_000_000_000; // 0.0004 ETH = 4×
        tranchePrices[2] = 800_000_000_000_000; // 0.0008 ETH = 8×
        tranchePrices[3] = 1_600_000_000_000_000; // 0.0016 ETH = 16×
        tranchePrices[4] = 3_200_000_000_000_000; // 0.0032 ETH = 32×
        tranchePrices[5] = 6_400_000_000_000_000; // 0.0064 ETH = 64×
        tranchePrices[6] = 12_800_000_000_000_000; // 0.0128 ETH = 128×
        tranchePrices[7] = 25_600_000_000_000_000; // 0.0256 ETH = 256×
        tranchePrices[8] = 51_200_000_000_000_000; // 0.0512 ETH = 512×
        tranchePrices[9] = 102_400_000_000_000_000; // 0.1024 ETH = 1024×

        highestActiveTranche = NUM_TRANCHES;
        lastTotalReceived = 0;
    }

    // ----------------------------------------------------------------------
    // Beneficiary controls
    // ----------------------------------------------------------------------

    /// @notice Allow the current beneficiary to update the beneficiary address.
    function updateBeneficiary(address newBeneficiary) external onlyBeneficiary {
        require(newBeneficiary != address(0), "beneficiary=0");
        address old = beneficiary;
        beneficiary = newBeneficiary;
        emit BeneficiaryUpdated(old, newBeneficiary);
    }

    // ----------------------------------------------------------------------
    // Internal helpers
    // ----------------------------------------------------------------------

    function _totalReceived() internal view returns (uint256) {
        return totalWithdrawnAll + TOKEN.balanceOf(address(this));
    }

    /// @dev Vest using lastTotalReceived as the base; then update lastTotalReceived.
    function _poke() internal {
        uint256 nowTs = block.timestamp;
        uint256 currentTotal = _totalReceived();
        uint256 lastTotal = lastTotalReceived;

        // First ever poke (no previous base)
        if (lastTotal == 0) {
            for (uint256 i = 0; i < NUM_TRANCHES; i++) {
                tranches[i].lastUpdate = nowTs;
            }
            lastTotalReceived = currentTotal;
            emit Poked(nowTs, currentTotal);
            return;
        }

        // Apply vesting for time since lastUpdate using lastTotal as cap base
        for (uint256 i = 0; i < NUM_TRANCHES; i++) {
            Tranche storage t = tranches[i];
            uint256 dt = nowTs - t.lastUpdate;
            if (dt == 0) continue;

            if (!t.active || trancheShares[i] == 0) {
                t.lastUpdate = nowTs;
                continue;
            }

            uint256 cap = (lastTotal * trancheShares[i]) / ONE;
            if (cap == 0 || t.unlocked >= cap) {
                t.lastUpdate = nowTs;
                continue;
            }

            uint256 rate = cap / YEAR;
            if (rate == 0) {
                t.lastUpdate = nowTs;
                continue;
            }

            uint256 delta = dt * rate;
            uint256 remaining = cap - t.unlocked;
            if (delta > remaining) delta = remaining;

            t.unlocked += delta;
            t.lastUpdate = nowTs;
        }

        lastTotalReceived = currentTotal;
        emit Poked(nowTs, currentTotal);
    }

    function _recomputeActiveTranches() internal {
        uint256 highest = NUM_TRANCHES;
        for (uint256 i = NUM_TRANCHES; i > 0;) {
            unchecked {
                i--;
            }
            if (bonds[i].active && bonds[i].remainingEth > 0) {
                highest = i;
                break;
            }
        }

        highestActiveTranche = highest;

        if (highest == NUM_TRANCHES) {
            for (uint256 j = 0; j < NUM_TRANCHES; j++) {
                tranches[j].active = false;
            }
        } else {
            for (uint256 j = 0; j < NUM_TRANCHES; j++) {
                tranches[j].active = (j <= highest);
            }
        }
    }

    // ----------------------------------------------------------------------
    // External: poke / withdraw
    // ----------------------------------------------------------------------

    function poke() external nonReentrant {
        _poke();
    }

    function withdrawFromTranche(uint256 trancheIndex, uint256 amount) external nonReentrant {
        require(trancheIndex < NUM_TRANCHES, "withdraw: bad tranche");
        require(amount > 0, "withdraw: amount is zero");

        _poke();

        Tranche storage t = tranches[trancheIndex];
        require(t.unlocked >= t.withdrawn + amount, "withdraw: insufficient unlocked");

        t.withdrawn += amount;
        totalWithdrawnAll += amount;
        TOKEN.safeTransfer(beneficiary, amount);

        emit Withdrawn(trancheIndex, amount);
    }

    function withdrawAllAvailable() external nonReentrant {
        _poke();

        uint256 totalToWithdraw;
        for (uint256 i = 0; i < NUM_TRANCHES; i++) {
            Tranche storage t = tranches[i];
            if (t.unlocked > t.withdrawn) {
                uint256 avail = t.unlocked - t.withdrawn;
                t.withdrawn += avail;
                totalWithdrawnAll += avail;
                totalToWithdraw += avail;
                emit Withdrawn(i, avail);
            }
        }

        if (totalToWithdraw > 0) {
            TOKEN.safeTransfer(beneficiary, totalToWithdraw);
        }
    }

    /// @notice Beneficiary can withdraw arbitrary ERC20 tokens (except the FAO token)
    ///         from this contract at any time, with no vesting logic.
    /// @param otherToken Address of the ERC20 to withdraw
    /// @param amount     Amount to withdraw
    function rescueOtherToken(address otherToken, uint256 amount) external onlyBeneficiary {
        require(otherToken != address(TOKEN), "cannot rescue vested token");
        require(otherToken != address(0), "token=0");
        require(amount > 0, "amount=0");

        IERC20(otherToken).safeTransfer(beneficiary, amount);
    }

    /// @notice Beneficiary can withdraw arbitrary ETH from this contract at any time.
    /// @param amount Amount of ETH to withdraw (in wei)
    function rescueEth(uint256 amount) external onlyBeneficiary {
        require(amount > 0, "amount=0");
        require(address(this).balance >= amount, "insufficient ETH");

        (bool ok,) = beneficiary.call{value: amount}("");
        require(ok, "ETH transfer failed");
    }

    // ----------------------------------------------------------------------
    // Bond management
    // ----------------------------------------------------------------------

    function createBond(uint256 trancheIndex) external payable nonReentrant {
        require(trancheIndex < NUM_TRANCHES, "createBond: bad tranche");
        require(msg.value == BOND_SIZE, "createBond: incorrect bond size");

        _poke();

        Bond storage b = bonds[trancheIndex];
        require(!b.active, "createBond: bond already active");

        uint256 price = tranchePrices[trancheIndex];
        // Ensure bond can buy at least some FAO at this price.
        require((BOND_SIZE * ONE) / price > 0, "createBond: price too high");

        b.provider = msg.sender;
        b.remainingEth = msg.value;
        b.active = true;

        _recomputeActiveTranches();
        emit BondCreated(trancheIndex, msg.sender, msg.value);
    }

    function cancelBond(uint256 trancheIndex) external nonReentrant {
        require(trancheIndex < NUM_TRANCHES, "cancelBond: bad tranche");
        _poke();

        Bond storage b = bonds[trancheIndex];
        require(b.active, "cancelBond: no active bond");
        require(b.provider == msg.sender, "cancelBond: not provider");

        uint256 refund = b.remainingEth;
        b.remainingEth = 0;
        b.active = false;

        _recomputeActiveTranches();

        (bool ok,) = msg.sender.call{value: refund}("");
        require(ok, "cancelBond: ETH refund failed");

        emit BondCancelled(trancheIndex, msg.sender, refund);
    }

    function sellIntoBond(uint256 trancheIndex, uint256 faoAmountIn) external nonReentrant {
        require(trancheIndex < NUM_TRANCHES, "sellIntoBond: bad tranche");
        require(faoAmountIn > 0, "sellIntoBond: amount is zero");

        _poke();

        Bond storage b = bonds[trancheIndex];
        require(b.active, "sellIntoBond: no active bond");

        uint256 price = tranchePrices[trancheIndex];

        uint256 faoMax = (b.remainingEth * ONE) / price;
        if (faoMax == 0) {
            // No buying power -> bond is effectively dust, deactivate.
            b.remainingEth = 0;
            b.active = false;
            _recomputeActiveTranches();
            return;
        }

        uint256 faoToSell = faoAmountIn;
        if (faoToSell > faoMax) {
            faoToSell = faoMax;
        }

        uint256 ethOut = (faoToSell * price) / ONE;
        require(ethOut <= b.remainingEth, "sellIntoBond: math error");

        b.remainingEth -= ethOut;

        TOKEN.safeTransferFrom(msg.sender, b.provider, faoToSell);

        (bool ok,) = msg.sender.call{value: ethOut}("");
        require(ok, "sellIntoBond: ETH payment failed");

        emit BondFilled(trancheIndex, msg.sender, faoToSell, ethOut);

        uint256 newFaoMax = (b.remainingEth * ONE) / price;
        if (newFaoMax == 0) {
            b.remainingEth = 0;
            b.active = false;
            _recomputeActiveTranches();
        }
    }

    // ----------------------------------------------------------------------
    // View helpers
    // ----------------------------------------------------------------------

    function totalReceived() external view returns (uint256) {
        return _totalReceived();
    }

    /// @notice Cap used for vesting math (based on lastTotalReceived).
    function trancheCap(uint256 trancheIndex) external view returns (uint256) {
        require(trancheIndex < NUM_TRANCHES, "trancheCap: bad tranche");
        return (lastTotalReceived * trancheShares[trancheIndex]) / ONE;
    }

    function unlocked(uint256 trancheIndex) external view returns (uint256) {
        require(trancheIndex < NUM_TRANCHES, "unlocked: bad tranche");
        return tranches[trancheIndex].unlocked;
    }

    function withdrawn(uint256 trancheIndex) external view returns (uint256) {
        require(trancheIndex < NUM_TRANCHES, "withdrawn: bad tranche");
        return tranches[trancheIndex].withdrawn;
    }

    function available(uint256 trancheIndex) external view returns (uint256) {
        require(trancheIndex < NUM_TRANCHES, "available: bad tranche");
        Tranche storage t = tranches[trancheIndex];
        if (t.unlocked <= t.withdrawn) return 0;
        return t.unlocked - t.withdrawn;
    }
}
