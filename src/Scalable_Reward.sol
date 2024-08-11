// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 ScalableReward is modified fork of Liquity StabiltyPool to Showcase Scalable Reward and distribution for A compounded Deposits

 * Thus, a liquidation causes each depositor to receive a Staked token loss, in proportion to their deposit as a share of total deposits.
 * They also receive an Reward gain, as the Reward collateral is distributed among  depositors,
 * in the same proportion.

 Reward token can be taken as any Collateral erc20 toke like WETH,WBTC etc

  * When a liquidation occurs, it depletes every deposit by the same fraction: for example, a liquidation that depletes 40%
 * of the total staked token in the vault , depletes 40% of each deposit.


  * --- IMPLEMENTATION ---
 *
 * When a liquidation occurs, rather than updating each depositor's deposit and Reward gain, It simply update two state variables:
 * a product P, and a sum S.
 *
 * For a given deposit d_t, the ratio P/P_t tells us the factor by which a deposit has decreased since it joined the Stability Pool,
 * and the term d_t * (S - S_t)/P_t gives us the deposit's total accumulated ETH gain.
 *
 *A further mathematical aspects of this contract can be seen in the whitepaper- https://github.com/liquity/liquity/blob/master/papers/Scalable_Reward_Distribution_with_Compounding_Stakes.pdf
 */
