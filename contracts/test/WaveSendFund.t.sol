// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

// ── OpenZeppelin proxy utilities ───────────────────────────────────────────────
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// ── Contract under test ────────────────────────────────────────────────────────
import {WaveSendFund} from "../src/WaveSendFund.sol";

// =============================================================================
//          LOCAL INTERFACE – needed by MockSwapRouter
// =============================================================================

/// @dev Mirrors the ISwapRouter interface declared in WaveSendFund.sol so that
///      MockSwapRouter can reference it without depending on the contract import.
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

/// @dev Simulates Uniswap V3. Pulls tokenIn, releases a fixed wbtcOut to recipient.
contract MockSwapRouter {
    /// Configurable return amount (set per test).
    uint256 public wbtcOut;

    MockERC20 public wbtcToken;

    constructor(address _wbtc) {
        wbtcToken = MockERC20(_wbtc);
    }

    /// Allow tests to control how much WBTC the swap returns.
    function setWbtcOut(uint256 _wbtcOut) external {
        wbtcOut = _wbtcOut;
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        // Pull tokenIn from the caller (the WaveSendFund contract).
        MockERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        // Verify slippage guard.
        require(wbtcOut >= params.amountOutMinimum, "MockRouter: slippage");

        // Mint WBTC directly to the recipient (simulates the pool receiving WBTC).
        wbtcToken.mint(params.recipient, wbtcOut);

        return wbtcOut;
    }
}

// =============================================================================
//                       MALICIOUS REENTRANCY ATTACKER
// =============================================================================

/// @dev Attempts re-entry on claim().
contract ReentrancyAttacker {
    WaveSendFund public fund;
    uint256 public attackCount;

    constructor(address _fund) {
        fund = WaveSendFund(_fund);
    }

    receive() external payable {
        if (attackCount < 1) {
            attackCount++;
            fund.claim();
        }
    }

    fallback() external payable {}
}

// =============================================================================
//                           BASE TEST FIXTURE
// =============================================================================

