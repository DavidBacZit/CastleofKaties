// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface ILiquidMeowRWD {
    function mint(address to, uint256 amount) external;
}

/**
 * @title LiquidMeowTokenV2 (Liquid Katies Token)
 * @notice
 *  - ERC20 wrapper token for NFTs from the KATIES collection.
 *  - 1 NFT -> 10000 LKT (LMT_PER_NFT).
 *  - Users deposit KATIES NFTs to receive LKT and withdraw NFTs by burning LKT.
 *
 *  Reward model (RWD token emissions):
 *  - Rewards are emitted at a rate of `rewardPerBlockPerNFT` RWD per block for each
 *    NFT-equivalent of stake (i.e., per 10000 LKT).
 *  - The global accumulator `rewardPerTokenStored` tracks accrued rewards per 1 LKT
 *    (scaled by PRECISION) from the beginning up to `lastUpdateBlock`.
 *  - User rewards are tracked via `userRewardPerTokenPaid` and `rewards`.
 *
 *  Security:
 *  - Uses ReentrancyGuard on all external functions that touch external contracts.
 *  - Uses Pausable to allow pausing deposits/withdrawals in emergencies.
 *  - All external calls (NFT transfers, RWD minting) are done after internal state updates
 *    (checks-effects-interactions).
 */