contract ScalableReward is Ownable2Step {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // Event declarations
    event DepositMade(
        address indexed user,
        uint256 amount,
        uint256 newTotalStaked
    );
    event WithdrawalMade(
        address indexed user,
        uint256 amount,
        uint256 newTotalStaked
    );
    event Liquidation(
        uint256 debtToOffset,
        uint256 rewardTokenToAdd,
        uint256 newTotalStaked
    );
    event RewardSent(address indexed user, uint256 rewardAmount);

    event EpochUpdated(uint256 _currentEpoch);
    event ScaleUpdated(uint256 _currentScale);

    IERC20 public stakingToken; // Token to be staked (e.g., stable USD)
    IERC20 public rewardToken; // Reward token (e.g., WETH)

    struct Snapshot {
        uint256 S;
        uint256 P;
        uint256 scale;
        uint256 epoch;
    }

    mapping(address => uint256) public deposits; // Mapping of user deposits
    uint public constant DECIMAL_PRECISION = 1e18; // Precision constant
    uint public constant SCALE_FACTOR = 1e9;
    uint public P = DECIMAL_PRECISION; // Product variable
    uint256 public totalStaked; // Total staked tokens
    mapping(address => Snapshot) public depositSnapshots; // Mapping of user deposit snapshots

    uint256 public rewardTokenAmount; // Deposited reward tracker

    // Error trackers for the error correction in the offset calculation
    uint public lastRewardError_Offset;
    uint public lastStakedLossError_Offset;

    uint256 currentEpoch; // Current epoch tracker

    mapping(uint256 => mapping(uint256 => uint256)) public epochtoSum; // Mapping of epoch to sum of rewards

    uint256 public currentScale; // Scale factor

    constructor(
        address _stakingToken,
        address _rewardToken
    ) Ownable(msg.sender) {
        stakingToken = IERC20(_stakingToken); // Staking token (e.g., stable USD)
        rewardToken = IERC20(_rewardToken); // Reward token (e.g., WETH)
    }

    /**
     * @dev Allows a user to deposit tokens into the vault.
     * Updates the user's deposit and sends any accumulated rewards.
     * Emits a `DepositMade` event.
     */

    /**

    According to the whitepaper
    Making a deposit:
    Record deposit: deposit[user] = dt
    Update total deposits: D = D + dt
    Record product snapshot: Pt = P
    Record sum snapshot: St = S

    */
    function depositInVault(uint256 amount) external {
        require(amount > 0, "AmountIsZero");

        uint initialDeposit = deposits[msg.sender];
        uint256 depositorRewardGain = getdepositorRewardGain(msg.sender);

        uint256 compoundedDeposit = getCompoundedDeposit(msg.sender);

        uint256 Loss = initialDeposit - compoundedDeposit;

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        totalStaked += amount;

        uint256 newDeposit = compoundedDeposit + amount;
        _updateDepositAndSnapshots(msg.sender, newDeposit);

        _sendRewardGainToDepositor(depositorRewardGain);

        emit DepositMade(msg.sender, amount, totalStaked);
    }

    /**
     * @dev Allows a user to withdraw tokens from the vault.
     * Updates the user's deposit and sends any accumulated rewards.
     * Emits a `WithdrawalMade` event.
     */

    function withdrawFromVault(uint256 amount) external {
        require(amount > 0, "AmountIsZero");

        uint256 initialDeposit = deposits[msg.sender];

        require(initialDeposit > 0, "NoDeposit");

        uint256 depositorRewardGain = getdepositorRewardGain(msg.sender);

        uint256 compoundedDeposit = getCompoundedDeposit(msg.sender);

        uint256 withdrawalAmount = amount > compoundedDeposit
            ? compoundedDeposit
            : amount;

        uint256 Loss = initialDeposit - compoundedDeposit;

        stakingToken.safeTransferFrom(
            address(this),
            msg.sender,
            withdrawalAmount
        );

        uint256 newDeposit = compoundedDeposit - withdrawalAmount;
        _updateDepositAndSnapshots(msg.sender, newDeposit);

        _sendRewardGainToDepositor(depositorRewardGain);

        emit WithdrawalMade(msg.sender, amount, totalStaked);
    }

    /**
     * @dev Allows an admin to liquidate a portion of the vault.
     * Adjusts the reward and loss per unit staked.
     * Emits a `Liquidation` event.
     */

    /**
    refer to this https://github.com/liquity/liquity/blob/master/papers/Scalable_Reward_Distribution_with_Compounding_Stakes.pdf
     */
    function liquidate(
        uint256 debtToOffset,
        uint256 rewardTokenToAdd
    ) external onlyOwner {
        if (debtToOffset == 0 || totalStaked == 0) {
            return;
        }
        (
            uint RewardGainPerUnitStaked,
            uint LossPerUnitStaked
        ) = _computeRewardsPerUnitStaked(rewardTokenToAdd, debtToOffset);

        _updateRewardSumAndProduct(RewardGainPerUnitStaked, LossPerUnitStaked);

        //Contract should have access or method to burn/transfer tokens to zero address
        totalStaked -= debtToOffset;
        //Assuing staking token is already transferred or burn
        //  stakingToken.burn(address(this), debtToOffset);

        emit Liquidation(debtToOffset, rewardTokenToAdd, totalStaked);
    }

    function _computeRewardsPerUnitStaked(
        uint256 rewardTokenToAdd,
        uint256 debtToOffset
    )
        internal
        returns (uint256 RewardGainPerUnitStaked, uint256 LossPerUnitStaked)
    {
        uint256 RewardNumerator = (rewardTokenToAdd * DECIMAL_PRECISION) +
            lastRewardError_Offset;

        require(debtToOffset <= totalStaked, "UnderFlow");
        if (debtToOffset == totalStaked) {
            LossPerUnitStaked = DECIMAL_PRECISION;
            lastStakedLossError_Offset = 0;
        } else {
            uint256 StakedLossNumerator = debtToOffset *
                DECIMAL_PRECISION -
                lastStakedLossError_Offset;

            LossPerUnitStaked = (StakedLossNumerator / totalStaked) + 1;
            lastStakedLossError_Offset =
                (LossPerUnitStaked * totalStaked) -
                StakedLossNumerator;
        }

        RewardGainPerUnitStaked = RewardNumerator / (totalStaked);

        lastRewardError_Offset =
            RewardNumerator -
            (RewardGainPerUnitStaked * totalStaked);
    }

    function _updateRewardSumAndProduct(
        uint256 RewardGainPerUnitStaked,
        uint256 LossPerUnitStaked
    ) internal {
        uint256 currentP = P;
        uint256 newP;

        require(LossPerUnitStaked <= DECIMAL_PRECISION, "404");
        uint256 newProductFactor = DECIMAL_PRECISION - LossPerUnitStaked;

        uint256 currentScaleCached = currentScale;
        uint256 currentEpochCached = currentEpoch;
        uint256 currentS = epochtoSum[currentEpochCached][currentScaleCached];
        //Calculate the new S first, before we update P.
        uint256 marginalRewardGain = RewardGainPerUnitStaked * currentP;
        uint256 newS = currentS + marginalRewardGain;
        epochtoSum[currentEpochCached][currentScaleCached] = newS;

        // If the Stability Pool was emptied, increment the epoch, and reset the scale and product P
        if (newProductFactor == 0) {
            currentEpoch = currentEpochCached + 1;
            emit EpochUpdated(currentEpoch);
            currentScale = 0;
            emit ScaleUpdated(currentScale);
            newP = DECIMAL_PRECISION;

            // If multiplying P by a non-zero product factor would reduce P below the scale boundary, increment the scale
        } else if (
            currentP.mulDiv(newProductFactor, DECIMAL_PRECISION) < SCALE_FACTOR
        ) {
            newP =
                currentP *
                newProductFactor.mulDiv(SCALE_FACTOR, DECIMAL_PRECISION);
            currentScale = currentScaleCached + 1;
            emit ScaleUpdated(currentScale);
        } else {
            newP = currentP.mulDiv(newProductFactor, DECIMAL_PRECISION);
        }

        require(newP > 0, "NewP is zero");
        P = newP;
    }

    /**
     * @dev Internal function to send accumulated rewards to the depositor.
     * Emits a `RewardSent` event.
     */
    function _sendRewardGainToDepositor(uint256 value) internal {
        if (value == 0) return;

        rewardTokenAmount -= value;

        rewardToken.safeTransferFrom(address(this), msg.sender, value);

        emit RewardSent(msg.sender, value);
    }

    /**
     * @dev Returns the reward gain for a given depositor based on snapshots.
     */
    function getdepositorRewardGain(
        address depositor
    ) public view returns (uint256) {
        uint256 initialDeposit = deposits[depositor];

        if (initialDeposit == 0) return 0;

        Snapshot memory snapshots = depositSnapshots[depositor];

        uint256 rewardGain = _getRewardGainFromSnapshots(
            initialDeposit,
            snapshots
        );

        return rewardGain;
    }

    function _getRewardGainFromSnapshots(
        uint256 initialDeposit,
        Snapshot memory snapshots
    ) internal view returns (uint256) {
        uint256 epochSnapShot = snapshots.epoch;
        uint256 scaleSnapShot = snapshots.scale;

        uint256 S_Snap = snapshots.S;
        uint256 P_Snap = snapshots.P;

        uint256 firstPortion = epochtoSum[epochSnapShot][scaleSnapShot] -
            S_Snap;
        uint256 secondPortion = epochtoSum[epochSnapShot][scaleSnapShot + 1] /
            SCALE_FACTOR;

        uint256 rewardGain = initialDeposit.mulDiv(
            firstPortion + secondPortion,
            P_Snap
        ) / (DECIMAL_PRECISION);

        return rewardGain;
    }

    /**
     * @dev Returns the compounded deposit for a given depositor based on snapshots.
     */
    function getCompoundedDeposit(
        address depositor
    ) public view returns (uint256) {
        uint256 initialDeposit = deposits[depositor];
        if (initialDeposit == 0) {
            return 0;
        }

        Snapshot memory snapshots = depositSnapshots[depositor];

        uint256 compoundedDeposit = _getCompoundedDepositFromSnap(
            initialDeposit,
            snapshots
        );

        return compoundedDeposit;
    }

    function _getCompoundedDepositFromSnap(
        uint256 initialStake,
        Snapshot memory snapshots
    ) public view returns (uint256) {
        uint256 snapP = snapshots.P;
        uint256 scaleSnap = snapshots.scale;
        uint256 epochSnap = snapshots.epoch;

        if (epochSnap < currentEpoch) return 0;

        uint256 compoundedStake;
        uint256 scaleDiff = currentScale - scaleSnap;

        if (scaleDiff == 0) {
            compoundedStake = initialStake.mulDiv(P, snapP);
        } else if (scaleDiff == 1) {
            compoundedStake = initialStake.mulDiv(P, snapP) / (SCALE_FACTOR);
        } else {
            compoundedStake = 0;
        }

        if (compoundedStake < initialStake / SCALE_FACTOR) return 0;

        return compoundedStake;
    }

    /**
     * @dev Updates the deposit amount and snapshots for a given depositor.
     * If the deposit amount is zero, the snapshot is deleted.
     */
    function _updateDepositAndSnapshots(
        address depositor,
        uint256 newValue
    ) internal {
        deposits[depositor] = newValue;
        if (newValue == 0) {
            delete depositSnapshots[depositor];
            return;
        }
        uint256 currentScaleCached = currentScale;
        uint256 currentEpochCached = currentEpoch;
        uint256 currentP = P;

        uint256 currentS = epochtoSum[currentEpochCached][currentScaleCached];

        depositSnapshots[depositor].P = currentP;
        depositSnapshots[depositor].S = currentS;
        depositSnapshots[depositor].scale = currentScaleCached;
        depositSnapshots[depositor].epoch = currentEpochCached;
    }

    // GETTERS

    function getTotalStaked() external view returns (uint256) {
        return totalStaked;
    }

    function getdepositorDeposit(
        address depositor
    ) external view returns (uint256) {
        return deposits[depositor];
    }
}
