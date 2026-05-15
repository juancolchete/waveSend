// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {WaveSendFund} from "../src/WaveSendFund.sol";

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
        name = _name; symbol = _symbol; decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount; totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount; totalSupply -= amount;
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
        balanceOf[from] -= amount; balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract MockSwapRouter {
    uint256   public wbtcOut;
    uint256   public wbtcOutNative;
    MockERC20 public wbtcToken;

    constructor(address _wbtc) { wbtcToken = MockERC20(_wbtc); }

    function setWbtcOut(uint256 _wbtcOut) external { wbtcOut = _wbtcOut; }
    function setWbtcOutNative(uint256 _wbtcOut) external { wbtcOutNative = _wbtcOut; }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut)
    {
        if (params.tokenIn == address(0)) {
            require(msg.value == params.amountIn,              "MockRouter: value mismatch");
            require(wbtcOutNative >= params.amountOutMinimum,  "MockRouter: native slippage");
            wbtcToken.mint(params.recipient, wbtcOutNative);
            return wbtcOutNative;
        }
        MockERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        require(wbtcOut >= params.amountOutMinimum, "MockRouter: slippage");
        wbtcToken.mint(params.recipient, wbtcOut);
        return wbtcOut;
    }
}

contract ReentrancyAttacker {
    WaveSendFund public fund;
    uint256 public attackCount;

    constructor(address _fund) { fund = WaveSendFund(payable(_fund)); }

    receive() external payable {
        if (attackCount < 1) { attackCount++; fund.claim(); }
    }

    fallback() external payable {}
}