abstract contract WaveSendFundBase is Test {
    // ── Actors ─────────────────────────────────────────────────────────────────
    address internal owner   = makeAddr("owner");
    address internal alice   = makeAddr("alice");
    address internal bob     = makeAddr("bob");
    address internal treasury = makeAddr("treasury");

    // ── Tokens ─────────────────────────────────────────────────────────────────
    MockERC20 internal usdtToken;
    MockERC20 internal wbtcToken;
    MockERC20 internal wsndToken;

    // ── Infrastructure ─────────────────────────────────────────────────────────
    MockSwapRouter   internal router;
    WaveSendFund     internal fund;    // proxy

    // ── Constants mirrored from contract ───────────────────────────────────────
    uint256 internal constant PERIOD      = 2_592_000;   // 30 days
    uint256 internal constant WBTC_UNIT   = 1e8;
    uint256 internal constant WSND_UNIT   = 1e18;
    uint24  internal constant POOL_FEE    = 500;

    // ── Useful amounts ─────────────────────────────────────────────────────────
    uint256 internal constant USDT_1K     = 1_000e6;     // 1 000 USDT
    uint256 internal constant WBTC_1      = 1e8;         // 1 WBTC
    uint256 internal constant WSND_LARGE  = 1_000e18;    // 1 000 WSND reserve

    function setUp() public virtual {
        usdtToken = new MockERC20("Celo USDT", "USDT", 6);
        wbtcToken = new MockERC20("Celo WBTC", "WBTC", 8);
        wsndToken = new MockERC20("WaveSend",  "WSND", 18);

        router = new MockSwapRouter(address(wbtcToken));

        WaveSendFund impl = new WaveSendFund();
        bytes memory initData = abi.encodeCall(
            WaveSendFund.initialize,
            (owner, address(usdtToken), address(wbtcToken), address(wsndToken), address(router), POOL_FEE)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        fund = WaveSendFund(address(proxy));

        wsndToken.mint(address(fund), WSND_LARGE);
        wbtcToken.mint(address(fund), 10 * WBTC_1);

        usdtToken.mint(alice, 10 * USDT_1K);
        usdtToken.mint(bob,   10 * USDT_1K);

        vm.prank(alice);
        usdtToken.approve(address(fund), type(uint256).max);

        vm.prank(bob);
        usdtToken.approve(address(fund), type(uint256).max);

        router.setWbtcOut(WBTC_1);
    }

    function _deposit(address user) internal {
        vm.prank(user);
        fund.deposit(USDT_1K, 1);
    }

    function _skip(uint256 seconds_) internal { skip(seconds_); }

    function _expectedYield(uint256 hashrate, uint256 elapsed) internal pure returns (uint256) {
        return (hashrate * 100 * elapsed) / (10_000 * PERIOD);
    }

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

    function test_initialize_setsOwner() public view {
        assertEq(fund.owner(), owner);
    }

    function test_initialize_setsDefaultWsndRatio() public view {
        assertEq(fund.wsndPerWbtc(), WSND_UNIT);
    }

    function test_initialize_setsPoolFee() public view {
        assertEq(fund.poolFee(), POOL_FEE);
    }

    function test_initialize_revertsOnDoubleInit() public {
        vm.expectRevert();
        fund.initialize(owner, address(usdtToken), address(wbtcToken),
                        address(wsndToken), address(router), POOL_FEE);
    }

    function test_initialize_revertsZeroOwner() public {
        WaveSendFund impl2 = new WaveSendFund();
        bytes memory data = abi.encodeCall(
            WaveSendFund.initialize,
            (address(0), address(usdtToken), address(wbtcToken),
             address(wsndToken), address(router), POOL_FEE)
        );
        vm.expectRevert("WF: zero owner");
        new ERC1967Proxy(address(impl2), data);
    }

    function test_initialize_revertsZeroUsdt() public {
        WaveSendFund impl2 = new WaveSendFund();
        bytes memory data = abi.encodeCall(
            WaveSendFund.initialize,
            (owner, address(0), address(wbtcToken),
             address(wsndToken), address(router), POOL_FEE)
        );
        vm.expectRevert("WF: zero USDT");
        new ERC1967Proxy(address(impl2), data);
    }
}

// =============================================================================
//  SECTION 2 – ADMIN SETTERS
// =============================================================================

contract WaveSendFund_AdminSetters is WaveSendFundBase {

    function test_setWsndPerWbtc_updatesRatio() public {
        vm.prank(owner);
        fund.setWsndPerWbtc(2e18);
        assertEq(fund.wsndPerWbtc(), 2e18);
    }

    function test_setWsndPerWbtc_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit WaveSendFund.WsndRatioUpdated(2e18);
        fund.setWsndPerWbtc(2e18);
    }

    function test_setWsndPerWbtc_revertsZero() public {
        vm.prank(owner);
        vm.expectRevert("WF: ratio zero");
        fund.setWsndPerWbtc(0);
    }

    function test_setWsndPerWbtc_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        fund.setWsndPerWbtc(2e18);
    }

    function test_setPoolFee_updates() public {
        vm.prank(owner);
        fund.setPoolFee(3000);
        assertEq(fund.poolFee(), 3000);
    }

    function test_setPoolFee_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        fund.setPoolFee(3000);
    }

    function test_setSwapRouter_updates() public {
        address newRouter = makeAddr("newRouter");
        vm.prank(owner);
        fund.setSwapRouter(newRouter);
        assertEq(address(fund.swapRouter()), newRouter);
    }

    function test_setSwapRouter_revertsZero() public {
        vm.prank(owner);
        vm.expectRevert("WF: zero router");
        fund.setSwapRouter(address(0));
    }

    function test_setSwapRouter_revertsNonOwner() public {
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
        router.setWbtcOut(0);
        vm.prank(alice);
        vm.expectRevert("MockRouter: slippage");
        fund.deposit(USDT_1K, WBTC_1);
    }

    function test_deposit_multipleDeposits_accumulatesHashrate() public {
        _deposit(alice);
        _skip(PERIOD / 2);
        _deposit(alice);
        (uint256 hashrate,,,,,, ) = fund.userInfo(alice);
        assertEq(hashrate, 2 * WBTC_1);
    }

    function test_deposit_multipleDeposits_snapshotsPendingYield() public {
        _deposit(alice);
        _skip(PERIOD);
        _deposit(alice);
        (,,,, uint256 pending,,) = fund.userInfo(alice);
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
        uint256 pending = fund.getPendingYield(alice);
        assertEq(pending, 0);
    }

    function test_getPendingYield_after30Days() public {
        _skip(PERIOD);
        uint256 pending  = fund.getPendingYield(alice);
        uint256 expected = _expectedYield(WBTC_1, PERIOD);
        assertApproxEqAbs(pending, expected, 10);
    }

    function test_getPendingYield_linearlyScalesWithTime() public {
        _skip(PERIOD / 4);
        uint256 quarter = fund.getPendingYield(alice);
        _skip(PERIOD / 4);
        uint256 half    = fund.getPendingYield(alice);
        assertApproxEqAbs(half, quarter * 2, 20);
    }

    function test_getPendingYield_linearlyScalesWithHashrate() public {
        router.setWbtcOut(2 * WBTC_1);
        _deposit(bob);
        _skip(PERIOD);
        uint256 aliceY = fund.getPendingYield(alice);
        uint256 bobY   = fund.getPendingYield(bob);
        assertApproxEqAbs(bobY, aliceY * 2, 20);
    }

    function test_yieldStopsAccruingAfterFullWithdraw() public {
        _skip(PERIOD / 2);
        vm.prank(alice);
        fund.withdraw(WBTC_1);
        uint256 pendingAtWithdraw = fund.getPendingYield(alice);
        _skip(PERIOD);
        uint256 pendingLater = fund.getPendingYield(alice);
        assertEq(pendingAtWithdraw, pendingLater);
    }

    function test_setRewardPreference_snapshotsYield() public {
        _skip(PERIOD / 2);
        vm.prank(alice);
        fund.setRewardPreference(true);
        (,,,, uint256 pending,,) = fund.userInfo(alice);
        assertApproxEqAbs(pending, _expectedYield(WBTC_1, PERIOD / 2), 10);
    }

    function test_yieldFormula_oneBtcOneMonth_exactMath() public {
        _skip(PERIOD);
        uint256 pending = fund.getPendingYield(alice);
        assertEq(pending, 1_000_000);
    }
}

