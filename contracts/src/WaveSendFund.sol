// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// =============================================================
//                        INTERFACES
// =============================================================

/// @notice Minimal ERC20 interface (OpenZeppelin SafeERC20 compatible).
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

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
        external
        payable
        returns (uint256 amountOut);
}

// =============================================================
//               OpenZeppelin UUPS Upgradeable imports
// =============================================================

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

// =============================================================
//                     WAVESEND FUND CONTRACT
// =============================================================

/**
 * @title  WaveSendFund
 * @author Senior Smart Contract Developer
 * @notice A UUPS-upgradeable DeFi Mining Pool on Celo Mainnet operated by Wavesend.
 *
 *         ┌─ User Flow ──────────────────────────────────────────────────┐
 *         │  deposit(usdt, minWbtcOut) → swap USDT→WBTC → earn hashrate  │
 *         │  claim()                  → receive yield in WBTC or WSND    │
 *         │  withdraw(wbtcAmount)     → reclaim principal                 │
 *         └──────────────────────────────────────────────────────────────┘
 *
 *         ┌─ Company Flow ───────────────────────────────────────────────┐
 *         │  fundDeposit(token, amt)  → add liquidity, no yield accrual  │
 *         │  operationalWithdraw(...) → take ≤10 % of any token/month    │
 *         └──────────────────────────────────────────────────────────────┘
 *
 * @dev    Yield formula (linear, per second):
 *           pendingRewards = (activeHashrate × 100 × timeElapsed) / (10_000 × 2_592_000)
 *
 *         Decimals:
 *           USDT  — 6  decimals  (Celo bridged USDT)
 *           WBTC  — 8  decimals  (Celo bridged WBTC)
 *           WSND  — 18 decimals  (Wave Send Token)
 */
