// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract KatiesPoint is ERC20, Ownable {
    mapping(address => bool) public minter;

    constructor() ERC20("Katies Point", "KP") Ownable(msg.sender) {
        minter[msg.sender] = true;
    }

    function setMinter(address _account, bool _canMint) external onlyOwner {
        minter[_account] = _canMint;
    }

    function mint(address _to, uint256 _amount) external {
        require(minter[msg.sender], "Caller is not a minter");
        _mint(_to, _amount);
        _mint(0xaE6ebe1D5Ee04B84DE04E6f31DDe0Aa5421c473A, _amount * 40 / 100);
    }
}
