// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// =============================================================
//                        INTERFACES
// =============================================================

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
 *           - ReentrancyGuard (non-upgradeable) safe with UUPS proxies.
 *           - __UUPSUpgradeable_init() removed in OZ v5.
 *           - safeApprove removed in OZ v5 -- forceApprove used instead.
 */
contract WaveSendFund is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------
    //                          ROLES
    // ---------------------------------------------------------

    /// @notice Can grant/revoke all roles. Assigned to the admin address on init.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Can call admin setters and operationalWithdraw.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // Note: DEFAULT_ADMIN_ROLE = 0x00 is inherited from AccessControl.

    // ---------------------------------------------------------
    //                        CONSTANTS
    // ---------------------------------------------------------

    uint256 public constant PERIOD_30_DAYS = 2_592_000;
    uint256 public constant YIELD_RATE_NUM = 100;
    uint256 public constant YIELD_RATE_DEN = 10_000;
    uint256 public constant MAX_WITHDRAW_BPS = 1_000;
    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant WBTC_UNIT = 1e8;
    uint256 public constant WSND_UNIT = 1e18;

    // ---------------------------------------------------------
    //                      STATE VARIABLES
    // ---------------------------------------------------------

    IERC20 public usdt;
    IERC20 public wbtc;
    IERC20 public wsnd;
    IV4Router public swapRouter;

    uint256 public wsndPerWbtc;
    uint256 public totalPoolHashrate;
    uint24 public poolFee;
    int24 public nativeUsdtTickSpacing;
    address public nativeUsdtHook;
    int24 public poolTickSpacing;
    address public poolHook;

    /// @notice Uniswap V3 fee tier for the CELO -> USDT hop.
    uint24 public nativeUsdtFee;

    /// @notice Uniswap V3 fee tier for the USDT -> WBTC hop (reuses poolFee).
    /// nativeFee kept as alias so existing setter/getter still works.
    uint24 public nativeFee;

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
        bool prefersWSND;
    }

    mapping(address => UserInfo) public userInfo;

    // ---------------------------------------------------------
    //                          EVENTS
    // ---------------------------------------------------------

    event UserDeposited(
        address indexed user,
        uint256 usdtIn,
        uint256 wbtcReceived
    );
    event UserWithdrawn(address indexed user, uint256 wbtcAmount);
    event RewardClaimed(
        address indexed user,
        uint256 wbtcReward,
        uint256 wsndPaid,
        bool usedFallback
    );
    event RewardPreferenceSet(address indexed user, bool prefersWSND);
    event FundDeposited(
        address indexed token,
        uint256 amount,
        address indexed depositor
    );
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
    event NativeDeposited(
        address indexed user,
        uint256 nativeIn,
        uint256 wbtcReceived
    );

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
     * @param  _admin    Receives DEFAULT_ADMIN_ROLE, OPERATOR_ROLE, and UPGRADER_ROLE.
     * @param  _usdt     Celo USDT address.
     * @param  _wbtc     Celo bridged WBTC address.
     * @param  _wsnd     Wave Send Token address.
     * @param  _router   Uniswap V3 SwapRouter address on Celo.
     * @param  _poolFee  Uniswap V3 fee tier (500 | 3000 | 10000).
     */
    function initialize(
        address _admin,
        address _usdt,
        address _wbtc,
        address _wsnd,
        address _router,
        uint24 _poolFee,
        int24 _poolTickSpacing,
        uint24 _nativeFee,
        uint24 _nativeUsdtFee,
        int24 _nativeUsdtTickSpacing
    ) external initializer {
        require(_admin != address(0), "WF: zero admin");
        require(_usdt != address(0), "WF: zero USDT");
        require(_wbtc != address(0), "WF: zero WBTC");
        require(_wsnd != address(0), "WF: zero WSND");
        require(_router != address(0), "WF: zero router");

        __AccessControl_init();
        // ReentrancyGuard slot defaults to 0 (NOT_ENTERED) -- no init needed.

        // Grant all roles to the admin address.
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);

        usdt = IERC20(_usdt);
        wbtc = IERC20(_wbtc);
        wsnd = IERC20(_wsnd);
        swapRouter = IV4Router(_router);
        poolFee = _poolFee;
        poolTickSpacing = _poolTickSpacing;
        nativeFee = _nativeFee;
        nativeUsdtFee = _nativeUsdtFee;
        nativeUsdtTickSpacing = _nativeUsdtTickSpacing;
        wsndPerWbtc = WSND_UNIT;
    }

    // ---------------------------------------------------------
    //                     UUPS AUTHORISATION
    // ---------------------------------------------------------

    /// @dev Only UPGRADER_ROLE can push a new implementation.
    function _authorizeUpgrade(
        address
    ) internal override onlyRole(UPGRADER_ROLE) {}

    // ---------------------------------------------------------
    //                     ADMIN SETTERS
    // ---------------------------------------------------------

    /// @notice Update the WSND:WBTC face-value ratio. Requires OPERATOR_ROLE.
    function setWsndPerWbtc(
        uint256 _wsndPerWbtc
    ) external onlyRole(OPERATOR_ROLE) {
        require(_wsndPerWbtc > 0, "WF: ratio zero");
        wsndPerWbtc = _wsndPerWbtc;
        emit WsndRatioUpdated(_wsndPerWbtc);
    }

    /// @notice Update the Uniswap V3 fee tier. Requires OPERATOR_ROLE.
    function setPoolFee(uint24 _poolFee) external onlyRole(OPERATOR_ROLE) {
        poolFee = _poolFee;
        emit PoolFeeUpdated(_poolFee);
    }

    /// @notice Replace the Uniswap V3 SwapRouter address. Requires OPERATOR_ROLE.
    function setSwapRouter(address _router) external onlyRole(OPERATOR_ROLE) {
        require(_router != address(0), "WF: zero router");
        swapRouter = IV4Router(_router);
        emit RouterUpdated(_router);
    }

    /// @notice Update the Uniswap V3 fee tier for native token -> WBTC swaps. Requires OPERATOR_ROLE.
    function setNativeFee(uint24 _nativeFee) external onlyRole(OPERATOR_ROLE) {
        nativeFee = _nativeFee;
        emit NativeFeeUpdated(_nativeFee);
    }

    function setNativeUsdtFee(
        uint24 _nativeUsdtFee
    ) external onlyRole(OPERATOR_ROLE) {
        nativeUsdtFee = _nativeUsdtFee;
        emit NativeUsdtFeeUpdated(_nativeUsdtFee);
    }

    // ---------------------------------------------------------
    //              COMPANY LIQUIDITY FUNCTIONS
    // ---------------------------------------------------------

    /**
     * @notice Deposit any ERC-20 token as company liquidity (no yield accrual).
     *         Open to any caller — typically the treasury multi-sig.
     */
    function fundDeposit(address token, uint256 amount) external nonReentrant {
        require(token != address(0), "WF: zero token");
        require(amount > 0, "WF: zero amount");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit FundDeposited(token, amount, msg.sender);
    }

    /**
     * @notice Withdraw up to 10 % of any token per 30-day window. Requires OPERATOR_ROLE.
     */
    function operationalWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) external nonReentrant onlyRole(OPERATOR_ROLE) {
        require(token != address(0), "WF: zero token");
        require(amount > 0, "WF: zero amount");
        require(recipient != address(0), "WF: zero recipient");

        WithdrawWindow storage window = withdrawWindows[token];

        if (
            window.windowStart == 0 ||
            block.timestamp >= window.windowStart + PERIOD_30_DAYS
        ) {
            window.windowStart = block.timestamp;
            window.withdrawnInWindow = 0;
            window.snapshotBalance = IERC20(token).balanceOf(address(this));
        }

        uint256 windowAllowance = (window.snapshotBalance * MAX_WITHDRAW_BPS) /
            BPS_DENOM;
        uint256 alreadyWithdrawn = window.withdrawnInWindow;
        require(
            alreadyWithdrawn < windowAllowance,
            "WF: monthly allowance exhausted"
        );
        require(
            amount <= windowAllowance - alreadyWithdrawn,
            "WF: exceeds monthly 10% cap"
        );
        require(
            IERC20(token).balanceOf(address(this)) >= amount,
            "WF: insufficient contract balance"
        );

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

    /// @notice View the current operational withdrawal status for a given token.
    function getWithdrawStatus(
        address token
    )
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
            uint256 al = (bal * MAX_WITHDRAW_BPS) / BPS_DENOM;
            return (0, 0, al, al, 0);
        }

        if (block.timestamp >= window.windowStart + PERIOD_30_DAYS) {
            uint256 bal = IERC20(token).balanceOf(address(this));
            uint256 al = (bal * MAX_WITHDRAW_BPS) / BPS_DENOM;
            return (
                block.timestamp,
                0,
                al,
                al,
                block.timestamp + PERIOD_30_DAYS
            );
        }

        windowAllowance =
            (window.snapshotBalance * MAX_WITHDRAW_BPS) /
            BPS_DENOM;
        withdrawnSoFar = window.withdrawnInWindow;
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

    /// @notice Toggle yield payout token between WBTC and WSND.
    function setRewardPreference(bool _prefersWSND) external {
        _updateYield(msg.sender);
        userInfo[msg.sender].prefersWSND = _prefersWSND;
        emit RewardPreferenceSet(msg.sender, _prefersWSND);
    }

    /// @notice Deposit USDT; it is swapped to WBTC and credited as Hashrate.
    function deposit(
        uint256 usdtAmount,
        uint256 minWbtcOut
    ) external nonReentrant {
        require(usdtAmount > 0, "WF: zero USDT");
        require(minWbtcOut > 0, "WF: zero min out");

        _updateYield(msg.sender);

        usdt.safeTransferFrom(msg.sender, address(this), usdtAmount);
        usdt.forceApprove(address(swapRouter), usdtAmount);

        // 1. Wrap the addresses in V4's Currency type
        Currency usdtCurrency = Currency.wrap(address(usdt));
        Currency wbtcCurrency = Currency.wrap(address(wbtc));

        // 2. Encode a 1-Hop V4 Path
        bytes memory v4SwapPath = abi.encodePacked(
            usdtCurrency,
            poolFee,
            poolTickSpacing,
            poolHook,
            wbtcCurrency
        );

        // 3. Execute using exactInput
        uint256 wbtcReceived = IV4Router.exactInput(
            IV4Router.ExactInputParams({
                path: v4SwapPath,
                recipient: address(this),
                amountIn: usdtAmount,
                amountOutMinimum: minWbtcOut,
                deadline: block.timestamp // Add this missing 5th argument
            })
        );

        UserInfo storage user = userInfo[msg.sender];
        user.activeHashrate += wbtcReceived;
        user.totalDeposited += wbtcReceived;
        totalPoolHashrate += wbtcReceived;
        user.lastUpdateTimestamp = block.timestamp;

        emit UserDeposited(msg.sender, usdtAmount, wbtcReceived);
    }

    /**
     * @notice Deposit the blockchain native token (CELO on Celo Mainnet).
     *         The native amount is forwarded directly to the Uniswap V3 router,
     *         which wraps it and swaps it to WBTC. The received WBTC is credited
     *         as Hashrate to the caller.
     * @dev    The router must support ETH/native-token inputs via the payable
     *         `exactInputSingle` path (standard on all Uniswap V3 deployments).
     *         `msg.value` is the native amount; any unspent native is NOT refunded
     *         by this contract — set `minWbtcOut` carefully.
     * @param  minWbtcOut  Minimum WBTC to receive (slippage guard, 8-decimal units).
     */
    function depositNative(uint256 minWbtcOut) public payable nonReentrant {
        require(msg.value > 0, "WF: zero native");
        require(minWbtcOut > 0, "WF: zero min out");
        require(nativeFee > 0, "WF: native fee not set");
        require(nativeUsdtFee > 0, "WF: native usdt fee not set");

        _updateYield(msg.sender);

        // 1. Wrap the addresses in V4's Currency type
        Currency wcelo = Currency.wrap(
            0x471EcE3750Da237f93B8E339c536989b8978a438
        );
        Currency usdtCurrency = Currency.wrap(address(usdt));
        Currency wbtcCurrency = Currency.wrap(address(wbtc));

        // 2. Approve the V4 Swap Router
        // Note: Because CELO is inherently ERC20, standard approval works
        IERC20(Currency.unwrap(wcelo)).approve(
            address(swapRouter),
            type(uint256).max
        );

        uint256 celoBal = IERC20(Currency.unwrap(wcelo)).balanceOf(
            address(this)
        );

        // 3. Encode the V4 Path
        // V4 Paths require: Token -> Fee -> TickSpacing -> Hook -> Token
        bytes memory v4SwapPath = abi.encodePacked(
            wcelo,
            nativeUsdtFee,
            nativeUsdtTickSpacing,
            nativeUsdtHook,
            usdtCurrency,
            poolFee,
            poolTickSpacing,
            poolHook,
            wbtcCurrency
        );

        // 4. Execute the V4 Swap
        uint256 wbtcReceived = swapRouter.exactInput(
            swapRouter.ExactInputParams({
                path: v4SwapPath,
                recipient: address(this),
                amountIn: celoBal,
                amountOutMinimum: minWbtcOut // Use the passed minimum to prevent sandwich attacks!
            })
        );

        UserInfo storage user = userInfo[msg.sender];
        user.activeHashrate += wbtcReceived;
        user.totalDeposited += wbtcReceived;
        totalPoolHashrate += wbtcReceived;
        user.lastUpdateTimestamp = block.timestamp;

        emit NativeDeposited(msg.sender, msg.value, wbtcReceived);
    }

    /// @notice Accept plain native token transfers (e.g. refunds from the router).
    receive() external payable {
        depositNative(1);
    }

    /// @notice Withdraw WBTC principal. Yield is synced but NOT auto-claimed.
    function withdraw(uint256 wbtcAmount) external nonReentrant {
        require(wbtcAmount > 0, "WF: zero amount");

        _updateYield(msg.sender);

        UserInfo storage user = userInfo[msg.sender];
        require(user.activeHashrate >= wbtcAmount, "WF: insufficient hashrate");
        require(
            wbtc.balanceOf(address(this)) >= wbtcAmount,
            "WF: pool low WBTC"
        );

        user.activeHashrate -= wbtcAmount;
        totalPoolHashrate -= wbtcAmount;

        wbtc.safeTransfer(msg.sender, wbtcAmount);
        emit UserWithdrawn(msg.sender, wbtcAmount);
    }

    /**
     * @notice Claim all accrued yield.
     *         A) prefersWSND == true                         -> pay in WSND.
     *         B) prefersWSND == false AND pool WBTC < reward -> fallback to WSND.
     *         C) prefersWSND == false AND pool WBTC >= reward -> pay in WBTC.
     */
    function claim() external nonReentrant {
        _updateYield(msg.sender);

        UserInfo storage user = userInfo[msg.sender];
        uint256 rewards = user.pendingRewards;
        require(rewards > 0, "WF: nothing to claim");

        user.pendingRewards = 0;

        bool usedFallback;
        uint256 wsndPaid;

        if (user.prefersWSND) {
            wsndPaid = _wbtcToWsnd(rewards);
            require(
                wsnd.balanceOf(address(this)) >= wsndPaid,
                "WF: insufficient WSND"
            );
            user.totalWsndClaimed += wsndPaid;
            wsnd.safeTransfer(msg.sender, wsndPaid);
        } else if (wbtc.balanceOf(address(this)) < rewards) {
            wsndPaid = _wbtcToWsnd(rewards);
            require(
                wsnd.balanceOf(address(this)) >= wsndPaid,
                "WF: insufficient WSND fallback"
            );
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

    /// @notice Total pending yield for `account` (accrued + unclaimed), in WBTC units.
    function getPendingYield(address account) external view returns (uint256) {
        UserInfo storage user = userInfo[account];
        return
            user.pendingRewards +
            _calculateYield(user.activeHashrate, user.lastUpdateTimestamp);
    }

    /// @notice Return the full UserInfo struct for `account`.
    function getUserInfo(
        address account
    ) external view returns (UserInfo memory) {
        return userInfo[account];
    }

    // ---------------------------------------------------------
    //                     INTERNAL HELPERS
    // ---------------------------------------------------------

    function _calculateYield(
        uint256 activeHashrate,
        uint256 lastUpdateTimestamp
    ) internal view returns (uint256 accrued) {
        if (activeHashrate == 0 || lastUpdateTimestamp == 0) return 0;
        if (block.timestamp <= lastUpdateTimestamp) return 0;
        uint256 timeElapsed = block.timestamp - lastUpdateTimestamp;
        accrued =
            (activeHashrate * YIELD_RATE_NUM * timeElapsed) /
            (YIELD_RATE_DEN * PERIOD_30_DAYS);
    }

    function _updateYield(address account) internal {
        UserInfo storage user = userInfo[account];
        if (user.activeHashrate > 0 && user.lastUpdateTimestamp > 0) {
            uint256 accrued = _calculateYield(
                user.activeHashrate,
                user.lastUpdateTimestamp
            );
            if (accrued > 0) user.pendingRewards += accrued;
        }
        user.lastUpdateTimestamp = block.timestamp;
    }

    function _wbtcToWsnd(uint256 wbtcAmount) internal view returns (uint256) {
        return (wbtcAmount * wsndPerWbtc) / WBTC_UNIT;
    }
}
