const { ethers } = require("hardhat");
const hre = require("hardhat");
require("@nomiclabs/hardhat-web3");

async function main() {

    const Lock = await hre.ethers.getContractFactory("deploy1776");
    const lock = await Lock.deploy();    

    await lock.deployed();

    console.log(
      `deployed to ${lock.address}`
      );
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
