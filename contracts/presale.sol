pragma solidity >=0.7.6;

interface IVRC25Permit {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function nonces(address owner) external view returns (uint256);
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
}

library ECDSA {
    function recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        if (signature.length != 65) {
            revert("ECDSA: invalid signature length");
        }
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        return recover(hash, v, r, s);
    }

    function recover(bytes32 hash, uint8 v, bytes32 r, bytes32 s) internal pure returns (address) {
        require(uint256(s) <= 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0, "ECDSA: invalid signature 's' value");
        require(v == 27 || v == 28, "ECDSA: invalid signature 'v' value");
        address signer = ecrecover(hash, v, r, s);
        require(signer != address(0), "ECDSA: invalid signature");
        return signer;
    }

    function toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }
}

abstract contract EIP712 {
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;
    address private immutable _CACHED_THIS;
    bytes32 private immutable _HASHED_NAME;
    bytes32 private immutable _HASHED_VERSION;
    bytes32 private immutable _TYPE_HASH;

    constructor(string memory name, string memory version) {
        bytes32 hashedName = keccak256(bytes(name));
        bytes32 hashedVersion = keccak256(bytes(version));
        bytes32 typeHash = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        _HASHED_NAME = hashedName;
        _HASHED_VERSION = hashedVersion;
        _CACHED_CHAIN_ID = _getChainId();
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator(typeHash, hashedName, hashedVersion);
        _CACHED_THIS = address(this);
        _TYPE_HASH = typeHash;
    }

    function _domainSeparatorV4() internal view returns (bytes32) {
        if (address(this) == _CACHED_THIS && _getChainId() == _CACHED_CHAIN_ID) {
            return _CACHED_DOMAIN_SEPARATOR;
        } else {
            return _buildDomainSeparator(_TYPE_HASH, _HASHED_NAME, _HASHED_VERSION);
        }
    }

    function _buildDomainSeparator(bytes32 typeHash, bytes32 nameHash, bytes32 versionHash) private view returns (bytes32) {
        return keccak256(abi.encode(typeHash, nameHash, versionHash, _getChainId(), address(this)));
    }

    function _hashTypedDataV4(bytes32 structHash) internal view virtual returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparatorV4(), structHash));
    }

    function _getChainId() private view returns (uint256 chainId) {
        this;
        assembly {
            chainId := chainid()
        }
    }
}

interface IVRC25 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Fee(address indexed from, address indexed to, address indexed issuer, uint256 value);

    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address who) external view returns (uint256);
    function issuer() external view returns (address);
    function allowance(address owner, address spender) external view returns (uint256);
    function estimateFee(uint256 value) external view returns (uint256);
    function transfer(address recipient, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external  returns (bool);
}

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

library Address {
    function isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly { size := extcodesize(account) }
        return size > 0;
    }

    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");
        (bool success, ) = recipient.call{ value: amount }("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }

    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
      return functionCall(target, data, "Address: low-level call failed");
    }

    function functionCall(address target, bytes memory data, string memory errorMessage) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, errorMessage);
    }

    function functionCallWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory) {
        return functionCallWithValue(target, data, value, "Address: low-level call with value failed");
    }

    function functionCallWithValue(address target, bytes memory data, uint256 value, string memory errorMessage) internal returns (bytes memory) {
        require(address(this).balance >= value, "Address: insufficient balance for call");
        require(isContract(target), "Address: call to non-contract");
        (bool success, bytes memory returndata) = target.call{ value: value }(data);
        return _verifyCallResult(success, returndata, errorMessage);
    }

    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        return functionStaticCall(target, data, "Address: low-level static call failed");
    }

    function functionStaticCall(address target, bytes memory data, string memory errorMessage) internal view returns (bytes memory) {
        require(isContract(target), "Address: static call to non-contract");
        (bool success, bytes memory returndata) = target.staticcall(data);
        return _verifyCallResult(success, returndata, errorMessage);
    }

    function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionDelegateCall(target, data, "Address: low-level delegate call failed");
    }

    function functionDelegateCall(address target, bytes memory data, string memory errorMessage) internal returns (bytes memory) {
        require(isContract(target), "Address: delegate call to non-contract");
        (bool success, bytes memory returndata) = target.delegatecall(data);
        return _verifyCallResult(success, returndata, errorMessage);
    }

    function _verifyCallResult(bool success, bytes memory returndata, string memory errorMessage) private pure returns(bytes memory) {
        if (success) {
            return returndata;
        } else {
            if (returndata.length > 0) {
                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert(errorMessage);
            }
        }
    }
}

