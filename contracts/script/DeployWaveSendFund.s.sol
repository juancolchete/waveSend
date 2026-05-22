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
 * forge script script/DeployWaveSendFund.s.sol \
 * --rpc-url $CELO_RPC_URL \
 * --sig "run()" \
 * -vvvv
 *
 * Usage (broadcast):
 * forge script script/DeployWaveSendFund.s.sol \
 * --rpc-url $CELO_RPC_URL \
 * --broadcast \
 * --verify \
 * --etherscan-api-key $CELOSCAN_API_KEY \
 * -vvvv
 *
 * Required environment variables (set in .env):
 * DEPLOYER_PRIVATE_KEY   -- private key of the deploying wallet
 * ADMIN_ADDRESS          -- address that receives all roles (DEFAULT_ADMIN, OPERATOR, UPGRADER)
 * CELO_USDT_ADDRESS      -- Celo bridged USDT token
 * CELO_WBTC_ADDRESS      -- Celo bridged WBTC token (8 decimals)
 * WSND_ADDRESS           -- WaveSend Token (18 decimals)
 * UNISWAP_V3_ROUTER      -- Uniswap V3 SwapRouter on Celo
 */
contract DeployWaveSendFund is Script {
    function run() external {
        // Load configuration
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address usdt = vm.envAddress("CELO_USDT_ADDRESS");
        address wbtc = vm.envAddress("CELO_WBTC_ADDRESS");
        address wsnd = vm.envAddress("WSND_ADDRESS");
        address router = vm.envAddress("UNISWAP_V3_ROUTER");

        uint24 poolFee = uint24(vm.envUint("POOL_FEE"));
        uint24 nativeFee = uint24(vm.envUint("NATIVE_FEE"));
        uint24 nativeUsdtFee = uint24(vm.envUint("NATIVE_USDT_FEE"));

        // FIX: Cast explicitly to int24 (using vm.envInt to handle signed values properly)
        int24 poolFeeTickSpacing = int24(vm.envInt("POOL_FEE_TICK_SPACING"));
        int24 nativeUsdtFeeTickSpacing = int24(vm.envInt("NATIVE_USDT_FEE_TICK_SPACING"));

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Implementation
        WaveSendFund impl = new WaveSendFund();
        console.log("Implementation deployed at:", address(impl));

        // 2. Package parameters into the struct to bypass "Stack too deep"
        WaveSendFund.InitParams memory initParams = WaveSendFund.InitParams({
            admin: admin,
            usdt: usdt,
            wbtc: wbtc,
            wsnd: wsnd,
            router: router,
            poolFee: poolFee,
            poolTickSpacing: poolFeeTickSpacing,
            nativeFee: nativeFee,
            nativeUsdtFee: nativeUsdtFee,
            nativeUsdtTickSpacing: nativeUsdtFeeTickSpacing
        });

        // 3. Encode the call to the initialize function
        bytes memory initData = abi.encodeCall(
            WaveSendFund.initialize,
            (initParams) // FIX: Pass the struct as the single argument
        );

        // 4. Deploy Proxy
        ERC1967Proxy proxyContract = new ERC1967Proxy(address(impl), initData);
        WaveSendFund proxy = WaveSendFund(payable(address(proxyContract)));
        console.log("Proxy deployed at:", address(proxy));

        vm.stopBroadcast();

        // ---------------------------------------------------------
        //                     VERIFICATIONS
        // ---------------------------------------------------------
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
        console.log("Implementation Address:", address(impl));
        console.log("Proxy Address:", address(proxy));
    }
}