contract WaveSendFund is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20Upgradeable for IERC20;

    // ---------------------------------------------------------
    //                        CONSTANTS
    // ---------------------------------------------------------

    /// @dev 30-day yield/operational period in seconds.
    uint256 public constant PERIOD_30_DAYS  = 2_592_000;

    /// @dev Yield rate: 1 % = 100 / 10_000.
    uint256 public constant YIELD_RATE_NUM  = 100;
    uint256 public constant YIELD_RATE_DEN  = 10_000;

    /// @dev Maximum company withdrawal per token per 30-day window: 10 % = 10 / 100.
    uint256 public constant MAX_WITHDRAW_BPS = 1_000;  // basis points (10 %)
    uint256 public constant BPS_DENOM        = 10_000;

    /// @dev WBTC unit (8 decimals).
    uint256 public constant WBTC_UNIT       = 1e8;

    /// @dev WSND unit (18 decimals).
    uint256 public constant WSND_UNIT       = 1e18;

    // ---------------------------------------------------------
    //                      STATE VARIABLES
    // ---------------------------------------------------------

    /// @notice Celo bridged USDT (6 decimals).
    IERC20  public usdt;

    /// @notice Celo bridged WBTC (8 decimals) — principal & default yield token.
    IERC20  public wbtc;

    /// @notice Wave Send Token (18 decimals) — fallback yield token.
    IERC20  public wsnd;

    /// @notice Uniswap V3 SwapRouter on Celo.
    ISwapRouter public swapRouter;

    /**
     * @notice WSND units equivalent to 1 WBTC unit (1e8).
     * @dev    Default: 1e18 → face-value 1:1 (1 WBTC = 1 WSND).
     *         Conversion: wsndAmount = wbtcAmount * wsndPerWbtc / WBTC_UNIT
     */
    uint256 public wsndPerWbtc;

    /// @notice Pool-wide sum of all active user hashrates (WBTC, 8 dec).
    uint256 public totalPoolHashrate;

    /// @notice Uniswap V3 fee tier for USDT→WBTC swaps (e.g. 500 = 0.05 %).
    uint24  public poolFee;

    // ---------------------------------------------------------
    //              OPERATIONAL WITHDRAWAL TRACKING
    // ---------------------------------------------------------

    /**
     * @notice Per-token record of the company's rolling 30-day withdrawal window.
     * @dev    Key: token address.
     *         `windowStart`       — timestamp when the current window opened.
     *         `withdrawnInWindow` — cumulative amount already taken in this window.
     *         `snapshotBalance`   — contract balance at window open (caps the 10 %).
     */
    struct WithdrawWindow {
        uint256 windowStart;
        uint256 withdrawnInWindow;
        uint256 snapshotBalance;
    }

    mapping(address => WithdrawWindow) public withdrawWindows;

    // ---------------------------------------------------------
    //                        USER DATA
    // ---------------------------------------------------------

    /// @notice Per-user accounting state.
    struct UserInfo {
        uint256 activeHashrate;       // Current WBTC principal (8 dec)
        uint256 totalDeposited;       // Lifetime WBTC received after swap (8 dec)
        uint256 totalWbtcClaimed;     // Lifetime WBTC yield paid (8 dec)
        uint256 totalWsndClaimed;     // Lifetime WSND yield paid (18 dec)
        uint256 pendingRewards;       // Accrued WBTC-denominated yield (8 dec)
        uint256 lastUpdateTimestamp;  // Timestamp of last yield sync
        bool    prefersWSND;          // true → pay in WSND; false → WBTC (with fallback)
    }

    mapping(address => UserInfo) public userInfo;

    // ---------------------------------------------------------
    //                          EVENTS
    // ---------------------------------------------------------

    event UserDeposited(address indexed user, uint256 usdtIn, uint256 wbtcReceived);
    event UserWithdrawn(address indexed user, uint256 wbtcAmount);
    event RewardClaimed(address indexed user, uint256 wbtcReward, uint256 wsndPaid, bool usedFallback);
    event RewardPreferenceSet(address indexed user, bool prefersWSND);

    /// @notice Emitted when the company adds liquidity via fundDeposit.
    event FundDeposited(address indexed token, uint256 amount, address indexed depositor);

    /// @notice Emitted when the company makes an operational withdrawal.
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

    /**
     * @notice Initialise the proxy. Must be called once immediately after deployment.
     * @param  _owner    Address that will own (and control upgrades of) the contract.
     * @param  _usdt     Celo USDT address.
     * @param  _wbtc     Celo bridged WBTC address.
     * @param  _wsnd     Wave Send Token address.
     * @param  _router   Uniswap V3 SwapRouter address on Celo.
     * @param  _poolFee  Uniswap V3 fee tier (500 | 3000 | 10000).
     */
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
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        usdt        = IERC20(_usdt);
        wbtc        = IERC20(_wbtc);
        wsnd        = IERC20(_wsnd);
        swapRouter  = ISwapRouter(_router);
        poolFee     = _poolFee;

        // 1 WBTC (1e8) → 1 WSND (1e18) face-value default
        wsndPerWbtc = WSND_UNIT;
    }

    // ---------------------------------------------------------
    //                     UUPS AUTHORISATION
    // ---------------------------------------------------------

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ---------------------------------------------------------
    //                     ADMIN SETTERS
    // ---------------------------------------------------------

    /**
     * @notice Update the WSND : WBTC face-value ratio used when paying yield in WSND.
     * @param  _wsndPerWbtc  WSND units (18 dec) equal to 1 WBTC unit (1e8).
     */
    function setWsndPerWbtc(uint256 _wsndPerWbtc) external onlyOwner {
        require(_wsndPerWbtc > 0, "WF: ratio zero");
        wsndPerWbtc = _wsndPerWbtc;
        emit WsndRatioUpdated(_wsndPerWbtc);
    }

    /**
     * @notice Update the Uniswap V3 fee tier for USDT→WBTC swaps.
     * @param  _poolFee  Fee in hundredths of a bip (500 | 3000 | 10000).
     */
    function setPoolFee(uint24 _poolFee) external onlyOwner {
        poolFee = _poolFee;
        emit PoolFeeUpdated(_poolFee);
    }

    /**
     * @notice Replace the Uniswap V3 SwapRouter address.
     * @param  _router  New router address.
     */
    function setSwapRouter(address _router) external onlyOwner {
        require(_router != address(0), "WF: zero router");
        swapRouter = ISwapRouter(_router);
        emit RouterUpdated(_router);
    }

    // ---------------------------------------------------------
    //              COMPANY LIQUIDITY FUNCTIONS
    // ---------------------------------------------------------

    /**
     * @notice Deposit any ERC-20 token into the fund as company liquidity.
     * @dev    Pure liquidity top-up — no yield is accrued for the depositor.
     * @param  token   Address of the ERC-20 token to deposit.
     * @param  amount  Amount to deposit (in the token's native decimals).
     */
    function fundDeposit(address token, uint256 amount) external nonReentrant {
        require(token  != address(0), "WF: zero token");
        require(amount >  0,          "WF: zero amount");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit FundDeposited(token, amount, msg.sender);
    }

    /**
     * @notice Withdraw up to 10 % of any token's contract balance per 30-day rolling window.
     * @dev    A new window opens automatically once 30 days have elapsed.
     *         Partial withdrawals accumulate; the sum can never exceed 10 % in one window.
     * @param  token      ERC-20 token to withdraw.
     * @param  amount     Amount to withdraw (token's native decimals).
     * @param  recipient  Address that receives the tokens.
     */
    function operationalWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) external nonReentrant onlyOwner {
        require(token     != address(0), "WF: zero token");
        require(amount    >  0,          "WF: zero amount");
        require(recipient != address(0), "WF: zero recipient");

        WithdrawWindow storage window = withdrawWindows[token];

        // ── Open or roll the window ──────────────────────────────────────────
        if (
            window.windowStart == 0 ||
            block.timestamp >= window.windowStart + PERIOD_30_DAYS
        ) {
            window.windowStart        = block.timestamp;
            window.withdrawnInWindow  = 0;
            window.snapshotBalance    = IERC20(token).balanceOf(address(this));
        }

        // ── Compute allowance for this window ────────────────────────────────
        uint256 windowAllowance = (window.snapshotBalance * MAX_WITHDRAW_BPS) / BPS_DENOM;

        uint256 alreadyWithdrawn = window.withdrawnInWindow;
        require(alreadyWithdrawn < windowAllowance, "WF: monthly allowance exhausted");

        uint256 remaining = windowAllowance - alreadyWithdrawn;
        require(amount <= remaining, "WF: exceeds monthly 10% cap");

        require(
            IERC20(token).balanceOf(address(this)) >= amount,
            "WF: insufficient contract balance"
        );

        // ── CEI: update state before transfer ────────────────────────────────
        window.withdrawnInWindow += amount;

        IERC20(token).safeTransfer(recipient, amount);

        emit OperationalWithdrawn(
            token,
            amount,
            window.windowStart,
            window.withdrawnInWindow,
            windowAllowance
        );
    }

    /**
     * @notice View the current operational withdrawal status for a given token.
     * @param  token              ERC-20 token address to query.
     * @return windowStart        Timestamp when the current 30-day window opened.
     * @return withdrawnSoFar     Amount already withdrawn in the current window.
     * @return windowAllowance    Maximum withdrawable in the current window (10 % of snapshot).
     * @return remainingAllowance How much is still available this window.
     * @return windowEndsAt       Timestamp when this window closes.
     */
    function getWithdrawStatus(address token)
        external
        view
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
            uint256 currentBal = IERC20(token).balanceOf(address(this));
            uint256 allowance  = (currentBal * MAX_WITHDRAW_BPS) / BPS_DENOM;
            return (0, 0, allowance, allowance, 0);
        }

        bool windowExpired = block.timestamp >= window.windowStart + PERIOD_30_DAYS;

        if (windowExpired) {
            uint256 currentBal = IERC20(token).balanceOf(address(this));
            uint256 allowance  = (currentBal * MAX_WITHDRAW_BPS) / BPS_DENOM;
            return (
                block.timestamp,
                0,
                allowance,
                allowance,
                block.timestamp + PERIOD_30_DAYS
            );
        }

        windowAllowance    = (window.snapshotBalance * MAX_WITHDRAW_BPS) / BPS_DENOM;
        withdrawnSoFar     = window.withdrawnInWindow;
        remainingAllowance = windowAllowance > withdrawnSoFar
                            ? windowAllowance - withdrawnSoFar
                            : 0;
        return (
            window.windowStart,
            withdrawnSoFar,
            windowAllowance,
            remainingAllowance,
            window.windowStart + PERIOD_30_DAYS
        );
    }

    // ---------------------------------------------------------
    //                    USER-FACING FUNCTIONS
    // ---------------------------------------------------------

    /**
     * @notice Toggle whether your yield should be paid in WSND or WBTC.
     * @param  _prefersWSND  `true` → always receive WSND; `false` → receive WBTC when available.
     */
    function setRewardPreference(bool _prefersWSND) external {
        _updateYield(msg.sender);
        userInfo[msg.sender].prefersWSND = _prefersWSND;
        emit RewardPreferenceSet(msg.sender, _prefersWSND);
    }

    /**
     * @notice Deposit USDT into the pool. USDT is swapped to WBTC and credited as Hashrate.
     * @param  usdtAmount   Amount of USDT to deposit (6-decimal units).
     * @param  minWbtcOut   Minimum WBTC to receive from the swap (slippage guard).
     */
    function deposit(uint256 usdtAmount, uint256 minWbtcOut) external nonReentrant {
        require(usdtAmount > 0, "WF: zero USDT");
        require(minWbtcOut > 0, "WF: zero min out");

        _updateYield(msg.sender);

        usdt.safeTransferFrom(msg.sender, address(this), usdtAmount);

        usdt.safeApprove(address(swapRouter), usdtAmount);

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

        UserInfo storage user = userInfo[msg.sender];
        user.activeHashrate      += wbtcReceived;
        user.totalDeposited      += wbtcReceived;
        totalPoolHashrate        += wbtcReceived;
        user.lastUpdateTimestamp  = block.timestamp;

        emit UserDeposited(msg.sender, usdtAmount, wbtcReceived);
    }

    /**
     * @notice Withdraw WBTC principal from the pool.
     * @dev    Accrued yield is synced but NOT auto-claimed. Call `claim()` separately.
     * @param  wbtcAmount  Amount of WBTC to withdraw (8-decimal units).
     */
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

    /**
     * @notice Claim all accrued yield.
     *
     *         Priority tree:
     *         A) `prefersWSND == true`                         → pay full reward in WSND.
     *         B) `prefersWSND == false` AND pool WBTC < reward → full fallback to WSND.
     *         C) `prefersWSND == false` AND pool WBTC ≥ reward → pay in WBTC.
     */
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
            usedFallback = false;

        } else if (wbtc.balanceOf(address(this)) < rewards) {
            wsndPaid = _wbtcToWsnd(rewards);
            require(wsnd.balanceOf(address(this)) >= wsndPaid, "WF: insufficient WSND fallback");
            user.totalWsndClaimed += wsndPaid;
            wsnd.safeTransfer(msg.sender, wsndPaid);
            usedFallback = true;

        } else {
            user.totalWbtcClaimed += rewards;
            wbtc.safeTransfer(msg.sender, rewards);
            usedFallback = false;
        }

        emit RewardClaimed(msg.sender, rewards, wsndPaid, usedFallback);
    }

    // ---------------------------------------------------------
    //                       VIEW FUNCTIONS
    // ---------------------------------------------------------

    /**
     * @notice Total pending yield for `account` (accrued + not yet claimed).
     * @param  account  Wallet to query.
     * @return WBTC-denominated pending yield (8 decimals).
     */
    function getPendingYield(address account) external view returns (uint256) {
        UserInfo storage user = userInfo[account];
        return user.pendingRewards + _calculateYield(
            user.activeHashrate,
            user.lastUpdateTimestamp
        );
    }

    /**
     * @notice Return the full UserInfo struct for `account`.
     */
    function getUserInfo(address account) external view returns (UserInfo memory) {
        return userInfo[account];
    }

    // ---------------------------------------------------------
    //                     INTERNAL HELPERS
    // ---------------------------------------------------------

    /**
     * @dev Linearly calculate yield accrued since `lastUpdateTimestamp`.
     *      Formula: (activeHashrate × 100 × timeElapsed) / (10_000 × 2_592_000)
     */
    function _calculateYield(uint256 activeHashrate, uint256 lastUpdateTimestamp)
        internal
        view
        returns (uint256 accrued)
    {
        if (activeHashrate == 0 || lastUpdateTimestamp == 0) return 0;
        if (block.timestamp <= lastUpdateTimestamp)           return 0;

        uint256 timeElapsed = block.timestamp - lastUpdateTimestamp;
        accrued = (activeHashrate * YIELD_RATE_NUM * timeElapsed)
                  / (YIELD_RATE_DEN * PERIOD_30_DAYS);
    }

    /**
     * @dev Snapshot accrued yield into `pendingRewards` and reset the timestamp.
     *      Must be called at the start of every state-mutating user action.
     */
    function _updateYield(address account) internal {
        UserInfo storage user = userInfo[account];

        if (user.activeHashrate > 0 && user.lastUpdateTimestamp > 0) {
            uint256 accrued = _calculateYield(
                user.activeHashrate,
                user.lastUpdateTimestamp
            );
            if (accrued > 0) {
                user.pendingRewards += accrued;
            }
        }

        user.lastUpdateTimestamp = block.timestamp;
    }

    /**
     * @dev Convert a WBTC amount (8 dec) to its WSND equivalent (18 dec).
     *      wsndAmount = wbtcAmount × wsndPerWbtc / WBTC_UNIT
     */
    function _wbtcToWsnd(uint256 wbtcAmount) internal view returns (uint256) {
        return (wbtcAmount * wsndPerWbtc) / WBTC_UNIT;
    }
}
