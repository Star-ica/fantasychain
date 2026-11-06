const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

// ─── Helpers ──────────────────────────────────────────────────────────────────

const ZERO_ADDRESS = ethers.ZeroAddress;
const ONE_ETHER    = ethers.parseEther("1");
const HALF_ETHER   = ethers.parseEther("0.5");
const TEN_ETHER    = ethers.parseEther("10");

async function deployAll() {
    const [owner, organizer, oracle, user1, user2, user3, feeRecipient] =
        await ethers.getSigners();

    // Deploy CompetitionFactory
    const CompetitionFactory = await ethers.getContractFactory("CompetitionFactory");
    const factory = await CompetitionFactory.deploy(feeRecipient.address, 250); // 2.5% fee
    await factory.waitForDeployment();

    // Deploy PlayerRegistry
    const PlayerRegistry = await ethers.getContractFactory("PlayerRegistry");
    const registry = await PlayerRegistry.deploy();
    await registry.waitForDeployment();

    // Deploy TeamManager
    const TeamManager = await ethers.getContractFactory("TeamManager");
    const teamManager = await TeamManager.deploy(
        await factory.getAddress(),
        await registry.getAddress()
    );
    await teamManager.waitForDeployment();

    // Deploy ScoringManager
    const ScoringManager = await ethers.getContractFactory("ScoringManager");
    const scoringManager = await ScoringManager.deploy(
        await factory.getAddress(),
        await teamManager.getAddress()
    );
    await scoringManager.waitForDeployment();

    // Deploy PrizeEscrow
    const PrizeEscrow = await ethers.getContractFactory("PrizeEscrow");
    const prizeEscrow = await PrizeEscrow.deploy();
    await prizeEscrow.waitForDeployment();

    // Deploy ClaimManager
    const ClaimManager = await ethers.getContractFactory("ClaimManager");
    const claimManager = await ClaimManager.deploy(
        await prizeEscrow.getAddress(),
        await scoringManager.getAddress(),
        await teamManager.getAddress()
    );
    await claimManager.waitForDeployment();

    // Wire PrizeEscrow -> ClaimManager
    await prizeEscrow.setClaimManager(await claimManager.getAddress());

    // Authorize oracle
    await scoringManager.setOracle(oracle.address, true);

    return {
        factory, registry, teamManager, scoringManager, prizeEscrow, claimManager,
        owner, organizer, oracle, user1, user2, user3, feeRecipient
    };
}

// ─── CompetitionFactory Tests ─────────────────────────────────────────────────

