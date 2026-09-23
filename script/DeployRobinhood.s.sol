// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {Dispute} from "../src/Dispute.sol";
import {NanoLedger} from "../src/nanopay/NanoLedger.sol";
import {MarketsPerennial} from "../src/nanopay/MarketsPerennial.sol";
import {BuilderRegistry} from "../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../src/perennial/CaretakerRegistry.sol";
import {ProgressPool} from "../src/perennial/ProgressPool.sol";
import {ProgressArbiter} from "../src/perennial/ProgressArbiter.sol";

/// @notice Minimal mint-able 6-decimals USDC for FRESH self-contained deploys
/// (testnet + local simulation). On mainnet this is replaced by the real
/// Robinhood Chain USDC/stablecoin address — see ROBINHOOD-DEPLOY.md.
contract MockUSDCRobinhood is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title DeployRobinhood
/// @notice ONE-RUN, self-contained deploy of the PUBLIC Otus builder-funding
/// market on Robinhood Chain (a public port of the Arc perennial stack).
///
/// Public posture: there is NO privacy layer (the Arc EVM contracts are public
/// by design) and the short side is public for now. Everything lives on-chain;
/// value settles as NanoLedger internal balance so a sub-cent fee and a large
/// payout both cost ~one storage write.
///
/// The full funding loop stood up here:
///   attention (markets) -> commons (ProgressPool) -> verified progress
///   (ProgressArbiter propose/finalize) -> weight-proportional claim -> stream
///   -> builder wallet. Attention FILLS the commons; only VERIFIED PROGRESS
///   draws it, so the crowd's betting can never capture the builder's funding.
///
/// run()'s vm.startBroadcast()/stopBroadcast() block is BROADCAST-SAFE: it does
/// ONLY deterministic, time-independent work — deploys fresh (admin = msg.sender),
/// wires every role, funds the commons, and registers ONE demo builder (a
/// deterministic id counter). It contains NO timestamp-derived and NO time-gated
/// call, so the recorded tx set replays identically on-chain.
///
/// TWO classes of work are therefore kept OUT of the broadcast, in a sim-only
/// path guarded by `block.chainid == 31337` and driven under vm.startPrank (NOT
/// vm.startBroadcast), so neither can ever be recorded as a broadcast tx:
///
///  1. TIMESTAMP-DERIVED — the demo feed/agent/market + the exercising buy().
///     Registry.createFeed derives feedId = keccak256(msg.sender, desc,
///     block.timestamp). Under --broadcast forge bakes the feedId it computes
///     during its collection run into the recorded registerAgent / createMarket
///     calldata; the on-chain replay creates the feed at a DIFFERENT timestamp,
///     so the baked id does not exist -> FeedMissing, cascading to
///     AgentNotRegistered and MarketMissing. Running it under a prank keeps it
///     off the recorded tx set entirely.
///
///  2. TIME-GATED — the propose -> finalize -> closeEpoch -> claim -> settle
///     progress loop depends on THREE vm.warp() calls (past CHALLENGE_WINDOW,
///     EPOCH_LENGTH, STREAM_WINDOW). vm.warp is a simulation-only cheatcode and
///     does NOT advance block.timestamp on a live chain, so that loop can never
///     complete inside a single real broadcast.
///
/// Both live in simulateDemo(), which run() only invokes on the local in-memory
/// EVM. On a real testnet the demo market is driven later as a separate tx, and
/// the loop steps later still, once real time has actually elapsed.
contract DeployRobinhood is Script {
    uint256 constant ROBINHOOD_MAINNET = 4663;
    uint256 constant ROBINHOOD_TESTNET = 46630;
    address constant ROBINHOOD_MAINNET_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    // ── demo/market parameters (safe testnet values) ──
    uint256 constant MIN_BOND = 10e6; // Registry floor (10 USDC, 6 decimals)
    uint256 constant FEED_DISPUTE_WINDOW = 1 hours; // Registry MIN_DISPUTE_WINDOW
    uint256 constant EPOCH_LENGTH = 7 days; // ProgressPool salary cadence unit
    uint256 constant STREAM_WINDOW = 1 days; // payout vesting window (seconds)
    uint256 constant CHALLENGE_WINDOW = 1 hours; // ProgressArbiter challenge window
    uint256 constant STAKE_PER_PROPOSAL = 50e6; // caretaker bond locked per proposal
    uint256 constant MAX_WEIGHT_PER_PROPOSAL = 10; // one scored release artifact
    uint256 constant COMMONS_SEED = 100_000e6; // USDC seeded into the commons
    uint256 constant DEPLOYER_LEDGER = 500_000e6; // USDC the deployer parks on the ledger
    uint256 constant MARKET_LIQUIDITY = 10e6; // demo market seed liquidity
    uint256 constant BUY_COLLATERAL = 1_000e6; // demo buy() size (exercises fee leg)
    uint256 constant DEMO_WEIGHT = 10; // one release, capped by the arbiter

    // ── deployed addresses (return + log) ──
    MockUSDCRobinhood public usdc;
    IERC20 public settlementToken;
    NanoLedger public ledger;
    Registry public registry;
    Attestation public attestation;
    Dispute public dispute;
    BuilderRegistry public builders;
    CaretakerRegistry public caretakers;
    ProgressPool public pool;
    ProgressArbiter public arbiter;
    MarketsPerennial public markets;

    // ── demo ids ──
    uint256 public demoBuilderId;
    bytes32 public demoFeedId;
    bytes32 public demoMarketId;
    uint256 internal _commonsSeed;
    uint256 internal _deployerLedger;

    function run() external {
        address deployer = msg.sender;
        address operator;
        address resolver;

        if (block.chainid == 31337) {
            operator = deployer;
            resolver = address(0xBEEF);
            _commonsSeed = COMMONS_SEED;
            _deployerLedger = DEPLOYER_LEDGER;
        } else {
            require(block.chainid == ROBINHOOD_TESTNET || block.chainid == ROBINHOOD_MAINNET, "unsupported chain");
            operator = vm.envAddress("OPERATOR_ADDRESS");
            resolver = vm.envAddress("RESOLVER_ADDRESS");
            require(operator != address(0) && resolver != address(0), "operator/resolver required");
            require(operator != resolver && resolver != deployer, "resolver must be independent");
            if (block.chainid == ROBINHOOD_MAINNET) {
                // No production defaults: the operator must consciously size
                // real USDG exposure for this deployment.
                _commonsSeed = vm.envUint("COMMONS_SEED");
                _deployerLedger = vm.envUint("DEPLOYER_LEDGER");
                require(_commonsSeed > 0 && _deployerLedger > 0, "mainnet funding required");
            } else {
                _commonsSeed = vm.envOr("COMMONS_SEED", COMMONS_SEED);
                _deployerLedger = vm.envOr("DEPLOYER_LEDGER", DEPLOYER_LEDGER);
            }
        }

        vm.startBroadcast();

        // ─────────────────────── 1. token + oracle protocol ───────────────────────
        if (block.chainid == ROBINHOOD_MAINNET) {
            require(ROBINHOOD_MAINNET_USDG.code.length > 0, "canonical USDG missing");
            settlementToken = IERC20(ROBINHOOD_MAINNET_USDG);
        } else {
            usdc = new MockUSDCRobinhood();
            settlementToken = IERC20(address(usdc));
        }
        registry = new Registry(settlementToken);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, settlementToken);
        // one-shot deployer-only wiring (Arc reference sequence)
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));

        // ─────────────────────── 2. settlement + perennial spine ──────────────────
        ledger = new NanoLedger(settlementToken, deployer);
        builders = new BuilderRegistry(deployer);
        caretakers = new CaretakerRegistry(builders, deployer);
        pool = new ProgressPool(ledger, builders, caretakers, deployer, EPOCH_LENGTH, STREAM_WINDOW);
        arbiter = new ProgressArbiter(
            ledger, pool, builders, caretakers, deployer, CHALLENGE_WINDOW, STAKE_PER_PROPOSAL, MAX_WEIGHT_PER_PROPOSAL
        );

        // markets route the treasury (commons) fee leg to the ProgressPool
        markets = new MarketsPerennial(ledger, registry, attestation, builders, deployer, address(pool));

        // ─────────────────────── 3. role grants + wiring ──────────────────────────
        // arbiter is the ONLY writer of progress into the pool
        pool.grantRole(pool.PROGRESS_ROLE(), address(arbiter));
        // The assigned caretaker proposes; an independent resolver adjudicates.
        arbiter.grantRole(arbiter.PROPOSER_ROLE(), operator);
        arbiter.grantRole(arbiter.RESOLVER_ROLE(), resolver);
        require(!pool.hasRole(pool.PROGRESS_ROLE(), deployer), "deployer progress bypass");
        // pool whitelisted as a ledger source (recon reference; harmless for stream payouts)
        ledger.setSource(address(pool), true);
        // markets can create/credit ledger pools if ever needed (fee legs are direct transfers)
        ledger.setSource(address(markets), true);

        // ─────────────────────── 4. fund the deployer's ledger balance ────────────
        // Mint real (mock) USDC to the deployer and park a working balance on the
        // ledger so we can seed the commons, provide market liquidity, and (in
        // sim) fund the arbiter bond.
        // mint enough to cover the ledger balance, the commons seed, and the
        // agent bond (which the Registry pulls as real USDC, not ledger balance).
        uint256 requiredBalance = _deployerLedger + _commonsSeed + MIN_BOND;
        if (address(usdc) != address(0)) {
            usdc.mint(deployer, requiredBalance);
        } else {
            require(settlementToken.balanceOf(deployer) >= requiredBalance, "insufficient canonical USDG");
        }
        settlementToken.approve(address(ledger), type(uint256).max);
        settlementToken.approve(address(registry), type(uint256).max); // for the agent bond
        ledger.deposit(_deployerLedger);
        // let the markets contract pull the deployer's ledger balance (createMarket/buy)
        ledger.approveSpender(address(markets), type(uint256).max);
        // let the arbiter pull the deployer's ledger balance for the proposer bond
        ledger.approveSpender(address(arbiter), type(uint256).max);

        // fund the commons: deposit straight into the pool's ledger balance so a
        // progress claim has something to pay out even before market fees flow.
        ledger.depositTo(address(pool), _commonsSeed);

        // ─────────────────────── 5. register ONE demo builder ─────────────────────
        // Payout goes to a dedicated builder wallet; deployer is the caretaker
        // operator (named by the protocol, cannot redirect the builder's money).
        address demoBuilder;
        if (block.chainid != ROBINHOOD_MAINNET) {
            demoBuilder = address(uint160(uint256(keccak256("otus.demo.builder"))));
            demoBuilderId = builders.registerFor(demoBuilder, "ipfs://otus-demo-builder");
            caretakers.setCaretaker(demoBuilderId, operator);
        }

        vm.stopBroadcast();

        // ─────────────────────── 6. sim-only demo: feed/agent/market/buy + loop ────
        // EVERYTHING below is either timestamp-derived or time-gated and therefore
        // MUST NOT enter a broadcast tx set:
        //   * Registry.createFeed derives feedId as keccak256(msg.sender, desc,
        //     block.timestamp). Under --broadcast, forge bakes the feedId it
        //     computes during its collection run into the recorded registerAgent /
        //     createMarket calldata; the on-chain replay creates the feed at a
        //     DIFFERENT timestamp, so the baked id does not exist -> FeedMissing,
        //     cascading to AgentNotRegistered and MarketMissing.
        //   * The propose -> finalize -> closeEpoch -> claim -> settle loop needs
        //     vm.warp, which never advances a live chain's block.timestamp.
        // So we drive all of it under vm.startPrank(deployer) (NOT startBroadcast)
        // on the local in-memory EVM only (block.chainid == 31337). On a real
        // testnet these are driven later as separate transactions once real time
        // has actually elapsed.
        if (block.chainid == 31337) {
            simulateDemo(deployer, demoBuilder, resolver);
        }

        // ─────────────────────── 9. log everything ────────────────────────────────
        console2.log("=== OTUS PUBLIC (Robinhood Chain) deploy ===");
        console2.log("deployer / admin :", deployer);
        console2.log("caretaker/operator:", operator);
        console2.log("neutral resolver  :", resolver);
        console2.log("");
        console2.log("-- core addresses --");
        console2.log("Settlement token :", address(settlementToken));
        console2.log("NanoLedger       :", address(ledger));
        console2.log("Registry         :", address(registry));
        console2.log("Attestation      :", address(attestation));
        console2.log("Dispute          :", address(dispute));
        console2.log("BuilderRegistry  :", address(builders));
        console2.log("CaretakerRegistry:", address(caretakers));
        console2.log("ProgressPool     :", address(pool));
        console2.log("ProgressArbiter  :", address(arbiter));
        console2.log("MarketsPerennial :", address(markets));
        console2.log("");
        if (block.chainid != ROBINHOOD_MAINNET) {
            console2.log("-- demo builder --");
            console2.log("demo builder id  :", demoBuilderId);
            console2.log("demo builder addr:", demoBuilder);
            console2.log("");
        }

        if (block.chainid == 31337) {
            // ── local in-memory sim: the full demo (feed/market/buy + loop) ran ──
            console2.log("-- demo ids (SIM ONLY) --");
            console2.log("demo feed id     :");
            console2.logBytes32(demoFeedId);
            console2.log("demo market id   :");
            console2.logBytes32(demoMarketId);
            console2.log("");
            console2.log("-- attention -> commons fee leg (real buy, SIM ONLY) --");
            console2.log("buy collateral   :", BUY_COLLATERAL);
            console2.log("pool bal pre-buy :", _poolBalBeforeBuy);
            console2.log("pool bal post-buy:", _poolBalAfterBuy);
            console2.log("commons fee cred.:", _commonsFeeCredited);
            require(_commonsFeeCredited > 0, "fee leg failed: commons received no market fee");
            console2.log(">>> FEE OK: a real market fee landed on the commons (ProgressPool) ledger balance");

            console2.log("");
            console2.log("-- funding loop proof (SIM ONLY: propose -> finalize -> close -> claim -> settle) --");
            console2.log("proposal id      :", _proposalId);
            console2.log("claim epoch      :", _claimEpoch);
            console2.log("claim amount     :", _claimAmount);
            console2.log("stream id        :", _streamId);
            console2.log("settled to builder:", _settled);
            console2.log("builder ledger bal:", _builderLedgerBalance);
            require(_builderLedgerBalance > 0, "loop failed: builder was not paid");
            console2.log(">>> LOOP OK (sim): builder received USDC from the commons via verified progress");
        } else {
            // ── live chain: only the deterministic core stack + demo builder are LIVE ──
            console2.log("NOTE: the core stack (token/ledger/registry/attestation/dispute/builders/");
            console2.log("caretakers/pool/arbiter/markets) is deployed & wired, the commons is funded,");
            if (block.chainid == ROBINHOOD_TESTNET) {
                console2.log("and a registered demo builder is LIVE.");
            } else {
                console2.log("using canonical USDG; no demo builder or market was created.");
            }
            console2.log("");
            console2.log("NOTE: the demo market (createFeed/registerAgent/createMarket/buy) is");
            console2.log("timestamp-derived and the propose -> finalize -> claim -> settle loop is");
            console2.log("time-gated. Drive BOTH as separate later transactions on the live chain");
            console2.log("(the market first, then the loop once CHALLENGE_WINDOW / EPOCH_LENGTH /");
            console2.log("STREAM_WINDOW have elapsed).");
        }
    }

    // ─────────────────────── sim-only funding loop (never broadcast) ───────────
    // Results are stashed in storage so run()'s logging block can print them.
    uint256 internal _proposalId;
    uint256 internal _claimEpoch;
    uint256 internal _claimAmount;
    uint256 internal _streamId;
    uint256 internal _settled;
    uint256 internal _builderLedgerBalance;

    // fee-leg proof (sim-only): commons fee credited by the demo buy(), stashed so
    // the logging block can print it without holding a broadcast-path local.
    uint256 internal _poolBalBeforeBuy;
    uint256 internal _poolBalAfterBuy;
    uint256 internal _commonsFeeCredited;

    /// @notice Drive the entire demo: the timestamp-derived feed/agent/market/buy
    /// AND the TIME-DEPENDENT verified-progress payout loop (three vm.warp calls).
    /// Both are only valid on the local in-memory EVM. It is called by run()
    /// strictly under `block.chainid == 31337` and is NEVER part of a broadcast tx
    /// set. Everything runs under vm.startPrank(deployer) — NOT vm.startBroadcast —
    /// so no call here can ever be recorded as a broadcast transaction. On a live
    /// chain these steps are driven later as separate transactions once real time
    /// has actually elapsed. deployer holds PROPOSER/RESOLVER roles.
    function simulateDemo(address deployer, address demoBuilder, address resolver) internal {
        vm.startPrank(deployer);

        // ── demo oracle feed + agent, then ONE demo market ──
        // deployer acts as the bonded oracle/agent for the demo feed. createFeed
        // derives feedId from block.timestamp, so this cannot be broadcast-baked.
        demoFeedId = registry.createFeed(
            "OTUS-DEMO: builder ships milestone by expiry",
            keccak256("otus.demo.methodology"),
            MIN_BOND,
            FEED_DISPUTE_WINDOW,
            resolver
        );
        registry.registerAgent(demoFeedId, keccak256("otus.demo.methodology"), MIN_BOND);

        // create ONE demo market tagged to the demo builder. "Will metric >= 1?"
        demoMarketId = markets.createMarket(
            demoBuilderId,
            demoFeedId,
            deployer, // agent = bonded oracle
            int256(1), // threshold
            MarketsPerennial.Comparator.GreaterOrEqual,
            block.timestamp + 30 days, // expiry
            MARKET_LIQUIDITY
        );

        // ── exercise the attention -> commons fee leg with ONE real buy() ──
        // MarketsPerennial._payFees routes the treasury (commons) share via
        // internalTransfer(commons=pool), so a real fee lands on the ProgressPool's
        // ledger balance. Stash the before/after/credited amounts for logging.
        _poolBalBeforeBuy = ledger.balanceOf(address(pool));
        markets.buy(demoMarketId, MarketsPerennial.Outcome.Yes, BUY_COLLATERAL, 0);
        _poolBalAfterBuy = ledger.balanceOf(address(pool));
        _commonsFeeCredited = _poolBalAfterBuy - _poolBalBeforeBuy;

        // ── verified-progress payout loop (three vm.warp calls) ──
        // Caretaker deposits a bond, proposes verified progress for the builder,
        // finalizes it (unchallenged) which credits the pool, closes the epoch to
        // snapshot the pot, cranks the builder's claim (opens a stream), warps,
        // and settles so the builder actually receives USDC balance.
        arbiter.depositBond(STAKE_PER_PROPOSAL);
        _proposalId = arbiter.propose(demoBuilder, DEMO_WEIGHT);

        // let the challenge window pass, then finalize -> pool.addProgress
        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);
        arbiter.finalize(_proposalId);

        // close the epoch to snapshot the commons balance as the epoch pot
        vm.warp(block.timestamp + EPOCH_LENGTH + 1);
        pool.closeEpoch();
        _claimEpoch = pool.currentEpoch() - 1;

        // crank the builder's claim: opens a NanoLedger stream to the builder
        _claimAmount = pool.claimFor(_claimEpoch, demoBuilder);

        // let the whole stream window vest, then settle so the builder is credited
        vm.warp(block.timestamp + STREAM_WINDOW + 1);
        _streamId = pool.streamIdOf(_claimEpoch, demoBuilder);
        _settled = ledger.settleStream(_streamId);
        _builderLedgerBalance = ledger.balanceOf(demoBuilder);

        vm.stopPrank();
    }
}
