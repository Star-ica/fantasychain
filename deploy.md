# FantasyChain Deployment Guide

Step-by-step instructions for deploying the FantasyChain protocol to BOT Chain (chain ID 677).

---

## Prerequisites

Before starting, ensure the following are installed and configured:

**Node.js & Package Manager**
- Node.js v18 or later (`node --version`)
- npm v9+ or yarn v1.22+

**Hardhat**
- Installed locally as a dev dependency (see Install Dependencies below)
- Familiarity with Hardhat tasks and the `npx hardhat` CLI

**MetaMask (for manual verification / frontend testing)**
- MetaMask browser extension installed
- BOT Chain added as a custom network:
  - Network Name: BOT Chain
  - RPC URL: https://rpc.botchain.tg
  - Chain ID: 677
  - Currency Symbol: BOT
- Deployer wallet funded with BOT for gas

**Environment**
- A `.env` file at the project root (never commit this file)
- `DEPLOYER_PRIVATE_KEY` — private key of your deployer wallet (no `0x` prefix)
- `FEE_RECIPIENT` — address that receives platform fees
- `ORACLE_ADDRESS` — address of the authorized oracle wallet
- `BOTCHAIN_RPC_URL` — `https://rpc.botchain.tg` (or override for testnet)
- `BOTCHAIN_EXPLORER_API_KEY` — API key for the BOT Chain block explorer (if supported)

---

## Install Dependencies

From the project root:

```bash
npm init -y   # skip if package.json already exists

# Hardhat and tooling
npm install --save-dev hardhat @nomicfoundation/hardhat-toolbox

# OpenZeppelin Contracts (required by all six contracts)
npm install @openzeppelin/contracts

# Ethers.js v6 (bundled with hardhat-toolbox; listed here for clarity)
# npm install ethers   # already included via hardhat-toolbox
```

Confirm your `package.json` devDependencies include at minimum:
- `hardhat`
- `@nomicfoundation/hardhat-toolbox`
- `@openzeppelin/contracts` (as a regular dependency, not devDependency)

---

## Project Structure

```
fantasychain/
  contracts/
    PlayerRegistry.sol
    CompetitionFactory.sol
    TeamManager.sol
    ScoringManager.sol
    PrizeEscrow.sol
    ClaimManager.sol
  scripts/
    deploy.js
  test/
    fantasychain.test.js
  hardhat.config.js
  .env
```

---

## Hardhat Configuration

Create `hardhat.config.js` in the project root:

```js
require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

const { DEPLOYER_PRIVATE_KEY, BOTCHAIN_RPC_URL, BOTCHAIN_EXPLORER_API_KEY } = process.env;

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    botchain: {
      url: BOTCHAIN_RPC_URL || "https://rpc.botchain.tg",
      chainId: 677,
      accounts: DEPLOYER_PRIVATE_KEY ? [`0x${DEPLOYER_PRIVATE_KEY}`] : [],
    },
    localhost: {
      url: "http://127.0.0.1:8545",
    },
  },
  etherscan: {
    apiKey: {
      botchain: BOTCHAIN_EXPLORER_API_KEY || "placeholder",
    },
    customChains: [
      {
        network: "botchain",
        chainId: 677,
        urls: {
          apiURL: "https://explorer.botchain.tg/api",   // update if explorer URL differs
          browserURL: "https://explorer.botchain.tg",
        },
      },
    ],
  },
};
```

---

## Compile Contracts

```bash
npx hardhat compile
```

Expected output: `Compiled N Solidity files successfully`. Artifacts appear in `artifacts/` and type bindings in `typechain-types/` (if enabled).

If you see import errors for `@openzeppelin/contracts`, confirm OpenZeppelin is installed:

```bash
ls node_modules/@openzeppelin/contracts/access/Ownable.sol
```

---

## Deploy Order & Constructor Arguments

Contracts must be deployed in the following order because later contracts depend on earlier addresses.