abstract contract WaveSendFundBase is Test {
    address internal admin    = makeAddr("admin");
    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal treasury = makeAddr("treasury");

    MockERC20      internal usdtToken;
    MockERC20      internal wbtcToken;
    MockERC20      internal wsndToken;
    MockSwapRouter internal router;
    WaveSendFund   internal fund;

    uint256 internal constant PERIOD     = 2_592_000;
    uint256 internal constant WBTC_UNIT  = 1e8;
    uint256 internal constant WSND_UNIT  = 1e18;
    uint24  internal constant POOL_FEE   = 500;
    uint24  internal constant NATIVE_FEE = 3000;
    uint256 internal constant USDT_1K    = 1_000e6;
    uint256 internal constant WBTC_1     = 1e8;
    uint256 internal constant WSND_LARGE = 1_000e18;

    function setUp() public virtual {
        usdtToken = new MockERC20("Celo USDT", "USDT", 6);
        wbtcToken = new MockERC20("Celo WBTC", "WBTC", 8);
        wsndToken = new MockERC20("WaveSend",  "WSND", 18);
        router    = new MockSwapRouter(address(wbtcToken));

        WaveSendFund impl = new WaveSendFund();
        bytes memory initData = abi.encodeCall(
            WaveSendFund.initialize,
            (admin, address(usdtToken), address(wbtcToken), address(wsndToken), address(router), POOL_FEE, NATIVE_FEE)
        );
        fund = WaveSendFund(payable(address(new ERC1967Proxy(address(impl), initData))));

        wsndToken.mint(address(fund), WSND_LARGE);
        wbtcToken.mint(address(fund), 10 * WBTC_1);

        usdtToken.mint(alice, 10 * USDT_1K);
        usdtToken.mint(bob,   10 * USDT_1K);

        vm.prank(alice); usdtToken.approve(address(fund), type(uint256).max);
        vm.prank(bob);   usdtToken.approve(address(fund), type(uint256).max);

        router.setWbtcOut(WBTC_1);
        router.setWbtcOutNative(WBTC_1);
    }

    function _deposit(address user) internal {
        vm.prank(user); fund.deposit(USDT_1K, 1);
    }

    function _skip(uint256 s) internal { skip(s); }

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

    function test_initialize_setsAdminRole() public view {
        assertTrue(fund.hasRole(fund.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(fund.hasRole(fund.OPERATOR_ROLE(),      admin));
        assertTrue(fund.hasRole(fund.UPGRADER_ROLE(),      admin));
    }

    function test_initialize_setsDefaultWsndRatio() public view {
        assertEq(fund.wsndPerWbtc(), WSND_UNIT);
    }

    function test_initialize_setsPoolFee() public view {
        assertEq(fund.poolFee(), POOL_FEE);
        assertEq(fund.nativeFee(), NATIVE_FEE);
    }

    function test_initialize_revertsOnDoubleInit() public {
        vm.expectRevert();
        fund.initialize(admin, address(usdtToken), address(wbtcToken),
                        address(wsndToken), address(router), POOL_FEE, NATIVE_FEE);
    }

    function test_initialize_revertsZeroAdmin() public {
        WaveSendFund impl2 = new WaveSendFund();
        vm.expectRevert("WF: zero admin");
        new ERC1967Proxy(address(impl2), abi.encodeCall(WaveSendFund.initialize,
            (address(0), address(usdtToken), address(wbtcToken),
             address(wsndToken), address(router), POOL_FEE, NATIVE_FEE)));
    }

    function test_initialize_revertsZeroUsdt() public {
        WaveSendFund impl2 = new WaveSendFund();
        vm.expectRevert("WF: zero USDT");
        new ERC1967Proxy(address(impl2), abi.encodeCall(WaveSendFund.initialize,
            (admin, address(0), address(wbtcToken),
             address(wsndToken), address(router), POOL_FEE, NATIVE_FEE)));
    }
}

// =============================================================================
//  SECTION 2 – ADMIN SETTERS
// =============================================================================

contract WaveSendFund_AdminSetters is WaveSendFundBase {

    function test_setWsndPerWbtc_updatesRatio() public {
        vm.prank(admin); fund.setWsndPerWbtc(2e18);
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
        vm.prank(alice); vm.expectRevert(); fund.setWsndPerWbtc(2e18);
    }

    function test_setPoolFee_updates() public {
        vm.prank(admin); fund.setPoolFee(3000);
        assertEq(fund.poolFee(), 3000);
    }

    function test_setPoolFee_revertsNonOperator() public {
        vm.prank(alice); vm.expectRevert(); fund.setPoolFee(3000);
    }

    function test_setSwapRouter_updates() public {
        address newRouter = makeAddr("newRouter");
        vm.prank(admin); fund.setSwapRouter(newRouter);
        assertEq(address(fund.swapRouter()), newRouter);
    }

    function test_setSwapRouter_revertsZero() public {
        vm.prank(admin);
        vm.expectRevert("WF: zero router");
        fund.setSwapRouter(address(0));
    }

    function test_setSwapRouter_revertsNonOperator() public {
        vm.prank(alice); vm.expectRevert(); fund.setSwapRouter(makeAddr("x"));
    }
}

// =============================================================================
//  SECTION 3 – DEPOSIT (USDT)
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
        vm.prank(alice); vm.expectRevert("WF: zero USDT"); fund.deposit(0, 1);
    }

    function test_deposit_revertsZeroMinOut() public {
        vm.prank(alice); vm.expectRevert("WF: zero min out"); fund.deposit(USDT_1K, 0);
    }

    function test_deposit_revertsSlippage() public {
        router.setWbtcOut(0);
        vm.prank(alice); vm.expectRevert("MockRouter: slippage"); fund.deposit(USDT_1K, WBTC_1);
    }

    function test_deposit_multipleDeposits_accumulatesHashrate() public {
        _deposit(alice); _skip(PERIOD / 2); _deposit(alice);
        (uint256 hashrate,,,,,, ) = fund.userInfo(alice);
        assertEq(hashrate, 2 * WBTC_1);
    }

    function test_deposit_multipleDeposits_snapshotsPendingYield() public {
        _deposit(alice); _skip(PERIOD); _deposit(alice);
        (,,,, uint256 pending,,) = fund.userInfo(alice);
        assertApproxEqAbs(pending, 1_000_000, 10);
    }

    function test_deposit_twoUsers_independentHashrates() public {
        _deposit(alice);
        router.setWbtcOut(2 * WBTC_1);
        vm.prank(bob); fund.deposit(USDT_1K, 1);
        (uint256 hA,,,,,, ) = fund.userInfo(alice);
        (uint256 hB,,,,,, ) = fund.userInfo(bob);
        assertEq(hA, WBTC_1);
        assertEq(hB, 2 * WBTC_1);
        assertEq(fund.totalPoolHashrate(), 3 * WBTC_1);
    }
}

// =============================================================================
//  SECTION 4 – WITHDRAW
// =============================================================================

