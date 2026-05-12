// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// =============================================================
//                        INTERFACES
// =============================================================

/// @notice Uniswap V3 SwapRouter interface – exactInputSingle only.
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

// =============================================================
//               OpenZeppelin imports
// =============================================================

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// =============================================================
//                     WAVESEND FUND CONTRACT
// =============================================================

/**
 * @title  WaveSendFund
 * @author Senior Smart Contract Developer
 * @notice A UUPS-upgradeable DeFi Mining Pool on Celo Mainnet operated by Wavesend.
 *
 *         Yield formula (linear, per second):
 *           pendingRewards = (activeHashrate x 100 x timeElapsed) / (10_000 x 2_592_000)
 *
 *         Decimals:
 *           USDT  -- 6  decimals  (Celo bridged USDT)
 *           WBTC  -- 8  decimals  (Celo bridged WBTC)
 *           WSND  -- 18 decimals  (Wave Send Token)
 *
 *         OZ v5 notes:
 *           - ReentrancyGuard (non-upgradeable) used; safe with UUPS proxies.
 *           - __UUPSUpgradeable_init() removed in OZ v5 -- not called.
 *           - safeApprove removed in OZ v5 -- forceApprove used instead.
 *           - SafeERC20Upgradeable removed in OZ v5 -- SafeERC20 used instead.
 */