describe("CompetitionFactory", function () {
    let ctx;
    const futureDeadline = () => Math.floor(Date.now() / 1000) + 86400 * 7; // 1 week

    beforeEach(async () => { ctx = await deployAll(); });

    it("deploys with correct initial state", async () => {
        expect(await ctx.factory.competitionCount()).to.equal(0);
        expect(await ctx.factory.platformFeeBps()).to.equal(250);
        expect(await ctx.factory.feeRecipient()).to.equal(ctx.feeRecipient.address);
    });

    it("creates a native competition", async () => {
        const tx = await ctx.factory.connect(ctx.organizer).createCompetition(
            "Champions League Fantasy",
            0, // FOOTBALL
            ethers.parseEther("0.01"),
            100,
            futureDeadline(),
            ctx.oracle.address,
            ethers.keccak256(ethers.toUtf8Bytes("{}"))
        , { value: TEN_ETHER });

        await expect(tx).to.emit(ctx.factory, "CompetitionCreated")
            .withArgs(
                1n,
                ctx.organizer.address,
                "Champions League Fantasy",
                0n,
                ethers.parseEther("0.01"),
                BigInt(futureDeadline()),
                TEN_ETHER,
                0n
            );

        const comp = await ctx.factory.getCompetition(1);
        expect(comp.id).to.equal(1);
        expect(comp.organizer).to.equal(ctx.organizer.address);
        expect(comp.prizePool).to.equal(TEN_ETHER);
        expect(comp.status).to.equal(0); // OPEN
    });

    it("reverts if deadline is in the past", async () => {
        await expect(
            ctx.factory.connect(ctx.organizer).createCompetition(
                "Bad Competition", 0,
                0, 100, 1000, // past timestamp
                ctx.oracle.address,
                ethers.keccak256(ethers.toUtf8Bytes("{}")),
                { value: ONE_ETHER }
            )
        ).to.be.revertedWithCustomError(ctx.factory, "InvalidDeadline");
    });

    it("reverts if no prize pool provided", async () => {
        await expect(
            ctx.factory.connect(ctx.organizer).createCompetition(
                "Free Comp", 0, 0, 100, futureDeadline(),
                ctx.oracle.address,
                ethers.keccak256(ethers.toUtf8Bytes("{}")),
                { value: 0 }
            )
        ).to.be.revertedWithCustomError(ctx.factory, "InvalidPrizePool");
    });

    it("allows owner to pause and unpause", async () => {
        await ctx.factory.pause();
        await expect(
            ctx.factory.connect(ctx.organizer).createCompetition(
                "Should fail", 0, 0, 100, futureDeadline(),
                ctx.oracle.address,
                ethers.keccak256(ethers.toUtf8Bytes("{}")),
                { value: ONE_ETHER }
            )
        ).to.be.revertedWithCustomError(ctx.factory, "EnforcedPause");
        await ctx.factory.unpause();
    });

    it("organizer can cancel and get refund", async () => {
        await ctx.factory.connect(ctx.organizer).createCompetition(
            "To Cancel", 0, 0, 100, futureDeadline(),
            ctx.oracle.address,
            ethers.keccak256(ethers.toUtf8Bytes("{}")),
            { value: TEN_ETHER }
        );

        const before = await ethers.provider.getBalance(ctx.organizer.address);
        const tx = await ctx.factory.connect(ctx.organizer).cancelCompetition(1);
        const receipt = await tx.wait();
        const gasCost = receipt.gasUsed * receipt.gasPrice;
        const after = await ethers.provider.getBalance(ctx.organizer.address);

        expect(after).to.be.closeTo(before + TEN_ETHER - gasCost, ethers.parseEther("0.001"));
    });

    it("only owner can set platform fee", async () => {
        await expect(
            ctx.factory.connect(ctx.user1).setPlatformFee(500)
        ).to.be.revertedWithCustomError(ctx.factory, "OwnableUnauthorizedAccount");
        await ctx.factory.setPlatformFee(500);
        expect(await ctx.factory.platformFeeBps()).to.equal(500);
    });

    it("reverts if fee > 10%", async () => {
        await expect(ctx.factory.setPlatformFee(1001)).to.be.revertedWith("Fee too high");
    });
});

// ─── PlayerRegistry Tests ─────────────────────────────────────────────────────