### 1. PlayerRegistry

No constructor arguments.

```js
const PlayerRegistry = await ethers.getContractFactory("PlayerRegistry");
const registry = await PlayerRegistry.deploy();
await registry.waitForDeployment();
console.log("PlayerRegistry:", await registry.getAddress());
```

### 2. CompetitionFactory

Constructor: `(address _feeRecipient, uint256 _platformFeeBps)`

- `_feeRecipient` — wallet address that receives the 2.5% platform cut
- `_platformFeeBps` — fee in basis points; `250` = 2.5% (maximum allowed: `1000` = 10%)

```js
const CompetitionFactory = await ethers.getContractFactory("CompetitionFactory");
const factory = await CompetitionFactory.deploy(
  process.env.FEE_RECIPIENT,
  250  // 2.5% platform fee
);
await factory.waitForDeployment();
console.log("CompetitionFactory:", await factory.getAddress());
```

### 3. TeamManager

Constructor: `(address _competitionFactory, address _playerRegistry)`

```js
const TeamManager = await ethers.getContractFactory("TeamManager");
const teamManager = await TeamManager.deploy(
  await factory.getAddress(),
  await registry.getAddress()
);
await teamManager.waitForDeployment();
console.log("TeamManager:", await teamManager.getAddress());
```

### 4. ScoringManager

Constructor: `(address _competitionFactory, address _teamManager)`

```js
const ScoringManager = await ethers.getContractFactory("ScoringManager");
const scoringManager = await ScoringManager.deploy(
  await factory.getAddress(),
  await teamManager.getAddress()
);
await scoringManager.waitForDeployment();
console.log("ScoringManager:", await scoringManager.getAddress());
```

### 5. PrizeEscrow

Constructor: `(address _competitionFactory, address _scoringManager)`

```js
const PrizeEscrow = await ethers.getContractFactory("PrizeEscrow");
const prizeEscrow = await PrizeEscrow.deploy(
  await factory.getAddress(),
  await scoringManager.getAddress()
);
await prizeEscrow.waitForDeployment();
console.log("PrizeEscrow:", await prizeEscrow.getAddress());
```

### 6. ClaimManager

Constructor: `(address _prizeEscrow, address _competitionFactory)`

```js
const ClaimManager = await ethers.getContractFactory("ClaimManager");
const claimManager = await ClaimManager.deploy(
  await prizeEscrow.getAddress(),
  await factory.getAddress()
);
await claimManager.waitForDeployment();
console.log("ClaimManager:", await claimManager.getAddress());
```

---

## Full Deploy Script

Create `scripts/deploy.js`:

