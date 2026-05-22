// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {WaveSendFund} from "../src/WaveSendFund.sol";

/**
 * @title  DeployWaveSendFund
 * @notice Foundry deployment script for WaveSendFund on Celo Mainnet.
 */
contract DeployWaveSendFund is Script {
    function run() external {
        // Only load the private key as a standalone variable
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Load all environment variables directly into the struct 
        // to bypass the "Stack too deep" limit in the EVM.
        WaveSendFund.InitParams memory params = WaveSendFund.InitParams({
            admin: vm.envAddress("ADMIN_ADDRESS"),
            usdt: vm.envAddress("CELO_USDT_ADDRESS"),
            wbtc: vm.envAddress("CELO_WBTC_ADDRESS"),
            wsnd: vm.envAddress("WSND_ADDRESS"),
            router: vm.envAddress("UNISWAP_V3_ROUTER"),
            poolFee: uint24(vm.envUint("POOL_FEE")),
            poolTickSpacing: int24(vm.envInt("POOL_FEE_TICK_SPACING")),
            nativeFee: uint24(vm.envUint("NATIVE_FEE")),
            nativeUsdtFee: uint24(vm.envUint("NATIVE_USDT_FEE")),
            nativeUsdtTickSpacing: int24(vm.envInt("NATIVE_USDT_FEE_TICK_SPACING"))
        });

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Implementation
        WaveSendFund impl = new WaveSendFund();
        console.log("Implementation deployed at:", address(impl));

        // 2. Encode the call to the initialize function
        bytes memory initData = abi.encodeCall(
            WaveSendFund.initialize,
            (params)
        );

        // 3. Deploy Proxy
        ERC1967Proxy proxyContract = new ERC1967Proxy(address(impl), initData);
        WaveSendFund proxy = WaveSendFund(payable(address(proxyContract)));
        console.log("Proxy deployed at:", address(proxy));

        vm.stopBroadcast();

        // ---------------------------------------------------------
        //                     VERIFICATIONS
        // ---------------------------------------------------------
        // We now reference params.admin, params.usdt, etc., avoiding stack limits
        
        require(
            proxy.hasRole(proxy.DEFAULT_ADMIN_ROLE(), params.admin),
            "Verify: DEFAULT_ADMIN_ROLE not set"
        );
        require(
            proxy.hasRole(proxy.OPERATOR_ROLE(), params.admin),
            "Verify: OPERATOR_ROLE not set"
        );
        require(
            proxy.hasRole(proxy.UPGRADER_ROLE(), params.admin),
            "Verify: UPGRADER_ROLE not set"
        );
        console.log("[OK] Roles assigned to admin");

        // Tokens
        require(address(proxy.usdt()) == params.usdt, "Verify: USDT mismatch");
        require(address(proxy.wbtc()) == params.wbtc, "Verify: WBTC mismatch");
        require(address(proxy.wsnd()) == params.wsnd, "Verify: WSND mismatch");
        console.log("[OK] Token addresses");

        // Router & fee
        require(
            address(proxy.swapRouter()) == params.router,
            "Verify: router mismatch"
        );
        require(proxy.poolFee() == params.poolFee, "Verify: poolFee mismatch");
        require(proxy.nativeFee() == params.nativeFee, "Verify: nativeFee mismatch");
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
