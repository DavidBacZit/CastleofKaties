// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Import standard ERC20 and ownership management from OpenZeppelin
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract CustomMintERC20 is ERC20, Ownable {
    // Mapping to store addresses that are allowed to mint tokens
    mapping(address => bool) public minter;

    // Block number when rewards were last accrued
    uint256 public lastAccruedBlock;

    // Number of tokens minted per block (2.3 tokens with 18 decimals)
    // 2.3 * 10^18 = 23 * 10^17
    uint256 public constant TOKENS_PER_BLOCK = 23 * 10**17;

    // Constructor sets token name, symbol and makes deployer the initial owner
    constructor(
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) Ownable(msg.sender) {
        // Optionally set the contract deployer as a minter
        minter[msg.sender] = true;

        // Initialize lastAccruedBlock to the current block at deployment
        lastAccruedBlock = block.number;
    }

    // Function for the owner to add or remove minters
    function setMinter(address _account, bool _canMint) external onlyOwner {
        // Update minter status for the given address
        minter[_account] = _canMint;
    }

    // Internal function to mint accrued tokens to the owner based on blocks passed
    function _mintAccrued() internal {
        // Get current block number
        uint256 currentBlock = block.number;

        // If no new blocks have passed since last accrual, do nothing
        if (currentBlock <= lastAccruedBlock) {
            return;
        }

        // Calculate how many blocks have passed
        uint256 blocksElapsed = currentBlock - lastAccruedBlock;

        // Calculate the total amount of tokens to mint:
        // blocksElapsed * TOKENS_PER_BLOCK
        uint256 amountToMint = blocksElapsed * TOKENS_PER_BLOCK;

        // Update the last accrued block to the current block
        lastAccruedBlock = currentBlock;

        // Mint the accrued tokens to the owner
        _mint(owner(), amountToMint);
    }

    // Public function to manually trigger minting of accrued tokens to the owner
    function mintAccrued() external {
        _mintAccrued();
    }

    // Mint function that can only be called by allowed minters
    function mint(address _to, uint256 _amount) external {
        // Check if the caller is in the minter mapping
        require(minter[msg.sender], "Caller is not a minter");

        // First, mint tokens to the specified address
        _mint(_to, _amount);

        // Then, also mint accrued tokens to the owner based on blocks passed
        _mintAccrued();
    }
}
