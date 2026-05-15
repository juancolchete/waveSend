// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut);
}

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract WaveSendFund is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant PERIOD_30_DAYS   = 2_592_000;
    uint256 public constant YIELD_RATE_NUM   = 100;
    uint256 public constant YIELD_RATE_DEN   = 10_000;
    uint256 public constant MAX_WITHDRAW_BPS = 1_000;
    uint256 public constant BPS_DENOM        = 10_000;
    uint256 public constant WBTC_UNIT        = 1e8;
    uint256 public constant WSND_UNIT        = 1e18;

    IERC20      public usdt;
    IERC20      public wbtc;
    IERC20      public wsnd;
    ISwapRouter public swapRouter;

    uint256 public wsndPerWbtc;
    uint256 public totalPoolHashrate;
    uint24  public poolFee;
    uint24  public nativeFee;

    struct WithdrawWindow {
        uint256 windowStart;
        uint256 withdrawnInWindow;
        uint256 snapshotBalance;
    }
    mapping(address => WithdrawWindow) public withdrawWindows;

    struct UserInfo {
        uint256 activeHashrate;
        uint256 totalDeposited;
        uint256 totalWbtcClaimed;
        uint256 totalWsndClaimed;
        uint256 pendingRewards;
        uint256 lastUpdateTimestamp;
        bool    prefersWSND;
    }
    mapping(address => UserInfo) public userInfo;

    event UserDeposited(address indexed user, uint256 usdtIn, uint256 wbtcReceived);
    event NativeDeposited(address indexed user, uint256 nativeIn, uint256 wbtcReceived);
    event UserWithdrawn(address indexed user, uint256 wbtcAmount);
    event RewardClaimed(address indexed user, uint256 wbtcReward, uint256 wsndPaid, bool usedFallback);
    event RewardPreferenceSet(address indexed user, bool prefersWSND);
    event FundDeposited(address indexed token, uint256 amount, address indexed depositor);
    event OperationalWithdrawn(address indexed token, uint256 amount, uint256 windowStart, uint256 totalWithdrawnInWindow, uint256 allowance);
    event WsndRatioUpdated(uint256 newWsndPerWbtc);
    event PoolFeeUpdated(uint24 newFee);
    event NativeFeeUpdated(uint24 newFee);
    event RouterUpdated(address newRouter);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        address _admin,
        address _usdt,
        address _wbtc,
        address _wsnd,
        address _router,
        uint24  _poolFee,
        uint24  _nativeFee
    ) external initializer {
        require(_admin  != address(0), "WF: zero admin");
        require(_usdt   != address(0), "WF: zero USDT");
        require(_wbtc   != address(0), "WF: zero WBTC");
        require(_wsnd   != address(0), "WF: zero WSND");
        require(_router != address(0), "WF: zero router");

        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE,      _admin);
        _grantRole(UPGRADER_ROLE,      _admin);

        usdt        = IERC20(_usdt);
        wbtc        = IERC20(_wbtc);
        wsnd        = IERC20(_wsnd);
        swapRouter  = ISwapRouter(_router);
        poolFee     = _poolFee;
        nativeFee   = _nativeFee;
        wsndPerWbtc = WSND_UNIT;
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    function setWsndPerWbtc(uint256 _wsndPerWbtc) external onlyRole(OPERATOR_ROLE) {
        require(_wsndPerWbtc > 0, "WF: ratio zero");
        wsndPerWbtc = _wsndPerWbtc;
        emit WsndRatioUpdated(_wsndPerWbtc);
    }

    function setPoolFee(uint24 _poolFee) external onlyRole(OPERATOR_ROLE) {
        poolFee = _poolFee;
        emit PoolFeeUpdated(_poolFee);
    }

    function setNativeFee(uint24 _nativeFee) external onlyRole(OPERATOR_ROLE) {
        nativeFee = _nativeFee;
        emit NativeFeeUpdated(_nativeFee);
    }

    function setSwapRouter(address _router) external onlyRole(OPERATOR_ROLE) {
        require(_router != address(0), "WF: zero router");
        swapRouter = ISwapRouter(_router);
        emit RouterUpdated(_router);
    }

    function fundDeposit(address token, uint256 amount) external nonReentrant {
        require(token  != address(0), "WF: zero token");
        require(amount >  0,          "WF: zero amount");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit FundDeposited(token, amount, msg.sender);
    }

    function operationalWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) external nonReentrant onlyRole(OPERATOR_ROLE) {
        require(token     != address(0), "WF: zero token");
        require(amount    >  0,          "WF: zero amount");
        require(recipient != address(0), "WF: zero recipient");

        WithdrawWindow storage window = withdrawWindows[token];

        if (window.windowStart == 0 || block.timestamp >= window.windowStart + PERIOD_30_DAYS) {
            window.windowStart       = block.timestamp;
            window.withdrawnInWindow = 0;
            window.snapshotBalance   = IERC20(token).balanceOf(address(this));
        }

        uint256 windowAllowance  = (window.snapshotBalance * MAX_WITHDRAW_BPS) / BPS_DENOM;
        uint256 alreadyWithdrawn = window.withdrawnInWindow;
        require(alreadyWithdrawn < windowAllowance,               "WF: monthly allowance exhausted");
        require(amount <= windowAllowance - alreadyWithdrawn,     "WF: exceeds monthly 10% cap");
        require(IERC20(token).balanceOf(address(this)) >= amount, "WF: insufficient contract balance");

        window.withdrawnInWindow += amount;
        IERC20(token).safeTransfer(recipient, amount);

        emit OperationalWithdrawn(token, amount, window.windowStart, window.withdrawnInWindow, windowAllowance);
    }

    function getWithdrawStatus(address token)
        external view
        returns (uint256 windowStart, uint256 withdrawnSoFar, uint256 windowAllowance, uint256 remainingAllowance, uint256 windowEndsAt)
    {
        WithdrawWindow storage window = withdrawWindows[token];

        if (window.windowStart == 0) {
            uint256 bal = IERC20(token).balanceOf(address(this));
            uint256 al  = (bal * MAX_WITHDRAW_BPS) / BPS_DENOM;
            return (0, 0, al, al, 0);
        }

        if (block.timestamp >= window.windowStart + PERIOD_30_DAYS) {
            uint256 bal = IERC20(token).balanceOf(address(this));
            uint256 al  = (bal * MAX_WITHDRAW_BPS) / BPS_DENOM;
            return (block.timestamp, 0, al, al, block.timestamp + PERIOD_30_DAYS);
        }

        windowAllowance    = (window.snapshotBalance * MAX_WITHDRAW_BPS) / BPS_DENOM;
        withdrawnSoFar     = window.withdrawnInWindow;
        remainingAllowance = windowAllowance > withdrawnSoFar ? windowAllowance - withdrawnSoFar : 0;
        return (window.windowStart, withdrawnSoFar, windowAllowance, remainingAllowance, window.windowStart + PERIOD_30_DAYS);
    }

    function setRewardPreference(bool _prefersWSND) external {
        _updateYield(msg.sender);
        userInfo[msg.sender].prefersWSND = _prefersWSND;
        emit RewardPreferenceSet(msg.sender, _prefersWSND);
    }

    function deposit(uint256 usdtAmount, uint256 minWbtcOut) external nonReentrant {
        require(usdtAmount > 0, "WF: zero USDT");
        require(minWbtcOut > 0, "WF: zero min out");

        _updateYield(msg.sender);

        usdt.safeTransferFrom(msg.sender, address(this), usdtAmount);
        usdt.forceApprove(address(swapRouter), usdtAmount);

        uint256 wbtcReceived = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           address(usdt),
                tokenOut:          address(wbtc),
                fee:               poolFee,
                recipient:         address(this),
                deadline:          block.timestamp,
                amountIn:          usdtAmount,
                amountOutMinimum:  minWbtcOut,
                sqrtPriceLimitX96: 0
            })
        );

        UserInfo storage user    = userInfo[msg.sender];
        user.activeHashrate      += wbtcReceived;
        user.totalDeposited      += wbtcReceived;
        totalPoolHashrate        += wbtcReceived;
        user.lastUpdateTimestamp  = block.timestamp;

        emit UserDeposited(msg.sender, usdtAmount, wbtcReceived);
    }

    function depositNative(uint256 minWbtcOut) public payable nonReentrant {
        require(msg.value  > 0, "WF: zero native");
        require(minWbtcOut > 0, "WF: zero min out");
        require(nativeFee  > 0, "WF: native fee not set");

        _updateYield(msg.sender);

        uint256 wbtcReceived = swapRouter.exactInputSingle{value: msg.value}(
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           address(0),
                tokenOut:          address(wbtc),
                fee:               nativeFee,
                recipient:         address(this),
                deadline:          block.timestamp,
                amountIn:          msg.value,
                amountOutMinimum:  minWbtcOut,
                sqrtPriceLimitX96: 0
            })
        );

        UserInfo storage user    = userInfo[msg.sender];
        user.activeHashrate      += wbtcReceived;
        user.totalDeposited      += wbtcReceived;
        totalPoolHashrate        += wbtcReceived;
        user.lastUpdateTimestamp  = block.timestamp;

        emit NativeDeposited(msg.sender, msg.value, wbtcReceived);
    }

    receive() external payable {
        depositNative(1);
    }

    function withdraw(uint256 wbtcAmount) external nonReentrant {
        require(wbtcAmount > 0, "WF: zero amount");

        _updateYield(msg.sender);

        UserInfo storage user = userInfo[msg.sender];
        require(user.activeHashrate >= wbtcAmount,            "WF: insufficient hashrate");
        require(wbtc.balanceOf(address(this)) >= wbtcAmount, "WF: pool low WBTC");

        user.activeHashrate -= wbtcAmount;
        totalPoolHashrate   -= wbtcAmount;

        wbtc.safeTransfer(msg.sender, wbtcAmount);
        emit UserWithdrawn(msg.sender, wbtcAmount);
    }

    function claim() external nonReentrant {
        _updateYield(msg.sender);

        UserInfo storage user = userInfo[msg.sender];
        uint256 rewards = user.pendingRewards;
        require(rewards > 0, "WF: nothing to claim");

        user.pendingRewards = 0;

        bool    usedFallback;
        uint256 wsndPaid;

        if (user.prefersWSND) {
            wsndPaid = _wbtcToWsnd(rewards);
            require(wsnd.balanceOf(address(this)) >= wsndPaid, "WF: insufficient WSND");
            user.totalWsndClaimed += wsndPaid;
            wsnd.safeTransfer(msg.sender, wsndPaid);

        } else if (wbtc.balanceOf(address(this)) < rewards) {
            wsndPaid = _wbtcToWsnd(rewards);
            require(wsnd.balanceOf(address(this)) >= wsndPaid, "WF: insufficient WSND fallback");
            user.totalWsndClaimed += wsndPaid;
            wsnd.safeTransfer(msg.sender, wsndPaid);
            usedFallback = true;

        } else {
            user.totalWbtcClaimed += rewards;
            wbtc.safeTransfer(msg.sender, rewards);
        }

        emit RewardClaimed(msg.sender, rewards, wsndPaid, usedFallback);
    }

    function getPendingYield(address account) external view returns (uint256) {
        UserInfo storage user = userInfo[account];
        return user.pendingRewards + _calculateYield(user.activeHashrate, user.lastUpdateTimestamp);
    }

    function getUserInfo(address account) external view returns (UserInfo memory) {
        return userInfo[account];
    }

    function _calculateYield(uint256 activeHashrate, uint256 lastUpdateTimestamp)
        internal view returns (uint256 accrued)
    {
        if (activeHashrate == 0 || lastUpdateTimestamp == 0) return 0;
        if (block.timestamp <= lastUpdateTimestamp)           return 0;
        uint256 timeElapsed = block.timestamp - lastUpdateTimestamp;
        accrued = (activeHashrate * YIELD_RATE_NUM * timeElapsed) / (YIELD_RATE_DEN * PERIOD_30_DAYS);
    }

    function _updateYield(address account) internal {
        UserInfo storage user = userInfo[account];
        if (user.activeHashrate > 0 && user.lastUpdateTimestamp > 0) {
            uint256 accrued = _calculateYield(user.activeHashrate, user.lastUpdateTimestamp);
            if (accrued > 0) user.pendingRewards += accrued;
        }
        user.lastUpdateTimestamp = block.timestamp;
    }

    function _wbtcToWsnd(uint256 wbtcAmount) internal view returns (uint256) {
        return (wbtcAmount * wsndPerWbtc) / WBTC_UNIT;
    }
}
