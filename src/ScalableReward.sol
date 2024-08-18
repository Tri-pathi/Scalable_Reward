// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
/*
 * The Scalable_Reward Pool holds staking tokens deposited by depositors.
 *
 * When inteegrated yield source liquidated, then depending on system conditions, some of its debt gets offset with
 * staking token:  that is, the offset debt evaporates, and an equal amount of staking tokens in the Scalable_Reward is burned.
 *
 * Thus, a liquidation causes each depositor to receive a staked token loss, in proportion to their deposit as a share of total deposits.
 * They also receive an reward gain in the same proportion.
 *
 * When a liquidation occurs, it depletes every deposit by the same fraction: for example, a liquidation that depletes 40%
 * of the total staked deposits in the Stability Pool, depletes 40% of each deposit.
 *
 * A deposit that has experienced a series of liquidations is termed a "compounded deposit": each liquidation depletes the deposit,
 * multiplying it by some factor in range ]0,1[
 *
 *
 * --- IMPLEMENTATION ---
 *
 * We use a highly scalable method of tracking deposits and Reward gains that has O(1) complexity.
 *
 * When a liquidation occurs, rather than updating each depositor's deposit and Reward gain, we simply update two state variables:
 * a product P, and a sum S.
 *
 * A mathematical manipulation allows us to factor out the initial deposit, and accurately track all depositors' compounded deposits
 * and accumulated Reward gains over time, as liquidations occur, using just these two variables P and S. When depositors join the
 * Scalable_reward pool, they get a snapshot of the latest P and S: P_t and S_t, respectively.
 *
 *
 * For a given deposit d_t, the ratio P/P_t tells us the factor by which a deposit has decreased since it joined the  Pool,
 * and the term d_t * (S - S_t)/P_t gives us the deposit's total accumulated reward gain.
 *
 * Each liquidation updates the product P and sum S. After a series of liquidations, a compounded deposit and corresponding reward gain
 * can be calculated using the initial deposit, the depositor’s snapshots of P and S, and the latest values of P and S.
 *
 * Any time a depositor updates their deposit (withdrawal, top-up) their accumulated reward gain is paid out, their new deposit is recorded
 * (based on their latest compounded deposit and modified by the withdrawal/top-up), and they receive new snapshots of the latest P and S.
 * Essentially, they make a fresh deposit that overwrites the old one.
 *
 *
 * --- SCALE FACTOR ---
 *
 * Since P is a running product in range ]0,1] that is always-decreasing, it should never reach 0 when multiplied by a number in range ]0,1[.
 * Unfortunately, Solidity floor division always reaches 0, sooner or later.
 *
 * A series of liquidations that nearly empty the Pool (and thus each multiply P by a very small number in range ]0,1[ ) may push P
 * to its 18 digit decimal limit, and round it to 0, when in fact the Pool hasn't been emptied: this would break deposit tracking.
 *
 * So, to track P accurately, we use a scale factor: if a liquidation would cause P to decrease to <1e-9 (and be rounded to 0 by Solidity),
 * we first multiply P by 1e9, and increment a currentScale factor by 1.
 *
 * The added benefit of using 1e9 for the scale factor (rather than 1e18) is that it ensures negligible precision loss close to the 
 * scale boundary: when P is at its minimum value of 1e9, the relative precision loss in P due to floor division is only on the 
 * order of 1e-9. 
 *
 * --- EPOCHS ---
 *
 * Whenever a liquidation fully empties the Pool, all deposits should become 0. However, setting P to 0 would make P be 0
 * forever, and break all future reward calculations.
 *
 * So, every time the  Pool is emptied by a liquidation, we reset P = 1 and currentScale = 0, and increment the currentEpoch by 1.
 *
 * --- TRACKING DEPOSIT OVER SCALE CHANGES AND EPOCHS ---
 *
 * When a deposit is made, it gets snapshots of the currentEpoch and the currentScale.
 *
 * When calculating a compounded deposit, we compare the current epoch to the deposit's epoch snapshot. If the current epoch is newer,
 * then the deposit was present during a pool-emptying liquidation, and necessarily has been depleted to 0.
 *
 * Otherwise, we then compare the current scale to the deposit's scale snapshot. If they're equal, the compounded deposit is given by d_t * P/P_t.
 * If it spans one scale change, it is given by d_t * P/(P_t * 1e9). If it spans more than one scale change, we define the compounded deposit
 * as 0, since it is now less than 1e-9'th of its initial value (e.g. a deposit of 1 billion LUSD has depleted to < 1 LUSD).
 *
 *
 *  --- TRACKING DEPOSITOR'S REWARD GAIN OVER SCALE CHANGES AND EPOCHS ---
 *
 * In the current epoch, the latest value of S is stored upon each scale change, and the mapping (scale -> S) is stored for each epoch.
 *
 * This allows us to calculate a deposit's accumulated Reward gain, during the epoch in which the deposit was non-zero and earned Reward.
 *
 * We calculate the depositor's accumulated Reward gain for the scale at which they made the deposit, using the Reward gain formula:
 * e_1 = d_t * (S - S_t) / P_t
 *
 * and also for scale after, taking care to divide the latter by a factor of 1e9:
 * e_2 = d_t * S / (P_t * 1e9)
 *
 * The gain in the second scale will be full, as the starting point was in the previous scale, thus no need to subtract anything.
 * The deposit therefore was present for reward events from the beginning of that second scale.
 *
 *        S_i-S_t + S_{i+1}
 *      .<--------.------------>
 *      .         .
 *      . S_i     .   S_{i+1}
 *   <--.-------->.<----------->
 *   S_t.         .
 *   <->.         .
 *      t         .
 *  |---+---------|-------------|-----...
 *         i            i+1
 *
 * The sum of (e_1 + e_2) captures the depositor's total accumulated Reward gain, handling the case where their
 * deposit spanned one scale change. We only care about gains across one scale change, since the compounded
 * deposit is defined as being 0 once it has spanned more than one scale change.
 *
 *
 * --- UPDATING P WHEN A LIQUIDATION OCCURS ---
 *
 * Please see the implementation spec in the proof document, which closely follows on from the compounded deposit / ETH gain derivations:
 * https://github.com/liquity/liquity/blob/master/papers/Scalable_Reward_Distribution_with_Compounding_Stakes.pdf
 *
 */