describe("PlayerRegistry", function () {
    let ctx;

    beforeEach(async () => { ctx = await deployAll(); });

    it("registers a single player", async () => {
        const tx = await ctx.registry.registerPlayer(
            "Lionel Messi", "Inter Miami", 3 /*FORWARD*/, 4 /*SOCCER*/
        );
        await expect(tx).to.emit(ctx.registry, "PlayerRegistered")
            .withArgs(1n, "Lionel Messi", 3n, 4n, "Inter Miami");

        const player = await ctx.registry.getPlayer(1);
        expect(player.name).to.equal("Lionel Messi");
        expect(player.status).to.equal(0); // ACTIVE
    });

    it("batch registers players", async () => {
        const names    = ["Player A", "Player B", "Player C"];
        const teams    = ["Team X", "Team X", "Team Y"];
        const positions = [0, 1, 3];
        const sports   = [4, 4, 4];

        await ctx.registry.batchRegisterPlayers(1, names, teams, positions, sports);
        expect(await ctx.registry.playerCount()).to.equal(3);

        const compPlayers = await ctx.registry.getCompetitionPlayers(1);
        expect(compPlayers.length).to.equal(3);
    });

    it("adds and removes player from competition", async () => {
        await ctx.registry.registerPlayer("Test Player", "Test FC", 0, 0);
        await ctx.registry.addPlayerToCompetition(5, 1);
        expect(await ctx.registry.isPlayerInCompetition(5, 1)).to.be.true;

        await ctx.registry.removePlayerFromCompetition(5, 1);
        expect(await ctx.registry.isPlayerInCompetition(5, 1)).to.be.false;
    });

    it("updates player status", async () => {
        await ctx.registry.registerPlayer("Injured Player", "Team Z", 2, 0);
        await ctx.registry.updatePlayerStatus(1, 1 /*INJURED*/);
        const p = await ctx.registry.getPlayer(1);
        expect(p.status).to.equal(1);
    });

    it("reverts on empty player name", async () => {
        await expect(
            ctx.registry.registerPlayer("", "Team", 0, 0)
        ).to.be.revertedWithCustomError(ctx.registry, "InvalidPlayerName");
    });

    it("only registrar can register", async () => {
        await expect(
            ctx.registry.connect(ctx.user1).registerPlayer("Test", "Team", 0, 0)
        ).to.be.revertedWithCustomError(ctx.registry, "NotRegistrar");
    });
});

// ─── TeamManager Tests ────────────────────────────────────────────────────────

describe("TeamManager", function () {
    let ctx;
    const futureDeadline = () => Math.floor(Date.now() / 1000) + 86400 * 7;

    beforeEach(async () => {
        ctx = await deployAll();

        // Create a competition
        await ctx.factory.connect(ctx.organizer).createCompetition(
            "Test Cup", 0,
            ethers.parseEther("0.01"), // 0.01 BOT entry fee
            50,
            futureDeadline(),
            ctx.oracle.address,
            ethers.keccak256(ethers.toUtf8Bytes("{}")),
            { value: TEN_ETHER }
        );

        // Register 5 players and add to competition 1
        const names     = ["Alice", "Bob", "Carol", "Dave", "Eve"];
        const teams     = Array(5).fill("Team Alpha");
        const positions = [0, 1, 2, 3, 3];
        const sports    = Array(5).fill(4);
        await ctx.registry.batchRegisterPlayers(1, names, teams, positions, sports);

        // Set competition rules: 3–5 players per team
        await ctx.teamManager.setCompetitionRules(1, 3, 5);
    });

    it("creates a team with valid players", async () => {
        const tx = await ctx.teamManager.connect(ctx.user1).createTeam(
            1, "User1 Dream Team", [1, 2, 3],
            { value: ethers.parseEther("0.01") }
        );

        await expect(tx).to.emit(ctx.teamManager, "TeamCreated");

        const team = await ctx.teamManager.getUserTeam(1, ctx.user1.address);
        expect(team.name).to.equal("User1 Dream Team");
        expect(team.playerIds.length).to.equal(3);
    });

    it("reverts on duplicate player in team", async () => {
        await expect(
            ctx.teamManager.connect(ctx.user1).createTeam(
                1, "Bad Team", [1, 1, 2],
                { value: ethers.parseEther("0.01") }
            )
        ).to.be.revertedWithCustomError(ctx.teamManager, "DuplicatePlayer");
    });

    it("reverts if already entered", async () => {
        await ctx.teamManager.connect(ctx.user1).createTeam(
            1, "First Team", [1, 2, 3],
            { value: ethers.parseEther("0.01") }
        );
        await expect(
            ctx.teamManager.connect(ctx.user1).createTeam(
                1, "Second Team", [1, 2, 4],
                { value: ethers.parseEther("0.01") }
            )
        ).to.be.revertedWithCustomError(ctx.teamManager, "AlreadyEntered");
    });

    it("reverts if entry fee insufficient", async () => {
        await expect(
            ctx.teamManager.connect(ctx.user1).createTeam(
                1, "Cheap Team", [1, 2, 3],
                { value: ethers.parseEther("0.001") }
            )
        ).to.be.revertedWithCustomError(ctx.teamManager, "InsufficientEntryFee");
    });

    it("reverts past deadline", async () => {
        // Fast forward past deadline
        await time.increase(86400 * 8);
        await expect(
            ctx.teamManager.connect(ctx.user1).createTeam(
                1, "Late Team", [1, 2, 3],
                { value: ethers.parseEther("0.01") }
            )
        ).to.be.revertedWithCustomError(ctx.teamManager, "DeadlinePassed");
    });

    it("reverts if player count violates rules", async () => {
        await expect(
            ctx.teamManager.connect(ctx.user1).createTeam(
                1, "Too Small", [1, 2],
                { value: ethers.parseEther("0.01") }
            )
        ).to.be.revertedWithCustomError(ctx.teamManager, "InvalidPlayerCount");
    });
});

