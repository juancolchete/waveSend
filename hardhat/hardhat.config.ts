import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@openzeppelin/hardhat-upgrades";
import "@nomiclabs/hardhat-ganache";

require('dotenv').config()
const low_conf = {
  version: "0.7.6",
  settings: {
    optimizer: {
      enabled: true,
      runs: 0,
    },
  }
}
const LOWEST_OPTIMIZER_COMPILER_SETTINGS = {
  version: '0.7.6',
  settings: {
    evmVersion: 'istanbul',
    optimizer: {
      enabled: true,
      runs: 1_000,
    },
    metadata: {
      bytecodeHash: 'none',
    },
  },
}

const config: HardhatUserConfig = {
  networks: {
    hardhat: {
      accounts: {
        count: 1100
      }
    },
  },
  solidity: {
    compilers: [
      {
        version: "0.8.22",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        }
      },
    ],
  },
};


if (process?.env?.PVK != null) {
  config!.networks!.scrollTestnet = {
    url: process.env.RPC_SCROLL_TESTNET,
    accounts: [process.env.PVK!]
  }
}



export default config;