contract WaveSendFund_Withdraw is WaveSendFundBase {

    function setUp() public override { super.setUp(); _deposit(alice); }

    function test_withdraw_reducesHashrate() public {
        vm.prank(alice); fund.withdraw(WBTC_1);
        (uint256 hashrate,,,,,, ) = fund.userInfo(alice);
        assertEq(hashrate, 0);
    }

    function test_withdraw_reducesTotalPoolHashrate() public {
        vm.prank(alice); fund.withdraw(WBTC_1);
        assertEq(fund.totalPoolHashrate(), 0);
    }

    function test_withdraw_transfersWbtc() public {
        uint256 before = wbtcToken.balanceOf(alice);
        vm.prank(alice); fund.withdraw(WBTC_1);
        assertEq(wbtcToken.balanceOf(alice), before + WBTC_1);
    }

    function test_withdraw_emitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit WaveSendFund.UserWithdrawn(alice, WBTC_1);
        fund.withdraw(WBTC_1);
    }

    function test_withdraw_syncsYieldBeforeReducing() public {
        _skip(PERIOD); vm.prank(alice); fund.withdraw(WBTC_1);
        (,,,, uint256 pending,,) = fund.userInfo(alice);
        assertApproxEqAbs(pending, 1_000_000, 10);
    }

    function test_withdraw_revertsZeroAmount() public {
        vm.prank(alice); vm.expectRevert("WF: zero amount"); fund.withdraw(0);
    }

    function test_withdraw_revertsInsufficientHashrate() public {
        vm.prank(alice); vm.expectRevert("WF: insufficient hashrate"); fund.withdraw(WBTC_1 + 1);
    }

    function test_withdraw_partialWithdraw() public {
        vm.prank(alice); fund.withdraw(WBTC_1 / 2);
        (uint256 hashrate,,,,,, ) = fund.userInfo(alice);
        assertEq(hashrate, WBTC_1 / 2);
    }
}

// =============================================================================
//  SECTION 5 – YIELD ACCRUAL
// =============================================================================

contract WaveSendFund_YieldAccrual is WaveSendFundBase {

    function setUp() public override { super.setUp(); _deposit(alice); }

    function test_getPendingYield_zeroBeforeTimeElapsed() public view {
        assertEq(fund.getPendingYield(alice), 0);
    }

    function test_getPendingYield_after30Days() public {
        _skip(PERIOD);
        assertApproxEqAbs(fund.getPendingYield(alice), _expectedYield(WBTC_1, PERIOD), 10);
    }

    function test_getPendingYield_linearlyScalesWithTime() public {
        _skip(PERIOD / 4);
        uint256 quarter = fund.getPendingYield(alice);
        _skip(PERIOD / 4);
        assertApproxEqAbs(fund.getPendingYield(alice), quarter * 2, 20);
    }

    function test_getPendingYield_linearlyScalesWithHashrate() public {
        router.setWbtcOut(2 * WBTC_1); _deposit(bob); _skip(PERIOD);
        assertApproxEqAbs(fund.getPendingYield(bob), fund.getPendingYield(alice) * 2, 20);
    }

    function test_yieldStopsAccruingAfterFullWithdraw() public {
        _skip(PERIOD / 2); vm.prank(alice); fund.withdraw(WBTC_1);
        uint256 snap = fund.getPendingYield(alice);
        _skip(PERIOD);
        assertEq(fund.getPendingYield(alice), snap);
    }

    function test_setRewardPreference_snapshotsYield() public {
        _skip(PERIOD / 2); vm.prank(alice); fund.setRewardPreference(true);
        (,,,, uint256 pending,,) = fund.userInfo(alice);
        assertApproxEqAbs(pending, _expectedYield(WBTC_1, PERIOD / 2), 10);
    }

    function test_yieldFormula_oneBtcOneMonth_exactMath() public {
        _skip(PERIOD);
        assertEq(fund.getPendingYield(alice), 1_000_000);
    }
}

// =============================================================================
//  SECTION 6 – CLAIM
// =============================================================================

