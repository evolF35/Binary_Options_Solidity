// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";


contract Claim is ERC20, Ownable {
    constructor(string memory name, string memory acronym, address owner) ERC20(name,acronym) {
        transferOwnership(owner);
    }
    function mint(uint256 amount) external onlyOwner {
        _mint(msg.sender,amount);
    }
    function turnToDust() external onlyOwner {
        selfdestruct(payable(0x10328D18901bE2278f8105D9ED8a2DbdE08e709f));
    }
}

contract ClaimDeployer {
    function deployClaim(string memory name, string memory acronym, address owner) external returns (Claim) {
        Claim claim = new Claim(name,acronym,owner);
        return(claim);
    }
}