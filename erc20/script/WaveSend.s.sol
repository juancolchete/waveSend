// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {WaveSend} from "../src/WaveSend.sol";

contract WaveSendScript is Script {
  WaveSend public waveSend;

  function run() public {
    vm.startBroadcast();
    waveSend = new WaveSend();
    vm.stopBroadcast();
  }
}