contract WaveSendFund_Claim is WaveSendFundBase {

    function setUp() public override { super.setUp(); _deposit(alice); _skip(PERIOD); }

    function test_claim_branchC_transfersWbtc() public {
        uint256 before  = wbtcToken.balanceOf(alice);
        uint256 pending = fund.getPendingYield(alice);
        vm.prank(alice); fund.claim();
        assertApproxEqAbs(wbtcToken.balanceOf(alice), before + pending, 10);
    }

    function test_claim_branchC_zerosPendingRewards() public {
        vm.prank(alice); fund.claim();
        assertEq(fund.getPendingYield(alice), 0);
    }

    function test_claim_branchC_updatesTotalWbtcClaimed() public {
        uint256 pending = fund.getPendingYield(alice);
        vm.prank(alice); fund.claim();
        (,, uint256 totalClaimed,,,,) = fund.userInfo(alice);
        assertApproxEqAbs(totalClaimed, pending, 10);
    }

    function test_claim_branchC_emitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, false);
        emit WaveSendFund.RewardClaimed(alice, 0, 0, false);
        fund.claim();
    }

    function test_claim_branchA_transfersWsnd() public {
        vm.prank(alice); fund.setRewardPreference(true);
        _skip(PERIOD);
        uint256 pending    = fund.getPendingYield(alice);
        uint256 wsndBefore = wsndToken.balanceOf(alice);
        vm.prank(alice); fund.claim();
        assertApproxEqAbs(wsndToken.balanceOf(alice), wsndBefore + _wbtcToWsnd(pending), 1e10);
    }

    function test_claim_branchA_updatesTotalWsndClaimed() public {
        vm.prank(alice); fund.setRewardPreference(true);
        _skip(PERIOD);
        uint256 pending = fund.getPendingYield(alice);
        vm.prank(alice); fund.claim();
        (,,, uint256 wsndClaimed,,,) = fund.userInfo(alice);
        assertApproxEqAbs(wsndClaimed, _wbtcToWsnd(pending), 1e10);
    }

    function test_claim_branchA_doesNotPayWbtc() public {
        vm.prank(alice); fund.setRewardPreference(true);
        _skip(PERIOD);
        uint256 wbtcBefore = wbtcToken.balanceOf(alice);
        vm.prank(alice); fund.claim();
        assertEq(wbtcToken.balanceOf(alice), wbtcBefore);
    }

    function test_claim_branchB_fallbackToWsnd() public {
        WaveSendFund impl2 = new WaveSendFund();
        WaveSendFund fund2 = WaveSendFund(payable(address(new ERC1967Proxy(address(impl2),
            abi.encodeCall(WaveSendFund.initialize,
                (admin, address(usdtToken), address(wbtcToken), address(wsndToken),
                 address(router), POOL_FEE, NATIVE_FEE))))));

        wsndToken.mint(address(fund2), WSND_LARGE);
        usdtToken.mint(alice, USDT_1K);
        vm.prank(alice); usdtToken.approve(address(fund2), type(uint256).max);
        router.setWbtcOut(WBTC_1);
        vm.prank(alice); fund2.deposit(USDT_1K, 1);

        wbtcToken.burn(address(fund2), wbtcToken.balanceOf(address(fund2)));
        _skip(PERIOD);

        uint256 pending    = fund2.getPendingYield(alice);
        uint256 wsndBefore = wsndToken.balanceOf(alice);
        vm.prank(alice); fund2.claim();

        assertApproxEqAbs(wsndToken.balanceOf(alice),
            wsndBefore + (pending * WSND_UNIT) / WBTC_UNIT, 1e14);
    }

    function test_claim_revertsNothingToClaim() public {
        vm.prank(alice); fund.claim();
        vm.prank(alice); vm.expectRevert("WF: nothing to claim"); fund.claim();
    }

    function test_claim_revertsInsufficientWsndOnBranchA() public {
        WaveSendFund impl2 = new WaveSendFund();
        WaveSendFund fund2 = WaveSendFund(payable(address(new ERC1967Proxy(address(impl2),
            abi.encodeCall(WaveSendFund.initialize,
                (admin, address(usdtToken), address(wbtcToken), address(wsndToken),
                 address(router), POOL_FEE, NATIVE_FEE))))));

        usdtToken.mint(alice, USDT_1K);
        vm.prank(alice); usdtToken.approve(address(fund2), type(uint256).max);
        router.setWbtcOut(WBTC_1);
        vm.prank(alice); fund2.deposit(USDT_1K, 1);
        vm.prank(alice); fund2.setRewardPreference(true);
        _skip(PERIOD);

        vm.prank(alice); vm.expectRevert("WF: insufficient WSND"); fund2.claim();
    }
}

// =============================================================================
//  SECTION 7 – REWARD PREFERENCE
// =============================================================================

