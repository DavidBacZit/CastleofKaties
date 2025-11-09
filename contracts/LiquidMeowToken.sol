// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts@4.9.6/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts@4.9.6/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts@4.9.6/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts@4.9.6/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts@4.9.6/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts@4.9.6/security/Pausable.sol";
import "@openzeppelin/contracts@4.9.6/access/Ownable.sol";
import "@openzeppelin/contracts@4.9.6/token/ERC20/IERC20.sol";

interface ILiquidMeowRWD {
    function mint(address to, uint256 amount) external;
}

contract LiquidMeowToken is
    ERC20,
    ERC20Permit,
    ReentrancyGuard,
    Pausable,
    Ownable,
    IERC721Receiver
{
    uint8 private constant DECIMALS = 18;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant LMT_PER_NFT = 10000 * PRECISION;
    uint256 public constant SPECIFIC_FEE = 200 * PRECISION;

    uint256 public rewardPerBlock = 45 * (10**17);

    ILiquidMeowRWD public immutable rwdToken;
    address public treasury;

    struct VaultItem {
        address nft;
        uint256 tokenId;
        address depositor;
        uint256 depositedBlock;
    }
    VaultItem[] public vault;
    mapping(bytes32 => uint256) public indexOf; // stored as idx+1, 0 means not present

    uint256 public rewardPerTokenStored;
    uint256 public lastUpdateBlock;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event Deposited(address indexed depositor, address indexed nft, uint256 indexed tokenId, uint256 vaultIndex);
    event WithdrawnLIFO(address indexed caller, address indexed nft, uint256 indexed tokenId);
    event WithdrawnSpecific(address indexed caller, address indexed nft, uint256 indexed tokenId);
    event BatchDeposited(address indexed depositor, uint256 count);
    event BatchWithdrawnLIFO(address indexed caller, uint256 count);
    event BatchWithdrawnSpecific(address indexed caller, uint256 count);
    event TreasuryChanged(address indexed oldTreasury, address indexed newTreasury);
    event RewardPerBlockChanged(uint256 oldVal, uint256 newVal);
    event RewardsClaimed(address indexed user, address indexed to, uint256 amount);

    constructor(
        address _treasury,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) ERC20Permit(_name) {
        require(_treasury != owner(), "LM: treasury zero");
        treasury = _treasury;
        lastUpdateBlock = block.number;
    }

    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }

    // Update rewards accounting in token transfers
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override(ERC20) {
        _updateRewardPerToken();

        if (from != address(0)) {
            rewards[from] = earned(from);
            userRewardPerTokenPaid[from] = rewardPerTokenStored;
        }
        if (to != address(0)) {
            rewards[to] = earned(to);
            userRewardPerTokenPaid[to] = rewardPerTokenStored;
        }

        super._beforeTokenTransfer(from, to, amount);
    }

    function _updateRewardPerToken() internal {
        uint256 blocksElapsed = 0;
        if (block.number > lastUpdateBlock) {
            blocksElapsed = block.number - lastUpdateBlock;
        }
        if (blocksElapsed > 0) {
            uint256 supply = totalSupply();
            if (supply > 0) {
                uint256 accrued = (blocksElapsed * rewardPerBlock * PRECISION) / supply;
                rewardPerTokenStored += accrued;
            }
            lastUpdateBlock = block.number;
        }
    }

    function earned(address account) public view returns (uint256) {
        uint256 _rewardPerTokenStored = rewardPerTokenStored;
        uint256 blocksElapsed = 0;
        if (block.number > lastUpdateBlock) {
            blocksElapsed = block.number - lastUpdateBlock;
        }
        if (blocksElapsed > 0 && totalSupply() > 0) {
            uint256 accrued = (blocksElapsed * rewardPerBlock * PRECISION) / totalSupply();
            _rewardPerTokenStored += accrued;
        }
        uint256 _paid = userRewardPerTokenPaid[account];
        uint256 bal = balanceOf(account);
        uint256 pending = (bal * (_rewardPerTokenStored - _paid)) / PRECISION;
        return rewards[account] + pending;
    }

    function claimRewards() external nonReentrant {
        _claimFor(msg.sender);
    }

    function claimRewardsFor(address to) external nonReentrant {
        _claimFor(to);
    }

    function _claimFor(address to) internal {
        require(to != address(0), "LM: to zero");
        _updateRewardPerToken();
        rewards[to] = earned(to);
        userRewardPerTokenPaid[to] = rewardPerTokenStored;
        uint256 payment = rewards[to];
        if (payment == 0) {
            emit RewardsClaimed(msg.sender, to, 0);
            return;
        }
        rewards[to] = 0;
        rwdToken.mint(to, payment);
        emit RewardsClaimed(msg.sender, to, payment);
    }

    function deposit(address nft, uint256 tokenId) external nonReentrant whenNotPaused {
        _depositFor(msg.sender, nft, tokenId);
    }

    function depositBatch(address[] calldata nfts, uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
        require(nfts.length == tokenIds.length, "LM: len mismatch");
        for (uint256 i = 0; i < nfts.length; i++) {
            _depositFor(msg.sender, nfts[i], tokenIds[i]);
        }
        emit BatchDeposited(msg.sender, nfts.length);
    }

    function _depositFor(address depositor, address nft, uint256 tokenId) internal {
        require(nft != address(0), "LM: nft zero");
        bytes32 key = keccak256(abi.encodePacked(nft, tokenId));
        require(indexOf[key] == 0, "LM: already in vault");
        require(IERC721(nft).ownerOf(tokenId) == address(this), "LM: not received");
        VaultItem memory item = VaultItem({ nft: nft, tokenId: tokenId, depositor: depositor, depositedBlock: block.number });
        vault.push(item);
        uint256 idx = vault.length - 1;
        indexOf[key] = idx + 1;
        _mint(depositor, LMT_PER_NFT);
        emit Deposited(depositor, nft, tokenId, idx);
    }

    function withdrawLIFO() external nonReentrant whenNotPaused {
        require(vault.length > 0, "LM: vault empty");
        _burn(msg.sender, LMT_PER_NFT);
        VaultItem memory item = vault[vault.length - 1];
        bytes32 key = keccak256(abi.encodePacked(item.nft, item.tokenId));
        indexOf[key] = 0;
        vault.pop();
        IERC721(item.nft).safeTransferFrom(address(this), msg.sender, item.tokenId);
        emit WithdrawnLIFO(msg.sender, item.nft, item.tokenId);
    }

    function withdrawLIFOBatch(uint256 count) external nonReentrant whenNotPaused {
        require(count > 0 && count <= vault.length, "LM: invalid count");
        uint256 totalBurn = LMT_PER_NFT * count;
        _burn(msg.sender, totalBurn);
        for (uint256 i = 0; i < count; i++) {
            VaultItem memory item = vault[vault.length - 1];
            bytes32 key = keccak256(abi.encodePacked(item.nft, item.tokenId));
            indexOf[key] = 0;
            vault.pop();
            IERC721(item.nft).safeTransferFrom(address(this), msg.sender, item.tokenId);
            emit WithdrawnLIFO(msg.sender, item.nft, item.tokenId);
        }
        emit BatchWithdrawnLIFO(msg.sender, count);
    }

    function withdrawSpecific(address nft, uint256 tokenId) external nonReentrant whenNotPaused {
        bytes32 key = keccak256(abi.encodePacked(nft, tokenId));
        uint256 idxPlus1 = indexOf[key];
        require(idxPlus1 != 0, "LM: not in vault");
        uint256 idx = idxPlus1 - 1;
        _burn(msg.sender, LMT_PER_NFT);
        _transfer(msg.sender, treasury, SPECIFIC_FEE);
        uint256 lastIdx = vault.length - 1;
        if (idx != lastIdx) {
            VaultItem memory lastItem = vault[lastIdx];
            vault[idx] = lastItem;
            bytes32 lastKey = keccak256(abi.encodePacked(lastItem.nft, lastItem.tokenId));
            indexOf[lastKey] = idx + 1;
        }
        indexOf[key] = 0;
        vault.pop();
        _mint(treasury, SPECIFIC_FEE);
        IERC721(nft).safeTransferFrom(address(this), msg.sender, tokenId);
        emit WithdrawnSpecific(msg.sender, nft, tokenId);
    }

    function withdrawSpecificBatch(address[] calldata nfts, uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
        require(nfts.length == tokenIds.length && nfts.length > 0, "LM: invalid input");
        uint256 count = nfts.length;
        _transfer(msg.sender, treasury, SPECIFIC_FEE * count);
        _burn(msg.sender, LMT_PER_NFT * count);
        for (uint256 i = 0; i < count; i++) {
            bytes32 key = keccak256(abi.encodePacked(nfts[i], tokenIds[i]));
            uint256 idxPlus1 = indexOf[key];
            require(idxPlus1 != 0, "LM: not in vault");
            uint256 idx = idxPlus1 - 1;
            uint256 lastIdx = vault.length - 1;
            if (idx != lastIdx) {
                VaultItem memory lastItem = vault[lastIdx];
                vault[idx] = lastItem;
                bytes32 lastKey = keccak256(abi.encodePacked(lastItem.nft, lastItem.tokenId));
                indexOf[lastKey] = idx + 1;
            }
            indexOf[key] = 0;
            vault.pop();
            _mint(treasury, SPECIFIC_FEE);
            IERC721(nfts[i]).safeTransferFrom(address(this), msg.sender, tokenIds[i]);
            emit WithdrawnSpecific(msg.sender, nfts[i], tokenIds[i]);
        }
        emit BatchWithdrawnSpecific(msg.sender, count);
    }

    // Implement IERC721Receiver: ensures contract can receive safeTransferFrom
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata) external override returns (bytes4) {
        require(IERC721(msg.sender).ownerOf(tokenId) == address(this), "LM: not owned after transfer");
        _depositFor(from, msg.sender, tokenId);
        return this.onERC721Received.selector;
    }

    // Admins
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "LM: treasury zero");
        address old = treasury;
        treasury = _treasury;
        emit TreasuryChanged(old, _treasury);
    }

    function setRewardPerBlock(uint256 _rewardPerBlock) external onlyOwner {
        require(_rewardPerBlock > 0, "LM: zero reward");
        uint256 old = rewardPerBlock;
        rewardPerBlock = _rewardPerBlock;
        emit RewardPerBlockChanged(old, _rewardPerBlock);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // Rescue helpers
    function rescueERC721(address nft, uint256 tokenId, address to) external onlyOwner {
        require(to != address(0), "LM: rescue to zero");
        IERC721(nft).safeTransferFrom(address(this), to, tokenId);
    }

    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(this), "LM: cannot rescue LMT");
        IERC20(token).transfer(to, amount);
    }

    receive() external payable {}
    fallback() external payable {}
}
