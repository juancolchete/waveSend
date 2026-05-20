// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

// ── OpenZeppelin proxy utilities ───────────────────────────────────────────────
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// ── Contract under test ────────────────────────────────────────────────────────
import {WaveSendFund, IV4RouterMock} from "../src/WaveSendFund.sol";

// =============================================================================
//                          MOCK TOKENS
// =============================================================================

/// @dev Generic mintable ERC-20 used for USDT (6 dec), WBTC (8 dec), WSND (18 dec).
contract MockERC20 is Test {
    string  public name;
    string  public symbol;
    uint8   public decimals;
    uint256 public totalSupply;

    mapping(address => uint256)                     public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name     = _name;
        symbol   = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply    += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply      -= amount;
        emit Transfer(from, address(0), amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "MockERC20: allowance");
        allowance[from][msg.sender] -= amount;
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        require(balanceOf[from] >= amount, "MockERC20: balance");
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

// =============================================================================
//                          MOCK SWAP ROUTER
// =============================================================================

contract MockSwapRouter is IV4RouterMock {
    uint256   public wbtcOut;
    uint256   public wbtcOutNative;
    MockERC20 public usdtToken;
    MockERC20 public wbtcToken;

    constructor(address _usdt, address _wbtc) { 
        usdtToken = MockERC20(_usdt);
        wbtcToken = MockERC20(_wbtc);
    }

    function setWbtcOut(uint256 _wbtcOut) external { wbtcOut = _wbtcOut; }
    function setWbtcOutNative(uint256 _wbtcOut) external { wbtcOutNative = _wbtcOut; }

    function exactInput(IV4RouterMock.ExactInputParams calldata params)
        external payable override returns (uint256 amountOut)
    {
        if (msg.value == 0) {
            // USDT deposit -> WBTC
            usdtToken.transferFrom(msg.sender, address(this), params.amountIn);
            require(wbtcOut >= params.amountOutMinimum, "MockRouter: slippage");
            wbtcToken.mint(params.recipient, wbtcOut);
            return wbtcOut;
        } else {
            // Native CELO deposit -> USDT -> WBTC
            require(msg.value == params.amountIn,              "MockRouter: value mismatch");
            require(wbtcOutNative >= params.amountOutMinimum,  "MockRouter: native slippage");
            wbtcToken.mint(params.recipient, wbtcOutNative);
            return wbtcOutNative;
        }
    }
}

// =============================================================================
//                       MALICIOUS REENTRANCY ATTACKER
// =============================================================================

/// @dev Attempts re-entry on claimRewards().
contract ReentrancyAttacker {
    WaveSendFund public fund;
    uint256 public attackCount;
    
    constructor(address _fund) {
        fund = WaveSendFund(_fund);
    }

    // Fallback triggered when WBTC/WSND is transferred to this address.
    receive() external payable {
        if (attackCount < 1) {
            attackCount++;
            fund.claimRewards();
        }
    }

    fallback() external payable {}
}

// =============================================================================
//                           BASE TEST FIXTURE
// =============================================================================

abstract contract WaveSendFundBase is Test {
    // ── Actors ─────────────────────────────────────────────────────────────────
    address internal admin    = makeAddr("admin");
    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal treasury = makeAddr("treasury");

    // ── Tokens ─────────────────────────────────────────────────────────────────
    MockERC20 internal usdtToken;
    MockERC20 internal wbtcToken;
    MockERC20 internal wsndToken;

    // ── Infrastructure ─────────────────────────────────────────────────────────
    MockSwapRouter   internal router;
    WaveSendFund     internal fund;    // proxy

    // ── Constants mirrored from contract ───────────────────────────────────────
    uint256 internal constant PERIOD            = 2_592_000; // 30 days
    uint256 internal constant WBTC_UNIT         = 1e8;
    uint256 internal constant WSND_UNIT         = 1e18;
    uint24  internal constant POOL_FEE          = 500;
    uint24  internal constant NATIVE_FEE        = 3000;
    uint24  internal constant NATIVE_USDT_FEE   = 3000;

    // ── Useful amounts ─────────────────────────────────────────────────────────
    uint256 internal constant USDT_1K     = 1_000e6;  // 1 000 USDT
    uint256 internal constant WBTC_1      = 1e8;      // 1 WBTC
    uint256 internal constant WSND_LARGE  = 1_000e18; // 1 000 WSND reserve

    function setUp() public virtual {
        // Deploy tokens.
        usdtToken = new MockERC20("Celo USDT", "USDT", 6);
        wbtcToken = new MockERC20("Celo WBTC", "WBTC", 8);
        wsndToken = new MockERC20("WaveSend",  "WSND", 18);

        // Deploy mock router.
        router = new MockSwapRouter(address(usdtToken), address(wbtcToken));

        // Deploy WaveSendFund behind a UUPS proxy.
        WaveSendFund impl = new WaveSendFund();
        
        WaveSendFund.InitParams memory initParams = WaveSendFund.InitParams({
            admin: admin,
            usdt: address(usdtToken),
            wbtc: address(wbtcToken),
            wsnd: address(wsndToken),
            router: address(router),
            poolFee: POOL_FEE,
            poolTickSpacing: 60,
            nativeFee: NATIVE_FEE,
            nativeUsdtFee: NATIVE_USDT_FEE,
            nativeUsdtTickSpacing: 60
        });

        bytes memory initData = abi.encodeCall(WaveSendFund.initialize, (initParams));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        fund = WaveSendFund(payable(address(proxy)));

        // Seed WSND and WBTC reserves in the pool (company pre-fund).
        wsndToken.mint(address(fund), WSND_LARGE);
        wbtcToken.mint(address(fund), 10 * WBTC_1);

        // Give users USDT and approve the pool.
        usdtToken.mint(alice, 10 * USDT_1K);
        usdtToken.mint(bob,   10 * USDT_1K);

        vm.prank(alice);
        usdtToken.approve(address(fund), type(uint256).max);

        vm.prank(bob);
        usdtToken.approve(address(fund), type(uint256).max);

        // Default router: 1 000 USDT → 1 WBTC.
        router.setWbtcOut(WBTC_1);
        router.setWbtcOutNative(WBTC_1);
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────

    /// Deposit 1 000 USDT as `user`, receiving 1 WBTC hashrate.
    function _deposit(address user) internal {
        vm.prank(user);
        fund.deposit(USDT_1K, 1);
    }

    /// Advance time by `seconds_` and mine a block.
    function _skip(uint256 seconds_) internal {
        skip(seconds_);
    }

    /// Expected yield (WBTC) after `elapsed` seconds for `hashrate` WBTC.
    function _expectedYield(uint256 hashrate, uint256 elapsed) internal pure returns (uint256) {
        return (hashrate * 100 * elapsed) / (10_000 * PERIOD);
    }

    /// Expected WSND for a given WBTC reward at 1:1 face value.
    function _wbtcToWsnd(uint256 wbtcAmt) internal pure returns (uint256) {
        return (wbtcAmt * WSND_UNIT) / WBTC_UNIT;
    }
}

// =============================================================================
//  SECTION 1 – INITIALIZER
// =============================================================================

contract WaveSendFund_Initialize is WaveSendFundBase {

    function test_initialize_setsTokenAddresses() public view {
        assertEq(address(fund.usdt()), address(usdtToken));
        assertEq(address(fund.wbtc()), address(wbtcToken));
        assertEq(address(fund.wsnd()), address(wsndToken));
    }

    function test_initialize_setsAdminRole() public view {
        assertTrue(fund.hasRole(fund.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_initialize_setsDefaultWsndRatio() public view {
        assertEq(fund.wsndPerWbtc(), WSND_UNIT);
    }

    function test_initialize_setsPoolFee() public view {
        assertEq(fund.poolFee(), POOL_FEE);
    }

    function test_initialize_revertsOnDoubleInit() public {
        vm.expectRevert();
        WaveSendFund.InitParams memory params = WaveSendFund.InitParams({
            admin: admin, usdt: address(usdtToken), wbtc: address(wbtcToken),
            wsnd: address(wsndToken), router: address(router), poolFee: POOL_FEE,
            poolTickSpacing: 60, nativeFee: NATIVE_FEE, nativeUsdtFee: NATIVE_USDT_FEE, nativeUsdtTickSpacing: 60
        });
        fund.initialize(params);
    }

    function test_initialize_revertsZeroAdmin() public {
        WaveSendFund impl2 = new WaveSendFund();
        WaveSendFund.InitParams memory params = WaveSendFund.InitParams({
            admin: address(0), usdt: address(usdtToken), wbtc: address(wbtcToken),
            wsnd: address(wsndToken), router: address(router), poolFee: POOL_FEE,
            poolTickSpacing: 60, nativeFee: NATIVE_FEE, nativeUsdtFee: NATIVE_USDT_FEE, nativeUsdtTickSpacing: 60
        });
        bytes memory data = abi.encodeCall(WaveSendFund.initialize, (params));
        vm.expectRevert("WF: zero admin");
        new ERC1967Proxy(address(impl2), data);
    }

    function test_initialize_revertsZeroUsdt() public {
        WaveSendFund impl2 = new WaveSendFund();
        WaveSendFund.InitParams memory params = WaveSendFund.InitParams({
            admin: admin, usdt: address(0), wbtc: address(wbtcToken),
            wsnd: address(wsndToken), router: address(router), poolFee: POOL_FEE,
            poolTickSpacing: 60, nativeFee: NATIVE_FEE, nativeUsdtFee: NATIVE_USDT_FEE, nativeUsdtTickSpacing: 60
        });
        bytes memory data = abi.encodeCall(WaveSendFund.initialize, (params));
        vm.expectRevert("WF: zero USDT");
        new ERC1967Proxy(address(impl2), data);
    }
}

// =============================================================================
//  SECTION 2 – ADMIN SETTERS
// =============================================================================

contract WaveSendFund_AdminSetters is WaveSendFundBase {

    function test_setWsndPerWbtc_updatesRatio() public {
        vm.prank(admin);
        fund.setWsndPerWbtc(2e18);
        assertEq(fund.wsndPerWbtc(), 2e18);
    }

    function test_setWsndPerWbtc_emitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit WaveSendFund.WsndRatioUpdated(2e18);
        fund.setWsndPerWbtc(2e18);
    }

    function test_setWsndPerWbtc_revertsZero() public {
        vm.prank(admin);
        vm.expectRevert("WF: ratio zero");
        fund.setWsndPerWbtc(0);
    }

    function test_setWsndPerWbtc_revertsNonOperator() public {
        vm.prank(alice);
        vm.expectRevert();
        fund.setWsndPerWbtc(2e18);
    }

    function test_setPoolFee_updates() public {
        vm.prank(admin);
        fund.setPoolFee(3000);
        assertEq(fund.poolFee(), 3000);
    }

    function test_setPoolFee_revertsNonOperator() public {
        vm.prank(alice);
        vm.expectRevert();
        fund.setPoolFee(3000);
    }

    function test_setSwapRouter_updates() public {
        address newRouter = makeAddr("newRouter");
        vm.prank(admin);
        fund.setSwapRouter(newRouter);
        assertEq(address(fund.swapRouter()), newRouter);
    }

    function test_setSwapRouter_revertsZero() public {
        vm.prank(admin);
        vm.expectRevert("WF: zero router");
        fund.setSwapRouter(address(0));
    }

    function test_setSwapRouter_revertsNonOperator() public {
        vm.prank(alice);
        vm.expectRevert();
        fund.setSwapRouter(makeAddr("x"));
    }
}

// =============================================================================
//  SECTION 3 – DEPOSIT (user)
// =============================================================================

contract WaveSendFund_Deposit is WaveSendFundBase {

    function test_deposit_creditsHashrate() public {
        _deposit(alice);
        (uint256 hashrate,,,,,, ) = fund.userInfo(alice);
        assertEq(hashrate, WBTC_1);
    }

    function test_deposit_updatesTotalPoolHashrate() public {
        _deposit(alice);
        assertEq(fund.totalPoolHashrate(), WBTC_1);
    }

    function test_deposit_updatesTotalDeposited() public {
        _deposit(alice);
        (, uint256 totalDep,,,,,) = fund.userInfo(alice);
        assertEq(totalDep, WBTC_1);
    }

    function test_deposit_setsLastUpdateTimestamp() public {
        uint256 before = block.timestamp;
        _deposit(alice);
        (,,,,,uint256 ts,) = fund.userInfo(alice);
        assertEq(ts, before);
    }

    function test_deposit_emitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit WaveSendFund.UserDeposited(alice, USDT_1K, WBTC_1);
        fund.deposit(USDT_1K, 1);
    }

    function test_deposit_revertsZeroUsdt() public {
        vm.prank(alice);
        vm.expectRevert("WF: zero USDT");
        fund.deposit(0, 1);
    }

    function test_deposit_revertsZeroMinOut() public {
        vm.prank(alice);
        vm.expectRevert("WF: zero min out");
        fund.deposit(USDT_1K, 0);
    }

    function test_deposit_revertsSlippage() public {
        router.setWbtcOut(0); // router will underflow the minOut check
        vm.prank(alice);
        vm.expectRevert("MockRouter: slippage");
        fund.deposit(USDT_1K, WBTC_1);
    }

    function test_deposit_multipleDeposits_accumulatesHashrate() public {
        _deposit(alice);
        _skip(PERIOD / 2);
        _deposit(alice); // second deposit must snapshot yield first
        (uint256 hashrate,,,,,, ) = fund.userInfo(alice);
        assertEq(hashrate, 2 * WBTC_1);
    }

    function test_deposit_multipleDeposits_snapshotsPendingYield() public {
        _deposit(alice);
        _skip(PERIOD);
        _deposit(alice);
        (,,,, uint256 pending,,) = fund.userInfo(alice);
        // 1 month of yield on 1 WBTC = 1% = 0.01 WBTC = 1_000_000 (8 dec)
        assertApproxEqAbs(pending, 1_000_000, 10);
    }

    function test_deposit_twoUsers_independentHashrates() public {
        _deposit(alice);
        router.setWbtcOut(2 * WBTC_1);
        vm.prank(bob);
        fund.deposit(USDT_1K, 1);

        (uint256 hA,,,,,, ) = fund.userInfo(alice);
        (uint256 hB,,,,,, ) = fund.userInfo(bob);
        assertEq(hA, WBTC_1);
        assertEq(hB, 2 * WBTC_1);
        assertEq(fund.totalPoolHashrate(), 3 * WBTC_1);
    }
}

// =============================================================================
//  SECTION 4 – WITHDRAW (user)
// =============================================================================

contract WaveSendFund_Withdraw is WaveSendFundBase {

    function setUp() public override {
        super.setUp();
        _deposit(alice);
    }

    function test_withdraw_reducesHashrate() public {
        vm.prank(alice);
        fund.withdraw(WBTC_1);
        (uint256 hashrate,,,,,, ) = fund.userInfo(alice);
        assertEq(hashrate, 0);
    }

    function test_withdraw_reducesTotalPoolHashrate() public {
        vm.prank(alice);
        fund.withdraw(WBTC_1);
        assertEq(fund.totalPoolHashrate(), 0);
    }

    function test_withdraw_transfersWbtc() public {
        uint256 before = wbtcToken.balanceOf(alice);
        vm.prank(alice);
        fund.withdraw(WBTC_1);
        assertEq(wbtcToken.balanceOf(alice), before + WBTC_1);
    }

    function test_withdraw_emitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit WaveSendFund.UserWithdrawn(alice, WBTC_1);
        fund.withdraw(WBTC_1);
    }

    function test_withdraw_syncsYieldBeforeReducing() public {
        _skip(PERIOD);
        vm.prank(alice);
        fund.withdraw(WBTC_1);
        (,,,, uint256 pending,,) = fund.userInfo(alice);
        assertApproxEqAbs(pending, 1_000_000, 10);
    }

    function test_withdraw_revertsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert("WF: zero amount");
        fund.withdraw(0);
    }

    function test_withdraw_revertsInsufficientHashrate() public {
        vm.prank(alice);
        vm.expectRevert("WF: insufficient hashrate");
        fund.withdraw(WBTC_1 + 1);
    }

    function test_withdraw_partialWithdraw() public {
        vm.prank(alice);
        fund.withdraw(WBTC_1 / 2);
        (uint256 hashrate,,,,,, ) = fund.userInfo(alice);
        assertEq(hashrate, WBTC_1 / 2);
    }
}

// =============================================================================
//  SECTION 5 – YIELD ACCRUAL
// =============================================================================

contract WaveSendFund_YieldAccrual is WaveSendFundBase {

    function setUp() public override {
        super.setUp();
        _deposit(alice);
    }

    function test_getPendingYield_zeroBeforeTimeElapsed() public view {
        uint256 pending = fund.pendingRewardsOf(alice);
        assertEq(pending, 0);
    }

    function test_getPendingYield_after30Days() public {
        _skip(PERIOD);
        uint256 pending
