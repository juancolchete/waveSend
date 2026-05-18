// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {WaveSendFund} from "../src/WaveSendFund.sol";

/**
 * @title  DeployWaveSendFund
 * @notice Foundry deployment script for WaveSendFund on Celo Mainnet.
 *
 * Usage (dry-run):
 *   forge script script/DeployWaveSendFund.s.sol \
 *     --rpc-url $CELO_RPC_URL \
 *     --sig "run()" \
 *     -vvvv
 *
 * Usage (broadcast):
 *   forge script script/DeployWaveSendFund.s.sol \
 *     --rpc-url $CELO_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $CELOSCAN_API_KEY \
 *     -vvvv
 *
 * Required environment variables (set in .env):
 *   DEPLOYER_PRIVATE_KEY   -- private key of the deploying wallet
 *   ADMIN_ADDRESS          -- address that receives all roles (DEFAULT_ADMIN, OPERATOR, UPGRADER)
 *   CELO_USDT_ADDRESS      -- Celo bridged USDT token
 *   CELO_WBTC_ADDRESS      -- Celo bridged WBTC token (8 decimals)
 *   WSND_ADDRESS           -- WaveSend Token (18 decimals)
 *   UNISWAP_V3_ROUTER      -- Uniswap V3 SwapRouter on Celo
 *   POOL_FEE               -- Uniswap V3 fee tier for USDT->WBTC (e.g. 500 = 0.05%)
 *   NATIVE_FEE             -- Uniswap V3 fee tier for native->WBTC (e.g. 3000 = 0.3%)
 */
contract DeployWaveSendFund is Script {
    // ── Deployment artifacts (populated during run) ──────────────────────────
    WaveSendFund public implementation;
    WaveSendFund public proxy;

    function run() external {
        // ── Load env ─────────────────────────────────────────────────────────
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address usdt = vm.envAddress("CELO_USDT_ADDRESS");
        address wbtc = vm.envAddress("CELO_WBTC_ADDRESS");
        address wsnd = vm.envAddress("WSND_ADDRESS");
        address router = vm.envAddress("UNISWAP_V3_ROUTER");
        uint24 poolFee = uint24(vm.envUint("POOL_FEE"));
        uint24 nativeFee = uint24(vm.envUint("NATIVE_FEE"));
        uint24 nativeUsdtFee = uint24(vm.envUint("NATIVE_USDT_FEE"));

        // ── Sanity checks ────────────────────────────────────────────────────
        require(admin != address(0), "Deploy: zero admin");
        require(usdt != address(0), "Deploy: zero USDT");
        require(wbtc != address(0), "Deploy: zero WBTC");
        require(wsnd != address(0), "Deploy: zero WSND");
        require(router != address(0), "Deploy: zero router");
        require(poolFee > 0, "Deploy: zero poolFee");

        address deployer = vm.addr(deployerKey);
        console.log("=== WaveSendFund Deployment ===");
        console.log("Deployer     :", deployer);
        console.log("Admin        :", admin);
        console.log("USDT         :", usdt);
        console.log("WBTC         :", wbtc);
        console.log("WSND         :", wsnd);
        console.log("Router       :", router);
        console.log("Pool fee     :", poolFee);
        console.log("Native fee   :", nativeFee);
        console.log("NativeUSDT f :", nativeUsdtFee);
        console.log("NativeUSDT f :", nativeUsdtFee);

        vm.startBroadcast(deployerKey);

        // 1. Deploy implementation
        implementation = new WaveSendFund();
        console.log("Implementation:", address(implementation));

        // 2. Encode initializer call
        bytes memory initData = abi.encodeCall(
            WaveSendFund.initialize,
            (admin, usdt, wbtc, wsnd, router, poolFee, nativeFee, nativeUsdtFee)
        );

        // 3. Deploy UUPS proxy (implementation + initializer in one tx)
        ERC1967Proxy proxyContract = new ERC1967Proxy(
            address(implementation),
            initData
        );
        proxy = WaveSendFund(payable(address(proxyContract)));
        console.log("Proxy (use this address):", address(proxy));

        vm.stopBroadcast();

        // ── Post-deploy verification ─────────────────────────────────────────
        _verify(
            admin,
            usdt,
            wbtc,
            wsnd,
            router,
            poolFee,
            nativeFee,
            nativeUsdtFee
        );
    }

    /// @dev Read-only checks run after broadcast — reverts on any mismatch.
    function _verify(
        address admin,
        address usdt,
        address wbtc,
        address wsnd,
        address router,
        uint24 poolFee,
        uint24 nativeFee,
        uint24 nativeUsdtFee
    ) internal view {
        console.log("\n=== Post-deploy verification ===");

        // Roles
        require(
            proxy.hasRole(proxy.DEFAULT_ADMIN_ROLE(), admin),
            "Verify: DEFAULT_ADMIN_ROLE not set"
        );
        require(
            proxy.hasRole(proxy.OPERATOR_ROLE(), admin),
            "Verify: OPERATOR_ROLE not set"
        );
        require(
            proxy.hasRole(proxy.UPGRADER_ROLE(), admin),
            "Verify: UPGRADER_ROLE not set"
        );
        console.log("[OK] Roles assigned to admin");

        // Tokens
        require(address(proxy.usdt()) == usdt, "Verify: USDT mismatch");
        require(address(proxy.wbtc()) == wbtc, "Verify: WBTC mismatch");
        require(address(proxy.wsnd()) == wsnd, "Verify: WSND mismatch");
        console.log("[OK] Token addresses");

        // Router & fee
        require(
            address(proxy.swapRouter()) == router,
            "Verify: router mismatch"
        );
        require(proxy.poolFee() == poolFee, "Verify: poolFee mismatch");
        require(proxy.nativeFee() == nativeFee, "Verify: nativeFee mismatch");
        console.log("[OK] Router and pool fee");

        // Default ratio
        require(proxy.wsndPerWbtc() == 1e18, "Verify: wsndPerWbtc mismatch");
        console.log("[OK] Default WSND ratio (1:1 face value)");

        // Pool starts empty
        require(proxy.totalPoolHashrate() == 0, "Verify: hashrate not zero");
        console.log("[OK] Total pool hashrate starts at 0");

        console.log("\nDeployment successful.");
        console.log("Proxy address:", address(proxy));
        console.log("Impl  address:", address(implementation));
    }
}
