// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title YieldFarmToken
 * @dev Reward token for the yield farm
 */
contract YieldFarmToken is ERC20("Yield Farm Token", "YFT"), Ownable(msg.sender) {    
    mapping(address => bool) public minters;
    

    modifier onlyMinter() {
        require(minters[msg.sender], "Not authorized to mint");
        _; 
    }
    
    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }
    // @audit-info is it safe to have multiple minters?
    // @audit-info is the visibility supposed to be external?
    
    function addMinter(address minter) external onlyOwner {
        minters[minter] = true; 
    }
    
    function removeMinter(address minter) external onlyOwner {
        minters[minter] = false;
    }
    
}
