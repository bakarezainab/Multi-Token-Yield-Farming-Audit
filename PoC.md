# MULTI-TOKEN YIELD FARMING AUDIT
## Executive Summary
A comprehensive security audit of the `MultiTokenYieldFarm` and `YieldFarmToken` contracts revealed multiple critical vulnerabilities that could lead to fund loss, incorrect reward distribution, and potential contract exploitation.

## Contracts Audited
- MultiTokenYieldFarm.sol - Main yield farming contract

- YieldFarmToken.sol - Reward token contract

## 1. Incorrect Reward Distribution Mathematics
Severity: CRITICAL

### Description:
The `updatePool` function mints 110% of calculated rewards (100% to pool + 10% dev fee) but only accounts for 100% in `accRewardPerShare`. This creates a fundamental mathematical inconsistency where the contract mints more tokens than it accounts for in reward distribution.

## Vulnerable Code:

```solidity
function updatePool(uint256 _pid) public {
    // ...
    uint256 reward = (multiplier * rewardPerBlock * pool.allocPoint) / totalAllocPoint;
    rewardToken.mint(address(this), reward);          // Mint 100% to pool
    rewardToken.mint(feeCollector, reward / 10);      // Mint 10% to dev
    pool.accRewardPerShare += (reward * 1e12) / stakingSupply; // Only account for 100%
}
```
### Proof of Concept:

```solidity
// Test demonstrating the mathematical inconsistency
function testRewardDistributionMismatch() public {
    // Setup: User deposits tokens
    user.deposit(1000e18);
    
    // Advance 100 blocks
    vm.roll(block.number + 100);
    
    // Calculate expected rewards
    uint256 expectedRewards = (100 * REWARD_PER_BLOCK * 1000) / 1000; // 100 tokens
    
    // Update pool to mint rewards
    yieldFarm.updatePool(0);
    
    // Check balances
    uint256 poolBalance = rewardToken.balanceOf(address(yieldFarm));     // 100 tokens
    uint256 devBalance = rewardToken.balanceOf(feeCollector);           // 10 tokens
    uint256 totalMinted = poolBalance + devBalance;                     // 110 tokens
    
    // The bug: Contract mints 110 tokens but only accounts for 100 tokens
    assertEq(totalMinted, 110e18); // 110 tokens minted
    assertEq(poolBalance, 100e18); // But pool only has 100 tokens
    
    // Users expect rewards based on 100 tokens calculation
    // but the effective reward pool is diluted by the dev fee
}
```
### Impact:

- Systematic underfunding of user rewards
- Users receive ~9.1% less rewards than expected
- Potential contract insolvency if users try to withdraw all rewards simultaneously

### Mitigation:

```solidity
function updatePool(uint256 _pid) public {
    // ...
    uint256 totalReward = (multiplier * rewardPerBlock * pool.allocPoint) / totalAllocPoint;
    
    // Calculate proper distribution (90.9% to pool, 9.1% to dev)
    uint256 poolReward = (totalReward * 10000) / 11000; // ~90.9%
    uint256 devReward = totalReward - poolReward;       // ~9.1%
    
    rewardToken.mint(address(this), poolReward);
    rewardToken.mint(feeCollector, devReward);
    
    pool.accRewardPerShare += (poolReward * 1e12) / stakingSupply;
    // ...
}
```
## 2. No Event and Emit in the `add` function
### Severity: LOW

Description:
The `add` function performs a critical state-changing operation (creating a new staking pool) but doesn't emit any event. This violates best practices and makes it difficult to track pool creation off-chain.

Vulnerable Code:

```solidity
function add(uint256 _allocPoint,IERC20 _stakingToken,uint256 _depositFee,uint256 _withdrawFee,uint256 _minStakeTime,bool _withUpdate
    ) external onlyOwner {
        ...              
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint += _allocPoint;        
        ...
        poolLength++;
        // no event emitted
    }
```

### Impact:

- Reduces transparency and auditability
- Makes off-chain monitoring impossible
- DApps cannot automatically detect new pools
- No historical record of pool creation
- Violates blockchain best practices

### Mitigation:

In `MultiTokenYieldFarm.sol`, add the event and emit it in the `add` function


## 3. Missing Minting Limits in `YieldFarmToken`
Severity: MEDIUM

Description:
The `YieldFarmToken` has no maximum supply cap or minting limits, allowing unlimited inflation.

Vulnerable Code:

```solidity
function mint(address to, uint256 amount) external onlyMinter {
    _mint(to, amount); // No limits or caps
}
```
Impact:
- Unlimited token inflation
- Complete devaluation of token
- Centralized control over token supply

