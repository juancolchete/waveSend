// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// =============================================================
//               OpenZeppelin imports
// =============================================================

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";

// =============================================================
//                     WAVESEND FUND CONTRACT
// =============================================================

/**
 * @title  WaveSendFund
 * @author Senior Smart Contract Developer
 * @notice A UUPS-upgradeable DeFi Mining Pool on Celo Mainnet operated by Wavesend.
 *
 *         Role architecture:
 *           DEFAULT_ADMIN_ROLE  -- can grant/revoke all roles; assigned to deployer.
 *           OPERATOR_ROLE       -- admin setters (fee, router, ratio) + operationalWithdraw.
 *           UPGRADER_ROLE       -- authorises UUPS proxy upgrades.
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
 *           - AccessControlUpgradeable replaces OwnableUpgradeable.
 *           - ReentrancyGuard used.
 *           - __UUPSUpgradeable_init() removed in OZ v5.
 *           - safeApprove removed in OZ v5 -- forceApprove used instead.
 */
contract WaveSendFund is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuard  // FIX-1 (continued)
{
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------
    //                          ROLES
    // ---------------------------------------------------------
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Authorises UUPS proxy upgrades.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // Note: DEFAULT_ADMIN_ROLE = 0x00 is inherited from AccessControl.

    // ---------------------------------------------------------
    //                        CONSTANTS
    // ---------------------------------------------------------

    uint256 public constant PERIOD_30_DAYS  = 2_592_000;
    uint256 public constant YIELD_RATE_NUM  = 100;
    uint256 public constant YIELD_RATE_DEN  = 10_000;
    uint256 public constant MAX_WITHDRAW_BPS = 1_000;
    uint256 public constant BPS_DENOM       = 10_000;
    uint256 public constant WBTC_UNIT       = 1e8;
    uint256 public constant WSND_UNIT       = 1e18;

    // ---------------------------------------------------------
    //                      STATE VARIABLES
    // ---------------------------------------------------------

    IERC20    public usdt;
    IERC20    public wbtc;
    IERC20    public wsnd;
    IV4Router public swapRouter;

    uint256 public wsndPerWbtc;
    uint256 public totalPoolHashrate;

    // V4 pool params: USDT <-> WBTC pool
    uint24  public poolFee;
    int24   public poolTickSpacing;
    address public poolHook;

    // V4 pool params: CELO <-> USDT pool (first hop for native deposits)
    uint24  public nativeUsdtFee;
    int24   public nativeUsdtTickSpacing;
    address public nativeUsdtHook;

    // Kept for backward-compatible getter; alias for nativeUsdtFee context.
    uint24  public nativeFee;

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
    event NativeFeeUpdated(uint24 newFee);
    event NativeUsdtFeeUpdated(uint24 newFee);
    event NativeDeposited(address indexed user, uint256 nativeIn, uint256 wbtcReceived);

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
     * @notice Initialise the proxy. Called once immediately after deployment.
     * @param  _admin               Receives DEFAULT_ADMIN_ROLE, OPERATOR_ROLE, UPGRADER_ROLE.
     * @param  _usdt                Celo USDT address.
     * @param  _wbtc                Celo bridged WBTC address.
     * @param  _wsnd                Wave Send Token address.
     * @param  _router              Uniswap V4 UniversalRouter / V4Router address on Celo.
     * @param  _poolFee             V4 fee tier for the USDT<->WBTC pool.
     * @param  _poolTickSpacing     Tick spacing for the USDT<->WBTC pool.
     * @param  _nativeFee           V4 fee tier for the CELO<->USDT pool.
     * @param  _nativeUsdtFee       Alias kept for the CELO<->USDT hop fee.
     * @param  _nativeUsdtTickSpacing Tick spacing for the CELO<->USDT pool.
     */
    function initialize(
        address _admin,
        address _usdt,
        address _wbtc,
        address _wsnd,
        address _router,
        uint24  _poolFee,
        int24   _poolTickSpacing,
        uint24  _nativeFee,
        uint24  _nativeUsdtFee,
        int24   _nativeUsdtTickSpacing
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
        swapRouter  = IV4Router(_router);

        poolFee             = _poolFee;
        poolTickSpacing     = _poolTickSpacing;
        nativeFee           = _nativeFee;
        nativeUsdtFee       = _nativeUsdtFee;
        nativeUsdtTickSpacing = _nativeUsdtTickSpacing;

        wsndPerWbtc = WSND_UNIT; // default 1:1 (adjusted via setWsndPerWbtc)
    }

    // ---------------------------------------------------------
    //                     UUPS AUTHORISATION
    // ---------------------------------------------------------

    /// @dev Only UPGRADER_ROLE may push a new implementation.
    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    // ---------------------------------------------------------
    //                       ADMIN SETTERS
    // ---------------------------------------------------------

    /// @notice Update the WSND:WBTC face-value ratio.
    function setWsndPerWbtc(uint256 _wsndPerWbtc) external onlyRole(OPERATOR_ROLE) {
        require(_wsndPerWbtc > 0, "WF: ratio zero");
        wsndPerWbtc = _wsndPerWbtc;
        emit WsndRatioUpdated(_wsndPerWbtc);
    }

    /// @notice Update the V4 fee tier for the USDT<->WBTC pool.
    function setPoolFee(uint24 _poolFee) external onlyRole(OPERATOR_ROLE) {
        poolFee = _poolFee;
        emit PoolFeeUpdated(_poolFee);
    }

    /// @notice Replace the V4Router address.
    function setSwapRouter(address _router) external onlyRole(OPERATOR_ROLE) {
        require(_router != address(0), "WF: zero router");
        swapRouter = IV4Router(_router);
        emit RouterUpdated(_router);
    }

    /// @notice Update the V4 fee tier for the CELO<->USDT hop.
    function setNativeFee(uint24 _nativeFee) external onlyRole(OPERATOR_ROLE) {
        nativeFee = _nativeFee;
        emit NativeFeeUpdated(_nativeFee);
    }

    /// @notice Update the V4 fee tier for the CELO<->USDT pool (nativeUsdtFee).
    function setNativeUsdtFee(uint24 _nativeUsdtFee) external onlyRole(OPERATOR_ROLE) {
        nativeUsdtFee = _nativeUsdtFee;
        emit NativeUsdtFeeUpdated(_nativeUsdtFee);
    }

    // ---------------------------------------------------------
    //              COMPANY LIQUIDITY FUNCTIONS
    // ---------------------------------------------------------

    /**
     * @notice Deposit any ERC-20 token as company liquidity (no yield accrual).
     *         Typically called by the treasury multi-sig.
     */
    function fundDeposit(address token, uint256 amount) external nonReentrant {
        require(token  != address(0), "WF: zero token");
        require(amount > 0,           "WF: zero amount");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit FundDeposited(token, amount, msg.sender);
    }

    /**
     * @notice Withdraw up to 10 % of any token balance per 30-day rolling window.
     *         Requires OPERATOR_ROLE.
     */
    function operationalWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) external nonReentrant onlyRole(OPERATOR_ROLE) {
        require(token     != address(0), "WF: zero token");
        require(amount    > 0,           "WF: zero amount");
        require(recipient != address(0), "WF: zero recipient");

        WithdrawWindow storage window = withdrawWindows[token];

        // Open a new window if this is the first withdrawal or the previous one expired.
        if (window.windowStart == 0 || block.timestamp >= window.windowStart + PERIOD_30_DAYS) {
            window.windowStart       = block.timestamp;
            window.withdrawnInWindow = 0;
            window.snapshotBalance   = IERC20(token).balanceOf(address(this));
        }

        uint256 windowAllowance  = (window.snapshotBalance * MAX_WITHDRAW_BPS) / BPS_DENOM;
        uint256 alreadyWithdrawn = window.withdrawnInWindow;

        require(alreadyWithdrawn < windowAllowance,                        "WF: monthly allowance exhausted");
        require(amount <= windowAllowance - alreadyWithdrawn,              "WF: exceeds monthly 10% cap");
        require(IERC20(token).balanceOf(address(this)) >= amount,          "WF: insufficient contract balance");

        window.withdrawnInWindow += amount;
        IERC20(token).safeTransfer(recipient, amount);

        emit OperationalWithdrawn(token, amount, window.windowStart, window.withdrawnInWindow, windowAllowance);
    }

    /// @notice View the current operational withdrawal status for a given token.
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
            uint256 bal = IERC20(token).balanceOf(address(this));
            uint256 al  = (bal * MAX_WITHDRAW_BPS) / BPS_DENOM;
            return (0, 0, al, al, 0);
        }

        if (block.timestamp >= window.windowStart + PERIOD_30_DAYS) {
            uint256 bal = IERC20(token).balanceOf(address(this));
            uint256 al  = (bal * MAX_WITHDRAW_BPS) / BPS_DENOM;
            return (block.timestamp, 0, al, al, block.timestamp + PERIOD_30_DAYS);
        }

        windowAllowance   = (window.snapshotBalance * MAX_WITHDRAW_BPS) / BPS_DENOM;
        withdrawnSoFar    = window.withdrawnInWindow;
        remainingAllowance = windowAllowance > withdrawnSoFar ? windowAllowance - withdrawnSoFar : 0;
        return (window.windowStart, withdrawnSoFar, windowAllowance, remainingAllowance, window.windowStart + PERIOD_30_DAYS);
    }

    // ---------------------------------------------------------
    //                    USER-FACING FUNCTIONS
    // ---------------------------------------------------------

    /// @notice Toggle yield payout preference between WBTC and WSND.
    function setRewardPreference(bool _prefersWSND) external {
        _updateYield(msg.sender);
        userInfo[msg.sender].prefersWSND = _prefersWSND;
        emit RewardPreferenceSet(msg.sender, _prefersWSND);
    }

    /**
     * @notice Deposit USDT. It is swapped 1-hop (USDT -> WBTC) via Uniswap V4
     *         and the received WBTC is credited as Hashrate to the caller.
     * @param  usdtAmount  USDT amount to deposit (6-decimal units).
     * @param  minWbtcOut  Minimum WBTC to receive (slippage guard, 8-decimal units).
     */
    function deposit(uint256 usdtAmount, uint256 minWbtcOut) external nonReentrant {
        require(usdtAmount > 0, "WF: zero USDT");
        require(minWbtcOut > 0, "WF: zero min out");

        _updateYield(msg.sender);

        usdt.safeTransferFrom(msg.sender, address(this), usdtAmount);

        // Approve router for exactly the amount being swapped.
        usdt.forceApprove(address(swapRouter), usdtAmount);

        // --- Uniswap V4 exactInput: 1-hop USDT -> WBTC ---
        Currency usdtCurrency = Currency.wrap(address(usdt));
        Currency wbtcCurrency = Currency.wrap(address(wbtc));

        // V4 path encoding: tokenIn | fee | tickSpacing | hookAddress | tokenOut
        bytes memory path = abi.encodePacked(
            usdtCurrency,
            poolFee,
            poolTickSpacing,
            poolHook,
            wbtcCurrency
        );

        uint256 wbtcReceived = swapRouter.exactInput(
            IV4Router.ExactInputParams({
                path:             path,
                recipient:        address(this),
                amountIn:         usdtAmount,
                amountOutMinimum: minWbtcOut
            })
        );

        UserInfo storage user = userInfo[msg.sender];
        user.activeHashrate       += wbtcReceived;
        user.totalDeposited       += wbtcReceived;
        totalPoolHashrate         += wbtcReceived;
        user.lastUpdateTimestamp   = block.timestamp;

        emit UserDeposited(msg.sender, usdtAmount, wbtcReceived);
    }

    /**
     * @notice Deposit native CELO. Because CELO is a native ERC-20 on Celo Mainnet,
     *         msg.value arrives as an ERC-20 balance increase. The amount is swapped
     *         2-hop (CELO -> USDT -> WBTC) via Uniswap V4 and credited as Hashrate.
     * @param  minWbtcOut  Minimum WBTC to receive (slippage guard, 8-decimal units).
     */
    function depositNative(uint256 minWbtcOut) public payable nonReentrant {
        require(msg.value  > 0, "WF: zero native");
        require(minWbtcOut > 0, "WF: zero min out");
        require(nativeFee     > 0, "WF: native fee not set");
        require(nativeUsdtFee > 0, "WF: native usdt fee not set");

        _updateYield(msg.sender);

        // CELO native ERC-20 address (Celo Mainnet).
        address celoToken = 0x471EcE3750Da237f93B8E339c536989b8978a438;

        Currency celoCurrency = Currency.wrap(celoToken);
        Currency usdtCurrency = Currency.wrap(address(usdt));
        Currency wbtcCurrency = Currency.wrap(address(wbtc));

        // FIX-5: Use msg.value as the swap input instead of balanceOf().
        //        balanceOf() would sweep any pre-existing CELO held by the contract,
        //        attributing it to this caller's deposit — an accounting error.
        uint256 celoAmountIn = msg.value;

        // FIX-6: Use forceApprove (SafeERC20) instead of raw approve().
        //        Raw approve fails on tokens that require resetting to zero first.
        //        Scope the allowance to celoAmountIn, not type(uint256).max.
        IERC20(celoToken).forceApprove(address(swapRouter), celoAmountIn);

        // V4 path encoding: 2-hop CELO -> USDT -> WBTC
        bytes memory path = abi.encodePacked(
            celoCurrency,
            nativeUsdtFee,
            nativeUsdtTickSpacing,
            nativeUsdtHook,
            usdtCurrency,
            poolFee,
            poolTickSpacing,
            poolHook,
            wbtcCurrency
        );

        // FIX-7: swapRouter.ExactInputParams is not valid Solidity syntax.
        //        Always reference the struct via the interface type: IV4Router.ExactInputParams.
        uint256 wbtcReceived = swapRouter.exactInput(
            IV4Router.ExactInputParams({
                path:             path,
                recipient:        address(this),
                amountIn:         celoAmountIn,
                amountOutMinimum: minWbtcOut
            })
        );

        UserInfo storage user = userInfo[msg.sender];
        user.activeHashrate       += wbtcReceived;
        user.totalDeposited       += wbtcReceived;
        totalPoolHashrate         += wbtcReceived;
        user.lastUpdateTimestamp   = block.timestamp;

        emit NativeDeposited(msg.sender, msg.value, wbtcReceived);
    }

    /**
     * @notice Accept plain native CELO (e.g. router refunds). Does NOT auto-deposit.
     * @dev    FIX-8: The original called depositNative(1) from receive(), which always
     *         reverts because depositNative is nonReentrant and the guard is already
     *         locked during any in-flight swap refund. Hardcoding minWbtcOut=1 is also
     *         an unsafe slippage value. Plain receipt is the correct behaviour here.
     */
    receive() external payable {}

    /**
     * @notice Withdraw WBTC principal. Pending yield is synced but NOT auto-claimed.
     * @param  wbtcAmount  Amount of WBTC to withdraw (8-decimal units).
     */
    function withdraw(uint256 wbtcAmount) external nonReentrant {
        require(wbtcAmount > 0, "WF: zero amount");

        _updateYield(msg.sender);

        UserInfo storage user = userInfo[msg.sender];
        require(user.activeHashrate >= wbtcAmount,             "WF: insufficient hashrate");
        require(wbtc.balanceOf(address(this)) >= wbtcAmount,  "WF: pool low WBTC");

        user.activeHashrate -= wbtcAmount;
        totalPoolHashrate   -= wbtcAmount;

        wbtc.safeTransfer(msg.sender, wbtcAmount);
        emit UserWithdrawn(msg.sender, wbtcAmount);
    }

    /**
     * @notice Claim all accrued yield.
     *         A) prefersWSND == true                          -> pay in WSND.
     *         B) prefersWSND == false AND pool WBTC < reward  -> fallback to WSND.
     *         C) prefersWSND == false AND pool WBTC >= reward -> pay in WBTC.
     */
    function claimRewards() external nonReentrant {
        _updateYield(msg.sender);

        UserInfo storage user = userInfo[msg.sender];
        uint256 pending = user.pendingRewards;
        require(pending > 0, "WF: nothing to claim");

        // Zero before transfer to prevent re-entrancy on exotic tokens.
        user.pendingRewards = 0;

        bool useWsnd      = user.prefersWSND;
        bool usedFallback = false;

        if (!useWsnd && wbtc.balanceOf(address(this)) < pending) {
            useWsnd      = true;
            usedFallback = true;
        }

        uint256 wsndPaid = 0;
        if (useWsnd) {
            // Scale the WBTC-denominated reward to 18-decimal WSND.
            wsndPaid = (pending * wsndPerWbtc) / WBTC_UNIT;
            require(wsnd.balanceOf(address(this)) >= wsndPaid, "WF: pool low WSND");
            user.totalWsndClaimed += wsndPaid;
            wsnd.safeTransfer(msg.sender, wsndPaid);
        } else {
            user.totalWbtcClaimed += pending;
            wbtc.safeTransfer(msg.sender, pending);
        }

        emit RewardClaimed(msg.sender, pending, wsndPaid, usedFallback);
    }

    // ---------------------------------------------------------
    //                     INTERNAL HELPERS
    // ---------------------------------------------------------

    /**
     * @dev Accrue yield for `_user` since their last update.
     *      Formula: newRewards = (activeHashrate * YIELD_RATE_NUM * elapsed)
     *                            / (YIELD_RATE_DEN * PERIOD_30_DAYS)
     *      At 100% hashrate for 30 days: 1e8 * 100 * 2_592_000 / (10_000 * 2_592_000) = 1_000 satoshis (1%).
     */
    function _updateYield(address _user) internal {
        UserInfo storage user = userInfo[_user];
        if (user.lastUpdateTimestamp == 0) {
            user.lastUpdateTimestamp = block.timestamp;
            return;
        }
        uint256 elapsed = block.timestamp - user.lastUpdateTimestamp;
        if (elapsed > 0 && user.activeHashrate > 0) {
            user.pendingRewards += (user.activeHashrate * YIELD_RATE_NUM * elapsed)
                / (YIELD_RATE_DEN * PERIOD_30_DAYS);
        }
        user.lastUpdateTimestamp = block.timestamp;
    }

    // ---------------------------------------------------------
    //                       VIEW HELPERS
    // ---------------------------------------------------------

    /// @notice Preview pending rewards for `_user` without mutating state.
    function pendingRewardsOf(address _user) external view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        uint256 accrued = user.pendingRewards;
        if (user.lastUpdateTimestamp > 0 && user.activeHashrate > 0) {
            uint256 elapsed = block.timestamp - user.lastUpdateTimestamp;
            accrued += (user.activeHashrate * YIELD_RATE_NUM * elapsed)
                / (YIELD_RATE_DEN * PERIOD_30_DAYS);
        }
        return accrued;
    }
}
