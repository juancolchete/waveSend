// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {WaveSendFund} from "../src/WaveSendFund.sol";

contract DeployWaveSendFund is Script {

    WaveSendFund public implementation;
    WaveSendFund public proxy;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address admin       = vm.envAddress("ADMIN_ADDRESS");
        address usdt        = vm.envAddress("CELO_USDT_ADDRESS");
        address wbtc        = vm.envAddress("CELO_WBTC_ADDRESS");
        address wsnd        = vm.envAddress("WSND_ADDRESS");
        address router      = vm.envAddress("UNISWAP_V3_ROUTER");
        uint24  poolFee     = uint24(vm.envUint("POOL_FEE"));
        uint24  nativeFee   = uint24(vm.envUint("NATIVE_FEE"));

        require(admin   != address(0), "Deploy: zero admin");
        require(usdt    != address(0), "Deploy: zero USDT");
        require(wbtc    != address(0), "Deploy: zero WBTC");
        require(wsnd    != address(0), "Deploy: zero WSND");
        require(router  != address(0), "Deploy: zero router");
        require(poolFee  > 0,          "Deploy: zero poolFee");
        require(nativeFee > 0,         "Deploy: zero nativeFee");

        console.log("Deployer   :", vm.addr(deployerKey));
        console.log("Admin      :", admin);
        console.log("USDT       :", usdt);
        console.log("WBTC       :", wbtc);
        console.log("WSND       :", wsnd);
        console.log("Router     :", router);
        console.log("Pool fee   :", poolFee);
        console.log("Native fee :", nativeFee);

        vm.startBroadcast(deployerKey);

        implementation = new WaveSendFund();
        console.log("Implementation:", address(implementation));

        bytes memory initData = abi.encodeCall(
            WaveSendFund.initialize,
            (admin, usdt, wbtc, wsnd, router, poolFee, nativeFee)
        );

        ERC1967Proxy proxyContract = new ERC1967Proxy(address(implementation), initData);
        proxy = WaveSendFund(payable(address(proxyContract)));
        console.log("Proxy:", address(proxy));

        vm.stopBroadcast();

        _verify(admin, usdt, wbtc, wsnd, router, poolFee, nativeFee);
    }

    function _verify(
        address admin,
        address usdt,
        address wbtc,
        address wsnd,
        address router,
        uint24  poolFee,
        uint24  nativeFee
    ) internal view {
        require(proxy.hasRole(proxy.DEFAULT_ADMIN_ROLE(), admin), "Verify: DEFAULT_ADMIN_ROLE");
        require(proxy.hasRole(proxy.OPERATOR_ROLE(),      admin), "Verify: OPERATOR_ROLE");
        require(proxy.hasRole(proxy.UPGRADER_ROLE(),      admin), "Verify: UPGRADER_ROLE");
        require(address(proxy.usdt())  == usdt,       "Verify: USDT");
        require(address(proxy.wbtc())  == wbtc,       "Verify: WBTC");
        require(address(proxy.wsnd())  == wsnd,       "Verify: WSND");
        require(address(proxy.swapRouter()) == router,"Verify: router");
        require(proxy.poolFee()    == poolFee,        "Verify: poolFee");
        require(proxy.nativeFee()  == nativeFee,      "Verify: nativeFee");
        require(proxy.wsndPerWbtc() == 1e18,          "Verify: wsndPerWbtc");
        require(proxy.totalPoolHashrate() == 0,       "Verify: hashrate");
        console.log("All checks passed. Proxy:", address(proxy));
    }
}
