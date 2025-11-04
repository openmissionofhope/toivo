// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

/**
 * @title Toivo Foundation
 * @notice Factory for creating upgradeable Charity contracts (ToivoCharity)
 */
contract ToivoFoundation is UUPSUpgradeable, OwnableUpgradeable {
    using Clones for address;

    /// @notice Implementation address for ToivoCharity
    address public charityImplementation;
    /// @notice All created charity proxies
    address[] public allCharities;

    event CharityCreated(address indexed proxy, address indexed creator);

    /**
     * @notice Initialize the foundation with the Charity implementation
     * @param _charityImpl Address of the ToivoCharity logic contract
     */
    function initialize(address _charityImpl) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        require(_charityImpl != address(0), "Toivo: zero impl");
        charityImplementation = _charityImpl;
    }

    /**
     * @notice Deploy a new Charity proxy
     * @param usdcToken ERC20 token used for donations
     * @param guardians List of guardian addresses
     * @param threshold Number of guardian approvals required for withdrawal
     */
    function createCharity(
        address usdcToken,
        address[] calldata guardians,
        uint256 threshold
    ) external returns (address) {
        address proxy = charityImplementation.clone();
        ToivoCharity(payable(proxy)).initialize(usdcToken, guardians, threshold, msg.sender);
        allCharities.push(proxy);
        emit CharityCreated(proxy, msg.sender);
        return proxy;
    }

    function _authorizeUpgrade(address newImpl) internal override onlyOwner {}
}

/**
 * @title Toivo Charity
 * @notice Donation and multisig withdrawal contract with on-chain receipts
 */
contract ToivoCharity is Initializable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /// @notice ERC20 token for donations (e.g., USDC)
    IERC20Upgradeable public donationToken;

    /// @notice Guardian settings
    address[] public guardians;
    mapping(address => bool) public isGuardian;
    uint256 public withdrawalThreshold;

    /// @notice Donation ledger
    mapping(address => uint256) public donated;
    uint256 public totalDonations;

    uint256 private proposalCount;
    struct Proposal {
        address to;
        uint256 amount;
        bytes32 receiptRoot;
        mapping(address => bool) approvals;
        uint256 approvalCount;
        bool executed;
    }
    mapping(uint256 => Proposal) private proposals;

    /// @notice Events for transparency
    event Donated(address indexed donor, uint256 amount, bytes32 receiptId);
    event WithdrawalProposed(uint256 indexed id, address indexed proposer, address to, uint256 amount, bytes32 receiptRoot);
    event WithdrawalApproved(uint256 indexed id, address indexed guardian);
    event Withdrawn(uint256 indexed id, address to, uint256 amount);

    /**
     * @notice Initialize a Charity instance
     * @param usdcToken ERC20 token for donations
     * @param _guardians Guardians for multisig withdrawals
     * @param _threshold Approval threshold
     * @param creator Creator address (for potential access)
     */
    function initialize(
        address usdcToken,
        address[] calldata _guardians,
        uint256 _threshold,
        address /* creator */
    ) external initializer {
        require(usdcToken != address(0), "Toivo: zero token");
        require(_guardians.length >= _threshold && _threshold > 0, "Toivo: invalid guardians");

        donationToken = IERC20Upgradeable(usdcToken);
        withdrawalThreshold = _threshold;
        for (uint256 i = 0; i < _guardians.length; i++) {
            guardians.push(_guardians[i]);
            isGuardian[_guardians[i]] = true;
        }
    }

    /**
     * @notice Donate tokens to this charity
     * @param amount Amount to donate
     */
    function donate(uint256 amount) external {
        require(amount > 0, "Toivo: zero amount");
        donationToken.safeTransferFrom(msg.sender, address(this), amount);
        donated[msg.sender] += amount;
        totalDonations += amount;
        bytes32 receipt = keccak256(abi.encodePacked(msg.sender, amount, block.timestamp));
        emit Donated(msg.sender, amount, receipt);
    }

    /**
     * @notice Propose a withdrawal with a Merkle-root receipt
     * @param to Recipient address
     * @param amount Amount to withdraw
     * @param receiptRoot Merkle root of donor receipts covering this spend
     */
    function proposeWithdrawal(
        address to,
        uint256 amount,
        bytes32 receiptRoot
    ) external {
        require(isGuardian[msg.sender], "Toivo: not guardian");
        require(amount > 0 && amount <= donationToken.balanceOf(address(this)), "Toivo: invalid amount");

        proposalCount++;
        Proposal storage p = proposals[proposalCount];
        p.to = to;
        p.amount = amount;
        p.receiptRoot = receiptRoot;
        p.approvals[msg.sender] = true;
        p.approvalCount = 1;

        emit WithdrawalProposed(proposalCount, msg.sender, to, amount, receiptRoot);
    }

    /**
     * @notice Approve and execute withdrawal once threshold reached
     * @param id Proposal identifier
     */
    function approveWithdrawal(uint256 id) external {
        Proposal storage p = proposals[id];
        require(isGuardian[msg.sender], "Toivo: not guardian");
        require(!p.executed, "Toivo: executed");
        require(!p.approvals[msg.sender], "Toivo: already approved");

        p.approvals[msg.sender] = true;
        p.approvalCount++;
        emit WithdrawalApproved(id, msg.sender);

        if (p.approvalCount >= withdrawalThreshold) {
            p.executed = true;
            donationToken.safeTransfer(p.to, p.amount);
            emit Withdrawn(id, p.to, p.amount);
        }
    }
}
