// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts@4.9.6/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts@4.9.6/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts@4.9.6/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts@4.9.6/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts@4.9.6/utils/math/Math.sol";
import "@openzeppelin/contracts@4.9.6/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts@4.9.6/security/Pausable.sol";
import "@openzeppelin/contracts@4.9.6/access/Ownable.sol";

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
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LMT_PER_NFT = 10000 * PRECISION;
    uint256 private constant SPECIFIC_FEE = 200 * PRECISION;
    uint256 private constant MAX_BATCH = 20;
    uint256 public rewardPerBlock = 45 * (10**17);

    ILiquidMeowRWD private constant rwdToken = ILiquidMeowRWD(0x2787CEd626674aBfC0FfB9bd1EEB7e1d5039A740);
    address public treasury;
    address public pendingTreasury;
    uint256 public pendingTreasuryTimestamp;
    uint48 private constant TREASURY_CHANGE_DELAY = 1 days;

    struct VaultItem {
        address nft;
        address depositor;
        uint256 tokenId;
        uint256 depositedBlock;
    }

    VaultItem[] public vault;
    mapping(bytes32 => uint256) public indexOf; // stored as idx+1, 0 means not present

    // Reward bookkeeping
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
    event TreasuryProposed(address indexed proposed);
    event RewardPerTokenUpdated(uint256 indexed rewardPerTokenStored);

    constructor(
        address _treasury,
        string memory _name,
        string memory _symbol
    ) payable ERC20(_name, _symbol) ERC20Permit(_name) {
        require(_treasury != address(0), "LM: treasury zero");
        treasury = _treasury;
        lastUpdateBlock = block.number;
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /// @dev Update rewards for `from` and `to` before token transfers (mint/burn/transfer).
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override(ERC20) {
        if (amount == 0) {
            super._beforeTokenTransfer(from, to, amount);
            return;
        }

        _updateRewardPerToken();

        uint256 cachedRewardPerTokenStored = rewardPerTokenStored; // Cache the storage variable

        if (from != address(0)) {
            uint256 earnedFrom = earned(from);
            rewards[from] = earnedFrom;
            userRewardPerTokenPaid[from] = cachedRewardPerTokenStored;
        }
        if (to != address(0)) {
            uint256 earnedTo = earned(to);
            rewards[to] = earnedTo;
            userRewardPerTokenPaid[to] = cachedRewardPerTokenStored;
        }

        super._beforeTokenTransfer(from, to, amount);
    }

    /// @dev Canonical update: add accrued rewardPerToken based on blocks elapsed and supply.
    function _updateRewardPerToken() internal {
        uint256 currentBlk = block.number;
        uint256 blocksElapsed;
        unchecked { blocksElapsed = currentBlk - lastUpdateBlock; } // safe: if negative won't happen in solidity unsigned

        if (blocksElapsed == 0) {
            return;
        }

        uint256 supply = totalSupply();
        uint256 rewardPerTokenStoredCache = rewardPerTokenStored; // Cache in memory

        if (supply != 0) {
            // accrued = blocksElapsed * rewardPerBlock * PRECISION / supply
            uint256 a = Math.mulDiv(blocksElapsed, rewardPerBlock, 1);
            uint256 accrued = Math.mulDiv(a, PRECISION, supply);
            rewardPerTokenStoredCache += accrued;
            emit RewardPerTokenUpdated(rewardPerTokenStoredCache);
        }

        rewardPerTokenStored = rewardPerTokenStoredCache; // Update storage once
        lastUpdateBlock = currentBlk;
    }

    /// @dev View helper: compute what `earned(account)` would be right now (without changing state).
    function earned(address account) public view returns (uint256) {
        uint256 _rewardPerTokenStored = rewardPerTokenStored;
        uint256 _lastUpdateBlock = lastUpdateBlock;
        uint256 _rewardPerBlock = rewardPerBlock;
        uint256 _precision = PRECISION;
        uint256 _userRewardPerTokenPaid = userRewardPerTokenPaid[account];
        uint256 _rewards = rewards[account];
        uint256 _balance = balanceOf(account);
        uint256 _totalSupply = totalSupply();

        uint256 blocksElapsed = 0;
        if (block.number > _lastUpdateBlock) {
            unchecked { blocksElapsed = block.number - _lastUpdateBlock; }
        }

        if (blocksElapsed != 0 && _totalSupply != 0) {
            uint256 a = Math.mulDiv(blocksElapsed, _rewardPerBlock, 1);
            uint256 accrued = Math.mulDiv(a, _precision, _totalSupply);
            _rewardPerTokenStored += accrued;
        }

        uint256 deltaPerToken = 0;
        if (_rewardPerTokenStored > _userRewardPerTokenPaid) {
            deltaPerToken = _rewardPerTokenStored - _userRewardPerTokenPaid;
        }

        uint256 pending = 0;
        if (_balance != 0 && deltaPerToken != 0) {
            pending = Math.mulDiv(_balance, deltaPerToken, _precision);
        }

        return _rewards + pending;
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
        delete rewards[to];

        rwdToken.mint(to, payment);
        emit RewardsClaimed(msg.sender, to, payment);
    }

    function deposit(address nft, uint256 tokenId) external nonReentrant whenNotPaused {
        _depositFor(msg.sender, nft, tokenId);
    }

    function depositBatch(address[] calldata nfts, uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
        require(nfts.length == tokenIds.length, "LM: len mismatch");
        uint256 len = nfts.length;
        require(len < MAX_BATCH + 1, "LM: batch too large");
        for (uint256 i = 0; i < len; ++i) {
            _depositFor(msg.sender, nfts[i], tokenIds[i]);
        }
        emit BatchDeposited(msg.sender, nfts.length);
    }

    function _depositFor(address depositor, address nft, uint256 tokenId) internal {
        require(nft != address(0), "LM: nft zero");
        bytes32 key = keccak256(abi.encode(nft, tokenId));
        require(indexOf[key] == 0, "LM: already in vault");
        require(IERC721(nft).ownerOf(tokenId) == address(this), "LM: not received");
        VaultItem memory item;
        item.nft = nft;
        item.tokenId = tokenId;
        item.depositor = depositor;
        item.depositedBlock = block.number;

        vault.push(item);
        uint256 idx = vault.length - 1; // Cache vault.length in memory
        indexOf[key] = idx + 1;
        _mint(depositor, LMT_PER_NFT);
        emit Deposited(depositor, nft, tokenId, idx);
    }

    function withdrawLIFO() external nonReentrant whenNotPaused {
        uint256 vaultLength = vault.length; // Cache the vault length
        require(vaultLength != 0, "LM: vault empty");
        _burn(msg.sender, LMT_PER_NFT);
        VaultItem storage item = vault[vaultLength - 1];
        bytes32 key = keccak256(abi.encode(item.nft, item.tokenId));
        delete indexOf[key];
        vault.pop();
        IERC721(item.nft).safeTransferFrom(address(this), msg.sender, item.tokenId);
        emit WithdrawnLIFO(msg.sender, item.nft, item.tokenId);
    }

    function withdrawLIFOBatch(uint256 count) external nonReentrant whenNotPaused {
        require(count != 0, "LM: count must be greater than 0");
        uint256 vaultLength = vault.length; // Cache vault length
        require(count < vaultLength + 1, "LM: count exceeds vault length");
        require(count < MAX_BATCH + 1, "LM: batch too large");

        uint256 totalBurn = LMT_PER_NFT * count;
        _burn(msg.sender, totalBurn);

        for (uint256 i = 0; i < count; ++i) {
            VaultItem memory item = vault[vaultLength - 1];
            bytes32 key = keccak256(abi.encode(item.nft, item.tokenId));
            delete indexOf[key];
            vault.pop();
            IERC721(item.nft).safeTransferFrom(address(this), msg.sender, item.tokenId);
            emit WithdrawnLIFO(msg.sender, item.nft, item.tokenId);
            unchecked {
                vaultLength--; // Decrement the cached length
            }
        }
        emit BatchWithdrawnLIFO(msg.sender, count);
    }

    function withdrawSpecific(address nft, uint256 tokenId) external nonReentrant whenNotPaused {
        bytes32 key = keccak256(abi.encode(nft, tokenId));
        uint256 idxPlus1 = indexOf[key];
        require(idxPlus1 != 0, "LM: not in vault");
        uint256 idx = idxPlus1 - 1;

        // Require caller has sufficient LMT and fee
        require(balanceOf(msg.sender) >= LMT_PER_NFT + SPECIFIC_FEE, "LM: insufficient LMT+fee");

        // Transfer specific fee to treasury and burn LMT_PER_NFT from caller
        _transfer(msg.sender, treasury, SPECIFIC_FEE);
        _burn(msg.sender, LMT_PER_NFT);
        
        uint256 vaultLength = vault.length; // Cache vault.length in memory
        uint256 lastIdx = vaultLength - 1;
        
        if (idx != lastIdx) {
            VaultItem memory lastItem = vault[lastIdx];
            vault[idx] = lastItem;
            bytes32 lastKey = keccak256(abi.encode(lastItem.nft, lastItem.tokenId));
            indexOf[lastKey] = idx + 1;
        }
        delete indexOf[key];
        vault.pop();
        IERC721(nft).safeTransferFrom(address(this), msg.sender, tokenId);
        emit WithdrawnSpecific(msg.sender, nft, tokenId);
    }

    function withdrawSpecificBatch(address[] calldata nfts, uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
        require(nfts.length == tokenIds.length, "LM: lengths do not match");
        require(nfts.length != 0, "LM: input cannot be empty");

        uint256 count = nfts.length;

        require(count < MAX_BATCH + 1, "LM: batch too large");

        uint256 vaultLength = vault.length;
        require(count <= vaultLength, "LM: count exceeds vault length");

        // Validate all requested items are present before making transfers or burns
        for (uint256 i = 0; i < count; ++i) {
            bytes32 key = keccak256(abi.encode(nfts[i], tokenIds[i]));
            require(indexOf[key] != 0, "LM: not in vault");
        }

        // Require caller has sufficient total LMT and fees for the whole batch
        uint256 totalFee = SPECIFIC_FEE * count;
        uint256 totalBurn = LMT_PER_NFT * count;
        require(balanceOf(msg.sender) >= totalFee + totalBurn, "LM: insufficient LMT+fee");

        // Charge fees & burn once validated
        _transfer(msg.sender, treasury, totalFee);
        _burn(msg.sender, totalBurn);

        for (uint256 i = 0; i < count; ++i) {
            bytes32 key = keccak256(abi.encode(nfts[i], tokenIds[i]));
            uint256 idxPlus1 = indexOf[key];
            uint256 idx = idxPlus1 - 1;
            uint256 lastIdx = vault.length - 1; // compute dynamically
            if (idx != lastIdx) {
                VaultItem memory lastItem = vault[lastIdx];
                vault[idx] = lastItem;
                bytes32 lastKey = keccak256(abi.encode(lastItem.nft, lastItem.tokenId));
                indexOf[lastKey] = idx + 1;
            }
            delete indexOf[key];

            vault.pop();
            IERC721(nfts[i]).safeTransferFrom(address(this), msg.sender, tokenIds[i]);
            emit WithdrawnSpecific(msg.sender, nfts[i], tokenIds[i]);
        }
        emit BatchWithdrawnSpecific(msg.sender, count);
    }

    bytes4 private constant ERC721_RECEIVED = IERC721Receiver.onERC721Received.selector;
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata) external override nonReentrant returns (bytes4) {
        _depositFor(from, msg.sender, tokenId);
        return ERC721_RECEIVED;
    }

    // Admins
    function updateTreasury(address _newTreasury) external onlyOwner {
        require(_newTreasury != address(0), "LM: treasury zero");

        if (_newTreasury != treasury) {
            // If the new address is different from the current treasury, treat as a proposal
            if (pendingTreasury != _newTreasury) {
                pendingTreasury = _newTreasury;
                pendingTreasuryTimestamp = block.timestamp + TREASURY_CHANGE_DELAY;
                emit TreasuryProposed(_newTreasury);
                return;
            }

            // If the same as pending, check if timelock elapsed
            require(block.timestamp > pendingTreasuryTimestamp, "LM: too early to accept");

            address old = treasury;
            treasury = pendingTreasury;
            pendingTreasury = address(0);
            delete pendingTreasuryTimestamp;
            emit TreasuryChanged(old, treasury);
        }
    }

    function setRewardPerBlock(uint256 _rewardPerBlock) external onlyOwner {
        require(_rewardPerBlock != 0, "LM: zero reward");
        uint256 old = rewardPerBlock; // Cache the state variable
        if (old != _rewardPerBlock) {
            rewardPerBlock = _rewardPerBlock;
            emit RewardPerBlockChanged(old, _rewardPerBlock);
        }
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