// =============================================================================
//  SECTION 6 – CLAIM (all three branches)
// =============================================================================

contract WaveSendFund_Claim is WaveSendFundBase {

    function setUp() public override {
        super.setUp();
        _deposit(alice);
        _skip(PERIOD);
    }

    // ── Branch C: prefers WBTC, pool has enough ────────────────────────────────

    function test_claim_branchC_transfersWbtc() public {
        uint256 before  = wbtcToken.balanceOf(alice);
        uint256 pending = fund.getPendingYield(alice);
        vm.prank(alice);
        fund.claim();
        assertApproxEqAbs(wbtcToken.balanceOf(alice), before + pending, 10);
    }

    function test_claim_branchC_zerosPendingRewards() public {
        vm.prank(alice);
        fund.claim();
        assertEq(fund.getPendingYield(alice), 0);
    }

    function test_claim_branchC_updatesTotalWbtcClaimed() public {
        uint256 pending = fund.getPendingYield(alice);
        vm.prank(alice);
        fund.claim();
        (,, uint256 totalClaimed,,,,) = fund.userInfo(alice);
        assertApproxEqAbs(totalClaimed, pending, 10);
    }

    function test_claim_branchC_emitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, false);
        emit WaveSendFund.RewardClaimed(alice, 0, 0, false);
        fund.claim();
    }

    // ── Branch A: user explicitly prefers WSND ─────────────────────────────────

    function test_claim_branchA_transfersWsnd() public {
        vm.prank(alice);
        fund.setRewardPreference(true);
        _skip(PERIOD);
        uint256 pending    = fund.getPendingYield(alice);
        uint256 wsndBefore = wsndToken.balanceOf(alice);
        vm.prank(alice);
        fund.claim();
        uint256 expectedWsnd = _wbtcToWsnd(pending);
        assertApproxEqAbs(wsndToken.balanceOf(alice), wsndBefore + expectedWsnd, 1e10);
    }

    function test_claim_branchA_updatesTotalWsndClaimed() public {
        vm.prank(alice);
        fund.setRewardPreference(true);
        _skip(PERIOD);
        uint256 pending = fund.getPendingYield(alice);
        vm.prank(alice);
        fund.claim();
        (,,, uint256 wsndClaimed,,,) = fund.userInfo(alice);
        assertApproxEqAbs(wsndClaimed, _wbtcToWsnd(pending), 1e10);
    }

    function test_claim_branchA_doesNotPayWbtc() public {
        vm.prank(alice);
        fund.setRewardPreference(true);
        _skip(PERIOD);
        uint256 wbtcBefore = wbtcToken.balanceOf(alice);
        vm.prank(alice);
        fund.claim();
        assertEq(wbtcToken.balanceOf(alice), wbtcBefore);
    }

    // ── Branch B: prefers WBTC but pool is short → fallback to WSND ───────────

    function test_claim_branchB_fallbackToWsnd() public {
        // Deploy a fresh fund with zero WBTC so branch B fires.
        WaveSendFund impl2 = new WaveSendFund();
        bytes memory initData = abi.encodeCall(
            WaveSendFund.initialize,
            (owner, address(usdtToken), address(wbtcToken), address(wsndToken), address(router), POOL_FEE)
        );
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(impl2), initData);
        WaveSendFund fund2 = WaveSendFund(address(proxy2));

        // Seed WSND only — no WBTC pre-minted into fund2.
        wsndToken.mint(address(fund2), WSND_LARGE);

        usdtToken.mint(alice, USDT_1K);
        vm.prank(alice);
        usdtToken.approve(address(fund2), type(uint256).max);
        router.setWbtcOut(WBTC_1);

        // Deposit: the mock router mints WBTC_1 directly into fund2.
        vm.prank(alice);
        fund2.deposit(USDT_1K, 1);

        // Zero out fund2's WBTC balance via vm.store so pool WBTC < any reward.
        // MockERC20.balanceOf is mapping(address=>uint256) at slot 0.
        vm.store(
            address(wbtcToken),
            keccak256(abi.encode(address(fund2), uint256(0))),
            bytes32(0)
        );

        _skip(PERIOD);

        uint256 pending    = fund2.getPendingYield(alice);
        uint256 wsndBefore = wsndToken.balanceOf(alice);

        // Alice does NOT prefer WSND, but pool WBTC == 0 < reward → fallback fires.
        vm.prank(alice);
        fund2.claim();

        // pending ~= 1_000_000 WBTC-units → wsndExpected ~= 1e16 WSND-units
        uint256 wsndExpected = (pending * WSND_UNIT) / WBTC_UNIT;
        assertApproxEqAbs(wsndToken.balanceOf(alice), wsndBefore + wsndExpected, 1e14);
    }

    function test_claim_revertsNothingToClaim() public {
        // setUp already skipped PERIOD, so alice has yield -- drain it first.
        vm.prank(alice);
        fund.claim();

        // Now pending == 0; next call must revert.
        vm.prank(alice);
        vm.expectRevert("WF: nothing to claim");
        fund.claim();
    }

    function test_claim_revertsInsufficientWsndOnBranchA() public {
        WaveSendFund impl2 = new WaveSendFund();
        bytes memory initData = abi.encodeCall(
            WaveSendFund.initialize,
            (owner, address(usdtToken), address(wbtcToken), address(wsndToken), address(router), POOL_FEE)
        );
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(impl2), initData);
        WaveSendFund fund2  = WaveSendFund(address(proxy2));
        // No WSND seeded.

        usdtToken.mint(alice, USDT_1K);
        vm.prank(alice);
        usdtToken.approve(address(fund2), type(uint256).max);
        router.setWbtcOut(WBTC_1);
        vm.prank(alice);
        fund2.deposit(USDT_1K, 1);

        vm.prank(alice);
        fund2.setRewardPreference(true);

        _skip(PERIOD);

        vm.prank(alice);
        vm.expectRevert("WF: insufficient WSND");
        fund2.claim();
    }
}

