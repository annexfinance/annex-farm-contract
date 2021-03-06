// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

// import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.1.0/contracts/token/ERC20/IERC20.sol";
// import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.1.0/contracts/token/ERC20/SafeERC20.sol";
// import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.1.0/contracts/utils/EnumerableSet.sol";
// import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.1.0/contracts/math/SafeMath.sol";
// import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.1.0/contracts/access/Ownable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// AnnexFarm is the master of Farm.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once ANN is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract AnnexFarm is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of ANNs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accAnnexPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accAnnexPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }
    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. ANNs to distribute per block.
        uint256 lastRewardBlock; // Last block number that ANNs distribution occurs.
        uint256 accAnnexPerShare; // Accumulated ANNs per share, times 1e12. See below.
    }
    // The Annex TOKEN!
    address public annex;
    // Dev address.
    address public devaddr;
    // Block number when bonus ANN period ends.
    uint256 public bonusEndBlock;
    // ANN tokens created per block.
    uint256 public annexPerBlock;
    // Bonus muliplier for early annex makers.
    uint256 public constant BONUS_MULTIPLIER = 10;
    // Info of each pool.
    PoolInfo[] private poolInfo;
    // Total ANN amount deposited in ANN single pool. To reduce tx-fee, not included in struct PoolInfo.
    uint256 private lpSupplyOfAnnPool;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when ANN mining starts.
    uint256 public startBlock;
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );

    constructor(
        address _annex,
        address _devaddr,
        uint256 _annexPerBlock,
        uint256 _startBlock,
        uint256 _bonusEndBlock
    ) public {
        annex = _annex;
        devaddr = _devaddr;
        annexPerBlock = _annexPerBlock;
        bonusEndBlock = _bonusEndBlock;
        startBlock = _startBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function getPoolInfo(uint _pid) external view returns (IERC20 lpToken, uint256 lpSupply, uint256 allocPoint, uint256 lastRewardBlock, uint accAnnexperShare) {
        PoolInfo storage pool = poolInfo[_pid];
        uint256 amount;
        if (annex == address(pool.lpToken)) {
            amount = lpSupplyOfAnnPool;
        } else {
            amount = pool.lpToken.balanceOf(address(this));
        }
        return (
            pool.lpToken,
            amount,
            pool.allocPoint,
            pool.lastRewardBlock,
            pool.accAnnexPerShare
        );
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock =
            block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accAnnexPerShare: 0
            })
        );
    }

    // Update the given pool's ANN allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Update the given ANN per block. Can only be called by the owner.
    function setAnnexPerBlock(
        uint256 speed
    ) public onlyOwner {
        annexPerBlock = speed;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {
        if (_to <= bonusEndBlock) {
            return _to.sub(_from).mul(BONUS_MULTIPLIER);
        } else if (_from >= bonusEndBlock) {
            return _to.sub(_from);
        } else {
            return
                bonusEndBlock.sub(_from).mul(BONUS_MULTIPLIER).add(
                    _to.sub(bonusEndBlock)
                );
        }
    }

    // View function to see pending ANNs on frontend.
    function pendingAnnex(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accAnnexPerShare = pool.accAnnexPerShare;
        uint256 lpSupply;
        if (annex == address(pool.lpToken)) {
            lpSupply = lpSupplyOfAnnPool;
        } else {
            lpSupply = pool.lpToken.balanceOf(address(this));
        }
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier =
                getMultiplier(pool.lastRewardBlock, block.number);
            uint256 annexReward =
                multiplier.mul(annexPerBlock).mul(pool.allocPoint).div(
                    totalAllocPoint
                );
            accAnnexPerShare = accAnnexPerShare.add(
                annexReward.mul(1e12).div(lpSupply)
            );
        }
        return user.amount.mul(accAnnexPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply;
        if (annex == address(pool.lpToken)) {
            lpSupply = lpSupplyOfAnnPool;
        } else {
            lpSupply = pool.lpToken.balanceOf(address(this));
        }
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 annexReward =
            multiplier.mul(annexPerBlock).mul(pool.allocPoint).div(
                totalAllocPoint
            );
        safeAnnexTransfer(devaddr, annexReward.div(10));
        pool.accAnnexPerShare = pool.accAnnexPerShare.add(
            annexReward.mul(1e12).div(lpSupply)
        );
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to Annexswap for ANN allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending =
                user.amount.mul(pool.accAnnexPerShare).div(1e12).sub(
                    user.rewardDebt
                );
            safeAnnexTransfer(msg.sender, pending);
        }
        pool.lpToken.safeTransferFrom(
            address(msg.sender),
            address(this),
            _amount
        );
        if (annex == address(pool.lpToken)) {
            lpSupplyOfAnnPool = lpSupplyOfAnnPool.add(_amount);
        }
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accAnnexPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from AnnexFarm.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending =
            user.amount.mul(pool.accAnnexPerShare).div(1e12).sub(
                user.rewardDebt
            );
        safeAnnexTransfer(msg.sender, pending);
        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accAnnexPerShare).div(1e12);
        if (annex == address(pool.lpToken)) {
            lpSupplyOfAnnPool = lpSupplyOfAnnPool.sub(_amount);
        }
        pool.lpToken.safeTransfer(address(msg.sender), _amount);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe annex transfer function, just in case if rounding error causes pool to not have enough ANNs.
    function safeAnnexTransfer(address _to, uint256 _amount) internal {
        uint256 annexAvailableBal = IERC20(annex).balanceOf(address(this));
        
        // Protect users liquidity
        if (annexAvailableBal > lpSupplyOfAnnPool) {
            annexAvailableBal = annexAvailableBal - lpSupplyOfAnnPool;
        } else {
            annexAvailableBal = 0;
        }

        if (_amount > annexAvailableBal) {
            IERC20(annex).transfer(_to, annexAvailableBal);
        } else {
            IERC20(annex).transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }
}
