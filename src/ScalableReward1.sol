// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/**
 * @title ScalableReward1
 * @dev A vault contract implementing ERC4626 for staking and distributing liquidation rewards.
 * This contract allows users to deposit an asset, receive shares, and earn rewards from liquidations.
 * It also manages the distribution of rewards proportionally among stakers.
 */
contract ScalableReward1 is ERC4626, Ownable2Step {
    using Math for uint256;
    using SafeERC20 for IERC20;

    // Event emitted when liquidation rewards are added
    event LiquidationRewardIsAdded(uint256 addedReward);

    // Error to indicate unsupported operations
    error UnsupportedOperation();

    uint256 public currentRewardFromLiquidation;
    uint256 public accRewardPerShare; // Accumulated reward per share from the liquidation
    address public lossAccmulator;

    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public rewardsPoint;

    /**
     * @notice Constructor for ScalableReward1
     * @param name_ The name of the ERC20 token representing shares.
     * @param symbol_ The symbol of the ERC20 token representing shares.
     * @param asset_ The address of the underlying asset.
     * @param _lossAccmulator The address where removed assets will be sent during liquidation.
     */
    constructor(
        string memory name_,
        string memory symbol_,
        address asset_,
        address _lossAccmulator
    ) ERC20(name_, symbol_) ERC4626(IERC20(asset_)) Ownable(msg.sender) {
        lossAccmulator = _lossAccmulator;
    }

    /**
     * @notice Updates the vault's state, distributing any pending liquidation rewards.
     */
    function updateVault() public {
        uint256 totalBalance = totalSupply();
        if (totalBalance == 0) {
            return;
        }
        uint reward = currentRewardFromLiquidation;
        if (reward == 0) {
            return;
        }

        accRewardPerShare = accRewardPerShare + reward / totalBalance;

        currentRewardFromLiquidation = 0;
    }

    /**
     * @notice Returns the pending reward points for the caller.
     * @return The pending reward points for the caller.
     */
    function pendingRewardPoints(address user) external view returns (uint256) {
        uint256 totalBalance = totalSupply();
        uint256 accPoints = accRewardPerShare;

        if (totalBalance != 0 && currentRewardFromLiquidation > 0) {
            accPoints =
                accPoints +
                (currentRewardFromLiquidation) /
                totalBalance;
        }

        return balanceOf(user) * accPoints - rewardDebt[msg.sender];
    }

    /**
     * @notice Performs liquidation by removing a specified amount of the asset and adding a reward.
     * @param assetToRemove The amount of the underlying asset to remove from the vault.
     * @param rewardToadd The reward amount to add for distribution among stakers.
     */
    function liquidate(
        uint256 assetToRemove,
        uint256 rewardToadd
    ) external onlyOwner {
        updateVault();

        IERC20(asset()).safeTransfer(lossAccmulator, assetToRemove);
        currentRewardFromLiquidation += rewardToadd * 1e6;//since reward should have same precision of shares

        emit LiquidationRewardIsAdded(rewardToadd);
    }

    /**
     * @notice Deposits a specified amount of the underlying asset and updates the reward state.
     * @param assets The amount of the underlying asset to deposit.
     * @param receiver The address that will receive the shares.
     * @return The number of shares minted.
     */
    function deposit(
        uint256 assets,
        address receiver
    ) public override returns (uint256) {
        require(assets > 0, "InvalidAmount");
        updateVault();

        if (balanceOf(msg.sender) > 0) {
            uint256 pendingLiquidationReward = balanceOf(msg.sender) *
                accRewardPerShare -
                rewardDebt[msg.sender];
            rewardsPoint[msg.sender] += pendingLiquidationReward;
        }

        uint256 shares = super.deposit(assets, receiver);

        rewardDebt[msg.sender] = balanceOf(msg.sender) * accRewardPerShare;

        return shares;
    }

    /**
     * @notice Redeems a specified number of shares and updates the reward state.
     * @param shares The number of shares to redeem.
     * @param receiver The address that will receive the redeemed assets.
     * @param owner The address of the owner of the shares to redeem.
     * @return The number of assets withdrawn.
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override returns (uint256) {
        updateVault();
        uint256 pendingLiquidationReward = balanceOf(msg.sender) *
            accRewardPerShare -
            rewardDebt[msg.sender];

        rewardsPoint[msg.sender] += pendingLiquidationReward;

        return super.redeem(shares, receiver, owner);
    }

    /**
     * @notice Minting new shares is not supported by this contract.
     * @dev Overrides the ERC4626 mint function to always revert.
     */
    function mint(uint256, address) public pure override returns (uint256) {
        revert UnsupportedOperation();
    }

    /**
     * @notice Withdrawing assets is not supported by this contract.
     * @dev Overrides the ERC4626 withdraw function to always revert.
     */
    function withdraw(
        uint256,
        address,
        address
    ) public pure override returns (uint256) {
        revert UnsupportedOperation();
    }

    /**
     * @notice Internal function to define the decimals offset for this contract.
     * @return The decimals offset.
     */
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }
}