Mitigation:

```solidity
uint256 public constant MAX_SUPPLY = 100000000 * 10**18;

function mint(address to, uint256 amount) external onlyMinter {
    require(totalSupply() + amount <= MAX_SUPPLY, "Exceeds max supply");
    _mint(to, amount);
}
```
## 4. Fee-on-Transfer Token Vulnerability
### Severity: HIGH

Description:
The `deposit` function uses balance difference to calculate received amount, which is vulnerable to fee-on-transfer and rebasing tokens.

Vulnerable Code:

```solidity
function deposit(uint256 _pid, uint256 _amount, address _referrer) external {
    // ...
    uint256 balanceBefore = pool.stakingToken.balanceOf(address(this));
    pool.stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
    uint256 actualAmount = pool.stakingToken.balanceOf(address(this)) - balanceBefore;
    // ...
}
```
### Proof of Concept:

```solidity
// Fee-on-transfer token implementation
contract FeeOnTransferToken is ERC20 {
    uint256 public constant FEE = 100; // 1% fee
    
    function transferFrom(address sender, address recipient, uint256 amount) 
        public override returns (bool) {
        uint256 fee = amount * FEE / 10000;
        uint256 received = amount - fee;
        
        _transfer(sender, recipient, received);
        _transfer(sender, address(this), fee); // Burn fee
        return true;
    }
}

function testFeeOnTransferExploit() public {
    FeeOnTransferToken fotToken = new FeeOnTransferToken();
    fotToken.mint(user1, 1000e18);
    
    // Add pool with FOT token
    yieldFarm.add(1000, fotToken, 0, 0, 0, false);
    
    vm.prank(user1);
    fotToken.approve(address(yieldFarm), 1000e18);
    
    // User deposits 1000 tokens
    yieldFarm.deposit(1, 1000e18, address(0));
    
    // Due to fee, only 990 tokens received, but contract calculates based on 1000
    // This creates accounting mismatch
}
```
### Impact:

- Accounting inconsistencies
- Potential over-issuance of rewards
- Contract may become unusable with certain tokens

Mitigation:

```solidity
function deposit(uint256 _pid, uint256 _amount, address _referrer) external {
    // ...
    uint256 balanceBefore = pool.stakingToken.balanceOf(address(this));
    pool.stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
    uint256 actualAmount = pool.stakingToken.balanceOf(address(this)) - balanceBefore;
    
    require(actualAmount <= _amount, "Received more than sent"); // Sanity check
    require(actualAmount > 0, "No tokens received");
    // ...
}
```

## 5. Reentrancy Vulnerability in Withdraw Function
### Severity: HIGH

Description:
The `withdraw` function makes external calls to transfer bonus tokens before updating user state, violating the checks-effects-interactions pattern.

Vulnerable Code:

```solidity
function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
    // ...
    // External call before state update - VULNERABLE
    bonus.bonusToken.safeTransfer(msg.sender, bonusPending);
    
    // State update after external call
    user.amount -= _amount;
    user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;
    // ...
}
```
### Proof of Concept:

```solidity
// Malicious bonus token contract
contract MaliciousBonusToken is ERC20 {
    MultiTokenYieldFarm public farm;
    
    function transfer(address to, uint256 amount) public override returns (bool) {
        // Reenter the farm contract
        if (farm.userInfo(0, msg.sender).amount > 0) {
            farm.withdraw(0, 1); // Reentrant call
        }
        return super.transfer(to, amount);
    }
}

function testReentrancyAttack() public {
    // Setup malicious bonus token
    MaliciousBonusToken maliciousToken = new MaliciousBonusToken();
    maliciousToken.setFarm(address(yieldFarm));
    
    // Set as bonus token for pool
    yieldFarm.setBonusToken(0, maliciousToken, 1e18, block.number + 1000);
    
    // Attacker deposits
    attacker.deposit(100e18);
    
    // Withdraw triggers reentrancy
    yieldFarm.withdraw(0, 50e18); // Reenters and can manipulate state
}
```
### Impact:

- Potential double spending of rewards
- State manipulation leading to incorrect reward calculations
- Fund loss through reentrancy attacks

### Mitigation:

```solidity
function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
    // ...
    // Update all state first
    user.amount -= _amount;
    user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;
    
    if (address(bonus.bonusToken) != address(0)) {
        user.bonusRewardDebt = (user.amount * bonus.accBonusPerShare) / 1e12;
    }
    
    // Then make external calls
    if (bonusPending > 0) {
        bonus.bonusToken.safeTransfer(msg.sender, bonusPending);
    }
    // ...
}
```


