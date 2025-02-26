import { ethers } from "hardhat";
async function main() {
  const WaveSend = await ethers.getContractFactory("WaveSend");
  const waveSend = await WaveSend.deploy();
  await waveSend.waitForDeployment()
  const waveSendAddress = await waveSend.getAddress();
  console.log("WaveSend: ", waveSendAddress);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