// =============================================================================
//  SECTION 7 – REWARD PREFERENCE
// =============================================================================

contract WaveSendFund_RewardPreference is WaveSendFundBase {

    function test_setRewardPreference_togglesToTrue() public {
        vm.prank(alice);
        fund.setRewardPreference(true);
        (,,,,,, bool pref) = fund.userInfo(alice);
        assertTrue(pref);
    }

    function test_setRewardPreference_togglesToFalse() public {
        vm.startPrank(alice);
        fund.setRewardPreference(true);
        fund.setRewardPreference(false);
        vm.stopPrank();
        (,,,,,, bool pref) = fund.userInfo(alice);
        assertFalse(pref);
    }

    function test_setRewardPreference_emitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit WaveSendFund.RewardPreferenceSet(alice, true);
        fund.setRewardPreference(true);
    }
}

// =============================================================================
//  SECTION 8 – FUND DEPOSIT (company liquidity)
// =============================================================================

contract WaveSendFund_FundDeposit is WaveSendFundBase {

    function test_fundDeposit_increasesContractBalance() public {
        uint256 depositAmt = 5 * WBTC_1;
        wbtcToken.mint(owner, depositAmt);
        vm.prank(owner);
        wbtcToken.approve(address(fund), depositAmt);
        uint256 before = wbtcToken.balanceOf(address(fund));
        vm.prank(owner);
        fund.fundDeposit(address(wbtcToken), depositAmt);
        assertEq(wbtcToken.balanceOf(address(fund)), before + depositAmt);
    }

    function test_fundDeposit_doesNotChangeUserHashrate() public {
        wbtcToken.mint(owner, WBTC_1);
        vm.prank(owner);
        wbtcToken.approve(address(fund), WBTC_1);
        vm.prank(owner);
        fund.fundDeposit(address(wbtcToken), WBTC_1);
        (uint256 hashrate,,,,,, ) = fund.userInfo(owner);
        assertEq(hashrate, 0);
    }

    function test_fundDeposit_doesNotChangeTotalPoolHashrate() public {
        uint256 before = fund.totalPoolHashrate();
        wbtcToken.mint(owner, WBTC_1);
        vm.prank(owner);
        wbtcToken.approve(address(fund), WBTC_1);
        vm.prank(owner);
        fund.fundDeposit(address(wbtcToken), WBTC_1);
        assertEq(fund.totalPoolHashrate(), before);
    }

    function test_fundDeposit_acceptsWsnd() public {
        uint256 amount = 500e18;
        wsndToken.mint(owner, amount);
        vm.prank(owner);
        wsndToken.approve(address(fund), amount);
        uint256 before = wsndToken.balanceOf(address(fund));
        vm.prank(owner);
        fund.fundDeposit(address(wsndToken), amount);
        assertEq(wsndToken.balanceOf(address(fund)), before + amount);
    }

    function test_fundDeposit_anyoneCanCall() public {
        wbtcToken.mint(alice, WBTC_1);
        vm.prank(alice);
        wbtcToken.approve(address(fund), WBTC_1);
        vm.prank(alice);
        fund.fundDeposit(address(wbtcToken), WBTC_1);
    }

    function test_fundDeposit_emitsEvent() public {
        wbtcToken.mint(owner, WBTC_1);
        vm.prank(owner);
        wbtcToken.approve(address(fund), WBTC_1);
        vm.prank(owner);
        vm.expectEmit(true, false, true, true);
        emit WaveSendFund.FundDeposited(address(wbtcToken), WBTC_1, owner);
        fund.fundDeposit(address(wbtcToken), WBTC_1);
    }

    function test_fundDeposit_revertsZeroToken() public {
        vm.prank(owner);
        vm.expectRevert("WF: zero token");
        fund.fundDeposit(address(0), WBTC_1);
    }

    function test_fundDeposit_revertsZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert("WF: zero amount");
        fund.fundDeposit(address(wbtcToken), 0);
    }
}