// ─── ScoringManager Tests ─────────────────────────────────────────────────────

describe("ScoringManager", function () {
    let ctx, compId;
    const futureDeadline = () => Math.floor(Date.now() / 1000) + 86400 * 7;

    beforeEach(async () => {
        ctx = await deployAll();
        compId = 1;

        // Create competition
        await ctx.factory.connect(ctx.organizer).createCompetition(
            "Score Cup", 0, 0, 50, futureDeadline(),
            ctx.oracle.address,
            ethers.keccak256(ethers.toUtf8Bytes("{}")),
            { value: TEN_ETHER }
        );

        // Register 3 players
        await ctx.registry.batchRegisterPlayers(
            compId,
            ["Alpha", "Beta", "Gamma"],
            ["T1", "T1", "T2"],
            [0, 1, 2],
            [4, 4, 4]
        );

        // Rules: 1-3 players
        await ctx.teamManager.setCompetitionRules(compId, 1, 3);

        // Two users create teams
        await ctx.teamManager.connect(ctx.user1).createTeam(compId, "Alpha Squad", [1, 2]);
        await ctx.teamManager.connect(ctx.user2).createTeam(compId, "Gamma Force", [2, 3]);
    });

    it("oracle submits match result and updates team scores", async () => {
        const dataHash = ethers.keccak256(ethers.toUtf8Bytes('{"match":1}'));
        await ctx.scoringManager.connect(ctx.oracle).submitMatchResult(
            compId, dataHash,
            [1, 2, 3],
            [10, 20, 30]
        );

        // Team 1 has players 1 (10) + 2 (20) = 30
        const team1Id = await ctx.teamManager.userTeam(compId, ctx.user1.address);
        const score1 = await ctx.scoringManager.getTeamScore(team1Id);
        expect(score1.totalScore).to.equal(30);

        // Team 2 has players 2 (20) + 3 (30) = 50
        const team2Id = await ctx.teamManager.userTeam(compId, ctx.user2.address);
        const score2 = await ctx.scoringManager.getTeamScore(team2Id);
        expect(score2.totalScore).to.equal(50);
    });

    it("finalizes competition after dispute window", async () => {
        const dataHash = ethers.keccak256(ethers.toUtf8Bytes("{}"));
        await ctx.scoringManager.connect(ctx.oracle).submitMatchResult(
            compId, dataHash, [1, 2, 3], [10, 20, 30]
        );

        // Fast forward past 48h dispute window
        await time.increase(48 * 3600 + 1);

        await ctx.scoringManager.finalizeCompetition(compId);

        const rankings = await ctx.scoringManager.getCompetitionRankings(compId);
        // Team 2 (score 50) should be ranked 1st, Team 1 (score 30) 2nd
        const team2Id = await ctx.teamManager.userTeam(compId, ctx.user2.address);
        expect(rankings[0]).to.equal(team2Id);
    });

    it("reverts finalization before dispute window", async () => {
        const dataHash = ethers.keccak256(ethers.toUtf8Bytes("{}"));
        await ctx.scoringManager.connect(ctx.oracle).submitMatchResult(
            compId, dataHash, [1, 2, 3], [10, 20, 30]
        );
        await expect(
            ctx.scoringManager.finalizeCompetition(compId)
        ).to.be.revertedWithCustomError(ctx.scoringManager, "DisputeWindowOpen");
    });

    it("non-oracle cannot submit results", async () => {
        await expect(
            ctx.scoringManager.connect(ctx.user1).submitMatchResult(
                compId, ethers.ZeroHash, [1], [10]
            )
        ).to.be.revertedWithCustomError(ctx.scoringManager, "NotOracle");
    });

    it("admin can correct match results", async () => {
        const dh = ethers.keccak256(ethers.toUtf8Bytes("{}"));
        await ctx.scoringManager.connect(ctx.oracle).submitMatchResult(
            compId, dh, [1, 2, 3], [10, 20, 30]
        );
        const newDh = ethers.keccak256(ethers.toUtf8Bytes('{"corrected":true}'));
        await ctx.scoringManager.correctMatchResult(1, newDh, [1, 2, 3], [5, 5, 5]);

        const team1Id = await ctx.teamManager.userTeam(compId, ctx.user1.address);
        const score = await ctx.scoringManager.getTeamScore(team1Id);
        expect(score.totalScore).to.equal(10); // 5+5
    });
});

