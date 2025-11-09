// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "@openzeppelin/contracts@4.9.0/access/AccessControl.sol";
import "@openzeppelin/contracts@4.9.0/token/ERC20/ERC20.sol";


contract KatiesPoint is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    uint256 public lastMintBlock;
    uint256 public ratePerBlock;

    address public recipient;

    event AccruedMinted(address indexed recipient, uint256 minted, uint256 fromBlock, uint256 toBlock);
    event RecipientChanged(address indexed oldRecipient, address indexed newRecipient);
    event RatePerBlockChanged(uint256 oldRate, uint256 newRate);

    constructor(address defaultAdmin, address minter) ERC20("Katies Point", "KP") {
        require(defaultAdmin != address(0), "defaultAdmin=0");
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(MINTER_ROLE, minter);

        recipient = defaultAdmin;
        lastMintBlock = block.number;

        ratePerBlock = 23 * 10 ** 17;
    }

    function claimable() public view returns (uint256) {
        if (block.number <= lastMintBlock) return 0;
        uint256 blocks = block.number - lastMintBlock;
        if (ratePerBlock == 0) return 0;
        require(blocks <= type(uint256).max / ratePerBlock, "overflow");
        return blocks * ratePerBlock;
    }

    function mintAccrued() public returns (uint256 minted) {
        if (block.number <= lastMintBlock) return 0;
        uint256 fromBlock = lastMintBlock;
        uint256 blocks = block.number - fromBlock;

        if (ratePerBlock == 0) {
            lastMintBlock = block.number;
            return 0;
        }
        require(blocks <= type(uint256).max / ratePerBlock, "overflow");

        uint256 toMint = blocks * ratePerBlock;
        if (toMint == 0) {
            lastMintBlock = block.number;
            return 0;
        }

        lastMintBlock = block.number;
        _mint(recipient, toMint);
        emit AccruedMinted(recipient, toMint, fromBlock, block.number);
        return toMint;
    }

    function setRecipient(address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRecipient != address(0), "recipient=0");
        address old = recipient;
        recipient = newRecipient;
        emit RecipientChanged(old, newRecipient);
    }

    function setRatePerBlock(uint256 newRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRate != 0, "rate=0");
        uint256 old = ratePerBlock;

        if (block.number > lastMintBlock) {
            mintAccrued();
        }

        ratePerBlock = newRate;
        emit RatePerBlockChanged(old, newRate);
    }

    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        mintAccrued();
        _mint(to, amount);
    }
}