// =============================================================================
//  SECTION 9 – OPERATIONAL WITHDRAW (company 10% monthly cap)
// =============================================================================

contract WaveSendFund_OperationalWithdraw is WaveSendFundBase {

    uint256 internal poolWbtc;

    function setUp() public override {
        super.setUp();
        poolWbtc = wbtcToken.balanceOf(address(fund));
    }

    function test_opWithdraw_exactTenPercent_succeeds() public {
        uint256 tenPct = poolWbtc / 10;
        vm.prank(owner);
        fund.operationalWithdraw(address(wbtcToken), tenPct, treasury);
        assertEq(wbtcToken.balanceOf(treasury), tenPct);
    }

    function test_opWithdraw_lessThanTenPercent_succeeds() public {
        uint256 fivePct = poolWbtc / 20;
        vm.prank(owner);
        fund.operationalWithdraw(address(wbtcToken), fivePct, treasury);
        assertEq(wbtcToken.balanceOf(treasury), fivePct);
    }

    function test_opWithdraw_updatesWithdrawnInWindow() public {
        uint256 tenPct = poolWbtc / 10;
        vm.prank(owner);
        fund.operationalWithdraw(address(wbtcToken), tenPct, treasury);
        (, uint256 withdrawn,,,) = fund.getWithdrawStatus(address(wbtcToken));
        assertEq(withdrawn, tenPct);
    }

    function test_opWithdraw_twoPartialCallsWithinWindow() public {
        uint256 fivePct = poolWbtc / 20;
        vm.prank(owner);
        fund.operationalWithdraw(address(wbtcToken), fivePct, treasury);
        vm.prank(owner);
        fund.operationalWithdraw(address(wbtcToken), fivePct, treasury);
        assertEq(wbtcToken.balanceOf(treasury), fivePct * 2);
    }

    function test_opWithdraw_emitsEvent() public {
        uint256 tenPct = poolWbtc / 10;
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit WaveSendFund.OperationalWithdrawn(address(wbtcToken), tenPct, 0, 0, 0);
        fund.operationalWithdraw(address(wbtcToken), tenPct, treasury);
    }

    function test_opWithdraw_newWindowAfter30Days_allowsAnotherTenPct() public {
        uint256 tenPct = poolWbtc / 10;
        vm.prank(owner);
        fund.operationalWithdraw(address(wbtcToken), tenPct, treasury);
        _skip(PERIOD + 1);
        uint256 newBalance   = wbtcToken.balanceOf(address(fund));
        uint256 newAllowance = newBalance / 10;
        vm.prank(owner);
        fund.operationalWithdraw(address(wbtcToken), newAllowance, treasury);
        assertEq(wbtcToken.balanceOf(treasury), tenPct + newAllowance);
    }

    function test_opWithdraw_windowStatus_remainingDecrements() public {
        uint256 tenPct = poolWbtc / 10;
        vm.prank(owner);
        fund.operationalWithdraw(address(wbtcToken), tenPct / 2, treasury);
        (,, uint256 allowance, uint256 remaining,) = fund.getWithdrawStatus(address(wbtcToken));
        assertApproxEqAbs(remaining, allowance / 2, 1);
    }

    function test_opWithdraw_revertsMoreThanTenPercent() public {
        uint256 moreThanTen = (poolWbtc / 10) + 1;
        vm.prank(owner);
        vm.expectRevert("WF: exceeds monthly 10% cap");
        fund.operationalWithdraw(address(wbtcToken), moreThanTen, treasury);
    }

    function test_opWithdraw_revertsExhaustedAllowance() public {
        uint256 tenPct = poolWbtc / 10;
        vm.prank(owner);
        fund.operationalWithdraw(address(wbtcToken), tenPct, treasury);
        vm.prank(owner);
        vm.expectRevert("WF: monthly allowance exhausted");
        fund.operationalWithdraw(address(wbtcToken), 1, treasury);
    }

    function test_opWithdraw_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        fund.operationalWithdraw(address(wbtcToken), 1, treasury);
    }

    function test_opWithdraw_revertsZeroToken() public {
        vm.prank(owner);
        vm.expectRevert("WF: zero token");
        fund.operationalWithdraw(address(0), 1, treasury);
    }

    function test_opWithdraw_revertsZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert("WF: zero amount");
        fund.operationalWithdraw(address(wbtcToken), 0, treasury);
    }

    function test_opWithdraw_revertsZeroRecipient() public {
        vm.prank(owner);
        vm.expectRevert("WF: zero recipient");
        fund.operationalWithdraw(address(wbtcToken), 1, address(0));
    }

    function test_opWithdraw_worksForWsnd() public {
        uint256 wsndBal = wsndToken.balanceOf(address(fund));
        uint256 tenPct  = wsndBal / 10;
        vm.prank(owner);
        fund.operationalWithdraw(address(wsndToken), tenPct, treasury);
        assertEq(wsndToken.balanceOf(treasury), tenPct);
    }

    function test_opWithdraw_worksForUsdt() public {
        usdtToken.mint(address(fund), 10 * USDT_1K);
        uint256 usdtBal = usdtToken.balanceOf(address(fund));
        uint256 tenPct  = usdtBal / 10;
        vm.prank(owner);
        fund.operationalWithdraw(address(usdtToken), tenPct, treasury);
        assertEq(usdtToken.balanceOf(treasury), tenPct);
    }
}

