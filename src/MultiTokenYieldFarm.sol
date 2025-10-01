// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./YieldFarmToken.sol";


/**
 * @title MultiTokenYieldFarm
 * @dev Yield farming contract with bonus mechanics and multiple reward tokens
 */
contract MultiTokenYieldFarm is Ownable(msg.sender), ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    struct PoolInfo {
        IERC20 stakingToken;           // LP token to stake
        uint256 allocPoint;            // Allocation points for this pool
        uint256 lastRewardBlock;       // Last block number where rewards were distributed
        uint256 accRewardPerShare;     // Accumulated reward per share
        uint256 depositFee;            // Deposit fee in basis points (100 = 1%)
        uint256 withdrawFee;           // Withdrawal fee in basis points
        uint256 minStakeTime;          // Minimum staking time to avoid early withdrawal penalty
        bool emergencyWithdrawEnabled; // Emergency withdrawal flag
    }
    
    struct UserInfo {
        uint256 amount;                // Amount of tokens staked
        uint256 rewardDebt;            // Reward debt for primary token
        uint256 bonusRewardDebt;       // Reward debt for bonus token
        uint256 lastDepositTime;       // Last deposit timestamp
        address referrer;              // Referrer address
        uint256 referralRewards;       // Accumulated referral rewards
    }
    
    struct BonusInfo {
        IERC20 bonusToken;            // Bonus reward token
        uint256 bonusPerBlock;         // Bonus tokens per block
        uint256 bonusEndBlock;         // Block when bonus period ends
        uint256 accBonusPerShare;      // Accumulated bonus per share
    }
    
    YieldFarmToken public rewardToken;
    uint256 public rewardPerBlock;
    uint256 public startBlock;
    uint256 public totalAllocPoint;
    
    // Referral system
    uint256 public referralCommission = 500; // 5% in basis points
    uint256 public constant MAX_REFERRAL_COMMISSION = 1000; // 10%
    
    // Time-based multipliers
    uint256 public constant WEEK = 7 days;
    uint256 public constant MONTH = 30 days;
    uint256 public constant QUARTER = 90 days;
    
    mapping(uint256 => PoolInfo) public poolInfo;
    mapping(uint256 => BonusInfo) public bonusInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(address => uint256) public referralCount;
    
    uint256 public poolLength;
    address public feeCollector;
    
    // Events
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 amount);
    event BonusTokenSet(uint256 indexed pid, address bonusToken, uint256 bonusPerBlock, uint256 bonusEndBlock);
    
    constructor(
        YieldFarmToken _rewardToken,
        uint256 _rewardPerBlock,
        uint256 _startBlock
    ) {
        rewardToken = _rewardToken;
        rewardPerBlock = _rewardPerBlock;
        startBlock = _startBlock;
        feeCollector = msg.sender;
    }
    
    
    // Add a new pool
    function add(
        uint256 _allocPoint,
        IERC20 _stakingToken,
        uint256 _depositFee,
        uint256 _withdrawFee,
        uint256 _minStakeTime,
        bool _withUpdate
    ) external onlyOwner {
        require(_depositFee <= 1000, "Deposit fee too high"); // Max 10%
        require(_withdrawFee <= 1000, "Withdraw fee too high"); // Max 10%
        
        if (_withUpdate) { 
            massUpdatePools();
        }
        
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint += _allocPoint;
        
        poolInfo[poolLength] = PoolInfo({
            stakingToken: _stakingToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accRewardPerShare: 0, //@audit-info is this supposed to be hardcoded?
            depositFee: _depositFee,
            withdrawFee: _withdrawFee,
            minStakeTime: _minStakeTime,
            emergencyWithdrawEnabled: true
        });
        
        poolLength++;
    }
    
    // Set bonus token for a pool
    function setBonusToken(
        uint256 _pid,
        IERC20 _bonusToken,
        uint256 _bonusPerBlock,
        uint256 _bonusEndBlock
    ) external onlyOwner {
        require(_pid < poolLength, "Invalid pool ID");
        require(_bonusEndBlock > block.number, "Bonus end block must be in future");
        
        updatePool(_pid);
        
        bonusInfo[_pid] = BonusInfo({
            bonusToken: _bonusToken,
            bonusPerBlock: _bonusPerBlock,
            bonusEndBlock: _bonusEndBlock,
            accBonusPerShare: 0 //@audit-info is this supposed to be hardcoded?
        });
        
        emit BonusTokenSet(_pid, address(_bonusToken), _bonusPerBlock, _bonusEndBlock);
    }
    
    // Update pool rewards
    function updatePool(uint256 _pid) public {
        require(_pid < poolLength, "Invalid pool ID");
        
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        } // 
        
        uint256 stakingSupply = pool.stakingToken.balanceOf(address(this));
        if (stakingSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        } //
        
        uint256 multiplier = block.number - pool.lastRewardBlock;
        uint256 reward = (multiplier * rewardPerBlock * pool.allocPoint) / totalAllocPoint;
        // @audit-info 
        // Mint rewards
        rewardToken.mint(address(this), reward);
        rewardToken.mint(feeCollector, reward / 10); // 10% dev fee
        
        pool.accRewardPerShare += (reward * 1e12) / stakingSupply;
        pool.lastRewardBlock = block.number;
        
        // Update bonus rewards if applicable
        BonusInfo storage bonus = bonusInfo[_pid];
        if (address(bonus.bonusToken) != address(0) && block.number < bonus.bonusEndBlock) {
            uint256 bonusReward = multiplier * bonus.bonusPerBlock;
            bonus.accBonusPerShare += (bonusReward * 1e12) / stakingSupply;
        }
    }
    
    // Update all pools
    function massUpdatePools() public {
        for (uint256 pid = 0; pid < poolLength; ++pid) {
            updatePool(pid);
        }
    }
    
    // Deposit tokens to farm
    function deposit(uint256 _pid, uint256 _amount, address _referrer) external nonReentrant whenNotPaused {
        require(_pid < poolLength, "Invalid pool ID");
        require(_amount > 0, "Amount must be greater than 0");
        // 
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        
        updatePool(_pid);
        
        // Set referrer if not set and valid
        if (user.referrer == address(0) && _referrer != address(0) && _referrer != msg.sender) {
            user.referrer = _referrer;
            referralCount[_referrer]++;
        }
        
        // Calculate and send pending rewards
        if (user.amount > 0) {
            uint256 pending = ((user.amount * pool.accRewardPerShare) / 1e12) - user.rewardDebt;
            uint256 timeMultiplier = getTimeMultiplier(user.lastDepositTime);
            pending = (pending * timeMultiplier) / 100;
            
            if (pending > 0) {
                safeRewardTransfer(msg.sender, pending);
                
                // Pay referral commission
                if (user.referrer != address(0)) {
                    uint256 commission = (pending * referralCommission) / 10000;
                    safeRewardTransfer(user.referrer, commission);
                    userInfo[_pid][user.referrer].referralRewards += commission;
                    emit ReferralCommissionPaid(msg.sender, user.referrer, commission);
                }
            }
            
            // Handle bonus rewards
            BonusInfo storage bonus = bonusInfo[_pid];
            if (address(bonus.bonusToken) != address(0)) {
                uint256 bonusPending = ((user.amount * bonus.accBonusPerShare) / 1e12) - user.bonusRewardDebt;
                if (bonusPending > 0) {
                    bonus.bonusToken.safeTransfer(msg.sender, bonusPending);
                }
            }
        }
        
        // Transfer tokens from user
        uint256 balanceBefore = pool.stakingToken.balanceOf(address(this));
        pool.stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 actualAmount = pool.stakingToken.balanceOf(address(this)) - balanceBefore;
        
        // Apply deposit fee
        uint256 depositFeeAmount = (actualAmount * pool.depositFee) / 10000;
        if (depositFeeAmount > 0) {
            pool.stakingToken.safeTransfer(feeCollector, depositFeeAmount);
            actualAmount -= depositFeeAmount;
        }
        
        user.amount += actualAmount;
        user.lastDepositTime = block.timestamp;
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;
        
        // Update bonus reward debt
        BonusInfo storage bonus = bonusInfo[_pid];
        if (address(bonus.bonusToken) != address(0)) {
            user.bonusRewardDebt = (user.amount * bonus.accBonusPerShare) / 1e12;
        }
        
        emit Deposit(msg.sender, _pid, actualAmount);
    }
    
    // Withdraw tokens from farm
    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
        require(_pid < poolLength, "Invalid pool ID");
        
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        
        require(user.amount >= _amount, "Insufficient balance");
        
        updatePool(_pid);
        
        // Calculate pending rewards with time multiplier
        uint256 pending = ((user.amount * pool.accRewardPerShare) / 1e12) - user.rewardDebt;
        uint256 timeMultiplier = getTimeMultiplier(user.lastDepositTime);
        pending = (pending * timeMultiplier) / 100;
        
        if (pending > 0) {
            safeRewardTransfer(msg.sender, pending);
            
            // Pay referral commission
            if (user.referrer != address(0)) {
                uint256 commission = (pending * referralCommission) / 10000;
                safeRewardTransfer(user.referrer, commission);
                userInfo[_pid][user.referrer].referralRewards += commission;
                emit ReferralCommissionPaid(msg.sender, user.referrer, commission);
            }
        }
        
        // Handle bonus rewards
        BonusInfo storage bonus = bonusInfo[_pid];
        if (address(bonus.bonusToken) != address(0)) {
            uint256 bonusPending = ((user.amount * bonus.accBonusPerShare) / 1e12) - user.bonusRewardDebt;
            if (bonusPending > 0) {
                bonus.bonusToken.safeTransfer(msg.sender, bonusPending);
            }
        }
        
        user.amount -= _amount;
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;
        
        // Update bonus reward debt
        if (address(bonus.bonusToken) != address(0)) {
            user.bonusRewardDebt = (user.amount * bonus.accBonusPerShare) / 1e12;
        }
        
        // Calculate withdrawal fee and early withdrawal penalty
        uint256 withdrawAmount = _amount;
        uint256 totalFee = pool.withdrawFee;
        
        // Add early withdrawal penalty if applicable
        if (block.timestamp < user.lastDepositTime + pool.minStakeTime) {
            totalFee += 500; // Additional 5% early withdrawal penalty
        }
        
        uint256 feeAmount = (withdrawAmount * totalFee) / 10000;
        if (feeAmount > 0) {
            pool.stakingToken.safeTransfer(feeCollector, feeAmount);
            withdrawAmount -= feeAmount;
        }
        
        pool.stakingToken.safeTransfer(msg.sender, withdrawAmount);
        
        emit Withdraw(msg.sender, _pid, withdrawAmount);
    }
    
    // Emergency withdraw without caring about rewards
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        require(_pid < poolLength, "Invalid pool ID");
        
        PoolInfo storage pool = poolInfo[_pid];
        require(pool.emergencyWithdrawEnabled, "Emergency withdraw disabled");
        
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        
        user.amount = 0;
        user.rewardDebt = 0;
        user.bonusRewardDebt = 0;
        
        // Emergency withdrawal has higher fee
        uint256 emergencyFee = (amount * 1500) / 10000; // 15% emergency fee
        uint256 withdrawAmount = amount - emergencyFee;
        
        if (emergencyFee > 0) {
            pool.stakingToken.safeTransfer(feeCollector, emergencyFee);
        }
        
        pool.stakingToken.safeTransfer(msg.sender, withdrawAmount);
        
        emit EmergencyWithdraw(msg.sender, _pid, withdrawAmount);
    }
    
    // Get time-based multiplier
    function getTimeMultiplier(uint256 _lastDepositTime) public view returns (uint256) {
        uint256 stakingDuration = block.timestamp - _lastDepositTime;
        
        if (stakingDuration >= QUARTER) {
            return 200; // 2x multiplier for 3+ months
        } else if (stakingDuration >= MONTH) {
            return 150; // 1.5x multiplier for 1+ month
        } else if (stakingDuration >= WEEK) {
            return 125; // 1.25x multiplier for 1+ week
        }
        
        return 100; // 1x multiplier (base)
    }
    
    // View function to see pending rewards
    function pendingRewards(uint256 _pid, address _user) external view returns (uint256, uint256) {
        require(_pid < poolLength, "Invalid pool ID");
        
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accRewardPerShare = pool.accRewardPerShare;
        
        uint256 stakingSupply = pool.stakingToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && stakingSupply != 0) {
            uint256 multiplier = block.number - pool.lastRewardBlock;
            uint256 reward = (multiplier * rewardPerBlock * pool.allocPoint) / totalAllocPoint;
            accRewardPerShare += (reward * 1e12) / stakingSupply;
        }
        
        uint256 pending = ((user.amount * accRewardPerShare) / 1e12) - user.rewardDebt;
        uint256 timeMultiplier = getTimeMultiplier(user.lastDepositTime);
        pending = (pending * timeMultiplier) / 100;
        
        // Calculate bonus pending
        uint256 bonusPending = 0;
        BonusInfo storage bonus = bonusInfo[_pid];
        if (address(bonus.bonusToken) != address(0)) {
            uint256 accBonusPerShare = bonus.accBonusPerShare;
            if (block.number > pool.lastRewardBlock && block.number < bonus.bonusEndBlock && stakingSupply != 0) {
                uint256 bonusMultiplier = block.number - pool.lastRewardBlock;
                uint256 bonusReward = bonusMultiplier * bonus.bonusPerBlock;
                accBonusPerShare += (bonusReward * 1e12) / stakingSupply;
            }
            bonusPending = ((user.amount * accBonusPerShare) / 1e12) - user.bonusRewardDebt;
        }
        
        return (pending, bonusPending);
    }
    
    // Safe reward transfer function
    function safeRewardTransfer(address _to, uint256 _amount) internal {
        uint256 rewardBalance = rewardToken.balanceOf(address(this));
        if (_amount > rewardBalance) {
            rewardToken.transfer(_to, rewardBalance);
        } else {
            rewardToken.transfer(_to, _amount);
        }
    }
    
    // Admin functions
    function setRewardPerBlock(uint256 _rewardPerBlock) external onlyOwner {
        massUpdatePools();
        rewardPerBlock = _rewardPerBlock;
    }
    
    function setReferralCommission(uint256 _referralCommission) external onlyOwner {
        require(_referralCommission <= MAX_REFERRAL_COMMISSION, "Commission too high");
        referralCommission = _referralCommission;
    }
    
    function setFeeCollector(address _feeCollector) external onlyOwner {
        require(_feeCollector != address(0), "Invalid address");
        feeCollector = _feeCollector;
    }
    
    function updatePoolFees(uint256 _pid, uint256 _depositFee, uint256 _withdrawFee) external onlyOwner {
        require(_pid < poolLength, "Invalid pool ID");
        require(_depositFee <= 1000, "Deposit fee too high");
        require(_withdrawFee <= 1000, "Withdraw fee too high");
        
        poolInfo[_pid].depositFee = _depositFee;
        poolInfo[_pid].withdrawFee = _withdrawFee;
    }
    
    function setEmergencyWithdrawEnabled(uint256 _pid, bool _enabled) external onlyOwner {
        require(_pid < poolLength, "Invalid pool ID");
        poolInfo[_pid].emergencyWithdrawEnabled = _enabled;
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // Emergency function to recover tokens
    function emergencyRewardWithdraw(uint256 _amount) external onlyOwner {
        safeRewardTransfer(msg.sender, _amount);
    }
}