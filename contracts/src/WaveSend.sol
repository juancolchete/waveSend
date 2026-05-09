// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract WaveSend is ERC20 {
    constructor() ERC20("Wave Send", "WSND") {
      _mint(msg.sender, 1000000000 * 10 ** decimals());
    }
}
