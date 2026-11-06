// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IPrizeEscrow {
    function releaseFunds(uint256 _competitionId) external;
    function getBalance(uint256 _competitionId) external view returns (uint256);
}

interface IScoringManagerForClaim {
    function getCompetitionRankings(uint256 _competitionId) external view returns (uint256[] memory);
    function finalizedAt(uint256 _competitionId) external view returns (uint256);
}

interface ITeamManagerForClaim {
    struct Team {
        uint256 id;
        address owner;
        uint256 competitionId;
        uint256[] playerIds;
        string  name;
        uint256 createdAt;
        bool    exists;
    }
    function getTeam(uint256 _teamId) external view returns (Team memory);
    function userTeam(uint256 _competitionId, address _user) external view returns (uint256);
}

/// @title ClaimManager
/// @notice Distributes prizes to competition winners; prevents double-claims and reentrancy
/// @dev Prize splits configurable per competition; default 50/30/20 for top 3
contract ClaimManager is Ownable, Pausable, ReentrancyGuard {

    // ─── Structs ──────────────────────────────────────────────────────────────

    struct PrizeDistribution {
        uint256[] rankBps;       // basis points for each rank (must sum <= 10000)
        bool      configured;
    }

    struct ClaimRecord {
        address claimant;
        uint256 teamId;
        uint256 rank;            // 1-indexed
        uint256 amount;
        uint256 claimedAt;
        bool    native;          // true = BOT, false = ERC-20
    }

    struct CompetitionPrizePool {
        uint256 totalAmount;
        address tokenAddress;    // address(0) = native
        bool    funded;
        bool    allClaimed;
        uint256 claimedAmount;
    }

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 public constant DEFAULT_FIRST_BPS  = 5000;  // 50%
    uint256 public constant DEFAULT_SECOND_BPS = 3000;  // 30%
    uint256 public constant DEFAULT_THIRD_BPS  = 2000;  // 20%

    // ─── Storage ──────────────────────────────────────────────────────────────

    IPrizeEscrow public prizeEscrow;
    IScoringManagerForClaim public scoringManager;
    ITeamManagerForClaim public teamManager;

    /// @notice Per-competition prize distribution config
    mapping(uint256 => PrizeDistribution) public prizeDistributions;

    /// @notice competitionId => prize pool tracking
    mapping(uint256 => CompetitionPrizePool) public prizePools;

    /// @notice competitionId => walletAddress => ClaimRecord
    mapping(uint256 => mapping(address => ClaimRecord)) public claims;

    /// @notice competitionId => whether funds have been pulled from escrow
    mapping(uint256 => bool) public escrowReleased;

    // ─── Events ───────────────────────────────────────────────────────────────

    event PrizeClaimed(
        uint256 indexed competitionId,
        address indexed claimant,
        uint256 indexed teamId,
        uint256 rank,
        uint256 amount
    );

    event FundsReceivedFromEscrow(
        uint256 indexed competitionId,
        uint256 amount
    );

    event PrizeDistributionSet(
        uint256 indexed competitionId,
        uint256[] rankBps
    );

    event UnclaimedFundsSwept(
        uint256 indexed competitionId,
        address indexed recipient,
        uint256 amount
    );

    // ─── Errors ───────────────────────────────────────────────────────────────

    error AlreadyClaimed();
    error NotWinner();
    error CompetitionNotFinalized();
    error NoTeamInCompetition();
    error TransferFailed();
    error FundsNotAvailable();
    error InvalidDistribution();
    error EscrowAlreadyReleased();
    error NothingToSweep();

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param _prizeEscrow PrizeEscrow contract address
    /// @param _scoringManager ScoringManager contract address
    /// @param _teamManager TeamManager contract address
    constructor(
        address _prizeEscrow,
        address _scoringManager,
        address _teamManager
    ) Ownable(msg.sender) {
        require(_prizeEscrow != address(0), "Invalid escrow");
        require(_scoringManager != address(0), "Invalid scoring");
        require(_teamManager != address(0), "Invalid team manager");
        prizeEscrow = IPrizeEscrow(_prizeEscrow);
        scoringManager = IScoringManagerForClaim(_scoringManager);
        teamManager = ITeamManagerForClaim(_teamManager);
    }

    // ─── External Functions ───────────────────────────────────────────────────

    /// @notice Set custom prize distribution for a competition
    /// @dev Must be set before finalization; bps values must sum to <= 10000
    /// @param _competitionId Competition ID
    /// @param _rankBps Array of basis points per rank (index 0 = 1st place)
    function setPrizeDistribution(uint256 _competitionId, uint256[] calldata _rankBps)
        external
        onlyOwner
    {
        uint256 total = 0;
        for (uint256 i = 0; i < _rankBps.length; i++) {
            total += _rankBps[i];
        }
        if (total > 10000) revert InvalidDistribution();

        prizeDistributions[_competitionId] = PrizeDistribution({
            rankBps: _rankBps,
            configured: true
        });

        emit PrizeDistributionSet(_competitionId, _rankBps);
    }

    /// @notice Pull funds from escrow and prepare for claims
    /// @param _competitionId Finalized competition ID
    /// @param _tokenAddress ERC-20 token address (address(0) for native)
    function pullFromEscrow(uint256 _competitionId, address _tokenAddress)
        external
        whenNotPaused
        nonReentrant
    {
        if (escrowReleased[_competitionId]) revert EscrowAlreadyReleased();
        if (scoringManager.finalizedAt(_competitionId) == 0) revert CompetitionNotFinalized();

        escrowReleased[_competitionId] = true;

        // Record pre-balance
        uint256 balanceBefore;
        if (_tokenAddress == address(0)) {
            balanceBefore = address(this).balance;
        } else {
            (bool ok, bytes memory data) = _tokenAddress.call(
                abi.encodeWithSignature("balanceOf(address)", address(this))
            );
            require(ok, "Balance check failed");
            balanceBefore = abi.decode(data, (uint256));
        }

        // Trigger release from escrow
        prizeEscrow.releaseFunds(_competitionId);

        // Record post-balance delta
        uint256 received;
        if (_tokenAddress == address(0)) {
            received = address(this).balance - balanceBefore;
        } else {
            (bool ok, bytes memory data) = _tokenAddress.call(
                abi.encodeWithSignature("balanceOf(address)", address(this))
            );
            require(ok, "Balance check failed");
            uint256 balanceAfter = abi.decode(data, (uint256));
            received = balanceAfter - balanceBefore;
        }

        prizePools[_competitionId] = CompetitionPrizePool({
            totalAmount: received,
            tokenAddress: _tokenAddress,
            funded: true,
            allClaimed: false,
            claimedAmount: 0
        });

        emit FundsReceivedFromEscrow(_competitionId, received);
    }

    /// @notice Claim prize for caller's team in a finalized competition
    /// @param _competitionId Competition ID
    function claimPrize(uint256 _competitionId)
        external
        whenNotPaused
        nonReentrant
    {
        // Checks
        if (claims[_competitionId][msg.sender].claimedAt > 0) revert AlreadyClaimed();
        if (scoringManager.finalizedAt(_competitionId) == 0) revert CompetitionNotFinalized();

        CompetitionPrizePool storage pool = prizePools[_competitionId];
        if (!pool.funded) revert FundsNotAvailable();

        // Find caller's team
        uint256 teamId = teamManager.userTeam(_competitionId, msg.sender);
        if (teamId == 0) revert NoTeamInCompetition();

        // Find rank
        uint256[] memory rankings = scoringManager.getCompetitionRankings(_competitionId);
        uint256 rank = 0;
        for (uint256 i = 0; i < rankings.length; i++) {
            if (rankings[i] == teamId) {
                rank = i + 1; // 1-indexed
                break;
            }
        }

        // Check if this rank has a prize
        uint256[] memory bps = _getDistributionBps(_competitionId);
        if (rank == 0 || rank > bps.length || bps[rank - 1] == 0) revert NotWinner();

        // Calculate amount
        uint256 amount = (pool.totalAmount * bps[rank - 1]) / 10000;
        if (amount == 0) revert NotWinner();

        // Effects
        claims[_competitionId][msg.sender] = ClaimRecord({
            claimant: msg.sender,
            teamId: teamId,
            rank: rank,
            amount: amount,
            claimedAt: block.timestamp,
            native: pool.tokenAddress == address(0)
        });

        pool.claimedAmount += amount;

        // Interactions
        if (pool.tokenAddress == address(0)) {
            (bool ok,) = payable(msg.sender).call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            (bool ok, bytes memory data) = pool.tokenAddress.call(
                abi.encodeWithSignature("transfer(address,uint256)", msg.sender, amount)
            );
            require(ok && (data.length == 0 || abi.decode(data, (bool))), "Token transfer failed");
        }

        emit PrizeClaimed(_competitionId, msg.sender, teamId, rank, amount);
    }

    /// @notice Sweep unclaimed prize funds after a competition's claim period (90 days)
    /// @param _competitionId Competition ID
    /// @param _recipient Address to send unclaimed funds to
    function sweepUnclaimed(uint256 _competitionId, address _recipient)
        external
        onlyOwner
        nonReentrant
    {
        uint256 finalTime = scoringManager.finalizedAt(_competitionId);
        require(finalTime > 0, "Not finalized");
        require(block.timestamp >= finalTime + 90 days, "Claim period not over");

        CompetitionPrizePool storage pool = prizePools[_competitionId];
        require(pool.funded, "No funds");

        uint256 unclaimed = pool.totalAmount - pool.claimedAmount;
        if (unclaimed == 0) revert NothingToSweep();

        pool.claimedAmount = pool.totalAmount;

        if (pool.tokenAddress == address(0)) {
            (bool ok,) = payable(_recipient).call{value: unclaimed}("");
            if (!ok) revert TransferFailed();
        } else {
            (bool ok, bytes memory data) = pool.tokenAddress.call(
                abi.encodeWithSignature("transfer(address,uint256)", _recipient, unclaimed)
            );
            require(ok && (data.length == 0 || abi.decode(data, (bool))), "Token transfer failed");
        }

        emit UnclaimedFundsSwept(_competitionId, _recipient, unclaimed);
    }

    // ─── View Functions ───────────────────────────────────────────────────────

    /// @notice Get caller's claimable amount in a competition
    /// @param _competitionId Competition ID
    /// @param _user User address to check
    function getClaimableAmount(uint256 _competitionId, address _user)
        external
        view
        returns (uint256 amount, uint256 rank)
    {
        if (claims[_competitionId][_user].claimedAt > 0) return (0, 0);

        uint256 teamId = teamManager.userTeam(_competitionId, _user);
        if (teamId == 0) return (0, 0);
        if (scoringManager.finalizedAt(_competitionId) == 0) return (0, 0);

        uint256[] memory rankings = scoringManager.getCompetitionRankings(_competitionId);
        for (uint256 i = 0; i < rankings.length; i++) {
            if (rankings[i] == teamId) {
                rank = i + 1;
                break;
            }
        }

        if (rank == 0) return (0, 0);

        uint256[] memory bps = _getDistributionBps(_competitionId);
        if (rank > bps.length || bps[rank - 1] == 0) return (0, rank);

        CompetitionPrizePool storage pool = prizePools[_competitionId];
        if (!pool.funded) return (0, rank);

        amount = (pool.totalAmount * bps[rank - 1]) / 10000;
    }

    /// @notice Get claim record for a user in a competition
    function getClaim(uint256 _competitionId, address _user)
        external
        view
        returns (ClaimRecord memory)
    {
        return claims[_competitionId][_user];
    }

    /// @notice Get prize pool info for a competition
    function getPrizePool(uint256 _competitionId)
        external
        view
        returns (CompetitionPrizePool memory)
    {
        return prizePools[_competitionId];
    }

    // ─── Admin Functions ──────────────────────────────────────────────────────

    function setPrizeEscrow(address _escrow) external onlyOwner {
        require(_escrow != address(0), "Invalid address");
        prizeEscrow = IPrizeEscrow(_escrow);
    }

    function setScoringManager(address _scoring) external onlyOwner {
        require(_scoring != address(0), "Invalid address");
        scoringManager = IScoringManagerForClaim(_scoring);
    }

    function setTeamManager(address _tm) external onlyOwner {
        require(_tm != address(0), "Invalid address");
        teamManager = ITeamManagerForClaim(_tm);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─── Internal Functions ───────────────────────────────────────────────────

    /// @dev Get distribution basis points for a competition
    function _getDistributionBps(uint256 _competitionId)
        internal
        view
        returns (uint256[] memory bps)
    {
        if (prizeDistributions[_competitionId].configured) {
            return prizeDistributions[_competitionId].rankBps;
        }
        // Default: 50/30/20
        bps = new uint256[](3);
        bps[0] = DEFAULT_FIRST_BPS;
        bps[1] = DEFAULT_SECOND_BPS;
        bps[2] = DEFAULT_THIRD_BPS;
    }

    receive() external payable {}
}