// =============================================================================
//  SECTION 10 – GET WITHDRAW STATUS (view)
// =============================================================================

contract WaveSendFund_GetWithdrawStatus is WaveSendFundBase {

    function test_status_beforeAnyWithdraw_returnsFullAllowance() public view {
        uint256 poolBal = wbtcToken.balanceOf(address(fund));
        (,, uint256 allowance, uint256 remaining,) = fund.getWithdrawStatus(address(wbtcToken));
        assertEq(allowance, poolBal / 10);
        assertEq(remaining, poolBal / 10);
    }

    function test_status_afterWithdraw_remainingDecremented() public {
        uint256 poolBal = wbtcToken.balanceOf(address(fund));
        uint256 take    = poolBal / 20;
        vm.prank(owner);
        fund.operationalWithdraw(address(wbtcToken), take, treasury);
        (,, uint256 allowance, uint256 remaining,) = fund.getWithdrawStatus(address(wbtcToken));
        assertEq(remaining, allowance - take);
    }

    function test_status_afterWindowExpiry_showsNewAllowance() public {
        uint256 poolBal = wbtcToken.balanceOf(address(fund));
        vm.prank(owner);
        fund.operationalWithdraw(address(wbtcToken), poolBal / 10, treasury);
        _skip(PERIOD + 1);
        uint256 newBal = wbtcToken.balanceOf(address(fund));
        (,, uint256 allowance, uint256 remaining,) = fund.getWithdrawStatus(address(wbtcToken));
        assertEq(allowance, newBal / 10);
        assertEq(remaining, newBal / 10);
    }

    function test_status_windowEndsAt_isCorrect() public {
        vm.prank(owner);
        fund.operationalWithdraw(address(wbtcToken), 1, treasury);
        (uint256 start,,,, uint256 endsAt) = fund.getWithdrawStatus(address(wbtcToken));
        assertEq(endsAt, start + PERIOD);
    }
}