```js
const { ethers } = require("hardhat");
require("dotenv").config();

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with account:", deployer.address);
  console.log("Account balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "BOT");

  // 1. PlayerRegistry
  console.log("\n[1/6] Deploying PlayerRegistry...");
  const PlayerRegistry = await ethers.getContractFactory("PlayerRegistry");
  const registry = await PlayerRegistry.deploy();
  await registry.waitForDeployment();
  const registryAddr = await registry.getAddress();
  console.log("    PlayerRegistry deployed to:", registryAddr);

  // 2. CompetitionFactory
  console.log("\n[2/6] Deploying CompetitionFactory...");
  const CompetitionFactory = await ethers.getContractFactory("CompetitionFactory");
  const factory = await CompetitionFactory.deploy(
    process.env.FEE_RECIPIENT,
    250
  );
  await factory.waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log("    CompetitionFactory deployed to:", factoryAddr);

  // 3. TeamManager
  console.log("\n[3/6] Deploying TeamManager...");
  const TeamManager = await ethers.getContractFactory("TeamManager");
  const teamManager = await TeamManager.deploy(factoryAddr, registryAddr);
  await teamManager.waitForDeployment();
  const teamManagerAddr = await teamManager.getAddress();
  console.log("    TeamManager deployed to:", teamManagerAddr);

  // 4. ScoringManager
  console.log("\n[4/6] Deploying ScoringManager...");
  const ScoringManager = await ethers.getContractFactory("ScoringManager");
  const scoringManager = await ScoringManager.deploy(factoryAddr, teamManagerAddr);
  await scoringManager.waitForDeployment();
  const scoringManagerAddr = await scoringManager.getAddress();
  console.log("    ScoringManager deployed to:", scoringManagerAddr);

  // 5. PrizeEscrow
  console.log("\n[5/6] Deploying PrizeEscrow...");
  const PrizeEscrow = await ethers.getContractFactory("PrizeEscrow");
  const prizeEscrow = await PrizeEscrow.deploy(factoryAddr, scoringManagerAddr);
  await prizeEscrow.waitForDeployment();
  const prizeEscrowAddr = await prizeEscrow.getAddress();
  console.log("    PrizeEscrow deployed to:", prizeEscrowAddr);

  // 6. ClaimManager
  console.log("\n[6/6] Deploying ClaimManager...");
  const ClaimManager = await ethers.getContractFactory("ClaimManager");
  const claimManager = await ClaimManager.deploy(prizeEscrowAddr, factoryAddr);
  await claimManager.waitForDeployment();
  const claimManagerAddr = await claimManager.getAddress();
  console.log("    ClaimManager deployed to:", claimManagerAddr);

  // Post-deployment: authorize oracle in CompetitionFactory
  if (process.env.ORACLE_ADDRESS) {
    console.log("\nAuthorizing oracle:", process.env.ORACLE_ADDRESS);
    await factory.setOracleAuthorization(process.env.ORACLE_ADDRESS, true);
    console.log("    Oracle authorized.");
  }

  console.log("\n=== Deployment Complete ===");
  console.log("PlayerRegistry:    ", registryAddr);
  console.log("CompetitionFactory:", factoryAddr);
  console.log("TeamManager:       ", teamManagerAddr);
  console.log("ScoringManager:    ", scoringManagerAddr);
  console.log("PrizeEscrow:       ", prizeEscrowAddr);
  console.log("ClaimManager:      ", claimManagerAddr);

  // Write addresses to a JSON file for the frontend
  const fs = require("fs");
  const addresses = {
    network: "botchain",
    chainId: 677,
    deployedAt: new Date().toISOString(),
    contracts: {
      PlayerRegistry: registryAddr,
      CompetitionFactory: factoryAddr,
      TeamManager: teamManagerAddr,
      ScoringManager: scoringManagerAddr,
      PrizeEscrow: prizeEscrowAddr,
      ClaimManager: claimManagerAddr,
    },
  };
  fs.writeFileSync("deployed-addresses.json", JSON.stringify(addresses, null, 2));
  console.log("\nAddresses saved to deployed-addresses.json");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
```

Run the deploy:

```bash
npx hardhat run scripts/deploy.js --network botchain
```

---

## Verify on Explorer

After deployment, verify each contract on the BOT Chain explorer so users can read source code and interact directly.

```bash
# PlayerRegistry (no constructor args)
npx hardhat verify --network botchain <PLAYER_REGISTRY_ADDRESS>

# CompetitionFactory
npx hardhat verify --network botchain <COMPETITION_FACTORY_ADDRESS> \
  "<FEE_RECIPIENT_ADDRESS>" "250"

# TeamManager
npx hardhat verify --network botchain <TEAM_MANAGER_ADDRESS> \
  "<COMPETITION_FACTORY_ADDRESS>" "<PLAYER_REGISTRY_ADDRESS>"

# ScoringManager
npx hardhat verify --network botchain <SCORING_MANAGER_ADDRESS> \
  "<COMPETITION_FACTORY_ADDRESS>" "<TEAM_MANAGER_ADDRESS>"

# PrizeEscrow
npx hardhat verify --network botchain <PRIZE_ESCROW_ADDRESS> \
  "<COMPETITION_FACTORY_ADDRESS>" "<SCORING_MANAGER_ADDRESS>"

# ClaimManager
npx hardhat verify --network botchain <CLAIM_MANAGER_ADDRESS> \
  "<PRIZE_ESCROW_ADDRESS>" "<COMPETITION_FACTORY_ADDRESS>"
```

