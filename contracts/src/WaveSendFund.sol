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

// =============================================================
//               Custom V4 Router Wrapper Interface
// =============================================================
interface IV4RouterMock {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline; 
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /// @notice Swaps `amountIn` using a V4-encoded packed path
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

// =============================================================
//                     WAVESEND FUND CONTRACT
// =============================================================

/**
 * @title  WaveSendFund
 * @author Senior Smart Contract Developer
 * @notice A UUPS-upgradeable DeFi Mining Pool on Celo Mainnet operated by Wavesend.
 *
 * Role architecture:
 * DEFAULT_ADMIN_ROLE  -- can grant/revoke all roles; assigned to deployer.
 * OPERATOR_ROLE       -- admin setters (fee, router, ratio) + operationalWithdraw.
 * UPGRADER_ROLE       -- authorises UUPS proxy upgrades.
 *
 * Yield formula (linear, per second):
 * pendingRewards = (activeHashrate x 100 x timeElapsed) / (10_000 x 2_592_000)
 *
 * Decimals:
 * USDT  -- 6  decimals  (Celo bridged USDT)
 * WBTC  -- 8  decimals  (Celo bridged WBTC)
 * WSND  -- 18 decimals  (Wave Send Token)
 *
 * OZ v5 notes:
 * - AccessControlUpgradeable replaces OwnableUpgradeable.
 * - ReentrancyGuard used.
 * - __UUPSUpgradeable_init() removed in OZ v5.
 * - safeApprove removed in OZ v5 -- forceApprove used instead.
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
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Authorises UUPS proxy upgrades.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

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

    IERC20        public usdt;
    IERC20        public wbtc;
    IERC20        public wsnd;
    IV4RouterMock public swapRouter;

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
        swapRouter  = IV4RouterMock(_router);

        poolFee               = _poolFee;
        poolTickSpacing       = _poolTickSpacing;
        nativeFee             = _nativeFee;
        nativeUsdtFee         = _nativeUsdtFee;
        nativeUsdtTickSpacing = _nativeUsdtTickSpacing;

        wsndPerWbtc = WSND_UNIT; // default 1:1 
    }

    // ---------------------------------------------------------
    //                     UUPS AUTHORISATION
    // ---------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    // ---------------------------------------------------------
    //                       ADMIN SETTERS
    // ---------------------------------------------------------

    function setWsndPerWbtc(uint256 _wsndPerWbtc) external onlyRole(OPERATOR_ROLE) {
        require(_wsndPerWbtc > 0, "WF: ratio zero");
        wsndPerWbtc = _wsndPerWbtc;
        emit WsndRatioUpdated(_wsndPerWbtc);
    }

    function setPoolFee(uint24 _poolFee) external onlyRole(OPERATOR_ROLE) {
        poolFee = _poolFee;
        emit PoolFeeUpdated(_poolFee);
    }

    function setSwapRouter(address _router) external onlyRole(OPERATOR_ROLE) {
        require(_router != address(0), "WF: zero router");
        swapRouter = IV4RouterMock(_router);
        emit RouterUpdated(_router);
    }

    function setNativeFee(uint24 _nativeFee) external onlyRole(OPERATOR_ROLE) {
        nativeFee = _nativeFee;
        emit NativeFeeUpdated(_nativeFee);
    }

    function setNativeUsdtFee(uint24 _nativeUsdtFee) external onlyRole(OPERATOR_ROLE) {
        nativeUsdtFee = _nativeUsdtFee;
        emit NativeUsdtFeeUpdated(_nativeUsdtFee);
    }

    // ---------------------------------------------------------
    //              COMPANY LIQUIDITY FUNCTIONS
    // ---------------------------------------------------------

    function fundDeposit(address token, uint256 amount) external nonReentrant {
        require(token  != address(0), "WF: zero token");
        require(amount > 0,           "WF: zero amount");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit FundDeposited(token, amount, msg.sender);
    }

    function operationalWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) external nonReentrant onlyRole(OPERATOR_ROLE) {
        require(token     != address(0), "WF: zero token");
        require(amount    > 0,           "WF: zero amount");
        require(recipient != address(0), "WF: zero recipient");

        WithdrawWindow storage window = withdrawWindows[token];

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

        Currency usdtCurrency = Currency.wrap(address(usdt));
        Currency wbtcCurrency = Currency.wrap(address(wbtc));

        bytes memory path = abi.encodePacked(
            usdtCurrency,
            poolFee,
            poolTickSpacing,
            poolHook,
            wbtcCurrency
        );

        uint256 wbtcReceived = swapRouter.exactInput(
            IV4RouterMock.ExactInputParams({
                path:             path,
                recipient:        address(this),
                deadline:         block.timestamp,
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

    function depositNative(uint256 minWbtcOut) public payable nonReentrant {
        require(msg.value  > 0, "WF: zero native");
        require(minWbtcOut > 0, "WF: zero min out");
        require(nativeFee     > 0, "WF: native fee not set");
        require(nativeUsdtFee > 0, "WF: native usdt fee not set");

        _updateYield(msg.sender);

        address celoToken = 0x471EcE3750Da237f93B8E339c536989b8978a438;
        uint256 celoAmountIn = msg.value;

        IERC20(celoToken).forceApprove(address(swapRouter), celoAmountIn);

        Currency celoCurrency = Currency.wrap(celoToken);
        Currency usdtCurrency = Currency.wrap(address(usdt));
        Currency wbtcCurrency = Currency.wrap(address(wbtc));

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

        uint256 wbtcReceived = swapRouter.exactInput(
            IV4RouterMock.ExactInputParams({
                path:             path,
                recipient:        address(this),
                deadline:         block.timestamp,
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

    receive() external payable {}

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

    function claimRewards() external nonReentrant {
        _updateYield(msg.sender);

        UserInfo storage user = userInfo[msg.sender];
        uint256 pending = user.pendingRewards;
        require(pending > 0, "WF: nothing to claim");

        user.pendingRewards = 0;

        bool useWsnd      = user.prefersWSND;
        bool usedFallback = false;

        if (!useWsnd && wbtc.balanceOf(address(this)) < pending) {
            useWsnd      = true;
            usedFallback = true;
        }

        uint256 wsndPaid = 0;
        if (useWsnd) {
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
