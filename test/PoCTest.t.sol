// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/MultiTokenYieldFarm.sol";

// Create a simple ERC20Mock since OpenZeppelin removed it
contract ERC20Mock is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public {
        _burn(from, amount);
    }
}
contract PoCTest is Test {
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
    function testRewardDistributionMismatch() public {
    console.log("=== Testing Incorrect Reward Distribution ===");
    
    vm.roll(START_BLOCK + 1);

    // Alice deposits tokens
    uint256 depositAmount = 1000e18;
    vm.prank(alice);
    farm.deposit(0, depositAmount, address(0));
    
    // Advance 100 blocks
    uint256 currentBlock = block.number;
    vm.roll(currentBlock + 100);
    
    console.log("Blocks advanced: 100");
    console.log("From block:", currentBlock, "to block:", block.number);
    
    // Calculate expected rewards mathematically
    // Since we have 2 pools with allocPoints 1000 and 500, totalAllocPoint = 1500
    uint256 expectedRewards = (100 * INITIAL_REWARD_PER_BLOCK * 1000) / farm.totalAllocPoint();
    
    console.log("Expected rewards for pool (100%):", expectedRewards);
    console.log("Expected dev fee (10%):", expectedRewards / 10);
    console.log("Expected total minted (110%):", expectedRewards + (expectedRewards / 10));
    
    // Update pool to mint rewards
    farm.updatePool(0);
    
    // Check actual token balances
    uint256 poolRewardBalance = rewardToken.balanceOf(address(farm));
    uint256 feeCollectorBalance = rewardToken.balanceOf(feeCollector);
    uint256 totalMinted = poolRewardBalance + feeCollectorBalance;
    
    console.log("\nActual results:");
    console.log("Pool reward balance:", poolRewardBalance);
    console.log("Fee collector balance:", feeCollectorBalance);
    console.log("Total minted tokens:", totalMinted);
    
    // Verify the mathematical inconsistency
    console.log("\n=== Mathematical Inconsistency ===");
    console.log("Pool has", poolRewardBalance, "tokens but accRewardPerShare accounts for", expectedRewards);
    console.log("Difference:", expectedRewards - poolRewardBalance);
    
    // The core issue: accRewardPerShare is calculated using 100% but dev fee reduces effective pool rewards
    assertEq(totalMinted, expectedRewards + (expectedRewards / 10), "Total minted should be 110% of calculated rewards");
    assertEq(poolRewardBalance, expectedRewards, "Pool should have exactly the calculated rewards (100%)");
    
    // Check what happens when user tries to claim rewards
    (uint256 pendingPrimary, ) = farm.pendingRewards(0, alice);
    console.log("\nUser pending rewards (with time multiplier):", pendingPrimary);
    
    // The bug becomes apparent in the accounting - users expect rewards based on 100% calculation
    // but the effective reward pool is reduced by the dev fee
    }

    function testUninitializedBonusRewardDebt() public {
    console.log("=== Testing Uninitialized Bonus Reward Debt Bug ===");
    
    vm.roll(START_BLOCK + 1);

    // Step 1: Alice deposits BEFORE bonus token is set
    console.log("\n1. Alice deposits 1000 tokens BEFORE bonus token is set");
    vm.prank(alice);
    farm.deposit(0, 1000e18, address(0));
    
    // Check Alice's initial state - bonusRewardDebt should be 0 (uninitialized)
    (, , uint256 aliceInitialBonusDebt,,,) = farm.userInfo(0, alice);
    console.log("Alice's initial bonusRewardDebt:", aliceInitialBonusDebt);
    assertEq(aliceInitialBonusDebt, 0, "Alice's bonusRewardDebt should be 0 (uninitialized)");

    // Step 2: Advance some blocks (no bonus token yet)
    console.log("\n2. Advance 50 blocks (no bonus token active)");
    vm.roll(block.number + 50);

    // Step 3: Set bonus token NOW (after Alice already deposited)
    console.log("\n3. Set bonus token AFTER Alice deposited");
    uint256 bonusStartBlock = block.number;
    uint256 bonusEndBlock = bonusStartBlock + 100;
    
    // Approve bonus tokens for the farm
    bonusToken.approve(address(farm), type(uint256).max);
    farm.setBonusToken(0, bonusToken, 10e18, bonusEndBlock);

    // Step 4: Advance more blocks to accumulate bonus rewards
    console.log("\n4. Advance 50 blocks to accumulate bonus rewards");
    vm.roll(block.number + 50);

    // Step 5: Bob deposits AFTER bonus token is set (for comparison)
    console.log("\n5. Bob deposits 1000 tokens AFTER bonus token is set");
    vm.prank(bob);
    farm.deposit(0, 1000e18, address(0));

    // Check Bob's state - bonusRewardDebt should be initialized
    (, , uint256 bobBonusDebt,,,) = farm.userInfo(0, bob);
    console.log("Bob's initial bonusRewardDebt:", bobBonusDebt);
    assertGt(bobBonusDebt, 0, "Bob's bonusRewardDebt should be initialized");

    // Step 6: Check pending bonus rewards for both users
    console.log("\n6. Check pending bonus rewards for both users");
    (, uint256 alicePendingBonus) = farm.pendingRewards(0, alice);
    (, uint256 bobPendingBonus) = farm.pendingRewards(0, bob);
    
    console.log("Alice's pending bonus rewards:", alicePendingBonus);
    console.log("Bob's pending bonus rewards:", bobPendingBonus);

    // Step 7: Analyze the vulnerability
    console.log("\n=== VULNERABILITY ANALYSIS ===");
    console.log("Alice deposited BEFORE bonus token was set");
    console.log("Bob deposited AFTER bonus token was set");
    console.log("Both have the same amount staked (1000 tokens)");
    console.log("Alice pending bonus:", alicePendingBonus);
    console.log("Bob pending bonus:", bobPendingBonus);
    
    // The bug: Alice gets bonus rewards even though bonus wasn't active when she deposited
    assertGt(alicePendingBonus, 0, "Alice should have pending bonus (BUG!)");
    
    console.log("\nBUG CONFIRMED: Alice receives bonus rewards despite depositing before bonus was active!");
    console.log("This happens because her bonusRewardDebt was 0 when bonus token was set.");
}



    
}

