// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CompetitionFactory
/// @notice Creates and manages fantasy sports competitions on BOT Chain
/// @dev Competitions can use native BOT token or USDT ERC-20 as prize currency
contract CompetitionFactory is Ownable, Pausable, ReentrancyGuard {

    // ─── Enums ────────────────────────────────────────────────────────────────

    enum SportType { FOOTBALL, BASKETBALL, CRICKET, BASEBALL, SOCCER, TENNIS, OTHER }
    enum CompetitionStatus { OPEN, CLOSED, SCORING, DISPUTED, FINALIZED, CANCELLED }
    enum PrizeCurrency { NATIVE, USDT }

    // ─── Structs ──────────────────────────────────────────────────────────────

    /// @notice Full competition data stored on-chain
    struct Competition {
        uint256 id;
        address organizer;
        string  name;
        SportType sport;
        uint256 entryFee;        // in wei (0 = free)
        uint256 maxTeams;        // 0 = unlimited
        uint256 deadline;        // Unix timestamp
        uint256 prizePool;       // total prize amount (wei / USDT wei)
        PrizeCurrency currency;
        address usdtToken;       // address(0) if native
        address oracle;
        bytes32 scoringRulesHash;// keccak256 of off-chain JSON rules
        CompetitionStatus status;
        uint256 createdAt;
        uint256 teamsCount;
    }

    // ─── Storage ──────────────────────────────────────────────────────────────

    uint256 public competitionCount;

    mapping(uint256 => Competition) public competitions;

    /// @notice Authorized oracle addresses per competition (can override global oracle)
    mapping(uint256 => address) public competitionOracles;

    /// @notice Globally whitelisted oracle addresses
    mapping(address => bool) public authorizedOracles;

    /// @notice Platform fee in basis points (default 250 = 2.5%)
    uint256 public platformFeeBps;

    /// @notice Address that collects platform fees
    address public feeRecipient;

    // ─── Events ───────────────────────────────────────────────────────────────

    event CompetitionCreated(
        uint256 indexed id,
        address indexed organizer,
        string name,
        SportType sport,
        uint256 entryFee,
        uint256 deadline,
        uint256 prizePool,
        PrizeCurrency currency
    );

    event CompetitionStatusUpdated(
        uint256 indexed id,
        CompetitionStatus oldStatus,
        CompetitionStatus newStatus
    );

    event CompetitionCancelled(uint256 indexed id, address indexed organizer);
    event OracleUpdated(uint256 indexed id, address indexed oracle);
    event PlatformFeeUpdated(uint256 newFeeBps);
    event FeeRecipientUpdated(address newRecipient);
    event OracleAuthorized(address indexed oracle, bool authorized);
    event TeamCountIncremented(uint256 indexed competitionId, uint256 newCount);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error InvalidDeadline();
    error InvalidMaxTeams();
    error CompetitionNotFound();
    error NotOrganizer();
    error NotAuthorized();
    error DeadlinePassed();
    error CompetitionNotOpen();
    error MaxTeamsReached();
    error InvalidFee();
    error InvalidPrizePool();
    error InvalidOracle();

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param _feeRecipient Initial fee recipient address
    /// @param _platformFeeBps Initial platform fee in basis points
    constructor(address _feeRecipient, uint256 _platformFeeBps) Ownable(msg.sender) {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_platformFeeBps <= 1000, "Fee too high"); // max 10%
        feeRecipient = _feeRecipient;
        platformFeeBps = _platformFeeBps;
    }

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier competitionExists(uint256 _id) {
        if (_id == 0 || _id > competitionCount) revert CompetitionNotFound();
        _;
    }

    modifier onlyOrganizer(uint256 _id) {
        if (competitions[_id].organizer != msg.sender) revert NotOrganizer();
        _;
    }

    // ─── External Functions ───────────────────────────────────────────────────

    /// @notice Create a new competition with native BOT prize pool
    /// @param _name Human-readable competition name
    /// @param _sport Sport type enum value
    /// @param _entryFee Per-team entry fee in wei (0 for free)
    /// @param _maxTeams Maximum teams allowed (0 = unlimited)
    /// @param _deadline Submission deadline as Unix timestamp
    /// @param _oracle Oracle address for submitting results
    /// @param _scoringRulesHash keccak256 hash of off-chain scoring rules JSON
    /// @return competitionId The newly created competition ID
    function createCompetition(
        string calldata _name,
        SportType _sport,
        uint256 _entryFee,
        uint256 _maxTeams,
        uint256 _deadline,
        address _oracle,
        bytes32 _scoringRulesHash
    ) external payable whenNotPaused nonReentrant returns (uint256 competitionId) {
        if (_deadline <= block.timestamp) revert InvalidDeadline();
        if (_oracle == address(0)) revert InvalidOracle();
        if (msg.value == 0) revert InvalidPrizePool();

        competitionId = ++competitionCount;

        competitions[competitionId] = Competition({
            id: competitionId,
            organizer: msg.sender,
            name: _name,
            sport: _sport,
            entryFee: _entryFee,
            maxTeams: _maxTeams,
            deadline: _deadline,
            prizePool: msg.value,
            currency: PrizeCurrency.NATIVE,
            usdtToken: address(0),
            oracle: _oracle,
            scoringRulesHash: _scoringRulesHash,
            status: CompetitionStatus.OPEN,
            createdAt: block.timestamp,
            teamsCount: 0
        });

        competitionOracles[competitionId] = _oracle;

        emit CompetitionCreated(
            competitionId,
            msg.sender,
            _name,
            _sport,
            _entryFee,
            _deadline,
            msg.value,
            PrizeCurrency.NATIVE
        );
    }

    /// @notice Create a competition with USDT ERC-20 prize pool
    /// @dev Caller must have approved this contract for _prizePool USDT
    /// @param _name Competition name
    /// @param _sport Sport type
    /// @param _entryFee Per-team entry fee in USDT wei
    /// @param _maxTeams Maximum teams (0 = unlimited)
    /// @param _deadline Submission deadline
    /// @param _oracle Oracle address
    /// @param _scoringRulesHash Hash of scoring rules
    /// @param _usdtToken USDT contract address
    /// @param _prizePool Prize pool amount in USDT wei
    /// @return competitionId Newly created competition ID
    function createCompetitionUSDT(
        string calldata _name,
        SportType _sport,
        uint256 _entryFee,
        uint256 _maxTeams,
        uint256 _deadline,
        address _oracle,
        bytes32 _scoringRulesHash,
        address _usdtToken,
        uint256 _prizePool
    ) external whenNotPaused nonReentrant returns (uint256 competitionId) {
        if (_deadline <= block.timestamp) revert InvalidDeadline();
        if (_oracle == address(0)) revert InvalidOracle();
        if (_usdtToken == address(0)) revert InvalidPrizePool();
        if (_prizePool == 0) revert InvalidPrizePool();

        // Transfer USDT to this contract
        (bool success, bytes memory data) = _usdtToken.call(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)",
                msg.sender,
                address(this),
                _prizePool
            )
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "USDT transfer failed");

        competitionId = ++competitionCount;

        competitions[competitionId] = Competition({
            id: competitionId,
            organizer: msg.sender,
            name: _name,
            sport: _sport,
            entryFee: _entryFee,
            maxTeams: _maxTeams,
            deadline: _deadline,
            prizePool: _prizePool,
            currency: PrizeCurrency.USDT,
            usdtToken: _usdtToken,
            oracle: _oracle,
            scoringRulesHash: _scoringRulesHash,
            status: CompetitionStatus.OPEN,
            createdAt: block.timestamp,
            teamsCount: 0
        });

        competitionOracles[competitionId] = _oracle;

        emit CompetitionCreated(
            competitionId,
            msg.sender,
            _name,
            _sport,
            _entryFee,
            _deadline,
            _prizePool,
            PrizeCurrency.USDT
        );
    }

    /// @notice Update competition status (organizer or oracle or owner)
    /// @param _id Competition ID
    /// @param _newStatus New status to set
    function updateStatus(uint256 _id, CompetitionStatus _newStatus)
        external
        competitionExists(_id)
    {
        Competition storage comp = competitions[_id];
        bool authorized = (
            msg.sender == comp.organizer ||
            msg.sender == comp.oracle ||
            msg.sender == owner()
        );
        if (!authorized) revert NotAuthorized();

        CompetitionStatus old = comp.status;
        comp.status = _newStatus;
        emit CompetitionStatusUpdated(_id, old, _newStatus);
    }

    /// @notice Cancel a competition and trigger emergency withdrawal
    /// @param _id Competition ID
    function cancelCompetition(uint256 _id)
        external
        competitionExists(_id)
        onlyOrganizer(_id)
        nonReentrant
    {
        Competition storage comp = competitions[_id];
        require(
            comp.status == CompetitionStatus.OPEN ||
            comp.status == CompetitionStatus.CLOSED,
            "Cannot cancel at this stage"
        );
        CompetitionStatus old = comp.status;
        comp.status = CompetitionStatus.CANCELLED;
        emit CompetitionStatusUpdated(_id, old, CompetitionStatus.CANCELLED);
        emit CompetitionCancelled(_id, msg.sender);

        // Return prize pool to organizer
        uint256 amount = comp.prizePool;
        comp.prizePool = 0;

        if (comp.currency == PrizeCurrency.NATIVE) {
            (bool ok,) = payable(comp.organizer).call{value: amount}("");
            require(ok, "Refund failed");
        } else {
            (bool ok, bytes memory data) = comp.usdtToken.call(
                abi.encodeWithSignature("transfer(address,uint256)", comp.organizer, amount)
            );
            require(ok && (data.length == 0 || abi.decode(data, (bool))), "USDT refund failed");
        }
    }

    /// @notice Called by TeamManager to increment team count and validate entry
    /// @param _id Competition ID
    function recordTeamEntry(uint256 _id)
        external
        competitionExists(_id)
        whenNotPaused
    {
        // Only TeamManager should call this — in a full deploy, restrict to TeamManager address
        Competition storage comp = competitions[_id];
        if (comp.status != CompetitionStatus.OPEN) revert CompetitionNotOpen();
        if (block.timestamp >= comp.deadline) revert DeadlinePassed();
        if (comp.maxTeams > 0 && comp.teamsCount >= comp.maxTeams) revert MaxTeamsReached();

        comp.teamsCount++;
        emit TeamCountIncremented(_id, comp.teamsCount);
    }

    // ─── View Functions ───────────────────────────────────────────────────────

    /// @notice Get a competition by ID
    function getCompetition(uint256 _id)
        external
        view
        competitionExists(_id)
        returns (Competition memory)
    {
        return competitions[_id];
    }

    /// @notice Get all competition IDs with optional status filter
    /// @param _status Status to filter by (255 = no filter)
    /// @param _offset Pagination offset
    /// @param _limit Max results to return
    function listCompetitions(uint8 _status, uint256 _offset, uint256 _limit)
        external
        view
        returns (Competition[] memory results, uint256 total)
    {
        uint256 count = 0;
        for (uint256 i = 1; i <= competitionCount; i++) {
            if (_status == 255 || uint8(competitions[i].status) == _status) {
                count++;
            }
        }
        total = count;

        if (_offset >= count) {
            return (new Competition[](0), total);
        }

        uint256 end = _offset + _limit;
        if (end > count) end = count;
        results = new Competition[](end - _offset);

        uint256 idx = 0;
        uint256 seen = 0;
        for (uint256 i = 1; i <= competitionCount; i++) {
            if (_status == 255 || uint8(competitions[i].status) == _status) {
                if (seen >= _offset && seen < end) {
                    results[idx++] = competitions[i];
                }
                seen++;
            }
        }
    }

    // ─── Admin Functions ──────────────────────────────────────────────────────

    /// @notice Authorize or deauthorize a global oracle address
    function setOracleAuthorization(address _oracle, bool _authorized) external onlyOwner {
        authorizedOracles[_oracle] = _authorized;
        emit OracleAuthorized(_oracle, _authorized);
    }

    /// @notice Update platform fee (max 10%)
    function setPlatformFee(uint256 _feeBps) external onlyOwner {
        require(_feeBps <= 1000, "Fee too high");
        platformFeeBps = _feeBps;
        emit PlatformFeeUpdated(_feeBps);
    }

    /// @notice Update fee recipient
    function setFeeRecipient(address _recipient) external onlyOwner {
        require(_recipient != address(0), "Invalid address");
        feeRecipient = _recipient;
        emit FeeRecipientUpdated(_recipient);
    }

    /// @notice Pause all competition creation
    function pause() external onlyOwner { _pause(); }

    /// @notice Unpause competition creation
    function unpause() external onlyOwner { _unpause(); }

    // ─── Receive ──────────────────────────────────────────────────────────────

    receive() external payable {}
}
