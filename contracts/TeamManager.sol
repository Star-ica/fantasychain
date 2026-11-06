// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ICompetitionFactory {
    enum CompetitionStatus { OPEN, CLOSED, SCORING, DISPUTED, FINALIZED, CANCELLED }
    enum PrizeCurrency { NATIVE, USDT }

    struct Competition {
        uint256 id;
        address organizer;
        string  name;
        uint8   sport;
        uint256 entryFee;
        uint256 maxTeams;
        uint256 deadline;
        uint256 prizePool;
        PrizeCurrency currency;
        address usdtToken;
        address oracle;
        bytes32 scoringRulesHash;
        CompetitionStatus status;
        uint256 createdAt;
        uint256 teamsCount;
    }

    function getCompetition(uint256 _id) external view returns (Competition memory);
    function recordTeamEntry(uint256 _id) external;
    function platformFeeBps() external view returns (uint256);
    function feeRecipient() external view returns (address);
}

interface IPlayerRegistry {
    function isPlayerInCompetition(uint256 _competitionId, uint256 _playerId) external view returns (bool);
}

/// @title TeamManager
/// @notice Manages team creation, player selection, and entry fee collection
/// @dev One team per wallet per competition; validates player eligibility
contract TeamManager is Ownable, Pausable, ReentrancyGuard {

    // ─── Structs ──────────────────────────────────────────────────────────────

    struct Team {
        uint256 id;
        address owner;
        uint256 competitionId;
        uint256[] playerIds;
        string  name;
        uint256 createdAt;
        bool    exists;
    }

    struct CompetitionRules {
        uint256 minPlayers;
        uint256 maxPlayers;
        bool    enforcePlayerCount;
    }

    // ─── Storage ──────────────────────────────────────────────────────────────

    uint256 public teamCount;

    ICompetitionFactory public competitionFactory;
    IPlayerRegistry public playerRegistry;

    mapping(uint256 => Team) public teams;

    /// @notice competitionId => walletAddress => teamId (0 = not entered)
    mapping(uint256 => mapping(address => uint256)) public userTeam;

    /// @notice competitionId => array of team IDs
    mapping(uint256 => uint256[]) private competitionTeams;

    /// @notice Per-competition rules (min/max players per team)
    mapping(uint256 => CompetitionRules) public competitionRules;

    // ─── Events ───────────────────────────────────────────────────────────────

    event TeamCreated(
        uint256 indexed teamId,
        uint256 indexed competitionId,
        address indexed owner,
        string name,
        uint256[] playerIds,
        uint256 entryFee
    );

    event TeamUpdated(uint256 indexed teamId, uint256[] newPlayerIds);
    event CompetitionRulesSet(uint256 indexed competitionId, uint256 minPlayers, uint256 maxPlayers);
    event EntryFeeCollected(uint256 indexed competitionId, address indexed payer, uint256 amount);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error AlreadyEntered();
    error DeadlinePassed();
    error CompetitionNotOpen();
    error InsufficientEntryFee();
    error InvalidPlayerCount();
    error PlayerNotEligible();
    error DuplicatePlayer();
    error TeamNotFound();
    error NotTeamOwner();
    error TransferFailed();

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param _competitionFactory Address of deployed CompetitionFactory
    /// @param _playerRegistry Address of deployed PlayerRegistry
    constructor(address _competitionFactory, address _playerRegistry) Ownable(msg.sender) {
        require(_competitionFactory != address(0), "Invalid factory");
        require(_playerRegistry != address(0), "Invalid registry");
        competitionFactory = ICompetitionFactory(_competitionFactory);
        playerRegistry = IPlayerRegistry(_playerRegistry);
    }

    // ─── External Functions ───────────────────────────────────────────────────

    /// @notice Set player count rules for a competition
    /// @dev Called by competition organizer or admin before entries open
    /// @param _competitionId Competition ID
    /// @param _minPlayers Minimum players required per team
    /// @param _maxPlayers Maximum players allowed per team
    function setCompetitionRules(
        uint256 _competitionId,
        uint256 _minPlayers,
        uint256 _maxPlayers
    ) external onlyOwner {
        require(_minPlayers > 0 && _maxPlayers >= _minPlayers, "Invalid rules");
        competitionRules[_competitionId] = CompetitionRules({
            minPlayers: _minPlayers,
            maxPlayers: _maxPlayers,
            enforcePlayerCount: true
        });
        emit CompetitionRulesSet(_competitionId, _minPlayers, _maxPlayers);
    }

    /// @notice Create a team and enter a competition
    /// @param _competitionId Competition ID to enter
    /// @param _teamName Display name for the team
    /// @param _playerIds Array of player IDs to include in the team
    function createTeam(
        uint256 _competitionId,
        string calldata _teamName,
        uint256[] calldata _playerIds
    ) external payable whenNotPaused nonReentrant returns (uint256 teamId) {
        // Check one-team-per-wallet
        if (userTeam[_competitionId][msg.sender] != 0) revert AlreadyEntered();

        // Fetch competition data
        ICompetitionFactory.Competition memory comp = competitionFactory.getCompetition(_competitionId);

        // Validate competition state
        if (comp.status != ICompetitionFactory.CompetitionStatus.OPEN) revert CompetitionNotOpen();
        if (block.timestamp >= comp.deadline) revert DeadlinePassed();

        // Validate entry fee
        if (msg.value < comp.entryFee) revert InsufficientEntryFee();

        // Validate player count
        CompetitionRules memory rules = competitionRules[_competitionId];
        if (rules.enforcePlayerCount) {
            if (_playerIds.length < rules.minPlayers || _playerIds.length > rules.maxPlayers) {
                revert InvalidPlayerCount();
            }
        } else {
            require(_playerIds.length > 0, "Team must have players");
        }

        // Validate players are unique and eligible
        _validatePlayers(_competitionId, _playerIds);

        // Record entry in factory (checks/updates max teams)
        competitionFactory.recordTeamEntry(_competitionId);

        // Handle entry fee
        if (comp.entryFee > 0) {
            // Collect platform fee
            uint256 feeBps = competitionFactory.platformFeeBps();
            address feeRecipient = competitionFactory.feeRecipient();
            uint256 platformFee = (comp.entryFee * feeBps) / 10000;
            uint256 poolContribution = comp.entryFee - platformFee;

            if (platformFee > 0) {
                (bool feeOk,) = payable(feeRecipient).call{value: platformFee}("");
                if (!feeOk) revert TransferFailed();
            }

            // Send remainder to competition prize pool (held by this contract or escrow)
            // In production, this would go to PrizeEscrow directly
            emit EntryFeeCollected(_competitionId, msg.sender, poolContribution);

            // Refund overpayment
            if (msg.value > comp.entryFee) {
                (bool refundOk,) = payable(msg.sender).call{value: msg.value - comp.entryFee}("");
                if (!refundOk) revert TransferFailed();
            }
        } else if (msg.value > 0) {
            // Free competition, refund any ETH sent
            (bool refundOk,) = payable(msg.sender).call{value: msg.value}("");
            if (!refundOk) revert TransferFailed();
        }

        // Create team
        teamId = ++teamCount;
        uint256[] memory playerIds = _playerIds; // copy to storage

        teams[teamId] = Team({
            id: teamId,
            owner: msg.sender,
            competitionId: _competitionId,
            playerIds: playerIds,
            name: _teamName,
            createdAt: block.timestamp,
            exists: true
        });

        userTeam[_competitionId][msg.sender] = teamId;
        competitionTeams[_competitionId].push(teamId);

        emit TeamCreated(teamId, _competitionId, msg.sender, _teamName, playerIds, comp.entryFee);
    }

    // ─── View Functions ───────────────────────────────────────────────────────

    /// @notice Get team data by ID
    function getTeam(uint256 _teamId) external view returns (Team memory) {
        require(teams[_teamId].exists, "Team not found");
        return teams[_teamId];
    }

    /// @notice Get a user's team in a competition
    function getUserTeam(uint256 _competitionId, address _user)
        external
        view
        returns (Team memory)
    {
        uint256 teamId = userTeam[_competitionId][_user];
        require(teamId != 0, "No team found");
        return teams[teamId];
    }

    /// @notice Get all team IDs in a competition
    function getCompetitionTeams(uint256 _competitionId)
        external
        view
        returns (uint256[] memory)
    {
        return competitionTeams[_competitionId];
    }

    /// @notice Get full team data for all teams in a competition
    function getCompetitionTeamDetails(uint256 _competitionId)
        external
        view
        returns (Team[] memory)
    {
        uint256[] memory ids = competitionTeams[_competitionId];
        Team[] memory result = new Team[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            result[i] = teams[ids[i]];
        }
        return result;
    }

    /// @notice Get player IDs for a team
    function getTeamPlayers(uint256 _teamId) external view returns (uint256[] memory) {
        require(teams[_teamId].exists, "Team not found");
        return teams[_teamId].playerIds;
    }

    // ─── Admin Functions ──────────────────────────────────────────────────────

    /// @notice Update factory address (for upgrades)
    function setCompetitionFactory(address _factory) external onlyOwner {
        require(_factory != address(0), "Invalid address");
        competitionFactory = ICompetitionFactory(_factory);
    }

    /// @notice Update player registry address
    function setPlayerRegistry(address _registry) external onlyOwner {
        require(_registry != address(0), "Invalid address");
        playerRegistry = IPlayerRegistry(_registry);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─── Internal Functions ───────────────────────────────────────────────────

    /// @dev Validate that all player IDs are unique and eligible for the competition
    function _validatePlayers(uint256 _competitionId, uint256[] calldata _playerIds) internal view {
        for (uint256 i = 0; i < _playerIds.length; i++) {
            // Check eligibility in this competition
            if (!playerRegistry.isPlayerInCompetition(_competitionId, _playerIds[i])) {
                revert PlayerNotEligible();
            }
            // Check duplicates
            for (uint256 j = i + 1; j < _playerIds.length; j++) {
                if (_playerIds[i] == _playerIds[j]) revert DuplicatePlayer();
            }
        }
    }

    receive() external payable {}
}