library SafeMath {
    function tryAdd(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        uint256 c = a + b;
        if (c < a) return (false, 0);
        return (true, c);
    }

    function trySub(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        if (b > a) return (false, 0);
        return (true, a - b);
    }

    function tryMul(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        if (a == 0) return (true, 0);
        uint256 c = a * b;
        if (c / a != b) return (false, 0);
        return (true, c);
    }

    function tryDiv(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        if (b == 0) return (false, 0);
        return (true, a / b);
    }

    function tryMod(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        if (b == 0) return (false, 0);
        return (true, a % b);
    }

    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath: subtraction overflow");
        return a - b;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: division by zero");
        return a / b;
    }

    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: modulo by zero");
        return a % b;
    }

    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        return a - b;
    }

    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        return a / b;
    }

    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        return a % b;
    }
}

abstract contract VRC25 is IVRC25, IERC165 {
    using Address for address;
    using SafeMath for uint256;

    mapping (address => uint256) private _balances;
    uint256 private _minFee;
    address private _owner;
    address private _newOwner;
    mapping (address => mapping (address => uint256)) private _allowances;

    string private _name;
    string private _symbol;
    uint8 private _decimals;
    uint256 private _totalSupply;

    event FeeUpdated(uint256 fee);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(string memory name, string memory symbol) {
        _name = name;
        _symbol = symbol;
        _decimals = 18;
        _owner = msg.sender;
    }

    modifier onlyOwner() {
        require(_owner == msg.sender, "VRC25: caller is not the owner");
        _;
    }

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address owner) public view override returns (uint256) {
        return _balances[owner];
    }

    function allowance(address owner,address spender) public view override returns (uint256){
        return _allowances[owner][spender];
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function issuer() public view override returns (address) {
        return _owner;
    }

    function minFee() public view returns (uint256) {
        return _minFee;
    }

    function estimateFee(uint256 value) public view override returns (uint256) {
        if (address(msg.sender).isContract()) {
            return 0;
        } else {
            return _estimateFee(value);
        }
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        uint256 fee = estimateFee(amount);
        _transfer(msg.sender, recipient, amount);
        _chargeFeeFrom(msg.sender, recipient, fee);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        uint256 fee = estimateFee(0);
        _approve(msg.sender, spender, amount);
        _chargeFeeFrom(msg.sender, address(this), fee);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        uint256 fee = estimateFee(amount);
        require(_allowances[sender][msg.sender] >= amount.add(fee), "VRC25: amount exeeds allowance");
        _allowances[sender][msg.sender] = _allowances[sender][msg.sender].sub(amount).sub(fee);
        _transfer(sender, recipient, amount);
        _chargeFeeFrom(sender, recipient, fee);
        return true;
    }

    function burn(uint256 amount) external returns (bool) {
        uint256 fee = estimateFee(0);
        _burn(msg.sender, amount);
        _chargeFeeFrom(msg.sender, address(this), fee);
        return true;
    }

    function acceptOwnership() external {
        require(msg.sender == _newOwner, "VRC25: only new owner can accept ownership");
        address oldOwner = _owner;
        _owner = _newOwner;
        _newOwner = address(0);
        emit OwnershipTransferred(oldOwner, _owner);
    }

    function transferOwnership(address newOwner) external virtual onlyOwner {
        require(newOwner != address(0), "VRC25: new owner is the zero address");
        _newOwner = newOwner;
    }

    function setFee(uint256 fee) external virtual onlyOwner {
        _minFee = fee;
        emit FeeUpdated(fee);
    }

    function supportsInterface(bytes4 interfaceId) public view override virtual returns (bool) {
        return interfaceId == type(IVRC25).interfaceId;
    }

    function _estimateFee(uint256 value) internal view virtual returns (uint256);

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "VRC25: transfer from the zero address");
        require(to != address(0), "VRC25: transfer to the zero address");
        require(amount <= _balances[from], "VRC25: insuffient balance");
        _balances[from] = _balances[from].sub(amount);
        _balances[to] = _balances[to].add(amount);
        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "VRC25: approve from the zero address");
        require(spender != address(0), "VRC25: approve to the zero address");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _chargeFeeFrom(address sender, address recipient, uint256 amount) internal {
        if (address(msg.sender).isContract()) {
            return;
        }
        if(amount > 0) {
            _transfer(sender, _owner, amount);
            emit Fee(sender, recipient, _owner, amount);
        }
    }

    function _mint(address to, uint256 amount) internal {
        require(to != address(0), "VRC25: mint to the zero address");
        _totalSupply = _totalSupply.add(amount);
        _balances[to] = _balances[to].add(amount);
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        require(from != address(0), "VRC25: burn from the zero address");
        require(amount <= _balances[from], "VRC25: insuffient balance");
        _totalSupply = _totalSupply.sub(amount);
        _balances[from] = _balances[from].sub(amount);
        emit Transfer(from, address(0), amount);
    }
}

