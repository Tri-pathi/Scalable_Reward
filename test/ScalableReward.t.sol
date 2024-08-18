// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, Vm, console} from "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ScalableReward} from "../src/ScalableReward.sol";
import {MockERC20} from "../src/MockERC20.sol";

contract Testing1 is Test {
    address alice;
    address bob;
    address lossAccmulator;
    MockERC20 stakingToken;
    MockERC20 rewardToken;
    ScalableReward public scalablereward;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        lossAccmulator = makeAddr("lossAccmulator");
        stakingToken = new MockERC20("Staking Token", "ST");
        rewardToken = new MockERC20("Reward Token", "RT");
        scalablereward = new ScalableReward(
            address(stakingToken),
            address(rewardToken),
            lossAccmulator
        );

        stakingToken.mint(alice, 10000 ether);
        stakingToken.mint(bob, 10000 ether);
        rewardToken.mint(address(this), 1000 ether);
    }

    function test_DepositInVault() public {
        vm.prank(alice);
        stakingToken.approve(address(scalablereward), 100 ether);
        vm.prank(alice);
        scalablereward.depositInVault(100 ether);

        assertEq(scalablereward.totalStaked(), 100 ether);
        assertEq(scalablereward.deposits(alice), 100 ether);
        assertEq(scalablereward.getCompoundedDeposit(alice), 100 ether);

        vm.prank(bob);
        stakingToken.approve(address(scalablereward), 100 ether);
        vm.prank(bob);
        scalablereward.depositInVault(100 ether);

        assertEq(scalablereward.totalStaked(), 200 ether);
        assertEq(scalablereward.deposits(bob), 100 ether);
        assertEq(scalablereward.getCompoundedDeposit(bob), 100 ether);
    }

    function test_IntroduceLossAndDistributeReward() public {
        test_DepositInVault();
        //Alice and bob both have 100 staking tokens in the pool now lets create loss of 20 tokens and distribute
        //1000 rewards token for corressponding loss

        rewardToken.approve(address(scalablereward), 1000 ether);

        scalablereward.liquidate(20 ether, 1000 ether);

        // 1. total staked decreased 10% hence every staker wil incur same 10% loss
        assertEq(scalablereward.totalStaked(), 180 ether);
        assertEq(scalablereward.getCompoundedDeposit(alice), 90 ether);
        assertEq(scalablereward.getCompoundedDeposit(bob), 90 ether);

        // 2. Product P and Sum S will change
        uint256 currentEpoch = scalablereward.currentEpoch();
        uint256 currentScale = scalablereward.currentScale();
        console.log("Global P :", scalablereward.P());
        console.log(
            "Global S :",
            scalablereward.epochtoSum(currentEpoch, currentScale)
        );

        // 3. Rewards will be distributed proportionally
        assertEq(scalablereward.getdepositorRewardGain(alice), 500 ether);
        assertEq(scalablereward.getdepositorRewardGain(bob), 500 ether);
        // 4. Now if one of staker make new deposit componded deposit will include previous liquidations

        // Alice made new deposit
        vm.prank(alice);
        stakingToken.approve(address(scalablereward), 100 ether);
        vm.prank(alice);
        scalablereward.depositInVault(100 ether);

        //Now if we check compoundedDeposit, it should be 190
        assertEq(scalablereward.getCompoundedDeposit(alice), 190 ether);

        //now do again liquidation and it can be seen that all the variable work properly
    }

    function test_WithdrawFunctionality() public {
        test_IntroduceLossAndDistributeReward();

        //Now Alice and Bob both have some reward gains let's withdraw for alice

        vm.prank(alice);
        scalablereward.withdrawFromVault(50 ether);

        assertEq(scalablereward.getCompoundedDeposit(alice), 140 ether);

        assertEq(rewardToken.balanceOf(alice), 500 ether);
    }
}