// ─── PrizeEscrow Tests ────────────────────────────────────────────────────────

describe("PrizeEscrow", function () {
    let ctx;

    beforeEach(async () => { ctx = await deployAll(); });

    it("creates a native escrow", async () => {
        await ctx.prizeEscrow.connect(ctx.organizer).createNativeEscrow(
            42, ctx.organizer.address, { value: TEN_ETHER }
        );
        expect(await ctx.prizeEscrow.getBalance(42)).to.equal(TEN_ETHER);
    });

    it("emergency withdraw returns funds to organizer", async () => {
        await ctx.prizeEscrow.connect(ctx.organizer).createNativeEscrow(
            43, ctx.organizer.address, { value: TEN_ETHER }
        );
        const before = await ethers.provider.getBalance(ctx.organizer.address);
        const tx = await ctx.prizeEscrow.connect(ctx.organizer).emergencyWithdraw(43);
        const receipt = await tx.wait();
        const gasCost = receipt.gasUsed * receipt.gasPrice;
        const after = await ethers.provider.getBalance(ctx.organizer.address);
        expect(after).to.be.closeTo(before + TEN_ETHER - gasCost, ethers.parseEther("0.001"));
    });

    it("only claim manager can release funds", async () => {
        await ctx.prizeEscrow.connect(ctx.organizer).createNativeEscrow(
            44, ctx.organizer.address, { value: TEN_ETHER }
        );
        await expect(
            ctx.prizeEscrow.connect(ctx.user1).releaseFunds(44)
        ).to.be.revertedWithCustomError(ctx.prizeEscrow, "NotClaimManager");
    });

    it("reverts on duplicate escrow", async () => {
        await ctx.prizeEscrow.createNativeEscrow(50, ctx.owner.address, { value: ONE_ETHER });
        await expect(
            ctx.prizeEscrow.createNativeEscrow(50, ctx.owner.address, { value: ONE_ETHER })
        ).to.be.revertedWithCustomError(ctx.prizeEscrow, "EscrowAlreadyExists");
    });
});

// ─── ClaimManager Tests ───────────────────────────────────────────────────────