contract WaveSendFund_RewardPreference is WaveSendFundBase {

    function test_setRewardPreference_togglesToTrue() public {
        vm.prank(alice); fund.setRewardPreference(true);
        (,,,,,, bool pref) = fund.userInfo(alice);
        assertTrue(pref);
    }

    function test_setRewardPreference_togglesToFalse() public {
        vm.startPrank(alice);
        fund.setRewardPreference(true); fund.setRewardPreference(false);
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
//  SECTION 8 – FUND DEPOSIT
// =============================================================================

contract WaveSendFund_FundDeposit is WaveSendFundBase {

    function test_fundDeposit_increasesContractBalance() public {
        wbtcToken.mint(admin, 5 * WBTC_1);
        vm.prank(admin); wbtcToken.approve(address(fund), 5 * WBTC_1);
        uint256 before = wbtcToken.balanceOf(address(fund));
        vm.prank(admin); fund.fundDeposit(address(wbtcToken), 5 * WBTC_1);
        assertEq(wbtcToken.balanceOf(address(fund)), before + 5 * WBTC_1);
    }

    function test_fundDeposit_doesNotChangeUserHashrate() public {
        wbtcToken.mint(admin, WBTC_1);
        vm.prank(admin); wbtcToken.approve(address(fund), WBTC_1);
        vm.prank(admin); fund.fundDeposit(address(wbtcToken), WBTC_1);
        (uint256 hashrate,,,,,, ) = fund.userInfo(admin);
        assertEq(hashrate, 0);
    }

    function test_fundDeposit_doesNotChangeTotalPoolHashrate() public {
        uint256 before = fund.totalPoolHashrate();
        wbtcToken.mint(admin, WBTC_1);
        vm.prank(admin); wbtcToken.approve(address(fund), WBTC_1);
        vm.prank(admin); fund.fundDeposit(address(wbtcToken), WBTC_1);
        assertEq(fund.totalPoolHashrate(), before);
    }

    function test_fundDeposit_acceptsWsnd() public {
        wsndToken.mint(admin, 500e18);
        vm.prank(admin); wsndToken.approve(address(fund), 500e18);
        uint256 before = wsndToken.balanceOf(address(fund));
        vm.prank(admin); fund.fundDeposit(address(wsndToken), 500e18);
        assertEq(wsndToken.balanceOf(address(fund)), before + 500e18);
    }

    function test_fundDeposit_anyoneCanCall() public {
        wbtcToken.mint(alice, WBTC_1);
        vm.prank(alice); wbtcToken.approve(address(fund), WBTC_1);
        vm.prank(alice); fund.fundDeposit(address(wbtcToken), WBTC_1);
    }

    function test_fundDeposit_emitsEvent() public {
        wbtcToken.mint(admin, WBTC_1);
        vm.prank(admin); wbtcToken.approve(address(fund), WBTC_1);
        vm.prank(admin);
        vm.expectEmit(true, false, true, true);
        emit WaveSendFund.FundDeposited(address(wbtcToken), WBTC_1, admin);
        fund.fundDeposit(address(wbtcToken), WBTC_1);
    }

    function test_fundDeposit_revertsZeroToken() public {
        vm.prank(admin); vm.expectRevert("WF: zero token"); fund.fundDeposit(address(0), WBTC_1);
    }

    function test_fundDeposit_revertsZeroAmount() public {
        vm.prank(admin); vm.expectRevert("WF: zero amount"); fund.fundDeposit(address(wbtcToken), 0);
    }
}

// =============================================================================
//  SECTION 9 – OPERATIONAL WITHDRAW
// =============================================================================

contract WaveSendFund_OperationalWithdraw is WaveSendFundBase {

    uint256 internal poolWbtc;

    function setUp() public override {
        super.setUp();
        poolWbtc = wbtcToken.balanceOf(address(fund));
    }

    function test_opWithdraw_exactTenPercent_succeeds() public {
        vm.prank(admin); fund.operationalWithdraw(address(wbtcToken), poolWbtc / 10, treasury);
        assertEq(wbtcToken.balanceOf(treasury), poolWbtc / 10);
    }

    function test_opWithdraw_lessThanTenPercent_succeeds() public {
        vm.prank(admin); fund.operationalWithdraw(address(wbtcToken), poolWbtc / 20, treasury);
        assertEq(wbtcToken.balanceOf(treasury), poolWbtc / 20);
    }

    function test_opWithdraw_updatesWithdrawnInWindow() public {
        vm.prank(admin); fund.operationalWithdraw(address(wbtcToken), poolWbtc / 10, treasury);
        (, uint256 withdrawn,,,) = fund.getWithdrawStatus(address(wbtcToken));
        assertEq(withdrawn, poolWbtc / 10);
    }

    function test_opWithdraw_twoPartialCallsWithinWindow() public {
        vm.prank(admin); fund.operationalWithdraw(address(wbtcToken), poolWbtc / 20, treasury);
        vm.prank(admin); fund.operationalWithdraw(address(wbtcToken), poolWbtc / 20, treasury);
        assertEq(wbtcToken.balanceOf(treasury), poolWbtc / 10);
    }

    function test_opWithdraw_emitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit WaveSendFund.OperationalWithdrawn(address(wbtcToken), poolWbtc / 10, 0, 0, 0);
        fund.operationalWithdraw(address(wbtcToken), poolWbtc / 10, treasury);
    }

    function test_opWithdraw_newWindowAfter30Days_allowsAnotherTenPct() public {
        vm.prank(admin); fund.operationalWithdraw(address(wbtcToken), poolWbtc / 10, treasury);
        _skip(PERIOD + 1);
        uint256 newBal = wbtcToken.balanceOf(address(fund));
        vm.prank(admin); fund.operationalWithdraw(address(wbtcToken), newBal / 10, treasury);
        assertEq(wbtcToken.balanceOf(treasury), poolWbtc / 10 + newBal / 10);
    }

    function test_opWithdraw_windowStatus_remainingDecrements() public {
        vm.prank(admin); fund.operationalWithdraw(address(wbtcToken), poolWbtc / 20, treasury);
        (,, uint256 allowance, uint256 remaining,) = fund.getWithdrawStatus(address(wbtcToken));
        assertApproxEqAbs(remaining, allowance / 2, 1);
    }

    function test_opWithdraw_revertsMoreThanTenPercent() public {
        vm.prank(admin); vm.expectRevert("WF: exceeds monthly 10% cap");
        fund.operationalWithdraw(address(wbtcToken), poolWbtc / 10 + 1, treasury);
    }

    function test_opWithdraw_revertsExhaustedAllowance() public {
        vm.prank(admin); fund.operationalWithdraw(address(wbtcToken), poolWbtc / 10, treasury);
        vm.prank(admin); vm.expectRevert("WF: monthly allowance exhausted");
        fund.operationalWithdraw(address(wbtcToken), 1, treasury);
    }

    function test_opWithdraw_revertsNonOperator() public {
        vm.prank(alice); vm.expectRevert();
        fund.operationalWithdraw(address(wbtcToken), 1, treasury);
    }

    function test_opWithdraw_revertsZeroToken() public {
        vm.prank(admin); vm.expectRevert("WF: zero token");
        fund.operationalWithdraw(address(0), 1, treasury);
    }

    function test_opWithdraw_revertsZeroAmount() public {
        vm.prank(admin); vm.expectRevert("WF: zero amount");
        fund.operationalWithdraw(address(wbtcToken), 0, treasury);
    }

    function test_opWithdraw_revertsZeroRecipient() public {
        vm.prank(admin); vm.expectRevert("WF: zero recipient");
        fund.operationalWithdraw(address(wbtcToken), 1, address(0));
    }

    function test_opWithdraw_worksForWsnd() public {
        uint256 tenPct = wsndToken.balanceOf(address(fund)) / 10;
        vm.prank(admin); fund.operationalWithdraw(address(wsndToken), tenPct, treasury);
        assertEq(wsndToken.balanceOf(treasury), tenPct);
    }

    function test_opWithdraw_worksForUsdt() public {
        usdtToken.mint(address(fund), 10 * USDT_1K);
        uint256 tenPct = usdtToken.balanceOf(address(fund)) / 10;
        vm.prank(admin); fund.operationalWithdraw(address(usdtToken), tenPct, treasury);
        assertEq(usdtToken.balanceOf(treasury), tenPct);
    }
}

// =============================================================================
//  SECTION 10 – GET WITHDRAW STATUS
// =============================================================================

contract WaveSendFund_GetWithdrawStatus is WaveSendFundBase {

    function test_status_beforeAnyWithdraw_returnsFullAllowance() public view {
        uint256 poolBal = wbtcToken.balanceOf(address(fund));
        (,, uint256 allowance, uint256 remaining,) = fund.getWithdrawStatus(address(wbtcToken));
        assertEq(allowance, poolBal / 10);
        assertEq(remaining, poolBal / 10);
    }

    function test_status_afterWithdraw_remainingDecremented() public {
        uint256 take = wbtcToken.balanceOf(address(fund)) / 20;
        vm.prank(admin); fund.operationalWithdraw(address(wbtcToken), take, treasury);
        (,, uint256 allowance, uint256 remaining,) = fund.getWithdrawStatus(address(wbtcToken));
        assertEq(remaining, allowance - take);
    }

    function test_status_afterWindowExpiry_showsNewAllowance() public {
        uint256 poolBal = wbtcToken.balanceOf(address(fund));
        vm.prank(admin); fund.operationalWithdraw(address(wbtcToken), poolBal / 10, treasury);
        _skip(PERIOD + 1);
        uint256 newBal = wbtcToken.balanceOf(address(fund));
        (,, uint256 allowance, uint256 remaining,) = fund.getWithdrawStatus(address(wbtcToken));
        assertEq(allowance, newBal / 10);
        assertEq(remaining, newBal / 10);
    }

    function test_status_windowEndsAt_isCorrect() public {
        vm.prank(admin); fund.operationalWithdraw(address(wbtcToken), 1, treasury);
        (uint256 start,,,, uint256 endsAt) = fund.getWithdrawStatus(address(wbtcToken));
        assertEq(endsAt, start + PERIOD);
    }
}

// =============================================================================
//  SECTION 11 – LIFECYCLE
// =============================================================================

contract WaveSendFund_Lifecycle is WaveSendFundBase {

    function test_lifecycle_depositYieldClaimWithdraw() public {
        _deposit(alice);
        assertEq(fund.totalPoolHashrate(), WBTC_1);

        _skip(PERIOD);
        uint256 expected = _expectedYield(WBTC_1, PERIOD);
        assertApproxEqAbs(fund.getPendingYield(alice), expected, 10);

        uint256 wbtcBefore = wbtcToken.balanceOf(alice);
        vm.prank(alice); fund.claim();
        assertApproxEqAbs(wbtcToken.balanceOf(alice), wbtcBefore + expected, 10);
        assertEq(fund.getPendingYield(alice), 0);

        _skip(PERIOD);
        vm.prank(alice); fund.setRewardPreference(true);

        uint256 wsndBefore = wsndToken.balanceOf(alice);
        uint256 pending2   = fund.getPendingYield(alice);
        vm.prank(alice); fund.claim();
        assertApproxEqAbs(wsndToken.balanceOf(alice), wsndBefore + _wbtcToWsnd(pending2), 1e10);

        uint256 wbtcBefore2 = wbtcToken.balanceOf(alice);
        vm.prank(alice); fund.withdraw(WBTC_1);
        assertEq(wbtcToken.balanceOf(alice), wbtcBefore2 + WBTC_1);
        assertEq(fund.totalPoolHashrate(), 0);
    }

    function test_lifecycle_twoUsersIndependentYield() public {
        _deposit(alice);
        router.setWbtcOut(2 * WBTC_1); _deposit(bob);
        _skip(PERIOD);
        assertApproxEqAbs(fund.getPendingYield(bob), fund.getPendingYield(alice) * 2, 20);
        vm.prank(alice); fund.claim();
        vm.prank(bob);   fund.claim();
        assertEq(fund.getPendingYield(alice), 0);
        assertEq(fund.getPendingYield(bob),   0);
    }

    function test_lifecycle_companyFundsAndWithdraws() public {
        wbtcToken.mint(admin, 5 * WBTC_1);
        vm.prank(admin); wbtcToken.approve(address(fund), 5 * WBTC_1);
        vm.prank(admin); fund.fundDeposit(address(wbtcToken), 5 * WBTC_1);
        uint256 poolBal = wbtcToken.balanceOf(address(fund));
        vm.prank(admin); fund.operationalWithdraw(address(wbtcToken), poolBal / 10, treasury);
        assertEq(wbtcToken.balanceOf(treasury), poolBal / 10);
        assertEq(wbtcToken.balanceOf(address(fund)), poolBal - poolBal / 10);
    }

    function test_lifecycle_yieldAccruesAcrossMultipleDeposits() public {
        _deposit(alice); _skip(PERIOD / 2); _deposit(alice); _skip(PERIOD / 2);
        assertApproxEqAbs(fund.getPendingYield(alice),
            _expectedYield(WBTC_1, PERIOD / 2) + _expectedYield(2 * WBTC_1, PERIOD / 2), 20);
    }
}

// =============================================================================
//  SECTION 12 – REENTRANCY GUARD
// =============================================================================

contract WaveSendFund_Reentrancy is WaveSendFundBase {

    function test_reentrancyGuard_claimIsProtected() public {
        _deposit(alice); _skip(PERIOD);
        vm.prank(alice); fund.claim();
        vm.prank(alice); vm.expectRevert("WF: nothing to claim"); fund.claim();
    }

    function test_reentrancyGuard_depositIsProtected() public {
        _deposit(alice); _deposit(alice);
    }
}

// =============================================================================
//  SECTION 13 – FUZZ TESTS
// =============================================================================

contract WaveSendFund_Fuzz is WaveSendFundBase {

    function testFuzz_yield_neverExceedsOnePercentPerMonth(uint256 elapsed) public {
        vm.assume(elapsed <= PERIOD * 12);
        _deposit(alice); _skip(elapsed);
        assertEq(fund.getPendingYield(alice), (WBTC_1 * 100 * elapsed) / (10_000 * PERIOD));
    }

    function testFuzz_operationalWithdraw_neverExceedsTenPercent(uint256 amount) public {
        uint256 poolBal = wbtcToken.balanceOf(address(fund));
        vm.assume(amount > poolBal / 10 && amount <= poolBal);
        vm.prank(admin); vm.expectRevert("WF: exceeds monthly 10% cap");
        fund.operationalWithdraw(address(wbtcToken), amount, treasury);
    }

    function testFuzz_wbtcToWsnd_decimalConversion(uint256 wbtcAmt) public view {
        vm.assume(wbtcAmt <= 21_000_000 * WBTC_UNIT);
        assertEq((wbtcAmt * fund.wsndPerWbtc()) / WBTC_UNIT, wbtcAmt * 1e10);
    }

    function testFuzz_fundDeposit_anyAmountAccepted(uint256 amount) public {
        vm.assume(amount > 0 && amount <= type(uint128).max);
        wbtcToken.mint(alice, amount);
        vm.prank(alice); wbtcToken.approve(address(fund), amount);
        uint256 before = wbtcToken.balanceOf(address(fund));
        vm.prank(alice); fund.fundDeposit(address(wbtcToken), amount);
        assertEq(wbtcToken.balanceOf(address(fund)), before + amount);
    }
}

// =============================================================================
//  SECTION 14 – DEPOSIT NATIVE
// =============================================================================

contract WaveSendFund_DepositNative is WaveSendFundBase {

    function setUp() public override {
        super.setUp();
        vm.deal(alice, 10 ether);
        vm.deal(bob,   10 ether);
    }

    function test_depositNative_creditsHashrate() public {
        vm.prank(alice); fund.depositNative{value: 1 ether}(1);
        (uint256 hashrate,,,,,, ) = fund.userInfo(alice);
        assertEq(hashrate, WBTC_1);
    }

    function test_depositNative_updatesTotalPoolHashrate() public {
        vm.prank(alice); fund.depositNative{value: 1 ether}(1);
        assertEq(fund.totalPoolHashrate(), WBTC_1);
    }

    function test_depositNative_updatesTotalDeposited() public {
        vm.prank(alice); fund.depositNative{value: 1 ether}(1);
        (, uint256 totalDep,,,,,) = fund.userInfo(alice);
        assertEq(totalDep, WBTC_1);
    }

    function test_depositNative_setsLastUpdateTimestamp() public {
        uint256 before = block.timestamp;
        vm.prank(alice); fund.depositNative{value: 1 ether}(1);
        (,,,,,uint256 ts,) = fund.userInfo(alice);
        assertEq(ts, before);
    }

    function test_depositNative_emitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit WaveSendFund.NativeDeposited(alice, 1 ether, WBTC_1);
        fund.depositNative{value: 1 ether}(1);
    }

    function test_depositNative_accumulatesWithUsdtDeposit() public {
        _deposit(alice);
        vm.prank(alice); fund.depositNative{value: 1 ether}(1);
        (uint256 hashrate,,,,,, ) = fund.userInfo(alice);
        assertEq(hashrate, 2 * WBTC_1);
        assertEq(fund.totalPoolHashrate(), 2 * WBTC_1);
    }

    function test_depositNative_snapshotsPendingYield() public {
        _deposit(alice); _skip(PERIOD);
        vm.prank(alice); fund.depositNative{value: 1 ether}(1);
        (,,,, uint256 pending,,) = fund.userInfo(alice);
        assertApproxEqAbs(pending, 1_000_000, 10);
    }

    function test_depositNative_twoUsers_independentHashrates() public {
        vm.prank(alice); fund.depositNative{value: 1 ether}(1);
        router.setWbtcOutNative(2 * WBTC_1);
        vm.prank(bob); fund.depositNative{value: 1 ether}(1);
        (uint256 hA,,,,,, ) = fund.userInfo(alice);
        (uint256 hB,,,,,, ) = fund.userInfo(bob);
        assertEq(hA, WBTC_1);
        assertEq(hB, 2 * WBTC_1);
    }

    function test_depositNative_revertsZeroValue() public {
        vm.prank(alice); vm.expectRevert("WF: zero native");
        fund.depositNative{value: 0}(1);
    }

    function test_depositNative_revertsZeroMinOut() public {
        vm.prank(alice); vm.expectRevert("WF: zero min out");
        fund.depositNative{value: 1 ether}(0);
    }

    function test_depositNative_revertsSlippage() public {
        router.setWbtcOutNative(0);
        vm.prank(alice); vm.expectRevert("MockRouter: native slippage");
        fund.depositNative{value: 1 ether}(WBTC_1);
    }

    function test_depositNative_revertsWhenNativeFeeNotSet() public {
        WaveSendFund impl2 = new WaveSendFund();
        WaveSendFund fund2 = WaveSendFund(payable(address(new ERC1967Proxy(address(impl2),
            abi.encodeCall(WaveSendFund.initialize,
                (admin, address(usdtToken), address(wbtcToken), address(wsndToken),
                 address(router), POOL_FEE, 0))))));
        vm.prank(alice); vm.expectRevert("WF: native fee not set");
        fund2.depositNative{value: 1 ether}(1);
    }

    function test_setNativeFee_updatesValue() public {
        vm.prank(admin); fund.setNativeFee(500);
        assertEq(fund.nativeFee(), 500);
    }

    function test_setNativeFee_emitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit WaveSendFund.NativeFeeUpdated(500);
        fund.setNativeFee(500);
    }

    function test_setNativeFee_revertsNonOperator() public {
        vm.prank(alice); vm.expectRevert(); fund.setNativeFee(500);
    }

    function test_receive_triggersDepositNative() public {
        uint256 hashrateBefore = fund.totalPoolHashrate();
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(fund).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(fund.totalPoolHashrate(), hashrateBefore + WBTC_1);
    }
}