### 6. Uninitialized Bonus Reward Debt
Severity: HIGH

Description:
When a bonus token is added to a pool, existing users' bonusRewardDebt remains uninitialized (0), allowing them to claim bonus rewards for periods before the bonus was active.

Vulnerable Code:

```solidity
// When bonus token is set, existing users have bonusRewardDebt = 0
function setBonusToken(uint256 _pid, IERC20 _bonusToken, ...) external onlyOwner {
    updatePool(_pid); // Updates accBonusPerShare but not user bonusRewardDebt
    // Existing users still have bonusRewardDebt = 0
}
```
### Impact:

- Users can claim unearned bonus rewards
- Fund loss from incorrect reward distribution
- Fairness violation

Mitigation:

```solidity
function setBonusToken(uint256 _pid, IERC20 _bonusToken, ...) external onlyOwner {
    updatePool(_pid);
    
    // Initialize all existing users' bonusRewardDebt
    // This requires tracking all users or initializing on next interaction
    bonusInfo[_pid] = BonusInfo({...});
    
    // Alternative: Initialize when user next interacts
    // Store a flag and initialize bonusRewardDebt in deposit/withdraw
}
```

### 7. Division Before Multiplication Precision Loss
Severity: MEDIUM

Description:
Reward calculations perform division before multiplication, leading to precision loss and potential zero rewards for small values.

Vulnerable Code:

```solidity
uint256 reward = (multiplier * rewardPerBlock * pool.allocPoint) / totalAllocPoint;
```
###Impact:

- Precision loss in reward calculations
- Small stakers may receive zero rewards
- Inaccurate reward distribution

Mitigation:

```solidity
uint256 reward = (multiplier * rewardPerBlock * pool.allocPoint * 1e18) / totalAllocPoint / 1e18;
```
### 8. Incorrect Time Multiplier Application
Severity: MEDIUM

Description:
Time multiplier is applied to already accumulated rewards rather than during accumulation, allowing users to game the system.

Vulnerable Code:

```solidity
// Applied during distribution, not accumulation
uint256 pending = ((user.amount * pool.accRewardPerShare) / 1e12) - user.rewardDebt;
uint256 timeMultiplier = getTimeMultiplier(user.lastDepositTime);
pending = (pending * timeMultiplier) / 100; // Gaming possible
```
### Impact:

- Users can deposit/withdraw to maximize multiplier
- Unfair reward distribution
- System gaming

Mitigation:

```solidity
// Apply multiplier during reward accumulation in updatePool
// Based on average staking duration
```
### 9. Missing Access Control on Emergency Functions
Severity: MEDIUM

Description:
Owner can withdraw all reward tokens at any time using emergencyRewardWithdraw.

### Impact:

- Potential rug pull vector
- Centralized risk
- Mitigation:

```solidity
// Add timelock or multi-sig requirement
uint256 public constant EMERGENCY_DELAY = 2 days;
mapping(address => uint256) public emergencyWithdrawTimestamps;

function emergencyRewardWithdraw(uint256 _amount) external onlyOwner {
    require(block.timestamp >= emergencyWithdrawTimestamps[msg.sender] + EMERGENCY_DELAY, "Timelock not passed");
    safeRewardTransfer(msg.sender, _amount);
}
```
### Low Severity Issues
### 10. Unbounded Loop in massUpdatePools
Severity: LOW

Description:
massUpdatePools iterates through all pools without gas limits.

Impact:

Potential gas limit exhaustion

Function may become unusable with many pools

Mitigation:

```solidity
function massUpdatePools(uint256 start, uint256 end) public {
    require(end <= poolLength, "End too high");
    for (uint256 pid = start; pid < end; ++pid) {
        updatePool(pid);
    }
}
```
### 11. Missing Events for Critical Operations
Severity: LOW

Description:
YieldFarmToken missing events for minting and minter changes.

### Impact:

- Difficult off-chain tracking
- Reduced transparency

Mitigation:

```solidity
event Mint(address indexed to, uint256 amount);
event MinterAdded(address indexed minter);
event MinterRemoved(address indexed minter);

function mint(address to, uint256 amount) external onlyMinter {
    _mint(to, amount);
    emit Mint(to, amount);
}
```
### 12. Division by Zero Risks
Severity: LOW

Description:
Multiple locations with potential division by zero.

Mitigation:

```solidity
// Add checks before division
require(stakingSupply > 0, "No tokens staked");
require(totalAllocPoint > 0, "No allocation points");
```