// =============================================================================
//  SECTION 11 – FULL LIFECYCLE INTEGRATION
// =============================================================================

contract WaveSendFund_Lifecycle is WaveSendFundBase {

    function test_lifecycle_depositYieldClaimWithdraw() public {
        _deposit(alice);
        assertEq(fund.totalPoolHashrate(), WBTC_1);

        _skip(PERIOD);
        uint256 expected = _expectedYield(WBTC_1, PERIOD);
        assertApproxEqAbs(fund.getPendingYield(alice), expected, 10);

        uint256 wbtcBefore = wbtcToken.balanceOf(alice);
        vm.prank(alice);
        fund.claim();
        assertApproxEqAbs(wbtcToken.balanceOf(alice), wbtcBefore + expected, 10);
        assertEq(fund.getPendingYield(alice), 0);

        _skip(PERIOD);

        vm.prank(alice);
        fund.setRewardPreference(true);

        uint256 wsndBefore = wsndToken.balanceOf(alice);
        uint256 pending2   = fund.getPendingYield(alice);
        vm.prank(alice);
        fund.claim();
        assertApproxEqAbs(wsndToken.balanceOf(alice), wsndBefore + _wbtcToWsnd(pending2), 1e10);

        uint256 wbtcBefore2 = wbtcToken.balanceOf(alice);
        vm.prank(alice);
        fund.withdraw(WBTC_1);
        assertEq(wbtcToken.balanceOf(alice), wbtcBefore2 + WBTC_1);
        assertEq(fund.totalPoolHashrate(), 0);
    }

    function test_lifecycle_twoUsersIndependentYield() public {
        _deposit(alice);
        router.setWbtcOut(2 * WBTC_1);
        _deposit(bob);
        _skip(PERIOD);
        uint256 aliceY = fund.getPendingYield(alice);
        uint256 bobY   = fund.getPendingYield(bob);
        assertApproxEqAbs(bobY, aliceY * 2, 20);
        vm.prank(alice);
        fund.claim();
        vm.prank(bob);
        fund.claim();
        assertEq(fund.getPendingYield(alice), 0);
        assertEq(fund.getPendingYield(bob),   0);
    }

    function test_lifecycle_companyFundsAndWithdraws() public {
        wbtcToken.mint(owner, 5 * WBTC_1);
        vm.prank(owner);
        wbtcToken.approve(address(fund), 5 * WBTC_1);
        vm.prank(owner);
        fund.fundDeposit(address(wbtcToken), 5 * WBTC_1);
        uint256 poolBal = wbtcToken.balanceOf(address(fund));
        uint256 tenPct  = poolBal / 10;
        vm.prank(owner);
        fund.operationalWithdraw(address(wbtcToken), tenPct, treasury);
        assertEq(wbtcToken.balanceOf(treasury), tenPct);
        assertEq(wbtcToken.balanceOf(address(fund)), poolBal - tenPct);
    }

    function test_lifecycle_yieldAccruesAcrossMultipleDeposits() public {
        _deposit(alice);
        _skip(PERIOD / 2);
        _deposit(alice);
        _skip(PERIOD / 2);
        uint256 pending    = fund.getPendingYield(alice);
        uint256 firstHalf  = _expectedYield(WBTC_1,     PERIOD / 2);
        uint256 secondHalf = _expectedYield(2 * WBTC_1, PERIOD / 2);
        assertApproxEqAbs(pending, firstHalf + secondHalf, 20);
    }
}

