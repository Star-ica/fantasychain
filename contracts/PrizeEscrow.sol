// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrizeEscrow
/// @notice Holds prize funds (native BOT or USDT) until competition results are finalized
/// @dev Only ClaimManager can release funds; organizer can emergency-withdraw on cancellation
contract PrizeEscrow is Ownable, Pausable, ReentrancyGuard {

    // ─── Structs ──────────────────────────────────────────────────────────────

    enum Currency { NATIVE, USDT }

    struct EscrowAccount {
        uint256 competitionId;
        address organizer;
        uint256 balance;
        Currency currency;
        address tokenAddress;   // ERC-20 token address (address(0) for native)
        bool    released;       // true when funds moved to ClaimManager
        bool    cancelled;
        uint256 depositedAt;
    }

    // ─── Storage ──────────────────────────────────────────────────────────────

    /// @notice competitionId => EscrowAccount
    mapping(uint256 => EscrowAccount) public escrows;

    /// @notice Address of the ClaimManager contract (can release funds)
    address public claimManager;

    /// @notice Track whether a competition has an escrow account
    mapping(uint256 => bool) public hasEscrow;

    // ─── Events ───────────────────────────────────────────────────────────────

    event EscrowCreated(
        uint256 indexed competitionId,
        address indexed organizer,
        uint256 amount,
        Currency currency
    );

    event EscrowFunded(
        uint256 indexed competitionId,
        uint256 additionalAmount,
        uint256 newTotal
    );

    event FundsReleased(
        uint256 indexed competitionId,
        address indexed claimManager,
        uint256 amount
    );

    event EmergencyWithdrawal(
        uint256 indexed competitionId,
        address indexed organizer,
        uint256 amount
    );

    event ClaimManagerUpdated(address indexed newClaimManager);
    event EntryFeeDeposited(uint256 indexed competitionId, uint256 amount);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error EscrowAlreadyExists();
    error EscrowNotFound();
    error NotOrganizer();
    error NotClaimManager();
    error FundsAlreadyReleased();
    error EscrowCancelled();
    error InsufficientFunds();
    error InvalidAmount();
    error TransferFailed();

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor() Ownable(msg.sender) {}

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier escrowExists(uint256 _competitionId) {
        if (!hasEscrow[_competitionId]) revert EscrowNotFound();
        _;
    }

    modifier onlyClaimManager() {
        if (msg.sender != claimManager && msg.sender != owner()) revert NotClaimManager();
        _;
    }

    // ─── External Functions ───────────────────────────────────────────────────

    /// @notice Create an escrow for a competition with native BOT prize pool
    /// @param _competitionId Competition ID
    /// @param _organizer Organizer address (can emergency withdraw on cancellation)
    function createNativeEscrow(uint256 _competitionId, address _organizer)
        external
        payable
        whenNotPaused
        nonReentrant
    {
        if (hasEscrow[_competitionId]) revert EscrowAlreadyExists();
        if (msg.value == 0) revert InvalidAmount();

        escrows[_competitionId] = EscrowAccount({
            competitionId: _competitionId,
            organizer: _organizer,
            balance: msg.value,
            currency: Currency.NATIVE,
            tokenAddress: address(0),
            released: false,
            cancelled: false,
            depositedAt: block.timestamp
        });

        hasEscrow[_competitionId] = true;

        emit EscrowCreated(_competitionId, _organizer, msg.value, Currency.NATIVE);
    }

    /// @notice Create an escrow for a competition with USDT prize pool
    /// @dev Caller must have approved this contract for _amount USDT
    /// @param _competitionId Competition ID
    /// @param _organizer Organizer address
    /// @param _tokenAddress USDT token contract address
    /// @param _amount Prize pool amount in token wei
    function createUSDTEscrow(
        uint256 _competitionId,
        address _organizer,
        address _tokenAddress,
        uint256 _amount
    ) external whenNotPaused nonReentrant {
        if (hasEscrow[_competitionId]) revert EscrowAlreadyExists();
        if (_amount == 0) revert InvalidAmount();

        // Transfer USDT from caller
        (bool ok, bytes memory data) = _tokenAddress.call(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)",
                msg.sender, address(this), _amount
            )
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "USDT transfer failed");

        escrows[_competitionId] = EscrowAccount({
            competitionId: _competitionId,
            organizer: _organizer,
            balance: _amount,
            currency: Currency.USDT,
            tokenAddress: _tokenAddress,
            released: false,
            cancelled: false,
            depositedAt: block.timestamp
        });

        hasEscrow[_competitionId] = true;

        emit EscrowCreated(_competitionId, _organizer, _amount, Currency.USDT);
    }

    /// @notice Add entry fee revenue to an existing escrow
    /// @param _competitionId Competition ID to fund
    function depositEntryFees(uint256 _competitionId)
        external
        payable
        escrowExists(_competitionId)
        whenNotPaused
    {
        EscrowAccount storage escrow = escrows[_competitionId];
        if (escrow.released) revert FundsAlreadyReleased();
        if (escrow.cancelled) revert EscrowCancelled();
        require(escrow.currency == Currency.NATIVE, "Use USDT deposit function");
        if (msg.value == 0) revert InvalidAmount();

        escrow.balance += msg.value;
        emit EntryFeeDeposited(_competitionId, msg.value);
        emit EscrowFunded(_competitionId, msg.value, escrow.balance);
    }

    /// @notice Release all funds to the ClaimManager contract (called after finalization)
    /// @param _competitionId Competition ID
    function releaseFunds(uint256 _competitionId)
        external
        escrowExists(_competitionId)
        onlyClaimManager
        nonReentrant
    {
        EscrowAccount storage escrow = escrows[_competitionId];
        if (escrow.released) revert FundsAlreadyReleased();
        if (escrow.cancelled) revert EscrowCancelled();

        uint256 amount = escrow.balance;
        if (amount == 0) revert InsufficientFunds();

        escrow.released = true;
        escrow.balance = 0;

        if (escrow.currency == Currency.NATIVE) {
            (bool ok,) = payable(claimManager).call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            (bool ok, bytes memory data) = escrow.tokenAddress.call(
                abi.encodeWithSignature("transfer(address,uint256)", claimManager, amount)
            );
            require(ok && (data.length == 0 || abi.decode(data, (bool))), "USDT transfer failed");
        }

        emit FundsReleased(_competitionId, claimManager, amount);
    }

    /// @notice Emergency withdrawal by organizer if competition is cancelled
    /// @param _competitionId Competition ID
    function emergencyWithdraw(uint256 _competitionId)
        external
        escrowExists(_competitionId)
        nonReentrant
    {
        EscrowAccount storage escrow = escrows[_competitionId];
        if (msg.sender != escrow.organizer && msg.sender != owner()) revert NotOrganizer();
        if (escrow.released) revert FundsAlreadyReleased();

        uint256 amount = escrow.balance;
        if (amount == 0) revert InsufficientFunds();

        escrow.cancelled = true;
        escrow.balance = 0;

        if (escrow.currency == Currency.NATIVE) {
            (bool ok,) = payable(escrow.organizer).call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            (bool ok, bytes memory data) = escrow.tokenAddress.call(
                abi.encodeWithSignature("transfer(address,uint256)", escrow.organizer, amount)
            );
            require(ok && (data.length == 0 || abi.decode(data, (bool))), "USDT transfer failed");
        }

        emit EmergencyWithdrawal(_competitionId, escrow.organizer, amount);
    }

    // ─── View Functions ───────────────────────────────────────────────────────

    /// @notice Get escrow details for a competition
    function getEscrow(uint256 _competitionId)
        external
        view
        escrowExists(_competitionId)
        returns (EscrowAccount memory)
    {
        return escrows[_competitionId];
    }

    /// @notice Get escrow balance for a competition
    function getBalance(uint256 _competitionId) external view returns (uint256) {
        return hasEscrow[_competitionId] ? escrows[_competitionId].balance : 0;
    }

    // ─── Admin Functions ──────────────────────────────────────────────────────

    /// @notice Set the ClaimManager contract address
    function setClaimManager(address _claimManager) external onlyOwner {
        require(_claimManager != address(0), "Invalid address");
        claimManager = _claimManager;
        emit ClaimManagerUpdated(_claimManager);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    receive() external payable {}
}