contract LiquidMeowTokenV2 is
    ERC20,
    ERC20Permit,
    ReentrancyGuard,
    Pausable,
    Ownable(0x25Ea0aEEfea7EAb97A163382c5B230e2E8dF5E1e),
    IERC721Receiver
{
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 private constant PRECISION = 1e18;
    uint256 private constant LMT_PER_NFT = 10000 * PRECISION;
    uint256 private constant SPECIFIC_FEE = 200 * PRECISION;
    uint256 private constant MAX_BATCH = 20;

    // upper bound to avoid overflow in reward calculations (M2)
    uint256 public constant MAX_REWARD_PER_BLOCK_PER_NFT = 1e36;

    /// @notice KATIES NFT collection
    address public constant KATIES =
        0x0a34eF3DAfD247eA4D66B8CC459CDcc8f5695234;

    /// @notice RWD token minter interface
    ILiquidMeowRWD private constant rwdToken =
        ILiquidMeowRWD(0xF8991d92c1e259867886CAF259Ce2016d1F05E05);

    // -------------------------------------------------------------------------
    // Reward configuration
    // -------------------------------------------------------------------------

    /**
     * @notice Reward emitted per block for each 1 NFT-equivalent of stake
     *         (i.e., per 10000 LKT).
     *
     * Units: RWD tokens (18 decimals) per block per NFT.
     *
     * Conceptually:
     *   #NFT = totalSupply / LMT_PER_NFT
     *   totalRewardPerBlock = rewardPerBlockPerNFT * (#NFT)
     *                       = rewardPerBlockPerNFT * (totalSupply / LMT_PER_NFT)
     */
    uint256 public rewardPerBlockPerNFT;

    /**
     * @notice Global accumulator of rewards per 1 LKT, scaled by PRECISION.
     *         This encodes the total RWD accrued per LKT from the beginning
     *         up to `lastUpdateBlock`.
     *
     * Units: (RWD per LKT) * PRECISION.
     */
    uint256 public rewardPerTokenStored;

    /// @notice Last block at which `rewardPerTokenStored` was updated.
    uint256 public lastUpdateBlock;

    /// @notice Per-user snapshot of `rewardPerTokenStored` at last settlement.
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @notice Accumulated but unclaimed rewards for each user.
    mapping(address => uint256) public rewards;

    // -------------------------------------------------------------------------
    // Vault (NFT) state
    // -------------------------------------------------------------------------

    /// @notice Treasury wallet receiving specific withdrawal fees
    address public treasury;

    // (L2) Simplified: remove unused depositor and depositedBlock
    struct VaultItem {
        uint256 tokenId;
    }

    VaultItem[] public vault;

    // stored as idx+1, 0 means not present
    mapping(bytes32 => uint256) public indexOf;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event Deposited(
        address indexed depositor,
        uint256 indexed tokenId,
        uint256 vaultIndex
    );
    event Withdrawn(address indexed caller, uint256 indexed tokenId);
    event TreasuryChanged(address indexed oldTreasury, address indexed newTreasury);

    /// @notice Emitted when rewardPerBlockPerNFT is changed by the owner.
    event RewardPerBlockPerNFTChanged(uint256 oldVal, uint256 newVal);

    event RewardsClaimed(address indexed user, address indexed to, uint256 amount);
    event RewardPerTokenUpdated(uint256 indexed rewardPerTokenStored);

    // (L3) Event for rescue of untracked NFTs
    event UntrackedKatiesRescued(uint256 indexed tokenId, address indexed to);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor()
        payable
        ERC20("Liquid Katies Token", "LKT")
        ERC20Permit("Liquid Katies Token")
    {
        treasury = 0x25Ea0aEEfea7EAb97A163382c5B230e2E8dF5E1e;
        lastUpdateBlock = block.number;

        // NOTE: rewardPerBlockPerNFT is initialized to zero.
        // Emissions are off until the owner calls setRewardPerBlockPerNFT().
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    // -------------------------------------------------------------------------
    // Core reward accounting
    // -------------------------------------------------------------------------

    /**
     * @dev Internal hook called by ERC20 on mint/burn/transfer.
     *
     * Invariant: Whenever balances change, we first settle global and per-user
     * reward state so that rewards are attributed to the previous balance.
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20) {
        if (value == 0) {
            // No balance change; avoid unnecessary reward updates.
            super._update(from, to, value);
            return;
        }

        // 1) Update global reward state (pool level)
        _updateRewardPerToken();

        uint256 cachedRewardPerTokenStored = rewardPerTokenStored;

        // 2) Settle rewards for `from` (if not minting)
        if (from != address(0)) {
            uint256 earnedFrom = earned(from);
            rewards[from] = earnedFrom;
            userRewardPerTokenPaid[from] = cachedRewardPerTokenStored;
        }

        // 3) Settle rewards for `to` (if not burning)
        if (to != address(0)) {
            uint256 earnedTo = earned(to);
            rewards[to] = earnedTo;
            userRewardPerTokenPaid[to] = cachedRewardPerTokenStored;
        }

        // 4) Finally, perform the ERC20 balance update
        super._update(from, to, value);
    }

    /**
     * @notice Update global reward accumulator `rewardPerTokenStored` up to the
     *         current block.
     *
     * Reward model:
     *   For each block:
     *     deltaRewardPerToken = rewardPerBlockPerNFT * PRECISION / LMT_PER_NFT
     *
     * Over `blocksElapsed` blocks, accrued increment is:
     *   accrued = blocksElapsed * rewardPerBlockPerNFT * PRECISION / LMT_PER_NFT
     *
     * This is added to `rewardPerTokenStored`, which tracks RWD-per-LKT
     * (scaled by PRECISION) from the start up to `lastUpdateBlock`.
     *
     * We require:
     *   - totalSupply() != 0  so we don't accrue when nobody is staked.
     *   - rewardPerBlockPerNFT != 0 so that rate = 0 disables emissions cleanly.
     */
    function _updateRewardPerToken() internal {
        uint256 currentBlk = block.number;
        uint256 blocksElapsed;

        unchecked {
            // safe: block.number >= lastUpdateBlock
            blocksElapsed = currentBlk - lastUpdateBlock;
        }

        if (blocksElapsed == 0) {
            return;
        }

        uint256 supply = totalSupply();
        uint256 rewardPerTokenStoredCache = rewardPerTokenStored;
        uint256 _rewardPerBlockPerNFT = rewardPerBlockPerNFT;

        if (supply != 0 && _rewardPerBlockPerNFT != 0) {
            // (L4) Remove redundant mulDiv(..., 1); use direct multiplication.
            // accrued = blocksElapsed * rewardPerBlockPerNFT * PRECISION / LMT_PER_NFT
            uint256 a = blocksElapsed * _rewardPerBlockPerNFT;
            uint256 accrued = Math.mulDiv(a, PRECISION, LMT_PER_NFT);
            rewardPerTokenStoredCache += accrued;

            emit RewardPerTokenUpdated(rewardPerTokenStoredCache);
        }

        rewardPerTokenStored = rewardPerTokenStoredCache;
        lastUpdateBlock = currentBlk;
    }

    /**
     * @notice View helper: compute total rewards earned by `account` up to now.
     *
     * This function simulates an up-to-date `rewardPerTokenStored` using the
     * same formula as `_updateRewardPerToken()` but does not modify state.
     *
     * Steps:
     *  1. Start from stored global values: rewardPerTokenStored, lastUpdateBlock.
     *  2. If time has passed, compute additional global accrual since then using
     *     rewardPerBlockPerNFT and LMT_PER_NFT.
     *  3. Compute the per-token delta for the user since their last checkpoint:
     *       deltaPerToken = updatedRewardPerTokenStored - userRewardPerTokenPaid[account].
     *  4. Multiply by user LKT balance and add any previously accumulated rewards.
     */
    function earned(address account) public view returns (uint256) {
        uint256 _rewardPerTokenStored = rewardPerTokenStored;
        uint256 _lastUpdateBlock = lastUpdateBlock;
        uint256 _rewardPerBlockPerNFT = rewardPerBlockPerNFT;
        uint256 _precision = PRECISION;
        uint256 _userRewardPerTokenPaid = userRewardPerTokenPaid[account];
        uint256 _rewards = rewards[account];
        uint256 _balance = balanceOf(account);
        uint256 _totalSupply = totalSupply();

        uint256 blocksElapsed = 0;
        if (block.number > _lastUpdateBlock) {
            unchecked {
                blocksElapsed = block.number - _lastUpdateBlock;
            }
        }

        if (blocksElapsed != 0 && _totalSupply != 0 && _rewardPerBlockPerNFT != 0) {
            // accrued = blocksElapsed * rewardPerBlockPerNFT * PRECISION / LMT_PER_NFT
            // (L4) same simplification as in _updateRewardPerToken
            uint256 a = blocksElapsed * _rewardPerBlockPerNFT;
            uint256 accrued = Math.mulDiv(a, _precision, LMT_PER_NFT);
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

    // -------------------------------------------------------------------------
    // Reward claiming
    // -------------------------------------------------------------------------

    /**
     * @notice Claim caller's rewards to their own address.
     */
    function claimRewards() external nonReentrant whenNotPaused {
        _claimFor(msg.sender);
    }

    /**
     * @notice Claim rewards *for* `to` and send directly to `to`.
     * @dev
     *  Access control: Any caller can trigger a claim on behalf of `to`.
     *  The rewards are always sent to `to` (not msg.sender).
     */
    function claimRewardsFor(address to) external nonReentrant whenNotPaused {
        _claimFor(to);
    }

    /**
     * @dev Internal reward claim logic.
     *
     * Flow:
     *  1) Bring global rewardPerTokenStored up to date.
     *  2) Compute the user's total earned rewards with `earned(to)`.
     *  3) Update user checkpoints BEFORE any external calls.
     *  4) Mint RWD to `to` if non-zero.
     */
    function _claimFor(address to) internal {
        require(to != address(0), "LM: to zero");

        // 1) Update global accumulator
        _updateRewardPerToken();

        // 2) Compute what the user has earned in total
        uint256 reward = earned(to);

        // 3) Update checkpoints BEFORE minting
        userRewardPerTokenPaid[to] = rewardPerTokenStored;
        rewards[to] = 0;

        // 4) Mint if non-zero (external call after state updates)
        if (reward == 0) {
            emit RewardsClaimed(msg.sender, to, 0);
            return;
        }

        rwdToken.mint(to, reward);
        emit RewardsClaimed(msg.sender, to, reward);
    }

    // -------------------------------------------------------------------------
    // Admin: reward rate configuration
    // -------------------------------------------------------------------------

    /**
     * @notice Set reward emission rate per block per NFT (per 10000 LKT).
     * @dev
     *  - Only owner can call.
     *  - Always settles global rewards at the old rate up to current block
     *    before switching to the new rate.
     *  - Allows setting to zero to disable emissions (M3).
     *  - Enforces an upper bound to avoid overflow (M2).
     *
     * @param amount New rewardPerBlockPerNFT value.
     */
    function setRewardPerBlockPerNFT(uint256 amount) external onlyOwner {
        require(
            amount <= MAX_REWARD_PER_BLOCK_PER_NFT,
            "LM: reward too high"
        );

        // 1) Settle all rewards at the old rate up to the current block
        _updateRewardPerToken();

        // 2) Update the rate
        uint256 old = rewardPerBlockPerNFT;
        if (old != amount) {
            rewardPerBlockPerNFT = amount;
            emit RewardPerBlockPerNFTChanged(old, amount);
        }
    }

    // -------------------------------------------------------------------------
    // NFT deposit (using transferFrom)
    // -------------------------------------------------------------------------

    function deposit(uint256 tokenId) external nonReentrant whenNotPaused {
        // User must be owner or approved for this tokenId
        IERC721(KATIES).transferFrom(msg.sender, address(this), tokenId);
        _depositFor(msg.sender, tokenId);
    }

    function depositBatch(uint256[] calldata tokenIds)
        external
        nonReentrant
        whenNotPaused
    {
        uint256 len = tokenIds.length;
        require(len < MAX_BATCH + 1, "LM: batch too large");

        for (uint256 i = 0; i < len; ++i) {
            IERC721(KATIES).transferFrom(msg.sender, address(this), tokenIds[i]);
            _depositFor(msg.sender, tokenIds[i]);
        }
    }

    function _depositFor(address depositor, uint256 tokenId) internal {
        bytes32 key = keccak256(abi.encode(KATIES, tokenId));
        require(indexOf[key] == 0, "LM: already in vault");
        // sanity check: the contract must actually own the NFT
        require(
            IERC721(KATIES).ownerOf(tokenId) == address(this),
            "LM: not received"
        );

        VaultItem memory item;
        item.tokenId = tokenId; // (L2) only tokendId is stored

        vault.push(item);
        uint256 idx = vault.length - 1;
        indexOf[key] = idx + 1;

        // Mint LKT according to the NFT -> LKT ratio
        _mint(depositor, LMT_PER_NFT);

        emit Deposited(depositor, tokenId, idx);
    }

    // -------------------------------------------------------------------------
    // NFT withdraw (LIFO)
    // -------------------------------------------------------------------------

    function withdrawLIFO() external nonReentrant whenNotPaused {
        uint256 vaultLength = vault.length;
        require(vaultLength != 0, "LM: vault empty");

        // Burn LKT corresponding to 1 NFT
        _burn(msg.sender, LMT_PER_NFT);

        VaultItem storage item = vault[vaultLength - 1];
        bytes32 key = keccak256(abi.encode(KATIES, item.tokenId));
        delete indexOf[key];
        vault.pop();

        IERC721(KATIES).safeTransferFrom(
            address(this),
            msg.sender,
            item.tokenId
        );
        emit Withdrawn(msg.sender, item.tokenId);
    }

    function withdrawLIFOBatch(uint256 count)
        external
        nonReentrant
        whenNotPaused
    {
        require(count != 0, "LM: count must be greater than 0");
        uint256 vaultLength = vault.length;
        require(count < vaultLength + 1, "LM: count exceeds vault length");
        require(count < MAX_BATCH + 1, "LM: batch too large");

        uint256 totalBurn = LMT_PER_NFT * count;
        _burn(msg.sender, totalBurn);

        for (uint256 i = 0; i < count; ++i) {
            VaultItem memory item = vault[vaultLength - 1];
            bytes32 key = keccak256(abi.encode(KATIES, item.tokenId));
            delete indexOf[key];
            vault.pop();

            IERC721(KATIES).safeTransferFrom(
                address(this),
                msg.sender,
                item.tokenId
            );
            emit Withdrawn(msg.sender, item.tokenId);

            unchecked {
                vaultLength--;
            }
        }
    }

    // -------------------------------------------------------------------------
    // NFT withdraw (specific, KATIES only)
    // -------------------------------------------------------------------------

    function withdrawSpecific(uint256 tokenId)
        external
        nonReentrant
        whenNotPaused
    {
        // Only KATIES collection
        bytes32 key = keccak256(abi.encode(KATIES, tokenId));
        uint256 idxPlus1 = indexOf[key];
        require(idxPlus1 != 0, "LM: not in vault");
        uint256 idx = idxPlus1 - 1;

        // Require caller has sufficient LKT and fee
        require(
            balanceOf(msg.sender) >= LMT_PER_NFT + SPECIFIC_FEE,
            "LM: insufficient LMT+fee"
        );

        // Transfer specific fee to treasury and burn LMT_PER_NFT from caller
        _transfer(msg.sender, treasury, SPECIFIC_FEE);
        _burn(msg.sender, LMT_PER_NFT);

        uint256 vaultLength = vault.length;
        uint256 lastIdx = vaultLength - 1;

        if (idx != lastIdx) {
            VaultItem memory lastItem = vault[lastIdx];
            vault[idx] = lastItem;
            bytes32 lastKey = keccak256(abi.encode(KATIES, lastItem.tokenId));
            indexOf[lastKey] = idx + 1;
        }
        delete indexOf[key];
        vault.pop();

        IERC721(KATIES).safeTransferFrom(address(this), msg.sender, tokenId);
        emit Withdrawn(msg.sender, tokenId);
    }

    function withdrawSpecificBatch(uint256[] calldata tokenIds)
        external
        nonReentrant
        whenNotPaused
    {
        uint256 count = tokenIds.length;
        require(count != 0, "LM: input cannot be empty");
        require(count < MAX_BATCH + 1, "LM: batch too large");

        uint256 vaultLength = vault.length;
        require(count <= vaultLength, "LM: count exceeds vault length");

        // Validate all requested items are present before making transfers or burns
        for (uint256 i = 0; i < count; ++i) {
            bytes32 key = keccak256(abi.encode(KATIES, tokenIds[i]));
            require(indexOf[key] != 0, "LM: not in vault");
        }

        // Require caller has sufficient total LKT and fees for the whole batch
        uint256 totalFee = SPECIFIC_FEE * count;
        uint256 totalBurn = LMT_PER_NFT * count;
        require(
            balanceOf(msg.sender) >= totalFee + totalBurn,
            "LM: insufficient LMT+fee"
        );

        // Charge fees & burn once validated
        _transfer(msg.sender, treasury, totalFee);
        _burn(msg.sender, totalBurn);

        for (uint256 i = 0; i < count; ++i) {
            bytes32 key = keccak256(abi.encode(KATIES, tokenIds[i]));
            uint256 idxPlus1 = indexOf[key];
            uint256 idx = idxPlus1 - 1;
            uint256 lastIdx = vault.length - 1;

            if (idx != lastIdx) {
                VaultItem memory lastItem = vault[lastIdx];
                vault[idx] = lastItem;
                bytes32 lastKey = keccak256(abi.encode(KATIES, lastItem.tokenId));
                indexOf[lastKey] = idx + 1;
            }
            delete indexOf[key];

            vault.pop();
            IERC721(KATIES).safeTransferFrom(
                address(this),
                msg.sender,
                tokenIds[i]
            );
            emit Withdrawn(msg.sender, tokenIds[i]);
        }
    }

    // -------------------------------------------------------------------------
    // ERC721 Receiver
    // -------------------------------------------------------------------------

    bytes4 private constant ERC721_RECEIVED =
        IERC721Receiver.onERC721Received.selector;

    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata
    ) external override nonReentrant whenNotPaused returns (bytes4) {
        // Only accept KATIES NFTs via safeTransferFrom
        require(msg.sender == KATIES, "LM: invalid NFT");
        _depositFor(from, tokenId);
        return ERC721_RECEIVED;
    }

    // -------------------------------------------------------------------------
    // Admins (treasury & pause)
    // -------------------------------------------------------------------------

    /// @notice Update treasury wallet (receives specific withdraw fees).
    function updateTreasury(address _newTreasury) external onlyOwner {
        require(_newTreasury != address(0), "LM: treasury zero");

        if (_newTreasury != treasury) {
            address old = treasury;
            treasury = _newTreasury;
            emit TreasuryChanged(old, treasury);
        }
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Rescue function for untracked KATIES NFTs
    // -------------------------------------------------------------------------

    /**
     * @notice Rescue KATIES NFTs that are owned by this contract but not tracked
     *         in the vault (e.g., sent via transferFrom directly).
     */
    function rescueUntrackedKaties(uint256 tokenId, address to)
        external
        onlyOwner
        nonReentrant
    {
        require(to != address(0), "LM: to zero");
        bytes32 key = keccak256(abi.encode(KATIES, tokenId));
        require(indexOf[key] == 0, "LM: tracked in vault");
        require(IERC721(KATIES).ownerOf(tokenId) == address(this), "LM: not owned");

        IERC721(KATIES).safeTransferFrom(address(this), to, tokenId);
        emit UntrackedKatiesRescued(tokenId, to);
    }
}