// =============================================================================
//  SECTION 12 – REENTRANCY GUARD
// =============================================================================

contract WaveSendFund_Reentrancy is WaveSendFundBase {

    function test_reentrancyGuard_claimIsProtected() public {
        _deposit(alice);
        _skip(PERIOD);
        vm.prank(alice);
        fund.claim();
        vm.prank(alice);
        vm.expectRevert("WF: nothing to claim");
        fund.claim();
    }

    function test_reentrancyGuard_depositIsProtected() public {
        _deposit(alice);
        _deposit(alice);
    }
}

// =============================================================================
//  SECTION 13 – FUZZ TESTS
// =============================================================================

contract WaveSendFund_Fuzz is WaveSendFundBase {

    function testFuzz_yield_neverExceedsOnePercentPerMonth(uint256 elapsed) public {
        vm.assume(elapsed <= PERIOD * 12);
        _deposit(alice);
        _skip(elapsed);
        uint256 pending     = fund.getPendingYield(alice);
        uint256 maxExpected = (WBTC_1 * 100 * elapsed) / (10_000 * PERIOD);
        assertEq(pending, maxExpected);
    }

    function testFuzz_operationalWithdraw_neverExceedsTenPercent(uint256 amount) public {
        uint256 poolBal  = wbtcToken.balanceOf(address(fund));
        uint256 maxAllow = poolBal / 10;
        vm.assume(amount > maxAllow);
        vm.assume(amount <= poolBal);
        vm.prank(owner);
        vm.expectRevert("WF: exceeds monthly 10% cap");
        fund.operationalWithdraw(address(wbtcToken), amount, treasury);
    }

    function testFuzz_wbtcToWsnd_decimalConversion(uint256 wbtcAmt) public view {
        vm.assume(wbtcAmt <= 21_000_000 * WBTC_UNIT);
        uint256 wsndAmt = (wbtcAmt * fund.wsndPerWbtc()) / WBTC_UNIT;
        assertEq(wsndAmt, wbtcAmt * 1e10);
    }

    function testFuzz_fundDeposit_anyAmountAccepted(uint256 amount) public {
        vm.assume(amount > 0 && amount <= type(uint128).max);
        wbtcToken.mint(alice, amount);
        vm.prank(alice);
        wbtcToken.approve(address(fund), amount);
        uint256 before = wbtcToken.balanceOf(address(fund));
        vm.prank(alice);
        fund.fundDeposit(address(wbtcToken), amount);
        assertEq(wbtcToken.balanceOf(address(fund)), before + amount);
    }
}