Replace each `<...>` placeholder with the actual deployed address from the previous step.

If the BOT Chain explorer does not support the Etherscan verification API, manually submit the flattened source via the explorer's web UI:

```bash
npx hardhat flatten contracts/PlayerRegistry.sol > flat/PlayerRegistry_flat.sol
# repeat for each contract
```

---

## Update Frontend Config

After deployment, update the contract addresses in `index.html`. Locate the `CONFIG` block near the top of the file and replace each address:

```js
const CONFIG = {
  chainId: 677,
  rpc: "https://rpc.botchain.tg",
  contracts: {
    PlayerRegistry:    "0x<PLAYER_REGISTRY_ADDRESS>",
    CompetitionFactory:"0x<COMPETITION_FACTORY_ADDRESS>",
    TeamManager:       "0x<TEAM_MANAGER_ADDRESS>",
    ScoringManager:    "0x<SCORING_MANAGER_ADDRESS>",
    PrizeEscrow:       "0x<PRIZE_ESCROW_ADDRESS>",
    ClaimManager:      "0x<CLAIM_MANAGER_ADDRESS>",
  },
};
```

The values are also saved to `deployed-addresses.json` by the deploy script for reference.

---

## Post-Deployment Checklist

Work through these items after all contracts are live and the frontend is updated.

**Contract Configuration**
- [ ] Oracle address authorized in CompetitionFactory (`setOracleAuthorization`)
- [ ] Platform fee and fee recipient set correctly (`platformFeeBps`, `feeRecipient`)
- [ ] Registrar wallet authorized in PlayerRegistry (`setRegistrar`) if using a separate hot wallet for player data
- [ ] CompetitionFactory address in TeamManager matches deployed address
- [ ] PlayerRegistry address in TeamManager matches deployed address
- [ ] All six contracts are verified on the BOT Chain explorer

**Smoke Tests**
- [ ] Register one test player via PlayerRegistry
- [ ] Create a test competition via CompetitionFactory (small native prize pool)
- [ ] Submit a test team via TeamManager
- [ ] Submit mock scores via ScoringManager as oracle
- [ ] Verify prize distribution via PrizeEscrow
- [ ] Claim prize via ClaimManager and confirm balance received

**Security & Operations**
- [ ] Deployer wallet private key removed from any CI/CD environment variables after deploy
- [ ] Contracts pausable via `pause()` on each contract (test pause/unpause flow)
- [ ] `.env` file excluded from version control (`.gitignore` entry confirmed)
- [ ] Multisig or cold wallet set as `owner` on all contracts via `transferOwnership()` if production
- [ ] `deployed-addresses.json` committed to repo for team reference
- [ ] Oracle hot wallet funded with enough BOT for ongoing gas costs
- [ ] Block explorer links shared with team for each deployed contract

---

## Troubleshooting

**"nonce too high" or "replacement transaction underpriced"**
Reset the deployer account nonce in MetaMask, or pass `--reset` to the network config.

**"insufficient funds for gas"**
Top up the deployer wallet with BOT via the BOT Chain faucet or bridge.

**Verification fails with "contract already verified"**
The contract is already verified; no action needed.

**Verification fails with "bytecode not found"**
Wait 30–60 seconds after deployment for the explorer to index the transaction, then retry.

**"USDT transfer failed" on createCompetitionUSDT**
Ensure the caller has called `approve(CompetitionFactoryAddress, amount)` on the USDT contract before calling `createCompetitionUSDT`.
