// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, Vm, console} from "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ScalableReward1} from "../src/ScalableReward1.sol";
import {MockERC20} from "../src/MockERC20.sol";

contract ScalableReward1Test is Test {
    address alice;
    address bob;
    address lossAccmulator;
    MockERC20 stakingToken;
    MockERC20 rewardToken;
    ScalableReward1 public scalablereward;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        lossAccmulator = makeAddr("lossAccmulator");
        stakingToken = new MockERC20("Staking Token", "ST");
        rewardToken = new MockERC20("Reward Token", "RT");
        scalablereward = new ScalableReward1(
            "SyndrVaultERC20",
            "SV",
            address(stakingToken),
            lossAccmulator
        );

        stakingToken.mint(alice, 10000 ether);
        stakingToken.mint(bob, 10000 ether);
        rewardToken.mint(address(this), 1000 ether);
    }

    function test_deposit() public {
        vm.prank(alice);
        stakingToken.approve(address(scalablereward), 100 ether);
        vm.prank(alice);
        scalablereward.deposit(100 ether, alice);
        assertEq(scalablereward.balanceOf(alice), 100 ether * 1e6); //since 6 is decimal offset

        vm.prank(bob);
        stakingToken.approve(address(scalablereward), 100 ether);
        vm.prank(bob);
        scalablereward.deposit(100 ether, bob);
        assertEq(scalablereward.balanceOf(bob), 100 ether * 1e6);
    }

    function test_LossDecreasesSharesProportionally() public {
        // in case of loss, All shareholders corresponding underlying assets in the same ratio as of loss
        test_deposit();
        //Now pool must have 200 underlying staking tokens and two shareholder Alice and Bob

        //lets create loss of 20 staking tokens i.e 20 staking token will be burnt/transferred from the pool

        //Since test contract is owner

        scalablereward.liquidate(20 ether, 0); //Not adding any reward at the moment

        assertEq(
            scalablereward.previewRedeem(scalablereward.balanceOf(alice)),
            90 ether
        );
        assertEq(
            scalablereward.previewRedeem(scalablereward.balanceOf(bob)),
            90 ether
        );
    }

    function test_RewardDistributedPropotionally() public {
        test_deposit();

        //In current state pool has 200 staking tokens and 2 share holders, holding equal shares
        //Assuming loss is 70 staking tokens for which 1000 reward tokens is distributed
        rewardToken.transfer(address(scalablereward), 1000 ether);
        scalablereward.liquidate(70 ether, 1000 ether);

        uint256 halfRewardPoints = (1000 ether * 1e6) / 2; //reward is in the precision of shares

        assertEq(scalablereward.pendingRewardPoints(alice), halfRewardPoints);
        assertEq(scalablereward.pendingRewardPoints(bob), halfRewardPoints);
    }
}
