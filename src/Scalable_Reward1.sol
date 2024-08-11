// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

contract ScalableReward1 is ERC4626, Ownable2Step {
    using Math for uint256;
    using SafeERC20 for IERC20;

    //Staking token will stay on the vault and corresponding number of shares
    //will represent the underlying deposit value
    /**
    1. Whenever liquidation happens totaAssets will decrease so balance of users will
       decrease in the same proportion

    2. In Liquidation, Corressponding Collateral will be released as rewards between all the stakers
       we can use sushi master chef logic to distribute this reward between all staker proportionally


    This is easy and simpler than previous contract and serving approx same purpose
     */

    //Event
    event LiquidationRewardIsAdded(uint256 addedReward);

    //Error

    error UnsupportedOperation();

    uint256 currentRewardFromLiquidation;
    uint256 accRewardPerShare; // Accumulated reward per shares from the liquidation

    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public rewardsPoint;
    constructor(
        string memory name_,
        string memory symbol_,
        address asset_
    ) ERC20(name_, symbol_) ERC4626(IERC20(asset_)) Ownable(msg.sender) {}

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

    //A point representation of current accumulated rewards
    function pendingRewardPoints() external view returns (uint256) {
        uint256 totalBalance = totalSupply();
        uint256 accPoints = accRewardPerShare;

        if (totalBalance != 0 && currentRewardFromLiquidation > 0) {
            accPoints =
                accPoints +
                (currentRewardFromLiquidation) /
                totalBalance;
        }

        return balanceOf(msg.sender) * accPoints - rewardDebt[msg.sender];
    }

    //Liquidation will cause removal of underlying asset and addition of reward

    //Taking the case of whitepaper LSUD is being removed and WETH is given as reward to all share holders proportionally

    function liquidate(
        uint256 /*assetToRemove*/,
        uint256 rewardToadd
    ) external onlyOwner {
        updateVault();
        //Assuming asset is already transferd from the vault hence we need to just increase the reward
        //so that it weth reward can be distributed for loss

        currentRewardFromLiquidation += rewardToadd;

        emit LiquidationRewardIsAdded(rewardToadd);
    }

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
     * @notice Mint is not supported by this contract
     */
    function mint(uint256, address) public pure override returns (uint256) {
        revert UnsupportedOperation();
    }

    /**
     * @notice Withdraw is not supported by this contract
     */
    function withdraw(
        uint256,
        address,
        address
    ) public pure override returns (uint256) {
        revert UnsupportedOperation();
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }
}