contract ScalableReward is Ownable2Step {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // Event declarations
    /**
     * @dev Emitted when a user makes a deposit.
     * @param user Address of the user who made the deposit.
     * @param amount Amount of tokens deposited.
     * @param newTotalStaked Updated total amount of staked tokens.
     */
    event DepositMade(
        address indexed user,
        uint256 amount,
        uint256 newTotalStaked
    );

    /**
     * @dev Emitted when a user withdraws from their staked tokens.
     * @param user Address of the user who made the withdrawal.
     * @param amount Amount of tokens withdrawn.
     * @param newTotalStaked Updated total amount of staked tokens.
     */
    event WithdrawalMade(
        address indexed user,
        uint256 amount,
        uint256 newTotalStaked
    );

    /**
     * @dev Emitted when a liquidation occurs.
     * @param debtToOffset Amount of debt to be offset by liquidation.
     * @param rewardTokenToAdd Amount of reward tokens to be added.
     * @param newTotalStaked Updated total amount of staked tokens after liquidation.
     */
    event Liquidation(
        uint256 debtToOffset,
        uint256 rewardTokenToAdd,
        uint256 newTotalStaked
    );

    /**
     * @dev Emitted when a reward is sent to a user.
     * @param user Address of the user receiving the reward.
     * @param rewardAmount Amount of reward tokens sent.
     */
    event RewardSent(address indexed user, uint256 rewardAmount);

    /**
     * @dev Emitted when the current epoch is updated.
     * @param _currentEpoch The new current epoch.
     */
    event EpochUpdated(uint256 _currentEpoch);

    /**
     * @dev Emitted when the current scale is updated.
     * @param _currentScale The new current scale.
     */
    event ScaleUpdated(uint256 _currentScale);

    // State variables
    IERC20 public stakingToken; // Token to be staked (e.g., stable USD)
    IERC20 public rewardToken; // Reward token (e.g., WETH)

    /**
     * @dev Snapshot struct to store depositor's snapshots of sum, product, scale, and epoch.
     */
    struct Snapshot {
        uint256 S; // Snapshot of the sum
        uint256 P; // Snapshot of the product
        uint256 scale; // Snapshot of the scale
        uint256 epoch; // Snapshot of the epoch
    }

    mapping(address => uint256) public deposits; // Mapping of user deposits
    uint public constant DECIMAL_PRECISION = 1e18; // Precision constant
    uint public constant SCALE_FACTOR = 1e9; // Scale factor constant
    uint public P = DECIMAL_PRECISION; // Product variable for tracking deposits
    uint256 public totalStaked; // Total staked tokens in the pool
    mapping(address => Snapshot) public depositSnapshots; // Mapping of user deposit snapshots

    uint256 public rewardTokenAmount; // Tracker for the amount of reward tokens deposited

    // Error trackers for error correction in offset calculation
    uint public lastRewardError_Offset; // Error offset for reward gain calculation
    uint public lastStakedLossError_Offset; // Error offset for staked loss calculation

    uint256 public currentEpoch; // Current epoch tracker
    mapping(uint256 => mapping(uint256 => uint256)) public epochtoSum; // Mapping of epoch to sum of rewards
    uint256 public currentScale; // Current scale factor

    address public LossAccumulator; // Since we haven't connected any yield source so funds will go at this address for representing loss

    /**
     * @dev Constructor for the ScalableReward contract.
     * @param _stakingToken Address of the staking token contract.
     * @param _rewardToken Address of the reward token contract.
     */
    constructor(
        address _stakingToken,
        address _rewardToken,
        address _lossAccumulator
    ) Ownable(msg.sender) {
        stakingToken = IERC20(_stakingToken); // Initialize staking token
        rewardToken = IERC20(_rewardToken); // Initialize reward token
        LossAccumulator = _lossAccumulator;
    }
    /**
     * @notice Allows a user to deposit tokens into the vault.
     * @dev Updates the user's deposit, sends any accumulated rewards, and emits a `DepositMade` event.
     * @param amount Amount of tokens to deposit.
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
     * @notice Allows a user to withdraw tokens from the vault.
     * @dev Updates the user's deposit, sends any accumulated rewards, and emits a `WithdrawalMade` event.
     * @param amount Amount of tokens to withdraw.
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

        if (withdrawalAmount != 0) {
            stakingToken.safeTransfer(msg.sender, withdrawalAmount);
            totalStaked -= withdrawalAmount;
        }

        uint256 newDeposit = compoundedDeposit - withdrawalAmount;
        _updateDepositAndSnapshots(msg.sender, newDeposit);

        _sendRewardGainToDepositor(depositorRewardGain);

        emit WithdrawalMade(msg.sender, amount, totalStaked);
    }

    /**
     * @notice Allows the contract owner to liquidate a portion of the vault.
     * @dev Adjusts the reward and loss per unit staked, and emits a `Liquidation` event.
     * @param debtToOffset Amount of debt to be offset by liquidation.
     * @param rewardTokenToAdd Amount of reward tokens to be added.
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
            uint256 LossPerUnitStaked,
            uint256 RewardGainPerUnitStaked
        ) = _computeRewardsPerUnitStaked(debtToOffset, rewardTokenToAdd);

        _updateRewardSumAndProduct(LossPerUnitStaked, RewardGainPerUnitStaked);

        //loss represented manually
        totalStaked -= debtToOffset;
        stakingToken.safeTransfer(LossAccumulator, debtToOffset);
        rewardToken.safeTransferFrom(owner(), address(this), rewardTokenToAdd);
        rewardTokenAmount += rewardTokenToAdd;

        emit Liquidation(debtToOffset, rewardTokenToAdd, totalStaked);
    }
    /**
     * @notice Computes the reward gain and loss per unit staked during liquidation.
     * @dev This function is internal and adjusts for any errors in previous calculations.
     * @param debtToOffset Amount of debt to be offset by liquidation.
     * @param rewardTokenToAdd Amount of reward tokens to be added.
     * @return LossPerUnitStaked Computed loss per unit staked.
     * @return RewardGainPerUnitStaked Computed reward gain per unit staked.
     */
    function _computeRewardsPerUnitStaked(
        uint256 debtToOffset,
        uint256 rewardTokenToAdd
    )
        internal
        returns (uint256 LossPerUnitStaked, uint256 RewardGainPerUnitStaked)
    {
        uint256 RewardNumerator = (rewardTokenToAdd * DECIMAL_PRECISION) +
            lastRewardError_Offset;

        uint256 _totalStaked = totalStaked;

        require(debtToOffset <= _totalStaked, "UnderFlow");
        if (debtToOffset == _totalStaked) {
            LossPerUnitStaked = DECIMAL_PRECISION;
            lastStakedLossError_Offset = 0;
        } else {
            uint256 StakedLossNumerator = (debtToOffset * DECIMAL_PRECISION) -
                lastStakedLossError_Offset;

            LossPerUnitStaked = (StakedLossNumerator / _totalStaked);
            lastStakedLossError_Offset =
                (LossPerUnitStaked * _totalStaked) -
                StakedLossNumerator;
        }

        RewardGainPerUnitStaked = RewardNumerator / (_totalStaked);

        lastRewardError_Offset =
            RewardNumerator -
            (RewardGainPerUnitStaked * _totalStaked);
    }
    /**
     * @notice Updates the reward sum and product with the calculated gains and losses.
     * @dev This function is internal and updates the global state variables for reward distribution.
     * @param RewardGainPerUnitStaked Computed reward gain per unit staked.
     * @param LossPerUnitStaked Computed loss per unit staked.
     */

    function _updateRewardSumAndProduct(
        uint256 LossPerUnitStaked,
        uint256 RewardGainPerUnitStaked
    ) internal {
        uint256 currentP = P;
        uint256 newP;

        require(
            LossPerUnitStaked <= DECIMAL_PRECISION,
            "loss per unit can't be more than 1e18"
        );
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
            newP = currentP.mulDiv(
                newProductFactor * SCALE_FACTOR,
                DECIMAL_PRECISION
            );
            currentScale = currentScaleCached + 1;
            emit ScaleUpdated(currentScale);
        } else {
            newP = currentP.mulDiv(newProductFactor, DECIMAL_PRECISION);
        }

        require(newP > 0, "NewP is zero");
        P = newP;
    }

    /**
     * @notice Sends the accumulated reward gain to the user.
     * @dev This function is internal and transfers the reward tokens to the user.
     * @param value Amount of reward tokens to send.
     */
    function _sendRewardGainToDepositor(uint256 value) internal {
        if (value == 0) return;

        rewardTokenAmount -= value;

        rewardToken.safeTransfer(msg.sender, value);

        emit RewardSent(msg.sender, value);
    }

    /**
     * @notice Calculates the depositor's reward gain.
     * @dev This function computes the reward gain based on the current state and user's snapshots.
     * @param depositor Address of the user whose reward gain is to be calculated.
     * @return rewardGain Computed reward gain for the user.
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
        /*
         * Grab the sum 'S' from the epoch at which the stake was made. The Reward gain may span up to one scale change.
         * If it does, the second portion of the reward gain is scaled by 1e9.
         * If the gain spans no scale change, the second portion will be 0.
         */
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
     * @notice Calculates the compounded deposit value for a user.
     * @dev This function computes the compounded deposit based on the current state and user's snapshots.
     * @param depositor Address of the user whose compounded deposit is to be calculated.
     * @return CompoundedDeposit Computed compounded deposit for the user.
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
            compoundedStake = initialStake.mulDiv(P, snapP * SCALE_FACTOR);
        } else {
            compoundedStake = 0;
        }
        /*
         * If compounded deposit is less than a billionth of the initial deposit, return 0.
         */
        if (compoundedStake < (initialStake / SCALE_FACTOR)) return 0;

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
