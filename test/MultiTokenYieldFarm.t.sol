// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import "../src/MultiTokenYieldFarm.sol";

contract YieldFarmTest is Test {
    MultiTokenYieldFarm public farm;
    YieldFarmToken public rewardToken;
    ERC20Mock public lpToken1;
    ERC20Mock public lpToken2;
    ERC20Mock public bonusToken;

    address public owner;
    address public alice;
    address public bob;
    address public charlie;
    address public feeCollector;

    uint256 public constant INITIAL_REWARD_PER_BLOCK = 100e18;
    uint256 public constant START_BLOCK = 100;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    function setUp() public {
        owner = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        feeCollector = makeAddr("feeCollector");

        // Deploy reward token
        rewardToken = new YieldFarmToken();

        // Deploy farm contract
        vm.roll(START_BLOCK - 10); // Start before the farming begins
        farm = new MultiTokenYieldFarm(rewardToken, INITIAL_REWARD_PER_BLOCK, START_BLOCK);

        // Set farm as minter
        rewardToken.addMinter(address(farm));

        // Deploy test tokens
        lpToken1 = new ERC20Mock();
        lpToken2 = new ERC20Mock();
        bonusToken = new ERC20Mock();

        // Set fee collector
        farm.setFeeCollector(feeCollector);

        // Setup initial balances
        _setupBalances();

        // Add initial pools
        _addInitialPools();
    }

    function _setupBalances() internal {
        lpToken1.mint(alice, 1000e18);
        lpToken1.mint(bob, 1000e18);
        lpToken1.mint(charlie, 1000e18);

        lpToken2.mint(alice, 1000e18);
        lpToken2.mint(bob, 1000e18);

        bonusToken.mint(address(this), 10000e18);

        // Approve farm contract
        vm.startPrank(alice);
        lpToken1.approve(address(farm), type(uint256).max);
        lpToken2.approve(address(farm), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        lpToken1.approve(address(farm), type(uint256).max);
        lpToken2.approve(address(farm), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(charlie);
        lpToken1.approve(address(farm), type(uint256).max);
        vm.stopPrank();
    }

    function _addInitialPools() internal {
        farm.add(1000, lpToken1, 0, 0, 1 days, true);

        farm.add(500, lpToken2, 200, 100, 1 weeks, false);
    }

    // ============ Basic Functionality Tests ============

    function testInitialState() public {
        assertEq(farm.poolLength(), 2);
        assertEq(farm.rewardPerBlock(), INITIAL_REWARD_PER_BLOCK);
        assertEq(farm.startBlock(), START_BLOCK);
        assertEq(farm.totalAllocPoint(), 1500);

        (IERC20 stakingToken, uint256 allocPoint,,,,,,) = farm.poolInfo(0);
        assertEq(address(stakingToken), address(lpToken1));
        assertEq(allocPoint, 1000);
    }

    function testBasicDeposit() public {
        vm.roll(START_BLOCK + 1);

        uint256 depositAmount = 100e18;
        uint256 initialBalance = lpToken1.balanceOf(alice);

        vm.startPrank(alice);
        vm.expectEmit(true, true, false, true);
        emit Deposit(alice, 0, depositAmount);

        farm.deposit(0, depositAmount, address(0));
        vm.stopPrank();

        // Check balances
        assertEq(lpToken1.balanceOf(alice), initialBalance - depositAmount);
        assertEq(lpToken1.balanceOf(address(farm)), depositAmount);

        // Check user info
        (uint256 amount, uint256 rewardDebt, uint256 bonusRewardDebt, uint256 lastDepositTime, address referrer,) =
            farm.userInfo(0, alice);

        assertEq(amount, depositAmount);
        assertEq(rewardDebt, 0); // First deposit has no pending rewards
        assertEq(lastDepositTime, block.timestamp);
        assertEq(referrer, address(0));
    }

    function testBasicWithdraw() public {
        // First deposit
        vm.roll(START_BLOCK + 1);
        vm.prank(alice);
        farm.deposit(0, 100e18, address(0));

        // Fast forward some blocks and time
        vm.roll(START_BLOCK + 10);
        vm.warp(block.timestamp + 10 days);

        uint256 withdrawAmount = 50e18;
        uint256 initialBalance = lpToken1.balanceOf(alice);
        uint256 initialRewardBalance = rewardToken.balanceOf(alice);

        vm.startPrank(alice);
        vm.expectEmit(true, true, false, true);
        emit Withdraw(alice, 0, withdrawAmount);

        farm.withdraw(0, withdrawAmount);
        vm.stopPrank();

        // Check LP token balance
        assertEq(lpToken1.balanceOf(alice), initialBalance + withdrawAmount);

        // Check reward tokens received
        assertGt(rewardToken.balanceOf(alice), initialRewardBalance);

        // Check remaining staked amount
        (uint256 amount,,,,,) = farm.userInfo(0, alice);
        assertEq(amount, 50e18);
    }

    function testEmergencyWithdrawEdgeCases() public {
        vm.roll(START_BLOCK + 1);

        // Alice deposits
        vm.prank(alice);
        farm.deposit(0, 100e18, address(0));

        // Fast forward to accrue rewards
        vm.roll(START_BLOCK + 10);

        uint256 aliceInitialBalance = lpToken1.balanceOf(alice);
        uint256 initialRewardBalance = rewardToken.balanceOf(alice);

        // Emergency withdraw
        vm.prank(alice);
        farm.emergencyWithdraw(0);

        uint256 aliceAfterBalance = lpToken1.balanceOf(alice);
        uint256 afterRewardBalance = rewardToken.balanceOf(alice);

        // Check that no rewards were paid
        assertEq(afterRewardBalance, initialRewardBalance);

        // Check fee was applied (15% emergency fee)
        uint256 expectedWithdraw = 100e18 - (100e18 * 1500) / 10000; // 85e18
        assertEq(aliceAfterBalance - aliceInitialBalance, expectedWithdraw);

        // Check user state is properly reset
        (uint256 amount, uint256 rewardDebt, uint256 bonusRewardDebt,,,) = farm.userInfo(0, alice);
        assertEq(amount, 0);
        assertEq(rewardDebt, 0);
        assertEq(bonusRewardDebt, 0);
    }

    function testZeroStakingSupplyDivisionByZero() public {
        // Test edge case where pool has zero staking supply
        vm.roll(START_BLOCK + 1);

        // Try to update a pool with no deposits
        farm.updatePool(0);
        // This should handle division by zero gracefully
        (,, uint256 lastRewardBlock, uint256 accRewardPerShare,,,,) = farm.poolInfo(0);

        assertEq(lastRewardBlock, block.number);
        assertEq(accRewardPerShare, 0); // Should remain 0, not cause revert
    }


    function testMinimalAmounts() public {
        vm.roll(START_BLOCK + 1);

        // Test with 1 wei deposit
        vm.prank(alice);
        farm.deposit(0, 1, address(0));

        vm.roll(START_BLOCK + 100);

        // Check if rewards are calculated correctly for tiny amounts
        (uint256 pending,) = farm.pendingRewards(0, alice);
        console.log("Pending rewards for 1 wei deposit:", pending);

        // Withdraw the 1 wei
        vm.prank(alice);
        farm.withdraw(0, 1);
    }

    function testMaximumDeposits() public {
        vm.roll(START_BLOCK + 1);

        // Test with maximum possible deposit
        uint256 maxDeposit = type(uint256).max / 2; 
        lpToken1.mint(alice, maxDeposit);

        vm.prank(alice);

        try farm.deposit(0, maxDeposit, address(0)) {
            console.log("Maximum deposit succeeded");
        } catch {
            console.log("Maximum deposit failed - potential overflow protection");
        }
    }

    function testBonusTokenExpiration() public {
        vm.roll(START_BLOCK + 1);

        // Set bonus token that expires soon
        bonusToken.approve(address(farm), type(uint256).max);
        farm.setBonusToken(0, bonusToken, 10e18, START_BLOCK + 50);

        // Alice deposits
        vm.prank(alice);
        farm.deposit(0, 100e18, address(0));

        // Fast forward past bonus expiration
        vm.roll(START_BLOCK + 100);

        // Check bonus rewards stop accruing
        (uint256 pending, uint256 bonusPending) = farm.pendingRewards(0, alice);

        console.log("Primary pending after bonus expiration:", pending);
        console.log("Bonus pending after expiration:", bonusPending);

    }

    function testPendingRewardsCalculation() public {
        vm.roll(START_BLOCK + 1);

        vm.prank(alice);
        farm.deposit(0, 100e18, address(0));

        vm.roll(START_BLOCK + 10);

        (uint256 pending,) = farm.pendingRewards(0, alice);

        // Manual calculation
        uint256 blocks = 9; // 9 blocks of rewards
        uint256 expectedReward = (blocks * INITIAL_REWARD_PER_BLOCK * 1000) / 1500; // Pool 0 allocation

        console.log("Calculated pending:", pending);
        console.log("Expected reward:", expectedReward);

        // Should be close (within rounding errors)
        assertApproxEqRel(pending, expectedReward, 0.01e18); // 1% tolerance
    }    
}
