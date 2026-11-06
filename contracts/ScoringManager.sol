// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ITeamManagerForScoring {
    struct Team {
        uint256 id;
        address owner;
        uint256 competitionId;
        uint256[] playerIds;
        string  name;
        uint256 createdAt;
        bool    exists;
    }
    function getCompetitionTeams(uint256 _competitionId) external view returns (uint256[] memory);
    function getTeam(uint256 _teamId) external view returns (Team memory);
    function getTeamPlayers(uint256 _teamId) external view returns (uint256[] memory);
}

interface ICompetitionFactoryForScoring {
    enum CompetitionStatus { OPEN, CLOSED, SCORING, DISPUTED, FINALIZED, CANCELLED }

    struct Competition {
        uint256 id;
        address organizer;
        string  name;
        uint8   sport;
        uint256 entryFee;
        uint256 maxTeams;
        uint256 deadline;
        uint256 prizePool;
        uint8   currency;
        address usdtToken;
        address oracle;
        bytes32 scoringRulesHash;
        CompetitionStatus status;
        uint256 createdAt;
        uint256 teamsCount;
    }

    function getCompetition(uint256 _id) external view returns (Competition memory);
    function updateStatus(uint256 _id, CompetitionStatus _newStatus) external;
}

/// @title ScoringManager
/// @notice Authorized oracles submit match results; computes and finalizes team scores
/// @dev 48-hour dispute window before scores are locked; admin can correct during dispute
contract ScoringManager is Ownable, Pausable, ReentrancyGuard {

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 public constant DISPUTE_WINDOW = 48 hours;

    // ─── Structs ──────────────────────────────────────────────────────────────

    struct MatchResult {
        uint256 matchId;
        uint256 competitionId;
        bytes32 dataHash;        // keccak256 of off-chain JSON performance data
        uint256[] playerIds;
        int256[]  playerScores;  // can be negative (penalty deductions)
        uint256 submittedAt;
        address submittedBy;
        bool    corrected;
    }

    struct TeamScore {
        uint256 teamId;
        int256  totalScore;
        uint256 lastUpdated;
        bool    finalized;
    }

    struct DisputeRecord {
        address disputer;
        string  reason;
        uint256 disputedAt;
        bool    resolved;
        bool    upheld;
    }

    // ─── Storage ──────────────────────────────────────────────────────────────

    ICompetitionFactoryForScoring public competitionFactory;
    ITeamManagerForScoring public teamManager;

    uint256 public matchResultCount;

    /// @notice matchId => MatchResult
    mapping(uint256 => MatchResult) public matchResults;

    /// @notice competitionId => array of matchIds
    mapping(uint256 => uint256[]) public competitionMatches;

    /// @notice teamId => TeamScore
    mapping(uint256 => TeamScore) public teamScores;

    /// @notice competitionId => array of team IDs sorted by score (populated on finalization)
    mapping(uint256 => uint256[]) public competitionRankings;

    /// @notice competitionId => finalization timestamp
    mapping(uint256 => uint256) public finalizedAt;

    /// @notice Dispute tracking: competitionId => DisputeRecord[]
    mapping(uint256 => DisputeRecord[]) public disputes;

    /// @notice Authorized oracle addresses (can be set per competition in factory)
    mapping(address => bool) public authorizedOracles;

    // ─── Events ───────────────────────────────────────────────────────────────

    event MatchResultSubmitted(
        uint256 indexed matchId,
        uint256 indexed competitionId,
        bytes32 dataHash,
        uint256 playerCount,
        address submittedBy
    );

    event MatchResultCorrected(
        uint256 indexed matchId,
        uint256 indexed competitionId,
        address correctedBy
    );

    event TeamScoreUpdated(
        uint256 indexed teamId,
        uint256 indexed competitionId,
        int256 totalScore
    );

    event CompetitionFinalized(
        uint256 indexed competitionId,
        uint256 finalizedAt,
        uint256 teamCount
    );

    event DisputeRaised(
        uint256 indexed competitionId,
        address indexed disputer,
        string reason
    );

    event DisputeResolved(
        uint256 indexed competitionId,
        uint256 disputeIndex,
        bool upheld
    );

    event OracleAuthorized(address indexed oracle, bool authorized);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error NotOracle();
    error ArrayLengthMismatch();
    error CompetitionAlreadyFinalized();
    error DisputeWindowOpen();
    error DisputeWindowClosed();
    error NotInDisputeWindow();
    error MatchNotFound();
    error EmptyPlayerArray();

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param _competitionFactory CompetitionFactory address
    /// @param _teamManager TeamManager address
    constructor(address _competitionFactory, address _teamManager) Ownable(msg.sender) {
        require(_competitionFactory != address(0), "Invalid factory");
        require(_teamManager != address(0), "Invalid team manager");
        competitionFactory = ICompetitionFactoryForScoring(_competitionFactory);
        teamManager = ITeamManagerForScoring(_teamManager);
        authorizedOracles[msg.sender] = true;
    }

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyOracle() {
        if (!authorizedOracles[msg.sender] && msg.sender != owner()) revert NotOracle();
        _;
    }

    // ─── Oracle Functions ─────────────────────────────────────────────────────

    /// @notice Submit player performance data for a match
    /// @param _competitionId Competition ID
    /// @param _dataHash keccak256 hash of off-chain performance JSON
    /// @param _playerIds Array of player IDs
    /// @param _playerScores Array of scores corresponding to playerIds (1 point = 1e0, e.g. 23 = 23 pts)
    /// @return matchId Newly created match result ID
    function submitMatchResult(
        uint256 _competitionId,
        bytes32 _dataHash,
        uint256[] calldata _playerIds,
        int256[] calldata _playerScores
    ) external whenNotPaused onlyOracle returns (uint256 matchId) {
        if (_playerIds.length == 0) revert EmptyPlayerArray();
        if (_playerIds.length != _playerScores.length) revert ArrayLengthMismatch();
        if (finalizedAt[_competitionId] > 0) revert CompetitionAlreadyFinalized();

        matchId = ++matchResultCount;

        matchResults[matchId] = MatchResult({
            matchId: matchId,
            competitionId: _competitionId,
            dataHash: _dataHash,
            playerIds: _playerIds,
            playerScores: _playerScores,
            submittedAt: block.timestamp,
            submittedBy: msg.sender,
            corrected: false
        });

        competitionMatches[_competitionId].push(matchId);

        emit MatchResultSubmitted(matchId, _competitionId, _dataHash, _playerIds.length, msg.sender);

        // Update team scores based on this result
        _updateTeamScores(_competitionId, _playerIds, _playerScores);
    }

    /// @notice Correct a previously submitted match result (admin only, within dispute window)
    /// @param _matchId Match result ID to correct
    /// @param _newDataHash Updated data hash
    /// @param _newPlayerIds New player IDs
    /// @param _newScores New scores
    function correctMatchResult(
        uint256 _matchId,
        bytes32 _newDataHash,
        uint256[] calldata _newPlayerIds,
        int256[] calldata _newScores
    ) external onlyOwner {
        MatchResult storage result = matchResults[_matchId];
        require(result.matchId == _matchId, "Match not found");
        if (_newPlayerIds.length != _newScores.length) revert ArrayLengthMismatch();

        uint256 compId = result.competitionId;
        if (finalizedAt[compId] > 0) revert CompetitionAlreadyFinalized();

        // Reverse old scores from team totals
        _updateTeamScores(compId, result.playerIds, _negateArray(result.playerScores));

        // Apply new scores
        result.dataHash = _newDataHash;
        result.playerIds = _newPlayerIds;
        result.playerScores = _newScores;
        result.corrected = true;

        _updateTeamScores(compId, _newPlayerIds, _newScores);

        emit MatchResultCorrected(_matchId, compId, msg.sender);
    }

    // ─── Finalization ─────────────────────────────────────────────────────────

    /// @notice Finalize scores for a competition after dispute window
    /// @dev Sorts teams by score and stores rankings
    /// @param _competitionId Competition ID to finalize
    function finalizeCompetition(uint256 _competitionId)
        external
        whenNotPaused
        nonReentrant
    {
        if (finalizedAt[_competitionId] > 0) revert CompetitionAlreadyFinalized();

        // Check dispute window: last match must be at least DISPUTE_WINDOW old
        uint256[] memory matches = competitionMatches[_competitionId];
        require(matches.length > 0, "No results submitted");

        uint256 lastMatchTime = 0;
        for (uint256 i = 0; i < matches.length; i++) {
            if (matchResults[matches[i]].submittedAt > lastMatchTime) {
                lastMatchTime = matchResults[matches[i]].submittedAt;
            }
        }

        if (block.timestamp < lastMatchTime + DISPUTE_WINDOW) revert DisputeWindowOpen();

        // Get all teams and sort by score
        uint256[] memory teamIds = teamManager.getCompetitionTeams(_competitionId);
        require(teamIds.length > 0, "No teams entered");

        // Mark all team scores as finalized
        for (uint256 i = 0; i < teamIds.length; i++) {
            teamScores[teamIds[i]].finalized = true;
        }

        // Sort teams by score (insertion sort — acceptable for typical competition sizes)
        uint256[] memory sorted = _sortTeamsByScore(teamIds);
        competitionRankings[_competitionId] = sorted;

        finalizedAt[_competitionId] = block.timestamp;

        // Update competition status in factory
        competitionFactory.updateStatus(
            _competitionId,
            ICompetitionFactoryForScoring.CompetitionStatus.FINALIZED
        );

        emit CompetitionFinalized(_competitionId, block.timestamp, teamIds.length);
    }

    // ─── Dispute Functions ────────────────────────────────────────────────────

    /// @notice Raise a dispute about competition results
    /// @param _competitionId Competition to dispute
    /// @param _reason Textual reason for the dispute
    function raiseDispute(uint256 _competitionId, string calldata _reason)
        external
        whenNotPaused
    {
        if (finalizedAt[_competitionId] > 0) revert CompetitionAlreadyFinalized();

        // Check we're within the dispute window
        uint256[] memory matches = competitionMatches[_competitionId];
        if (matches.length == 0) revert MatchNotFound();

        uint256 lastMatchTime = 0;
        for (uint256 i = 0; i < matches.length; i++) {
            if (matchResults[matches[i]].submittedAt > lastMatchTime) {
                lastMatchTime = matchResults[matches[i]].submittedAt;
            }
        }

        if (block.timestamp >= lastMatchTime + DISPUTE_WINDOW) revert DisputeWindowClosed();

        disputes[_competitionId].push(DisputeRecord({
            disputer: msg.sender,
            reason: _reason,
            disputedAt: block.timestamp,
            resolved: false,
            upheld: false
        }));

        // Set competition to DISPUTED status
        competitionFactory.updateStatus(
            _competitionId,
            ICompetitionFactoryForScoring.CompetitionStatus.DISPUTED
        );

        emit DisputeRaised(_competitionId, msg.sender, _reason);
    }

    /// @notice Resolve a dispute (admin only)
    /// @param _competitionId Competition ID
    /// @param _disputeIndex Index in the disputes array
    /// @param _upheld Whether the dispute was upheld
    function resolveDispute(
        uint256 _competitionId,
        uint256 _disputeIndex,
        bool _upheld
    ) external onlyOwner {
        DisputeRecord storage dispute = disputes[_competitionId][_disputeIndex];
        require(!dispute.resolved, "Already resolved");
        dispute.resolved = true;
        dispute.upheld = _upheld;

        if (!_upheld) {
            // Resume scoring state
            competitionFactory.updateStatus(
                _competitionId,
                ICompetitionFactoryForScoring.CompetitionStatus.SCORING
            );
        }

        emit DisputeResolved(_competitionId, _disputeIndex, _upheld);
    }

    // ─── View Functions ───────────────────────────────────────────────────────

    /// @notice Get a team's total score
    function getTeamScore(uint256 _teamId) external view returns (TeamScore memory) {
        return teamScores[_teamId];
    }

    /// @notice Get competition rankings (sorted array of teamIds, best first)
    function getCompetitionRankings(uint256 _competitionId)
        external
        view
        returns (uint256[] memory)
    {
        return competitionRankings[_competitionId];
    }

    /// @notice Get match result by ID
    function getMatchResult(uint256 _matchId) external view returns (MatchResult memory) {
        require(matchResults[_matchId].matchId == _matchId, "Not found");
        return matchResults[_matchId];
    }

    /// @notice Get all match IDs for a competition
    function getCompetitionMatches(uint256 _competitionId)
        external
        view
        returns (uint256[] memory)
    {
        return competitionMatches[_competitionId];
    }

    /// @notice Get disputes for a competition
    function getDisputes(uint256 _competitionId)
        external
        view
        returns (DisputeRecord[] memory)
    {
        return disputes[_competitionId];
    }

    /// @notice Check if competition is in dispute window
    function isInDisputeWindow(uint256 _competitionId) external view returns (bool) {
        uint256[] memory matches = competitionMatches[_competitionId];
        if (matches.length == 0) return false;

        uint256 lastMatchTime = 0;
        for (uint256 i = 0; i < matches.length; i++) {
            if (matchResults[matches[i]].submittedAt > lastMatchTime) {
                lastMatchTime = matchResults[matches[i]].submittedAt;
            }
        }

        return block.timestamp < lastMatchTime + DISPUTE_WINDOW;
    }

    // ─── Admin Functions ──────────────────────────────────────────────────────

    /// @notice Authorize or deauthorize an oracle
    function setOracle(address _oracle, bool _authorized) external onlyOwner {
        authorizedOracles[_oracle] = _authorized;
        emit OracleAuthorized(_oracle, _authorized);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─── Internal Functions ───────────────────────────────────────────────────

    /// @dev Update all team scores in a competition based on player score deltas
    function _updateTeamScores(
        uint256 _competitionId,
        uint256[] memory _playerIds,
        int256[] memory _scores
    ) internal {
        uint256[] memory teamIds = teamManager.getCompetitionTeams(_competitionId);

        for (uint256 t = 0; t < teamIds.length; t++) {
            uint256 teamId = teamIds[t];
            uint256[] memory teamPlayerIds = teamManager.getTeamPlayers(teamId);
            int256 delta = 0;

            for (uint256 p = 0; p < teamPlayerIds.length; p++) {
                for (uint256 s = 0; s < _playerIds.length; s++) {
                    if (teamPlayerIds[p] == _playerIds[s]) {
                        delta += _scores[s];
                        break;
                    }
                }
            }

            if (delta != 0) {
                teamScores[teamId].teamId = teamId;
                teamScores[teamId].totalScore += delta;
                teamScores[teamId].lastUpdated = block.timestamp;
                emit TeamScoreUpdated(teamId, _competitionId, teamScores[teamId].totalScore);
            }
        }
    }

    /// @dev Negate all values in an int256 array (for score reversal)
    function _negateArray(int256[] memory arr) internal pure returns (int256[] memory neg) {
        neg = new int256[](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            neg[i] = -arr[i];
        }
    }

    /// @dev Sort team IDs by score descending (insertion sort)
    function _sortTeamsByScore(uint256[] memory teamIds)
        internal
        view
        returns (uint256[] memory sorted)
    {
        sorted = new uint256[](teamIds.length);
        for (uint256 i = 0; i < teamIds.length; i++) {
            sorted[i] = teamIds[i];
        }

        for (uint256 i = 1; i < sorted.length; i++) {
            uint256 key = sorted[i];
            int256 keyScore = teamScores[key].totalScore;
            int256 j = int256(i) - 1;
            while (j >= 0 && teamScores[sorted[uint256(j)]].totalScore < keyScore) {
                sorted[uint256(j + 1)] = sorted[uint256(j)];
                j--;
            }
            sorted[uint256(j + 1)] = key;
        }
    }
}
