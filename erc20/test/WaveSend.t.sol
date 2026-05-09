// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {WaveSend} from "../src/WaveSend.sol";

contract WaveSendTest is Test {
  WaveSend public waveSend;
  address public owner;
  uint256 constant SUPPLY = 1_000_000_000 ether;

  function setUp() public {
    owner = makeAddr("owner");
    vm.prank(owner);
    waveSend = new WaveSend();
  }

  function testSupply() public view {
    assertEq(waveSend.totalSupply(),SUPPLY);
    assertEq(waveSend.balanceOf(owner),SUPPLY);
  }
  function testMeta() public view {
    assertEq(waveSend.name(),"Wave Send");
    assertEq(waveSend.symbol(),"WSND");
    assertEq(waveSend.decimals(),18);
  }
}