describe("ClaimManager", function () {
    let ctx, compId;
    const futureDeadline = () => Math.floor(Date.now() / 1000) + 86400 * 7;

    beforeEach(async () => {
        ctx = await deployAll();
        compId = 1;

        // Setup full pipeline
        await ctx.factory.connect(ctx.organizer).createCompetition(
            "Prize Cup", 0, 0, 50, futureDeadline(),
            ctx.oracle.address,
            ethers.keccak256(ethers.toUtf8Bytes("{}")),
            { value: TEN_ETHER }
        );

        // Create escrow
        await ctx.prizeEscrow.connect(ctx.organizer).createNativeEscrow(
            compId, ctx.organizer.address, { value: TEN_ETHER }
        );

        // Register players
        await ctx.registry.batchRegisterPlayers(
            compId, ["P1","P2","P3"],
            ["T1","T1","T2"],
            [0,1,2], [4,4,4]
        );
        await ctx.teamManager.setCompetitionRules(compId, 1, 3);

        // User1 and User2 enter teams
        await ctx.teamManager.connect(ctx.user1).createTeam(compId, "Team1", [1, 2]);
        await ctx.teamManager.connect(ctx.user2).createTeam(compId, "Team2", [2, 3]);

        // Submit scores: user2 wins (score 50 > 30)
        const dh = ethers.keccak256(ethers.toUtf8Bytes("{}"));
        await ctx.scoringManager.connect(ctx.oracle).submitMatchResult(
            compId, dh, [1, 2, 3], [10, 20, 30]
        );

        // Advance past dispute window
        await time.increase(48 * 3600 + 1);

        // Finalize
        await ctx.scoringManager.finalizeCompetition(compId);
    });

    it("pulls funds from escrow", async () => {
        await ctx.claimManager.pullFromEscrow(compId, ZERO_ADDRESS);
        const pool = await ctx.claimManager.getPrizePool(compId);
        expect(pool.funded).to.be.true;
        expect(pool.totalAmount).to.equal(TEN_ETHER);
    });

    it("1st place winner claims prize", async () => {
        await ctx.claimManager.pullFromEscrow(compId, ZERO_ADDRESS);

        const before = await ethers.provider.getBalance(ctx.user2.address);
        const tx = await ctx.claimManager.connect(ctx.user2).claimPrize(compId);
        const receipt = await tx.wait();
        const gasCost = receipt.gasUsed * receipt.gasPrice;
        const after = await ethers.provider.getBalance(ctx.user2.address);

        // 1st place = 50% of 10 ETH = 5 ETH
        const expected = ethers.parseEther("5");
        expect(after).to.be.closeTo(before + expected - gasCost, ethers.parseEther("0.01"));
    });

    it("2nd place winner claims prize", async () => {
        await ctx.claimManager.pullFromEscrow(compId, ZERO_ADDRESS);

        await ctx.claimManager.connect(ctx.user2).claimPrize(compId); // 1st place
        const before = await ethers.provider.getBalance(ctx.user1.address);
        const tx = await ctx.claimManager.connect(ctx.user1).claimPrize(compId); // 2nd place
        const receipt = await tx.wait();
        const gasCost = receipt.gasUsed * receipt.gasPrice;
        const after = await ethers.provider.getBalance(ctx.user1.address);

        // 2nd place = 30% of 10 ETH = 3 ETH
        const expected = ethers.parseEther("3");
        expect(after).to.be.closeTo(before + expected - gasCost, ethers.parseEther("0.01"));
    });

    it("reverts on double claim", async () => {
        await ctx.claimManager.pullFromEscrow(compId, ZERO_ADDRESS);
        await ctx.claimManager.connect(ctx.user2).claimPrize(compId);
        await expect(
            ctx.claimManager.connect(ctx.user2).claimPrize(compId)
        ).to.be.revertedWithCustomError(ctx.claimManager, "AlreadyClaimed");
    });

    it("non-winner cannot claim", async () => {
        await ctx.claimManager.pullFromEscrow(compId, ZERO_ADDRESS);
        await expect(
            ctx.claimManager.connect(ctx.user3).claimPrize(compId)
        ).to.be.revertedWithCustomError(ctx.claimManager, "NoTeamInCompetition");
    });

    it("custom prize distribution works", async () => {
        // Create new competition with custom split: 70/30
        await ctx.factory.connect(ctx.organizer).createCompetition(
            "Custom Split Cup", 0, 0, 50, futureDeadline(),
            ctx.oracle.address,
            ethers.keccak256(ethers.toUtf8Bytes("{}")),
            { value: TEN_ETHER }
        );

        await ctx.claimManager.setPrizeDistribution(2, [7000, 3000]);
        const dist = await ctx.claimManager.prizeDistributions(2);
        expect(dist.configured).to.be.true;
    });
});