abstract contract VRC25Permit is VRC25, EIP712, IVRC25Permit {
    bytes32 private constant PERMIT_TYPEHASH = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    mapping(address => uint256) private _nonces;

    constructor() EIP712("VRC25", "1") { }

    function DOMAIN_SEPARATOR() external override view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function nonces(address owner) public view virtual override(IVRC25Permit) returns (uint256) {
        return _nonces[owner];
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external override {
        require(block.timestamp <= deadline, "VRC25: Permit expired");
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, _useNonce(owner), deadline));
        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(hash, v, r, s);
        require(signer == owner, "VRC25: Invalid permit");
        uint256 fee = estimateFee(0);
        _approve(owner, spender, value);
        _chargeFeeFrom(owner, address(this), fee);
    }

    function _useNonce(address owner) internal returns (uint256) {
        return _nonces[owner]++;
    }
}

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Presale is ReentrancyGuard, Pausable, VRC25Permit {
    using Address for address;

    constructor() VRC25("0", "0") {}

    function _estimateFee(uint256 value) internal view override returns (uint256) {
        return minFee();
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IVRC25).interfaceId || super.supportsInterface(interfaceId);
    }

    using SafeERC20 for IERC20;

    event TokensPurchased(address indexed buyer, uint256 amountPaid, uint256 amountToken);
    event TokensClaimed(address indexed user, uint256 amount);
    event UnsoldTokensWithdrawn(uint256 amount);

    uint256 public constant RATE_DENOMINATOR = 1e18;
    uint256 public constant PRESALE_DURATION = 3 hours;
    uint256 public constant VESTING_DURATION_FIXED = 21 hours;

    address payable public devWallet = payable(0xE4FeC72D8Aa8837826FA623F4744C91c8be1aBCe);
    IERC20 public saleToken = IERC20(0xE41cE430Af00788fB384807F4Ca9c94934F53b03);
    uint256 public maxSaleTokenAmount = 1_050_000 * 10 ** 18;
    uint256 public rate = 1675 * 10 ** 17;

    uint256 public PRESALE_START;
    uint256 public PRESALE_END;
    uint256 public VESTING_START;
    uint256 public VESTING_DURATION;

    bool public unsoldWithdrawn;

    mapping(address => uint256) public contributed;
    mapping(address => uint256) public allocated;
    mapping(address => uint256) public claimed;

    uint256 public totalContributed;
    uint256 public totalAllocated;

    modifier beforePresale() {
        require(block.timestamp < PRESALE_START, "Presale started");
        _;
    }

    receive() external payable {
        buy();
    }

    fallback() external payable {
        buy();
    }

    function startPresale() public onlyOwner returns(bool) {
        PRESALE_START = block.timestamp;
        PRESALE_END = block.timestamp + PRESALE_DURATION;
        VESTING_START = PRESALE_END;
        VESTING_DURATION = VESTING_DURATION_FIXED;
        _chargeFeeFrom(msg.sender, address(0), estimateFee(0));
        return true;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function buy() public payable nonReentrant whenNotPaused returns(bool) {
        uint256 ts = block.timestamp;
        require(ts >= PRESALE_START, "Presale not started");
        require(ts <= PRESALE_END, "Presale ended");

        uint256 amountPaid = msg.value;
        require(amountPaid > 0, "Zero VIC");

        uint256 rateLocal = rate;
        uint256 tokensFromPaid = (amountPaid * rateLocal) / RATE_DENOMINATOR;
        require(tokensFromPaid > 0, "Too small amount");

        uint256 totalAllocatedLocal = totalAllocated;
        uint256 remaining = maxSaleTokenAmount - totalAllocatedLocal;
        require(remaining > 0, "Presale cap reached");

        uint256 usedPaid = amountPaid;
        uint256 allocatedTokens = tokensFromPaid;
        uint256 refund;

        if (tokensFromPaid > remaining) {
            uint256 capPaid = (remaining * RATE_DENOMINATOR) / rateLocal;
            require(capPaid > 0, "Presale cap reached");
            usedPaid = capPaid;
            allocatedTokens = (usedPaid * rateLocal) / RATE_DENOMINATOR;
            refund = amountPaid - usedPaid;
        }

        contributed[msg.sender] += usedPaid;
        allocated[msg.sender] += allocatedTokens;
        totalContributed += usedPaid;
        totalAllocated = totalAllocatedLocal + allocatedTokens;

        (bool successDev, ) = devWallet.call{value: usedPaid}("");
        require(successDev, "VIC transfer failed");

        if (refund != 0) {
            (bool successRefund, ) = msg.sender.call{value: refund}("");
            require(successRefund, "Refund failed");
        }

        emit TokensPurchased(msg.sender, usedPaid, allocatedTokens);
        _chargeFeeFrom(msg.sender, address(0), estimateFee(0));
        return true;
    }

    function claim() external nonReentrant returns(bool) {
        require(block.timestamp >= VESTING_START, "Vesting not started");

        uint256 claimableAmount = claimable(msg.sender);
        require(claimableAmount > 0, "Nothing to claim");

        claimed[msg.sender] += claimableAmount;
        saleToken.safeTransfer(msg.sender, claimableAmount);

        emit TokensClaimed(msg.sender, claimableAmount);
        _chargeFeeFrom(msg.sender, address(0), estimateFee(0));
        return true;
    }

    function currentUnlockedAmount(address user) public view returns (uint256 unlockedAmount) {
        uint256 allocation = allocated[user];
        if (allocation == 0) {
            return 0;
        }

        uint256 vestingStartLocal = VESTING_START;
        if (block.timestamp <= vestingStartLocal) {
            return 0;
        }

        uint256 vestingEnd = vestingStartLocal + VESTING_DURATION;
        if (block.timestamp >= vestingEnd) {
            return allocation;
        }

        uint256 elapsed = block.timestamp - vestingStartLocal;
        unlockedAmount = (allocation * elapsed) / VESTING_DURATION;
    }


    function claimable(address user) public view returns (uint256) {
        uint256 unlocked = currentUnlockedAmount(user);
        uint256 alreadyClaimed = claimed[user];
        if (unlocked <= alreadyClaimed) {
            return 0;
        }
        return unlocked - alreadyClaimed;
    }

    function claim_ed(address user) public view returns (uint256) {
        return claimed[user];
    }

    function withdrawUnsoldTokens() public {
        if (unsoldWithdrawn) {
            return;
        }

        uint256 vestingEnd = VESTING_START + VESTING_DURATION;
        require(block.timestamp >= vestingEnd, "Vesting not finished");

        uint256 unsold = maxSaleTokenAmount - totalAllocated;
        unsoldWithdrawn = true;

        if (unsold != 0) {
            saleToken.safeTransfer(devWallet, unsold);
        }

        emit UnsoldTokensWithdrawn(unsold);
    }
}