contract WaveSendFund is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------
    //                        CONSTANTS
    // ---------------------------------------------------------

    uint256 public constant PERIOD_30_DAYS   = 2_592_000;
    uint256 public constant YIELD_RATE_NUM   = 100;
    uint256 public constant YIELD_RATE_DEN   = 10_000;
    uint256 public constant MAX_WITHDRAW_BPS = 1_000;
    uint256 public constant BPS_DENOM        = 10_000;
    uint256 public constant WBTC_UNIT        = 1e8;
    uint256 public constant WSND_UNIT        = 1e18;

    // ---------------------------------------------------------
    //                      STATE VARIABLES
    // ---------------------------------------------------------

    IERC20      public usdt;
    IERC20      public wbtc;
    IERC20      public wsnd;
    ISwapRouter public swapRouter;

    uint256 public wsndPerWbtc;
    uint256 public totalPoolHashrate;
    uint24  public poolFee;

    // ---------------------------------------------------------
    //              OPERATIONAL WITHDRAWAL TRACKING
    // ---------------------------------------------------------

    struct WithdrawWindow {
        uint256 windowStart;
        uint256 withdrawnInWindow;
        uint256 snapshotBalance;
    }

    mapping(address => WithdrawWindow) public withdrawWindows;

    // ---------------------------------------------------------
    //                        USER DATA
    // ---------------------------------------------------------

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

    // ---------------------------------------------------------
    //                          EVENTS
    // ---------------------------------------------------------

    event UserDeposited(address indexed user, uint256 usdtIn, uint256 wbtcReceived);
    event UserWithdrawn(address indexed user, uint256 wbtcAmount);
    event RewardClaimed(address indexed user, uint256 wbtcReward, uint256 wsndPaid, bool usedFallback);
    event RewardPreferenceSet(address indexed user, bool prefersWSND);
    event FundDeposited(address indexed token, uint256 amount, address indexed depositor);
    event OperationalWithdrawn(
        address indexed token,
        uint256 amount,
        uint256 windowStart,
        uint256 totalWithdrawnInWindow,
        uint256 allowance
    );
    event WsndRatioUpdated(uint256 newWsndPerWbtc);
    event PoolFeeUpdated(uint24 newFee);
    event RouterUpdated(address newRouter);

    // ---------------------------------------------------------
    //                       CONSTRUCTOR
    // ---------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ---------------------------------------------------------
    //                       INITIALIZER
    // ---------------------------------------------------------

    function initialize(
        address _owner,
        address _usdt,
        address _wbtc,
        address _wsnd,
        address _router,
        uint24  _poolFee
    ) external initializer {
        require(_owner  != address(0), "WF: zero owner");
        require(_usdt   != address(0), "WF: zero USDT");
        require(_wbtc   != address(0), "WF: zero WBTC");
        require(_wsnd   != address(0), "WF: zero WSND");
        require(_router != address(0), "WF: zero router");

        __Ownable_init(_owner);
        // No __UUPSUpgradeable_init() in OZ v5.
        // ReentrancyGuard slot defaults to 0 (NOT_ENTERED) -- no init needed.

        usdt        = IERC20(_usdt);
        wbtc        = IERC20(_wbtc);
        wsnd        = IERC20(_wsnd);
        swapRouter  = ISwapRouter(_router);
        poolFee     = _poolFee;
        wsndPerWbtc = WSND_UNIT;
    }

    // ---------------------------------------------------------
    //                     UUPS AUTHORISATION
    // ---------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ---------------------------------------------------------
    //                     ADMIN SETTERS
    // ---------------------------------------------------------

    function setWsndPerWbtc(uint256 _wsndPerWbtc) external onlyOwner {
        require(_wsndPerWbtc > 0, "WF: ratio zero");
        wsndPerWbtc = _wsndPerWbtc;
        emit WsndRatioUpdated(_wsndPerWbtc);
    }

    function setPoolFee(uint24 _poolFee) external onlyOwner {
        poolFee = _poolFee;
        emit PoolFeeUpdated(_poolFee);
    }

    function setSwapRouter(address _router) external onlyOwner {
        require(_router != address(0), "WF: zero router");
        swapRouter = ISwapRouter(_router);
        emit RouterUpdated(_router);
    }

    // ---------------------------------------------------------
    //              COMPANY LIQUIDITY FUNCTIONS
    // ---------------------------------------------------------

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
    ) external nonReentrant onlyOwner {
        require(token     != address(0), "WF: zero token");
        require(amount    >  0,          "WF: zero amount");
        require(recipient != address(0), "WF: zero recipient");

        WithdrawWindow storage window = withdrawWindows[token];

        if (window.windowStart == 0 ||
            block.timestamp >= window.windowStart + PERIOD_30_DAYS) {
            window.windowStart       = block.timestamp;
            window.withdrawnInWindow = 0;
            window.snapshotBalance   = IERC20(token).balanceOf(address(this));
        }

        uint256 windowAllowance  = (window.snapshotBalance * MAX_WITHDRAW_BPS) / BPS_DENOM;
        uint256 alreadyWithdrawn = window.withdrawnInWindow;
        require(alreadyWithdrawn < windowAllowance,                "WF: monthly allowance exhausted");
        require(amount <= windowAllowance - alreadyWithdrawn,      "WF: exceeds monthly 10% cap");
        require(IERC20(token).balanceOf(address(this)) >= amount,  "WF: insufficient contract balance");

        window.withdrawnInWindow += amount;
        IERC20(token).safeTransfer(recipient, amount);

        emit OperationalWithdrawn(token, amount, window.windowStart,
                                  window.withdrawnInWindow, windowAllowance);
    }

    function getWithdrawStatus(address token)
        external view
        returns (
            uint256 windowStart,
            uint256 withdrawnSoFar,
            uint256 windowAllowance,
            uint256 remainingAllowance,
            uint256 windowEndsAt
        )
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
        remainingAllowance = windowAllowance > withdrawnSoFar
                           ? windowAllowance - withdrawnSoFar : 0;
        return (window.windowStart, withdrawnSoFar, windowAllowance,
                remainingAllowance, window.windowStart + PERIOD_30_DAYS);
    }

    // ---------------------------------------------------------
    //                    USER-FACING FUNCTIONS
    // ---------------------------------------------------------

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
        // forceApprove replaces safeApprove which was removed in OZ v5.
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

    // ---------------------------------------------------------
    //                       VIEW FUNCTIONS
    // ---------------------------------------------------------

    function getPendingYield(address account) external view returns (uint256) {
        UserInfo storage user = userInfo[account];
        return user.pendingRewards + _calculateYield(
            user.activeHashrate,
            user.lastUpdateTimestamp
        );
    }

    function getUserInfo(address account) external view returns (UserInfo memory) {
        return userInfo[account];
    }

    // ---------------------------------------------------------
    //                     INTERNAL HELPERS
    // ---------------------------------------------------------

    function _calculateYield(uint256 activeHashrate, uint256 lastUpdateTimestamp)
        internal view returns (uint256 accrued)
    {
        if (activeHashrate == 0 || lastUpdateTimestamp == 0) return 0;
        if (block.timestamp <= lastUpdateTimestamp)           return 0;
        uint256 timeElapsed = block.timestamp - lastUpdateTimestamp;
        accrued = (activeHashrate * YIELD_RATE_NUM * timeElapsed)
                  / (YIELD_RATE_DEN * PERIOD_30_DAYS);
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