// ─── Integration Test: Full End-to-End ────────────────────────────────────────

describe("Full E2E Flow", function () {
    it("runs a complete competition lifecycle", async () => {
        const ctx = await deployAll();
        const deadline = Math.floor(Date.now() / 1000) + 86400 * 3;

        // 1. Organizer creates competition
        await ctx.factory.connect(ctx.organizer).createCompetition(
            "E2E Cup", 1 /*BASKETBALL*/,
            ethers.parseEther("0.005"),
            10, deadline,
            ctx.oracle.address,
            ethers.keccak256(ethers.toUtf8Bytes('{"sport":"basketball","playerLimit":5}')),
            { value: ethers.parseEther("5") }
        );

        // 2. Admin registers player pool
        await ctx.registry.batchRegisterPlayers(
            1,
            ["LeBron James", "Stephen Curry", "Kevin Durant", "Giannis A.", "Luka Doncic"],
            ["Lakers", "Warriors", "Suns", "Bucks", "Mavs"],
            [14, 11, 12, 13, 10], // CENTER, SHOOTING_GUARD, SMALL_FORWARD, POWER_FORWARD, POINT_GUARD
            [1, 1, 1, 1, 1] // BASKETBALL
        );

        // 3. Set team rules
        await ctx.teamManager.setCompetitionRules(1, 3, 5);

        // 4. Users create teams
        await ctx.teamManager.connect(ctx.user1).createTeam(
            1, "LeBron Gang", [1, 2, 3],
            { value: ethers.parseEther("0.005") }
        );
        await ctx.teamManager.connect(ctx.user2).createTeam(
            1, "Luka Nation", [3, 4, 5],
            { value: ethers.parseEther("0.005") }
        );
        await ctx.teamManager.connect(ctx.user3).createTeam(
            1, "Steph Army", [1, 4, 5],
            { value: ethers.parseEther("0.005") }
        );

        // 5. Create escrow
        await ctx.prizeEscrow.connect(ctx.organizer).createNativeEscrow(
            1, ctx.organizer.address, { value: ethers.parseEther("5") }
        );

        // 6. Oracle submits results (Luka Nation wins)
        await ctx.scoringManager.connect(ctx.oracle).submitMatchResult(
            1,
            ethers.keccak256(ethers.toUtf8Bytes('{"game":"nba_finals"}')),
            [1, 2, 3, 4, 5],
            [25, 30, 20, 40, 45]
        );

        // 7. Advance past dispute window
        await time.increase(48 * 3600 + 1);

        // 8. Finalize competition
        await ctx.scoringManager.finalizeCompetition(1);

        const rankings = await ctx.scoringManager.getCompetitionRankings(1);
        expect(rankings.length).to.equal(3);

        // Verify rankings: user2 (score 20+40+45=105), user3 (25+40+45=110), user1 (25+30+20=75)
        // user3 should be 1st: 110, user2 2nd: 105, user1 3rd: 75
        const user3TeamId = await ctx.teamManager.userTeam(1, ctx.user3.address);
        expect(rankings[0]).to.equal(user3TeamId);

        // 9. Pull escrow funds
        await ctx.claimManager.pullFromEscrow(1, ethers.ZeroAddress);

        // 10. Winners claim prizes
        await ctx.claimManager.connect(ctx.user3).claimPrize(1); // 1st: 50%
        await ctx.claimManager.connect(ctx.user2).claimPrize(1); // 2nd: 30%
        await ctx.claimManager.connect(ctx.user1).claimPrize(1); // 3rd: 20%

        const pool = await ctx.claimManager.getPrizePool(1);
        expect(pool.claimedAmount).to.equal(pool.totalAmount);
    });
});
