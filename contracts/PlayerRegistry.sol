// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PlayerRegistry
/// @notice Manages the pool of real-world athletes eligible for fantasy competitions
/// @dev Admin registers players per competition; supports batch operations
contract PlayerRegistry is Ownable, Pausable {

    // ─── Enums ────────────────────────────────────────────────────────────────

    enum Position {
        GOALKEEPER,
        DEFENDER,
        MIDFIELDER,
        FORWARD,
        PITCHER,
        CATCHER,
        INFIELDER,
        OUTFIELDER,
        POINT_GUARD,
        SHOOTING_GUARD,
        SMALL_FORWARD,
        POWER_FORWARD,
        CENTER,
        QUARTERBACK,
        RUNNING_BACK,
        WIDE_RECEIVER,
        TIGHT_END,
        KICKER,
        GENERAL
    }

    enum PlayerStatus { ACTIVE, INJURED, SUSPENDED, RETIRED }

    // ─── Structs ──────────────────────────────────────────────────────────────

    /// @notice Core player data
    struct Player {
        uint256 id;
        string  name;
        string  realTeam;        // Real-world team name
        Position position;
        uint8   sport;           // Maps to CompetitionFactory.SportType
        PlayerStatus status;
        uint256 registeredAt;
        bool    exists;
    }

    // ─── Storage ──────────────────────────────────────────────────────────────

    /// @dev Global player counter — IDs are globally unique across all competitions
    uint256 public playerCount;

    /// @notice Global player storage by ID
    mapping(uint256 => Player) public players;

    /// @notice Authorized admins who can register players
    mapping(address => bool) public registrars;

    /// @notice competitionId => array of player IDs in that competition
    mapping(uint256 => uint256[]) private competitionPlayers;

    /// @notice competitionId => playerId => index+1 in competitionPlayers (0 = not in competition)
    mapping(uint256 => mapping(uint256 => uint256)) private playerIndexInComp;

    // ─── Events ───────────────────────────────────────────────────────────────

    event PlayerRegistered(
        uint256 indexed playerId,
        string name,
        Position position,
        uint8 sport,
        string realTeam
    );

    event PlayerStatusUpdated(
        uint256 indexed playerId,
        PlayerStatus oldStatus,
        PlayerStatus newStatus
    );

    event PlayerAddedToCompetition(uint256 indexed competitionId, uint256 indexed playerId);
    event PlayerRemovedFromCompetition(uint256 indexed competitionId, uint256 indexed playerId);
    event RegistrarUpdated(address indexed registrar, bool authorized);
    event BatchRegistered(uint256 indexed competitionId, uint256 count);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error NotRegistrar();
    error PlayerNotFound();
    error PlayerAlreadyInCompetition();
    error PlayerNotInCompetition();
    error EmptyBatch();
    error BatchTooLarge();
    error InvalidPlayerName();

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor() Ownable(msg.sender) {
        registrars[msg.sender] = true;
    }

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyRegistrar() {
        if (!registrars[msg.sender] && msg.sender != owner()) revert NotRegistrar();
        _;
    }

    modifier playerExists(uint256 _id) {
        if (!players[_id].exists) revert PlayerNotFound();
        _;
    }

    // ─── External Functions ───────────────────────────────────────────────────

    /// @notice Register a single player in the global registry
    /// @param _name Player's full name
    /// @param _realTeam Real-world team name
    /// @param _position Player position enum
    /// @param _sport Sport type (0=football, 1=basketball, etc.)
    /// @return playerId Newly created player ID
    function registerPlayer(
        string calldata _name,
        string calldata _realTeam,
        Position _position,
        uint8 _sport
    ) external whenNotPaused onlyRegistrar returns (uint256 playerId) {
        if (bytes(_name).length == 0) revert InvalidPlayerName();

        playerId = ++playerCount;
        players[playerId] = Player({
            id: playerId,
            name: _name,
            realTeam: _realTeam,
            position: _position,
            sport: _sport,
            status: PlayerStatus.ACTIVE,
            registeredAt: block.timestamp,
            exists: true
        });

        emit PlayerRegistered(playerId, _name, _position, _sport, _realTeam);
    }

    /// @notice Batch-register multiple players and assign them to a competition
    /// @param _competitionId Competition to add players to
    /// @param _names Array of player names
    /// @param _realTeams Array of real team names
    /// @param _positions Array of positions
    /// @param _sports Array of sport types
    /// @return firstId First newly created player ID; subsequent IDs are sequential
    function batchRegisterPlayers(
        uint256 _competitionId,
        string[] calldata _names,
        string[] calldata _realTeams,
        Position[] calldata _positions,
        uint8[] calldata _sports
    ) external whenNotPaused onlyRegistrar returns (uint256 firstId) {
        uint256 count = _names.length;
        if (count == 0) revert EmptyBatch();
        if (count > 100) revert BatchTooLarge();
        require(
            count == _realTeams.length &&
            count == _positions.length &&
            count == _sports.length,
            "Array length mismatch"
        );

        firstId = playerCount + 1;

        for (uint256 i = 0; i < count; i++) {
            if (bytes(_names[i]).length == 0) revert InvalidPlayerName();
            uint256 pid = ++playerCount;
            players[pid] = Player({
                id: pid,
                name: _names[i],
                realTeam: _realTeams[i],
                position: _positions[i],
                sport: _sports[i],
                status: PlayerStatus.ACTIVE,
                registeredAt: block.timestamp,
                exists: true
            });

            emit PlayerRegistered(pid, _names[i], _positions[i], _sports[i], _realTeams[i]);

            // Add to competition if competitionId > 0
            if (_competitionId > 0) {
                _addToCompetition(_competitionId, pid);
            }
        }

        if (_competitionId > 0) {
            emit BatchRegistered(_competitionId, count);
        }
    }

    /// @notice Add an existing player to a competition's player pool
    /// @param _competitionId Competition ID
    /// @param _playerId Player ID to add
    function addPlayerToCompetition(uint256 _competitionId, uint256 _playerId)
        external
        onlyRegistrar
        playerExists(_playerId)
    {
        _addToCompetition(_competitionId, _playerId);
        emit PlayerAddedToCompetition(_competitionId, _playerId);
    }

    /// @notice Remove a player from a competition's pool
    /// @param _competitionId Competition ID
    /// @param _playerId Player ID to remove
    function removePlayerFromCompetition(uint256 _competitionId, uint256 _playerId)
        external
        onlyRegistrar
    {
        uint256 idx = playerIndexInComp[_competitionId][_playerId];
        if (idx == 0) revert PlayerNotInCompetition();

        uint256[] storage arr = competitionPlayers[_competitionId];
        uint256 lastId = arr[arr.length - 1];
        arr[idx - 1] = lastId;
        playerIndexInComp[_competitionId][lastId] = idx;
        arr.pop();
        delete playerIndexInComp[_competitionId][_playerId];

        emit PlayerRemovedFromCompetition(_competitionId, _playerId);
    }

    /// @notice Update player status (active/injured/suspended/retired)
    /// @param _playerId Player ID
    /// @param _newStatus New status
    function updatePlayerStatus(uint256 _playerId, PlayerStatus _newStatus)
        external
        onlyRegistrar
        playerExists(_playerId)
    {
        PlayerStatus old = players[_playerId].status;
        players[_playerId].status = _newStatus;
        emit PlayerStatusUpdated(_playerId, old, _newStatus);
    }

    // ─── View Functions ───────────────────────────────────────────────────────

    /// @notice Get player data by ID
    function getPlayer(uint256 _id) external view playerExists(_id) returns (Player memory) {
        return players[_id];
    }

    /// @notice Get all players in a competition
    /// @param _competitionId Competition ID
    function getCompetitionPlayers(uint256 _competitionId)
        external
        view
        returns (uint256[] memory)
    {
        return competitionPlayers[_competitionId];
    }

    /// @notice Get full player data for all players in a competition
    /// @param _competitionId Competition ID
    function getCompetitionPlayerDetails(uint256 _competitionId)
        external
        view
        returns (Player[] memory)
    {
        uint256[] memory ids = competitionPlayers[_competitionId];
        Player[] memory result = new Player[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            result[i] = players[ids[i]];
        }
        return result;
    }

    /// @notice Check if a player is in a competition
    function isPlayerInCompetition(uint256 _competitionId, uint256 _playerId)
        external
        view
        returns (bool)
    {
        return playerIndexInComp[_competitionId][_playerId] > 0;
    }

    /// @notice Get players filtered by position within a competition
    /// @param _competitionId Competition ID
    /// @param _position Position to filter by
    function getPlayersByPosition(uint256 _competitionId, Position _position)
        external
        view
        returns (Player[] memory)
    {
        uint256[] memory ids = competitionPlayers[_competitionId];
        uint256 count = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            if (players[ids[i]].position == _position) count++;
        }
        Player[] memory result = new Player[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            if (players[ids[i]].position == _position) {
                result[idx++] = players[ids[i]];
            }
        }
        return result;
    }

    // ─── Admin Functions ──────────────────────────────────────────────────────

    /// @notice Authorize or deauthorize a registrar
    function setRegistrar(address _registrar, bool _authorized) external onlyOwner {
        registrars[_registrar] = _authorized;
        emit RegistrarUpdated(_registrar, _authorized);
    }

    /// @notice Pause registry operations
    function pause() external onlyOwner { _pause(); }

    /// @notice Unpause registry operations
    function unpause() external onlyOwner { _unpause(); }

    // ─── Internal Functions ───────────────────────────────────────────────────

    function _addToCompetition(uint256 _competitionId, uint256 _playerId) internal {
        if (playerIndexInComp[_competitionId][_playerId] > 0) {
            revert PlayerAlreadyInCompetition();
        }
        competitionPlayers[_competitionId].push(_playerId);
        playerIndexInComp[_competitionId][_playerId] = competitionPlayers[_competitionId].length;
    }
}
