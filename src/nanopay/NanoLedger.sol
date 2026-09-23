// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title NanoLedger. Fully on-chain, trustless nanopayment settlement.
/// @notice Value moves as INTERNAL BALANCE ACCOUNTING, not ERC20 transfers, so
///         the gas of a payment is decoupled from its size: a sub-cent payment
///         and a million-dollar payment both cost ~one storage write. Real USDC
///         only crosses the contract boundary at deposit and withdraw. Three
///         accrual modes share one balance core:
///           1. internalTransfer / batchPay  (agent-to-agent, discrete).
///           2. reserve-funded STREAMS        (continuous flows; virtual while
///              running, settled lazily/batched, solvent by reservation).
///           3. accrual POOLS                 (one write distributes to many
///              share-holders; lazy claim. Powers the market fee split.).
///
/// Trustless: the contract custodies USDC and every move is atomic on-chain.
/// No operator, no payment channel, no liveness assumption, no off-chain root.
///
/// SOLVENCY: `totalOwed` increases ONLY on deposit and decreases ONLY on
/// withdraw; every other operation merely reshuffles ownership among internal
/// owners (sender->receiver, balance->stream-reserve, source->pool->payee).
/// Conservation therefore holds by construction, and the invariant
/// `USDC.balanceOf(this) >= totalOwed` is structural. Asserted by a fuzz
/// invariant. Rounding dust on pool accrual is stranded conservatively (favors
/// the ledger, never over-credits).
///
/// See docs/superpowers/specs/2026-06-16-nanopay-ledger-design.md.
contract NanoLedger is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    uint256 private constant ACC_PRECISION = 1e18;

    IERC20 public immutable USDC;

    /// Free internal balance (excludes funds reserved into open streams).
    mapping(address => uint256) public balanceOf;
    /// ERC20-style allowance at the internal-balance layer: owner => spender =>
    /// amount the spender may pull via transferFromInternal. Lets apps
    /// (MarketsV4, an x402 facilitator, an operator vault) move a user's ledger
    /// balance with the user's approval, without touching ERC20.
    mapping(address => mapping(address => uint256)) public allowance;
    /// USDC the ledger owes in total. Changes ONLY on deposit (+) / withdraw (-).
    uint256 public totalOwed;

    /// Contracts allowed to create/credit accrual pools (e.g. MarketsV4).
    mapping(address => bool) public isSource;

    // ── streams ──
    struct Stream {
        address from;
        address to;
        uint256 ratePerSec; // 6-dec USDC per second; may be tiny
        uint256 cap;        // total reserved from `from` at open
        uint256 settled;    // amount already credited to `to`
        uint40 start;
        bool closed;
    }
    Stream[] public streams;

    // ── accrual pools ──
    struct Pool {
        address source;
        uint256 totalShares;
        uint256 accPerShare; // scaled by ACC_PRECISION
    }
    mapping(bytes32 => Pool) public pools;
    mapping(bytes32 => mapping(address => uint256)) public shareOf;
    mapping(bytes32 => mapping(address => uint256)) public claimedPerShare;

    event Deposit(address indexed payer, address indexed to, uint256 amount);
    event Withdraw(address indexed owner, uint256 amount);
    event InternalTransfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event StreamOpened(uint256 indexed id, address indexed from, address indexed to, uint256 ratePerSec, uint256 cap);
    event StreamSettled(uint256 indexed id, address indexed to, uint256 amount);
    event StreamClosed(uint256 indexed id, uint256 returnedToSender);
    event PoolCreated(bytes32 indexed poolId, address indexed source);
    event SharesSet(bytes32 indexed poolId, address indexed payee, uint256 shares);
    event Accrued(bytes32 indexed poolId, uint256 amount);
    event Claimed(bytes32 indexed poolId, address indexed payee, uint256 amount);
    event SourceSet(address indexed source, bool allowed);

    error ZeroAmount();
    error ZeroAddress();
    error InsufficientBalance();
    error LengthMismatch();
    error InsufficientAllowance();
    error NotSource();
    error NoStream();
    error NotStreamOwner();
    error StreamIsClosed();
    error PoolExists();
    error NoPool();
    error NotPoolSource();
    error NoShares();

    constructor(IERC20 usdc_, address admin) {
        if (address(usdc_) == address(0) || admin == address(0)) revert ZeroAddress();
        USDC = usdc_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    // ─────────────────────── ERC20 boundary ───────────────────────

    function deposit(uint256 amount) external nonReentrant {
        _depositTo(msg.sender, amount);
    }

    function depositTo(address to, uint256 amount) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _depositTo(to, amount);
    }

    function _depositTo(address to, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        balanceOf[to] += amount;
        totalOwed += amount;
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, to, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 bal = balanceOf[msg.sender];
        if (amount > bal) revert InsufficientBalance();
        unchecked {
            balanceOf[msg.sender] = bal - amount;
            totalOwed -= amount; // amount <= bal <= totalOwed
        }
        USDC.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    // ─────────────────────── internal payments ───────────────────────

    function internalTransfer(address to, uint256 amount) public {
        _move(msg.sender, to, amount);
        emit InternalTransfer(msg.sender, to, amount);
    }

    function batchPay(address[] calldata to, uint256[] calldata amount) external {
        uint256 n = to.length;
        if (n != amount.length) revert LengthMismatch();
        for (uint256 i; i < n; ++i) {
            _move(msg.sender, to[i], amount[i]);
            emit InternalTransfer(msg.sender, to[i], amount[i]);
        }
    }

    function _move(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 bal = balanceOf[from];
        if (amount > bal) revert InsufficientBalance();
        unchecked { balanceOf[from] = bal - amount; }
        balanceOf[to] += amount;
    }

    /// @notice Approve `spender` to move up to `amount` of your internal balance.
    function approveSpender(address spender, uint256 amount) external {
        if (spender == address(0)) revert ZeroAddress();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
    }

    /// @notice Move `from`'s internal balance to `to`, spending the caller's
    /// allowance. Conservation preserved by _move; the only new authority is the
    /// owner-granted allowance. max allowance is treated as infinite.
    function transferFromInternal(address from, address to, uint256 amount) external {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            if (amount > a) revert InsufficientAllowance();
            unchecked { allowance[from][msg.sender] = a - amount; }
        }
        _move(from, to, amount);
        emit InternalTransfer(from, to, amount);
    }

    // ───────────────────────────── streams ─────────────────────────────

    /// @notice Open a continuous stream to `to` at `ratePerSec`, reserving `cap`
    /// from the caller's free balance NOW (so the stream is always solvent). The
    /// stream is virtual (zero gas while it runs); call settleStream to realize.
    function openStream(address to, uint256 ratePerSec, uint256 cap)
        external returns (uint256 id)
    {
        if (to == address(0)) revert ZeroAddress();
        if (ratePerSec == 0 || cap == 0) revert ZeroAmount();
        uint256 bal = balanceOf[msg.sender];
        if (cap > bal) revert InsufficientBalance();
        unchecked { balanceOf[msg.sender] = bal - cap; } // reserve: leaves free balance, stays in totalOwed
        id = streams.length;
        streams.push(Stream({
            from: msg.sender, to: to, ratePerSec: ratePerSec, cap: cap,
            settled: 0, start: uint40(block.timestamp), closed: false
        }));
        emit StreamOpened(id, msg.sender, to, ratePerSec, cap);
    }

    function streamCount() external view returns (uint256) { return streams.length; }

    /// @notice Total amount streamed since open, capped at `cap`.
    /// @dev Computes min(cap, ratePerSec * elapsed) WITHOUT ever overflowing the
    /// multiplication: if ratePerSec * elapsed would reach cap we return cap
    /// directly, so an arbitrarily large ratePerSec can never brick settle/cancel
    /// (which would otherwise lock the reserved funds). The result is always
    /// bounded by cap, so the only multiply executed is provably <= cap.
    function streamedSoFar(uint256 id) public view returns (uint256) {
        Stream storage s = streams[id];
        if (s.to == address(0)) revert NoStream();
        uint256 elapsed = block.timestamp - s.start;
        if (elapsed == 0) return 0;
        uint256 cap = s.cap;
        uint256 rate = s.ratePerSec;
        // If rate*elapsed >= cap, the stream is fully streamed. This branch also
        // guards the multiply: it only runs when rate <= cap/elapsed, so
        // rate*elapsed <= cap < 2^256 and cannot overflow.
        if (rate > cap / elapsed) return cap;
        return rate * elapsed;
    }

    function claimableStream(uint256 id) external view returns (uint256) {
        Stream storage s = streams[id];
        if (s.closed) return 0;
        return streamedSoFar(id) - s.settled;
    }

    /// @notice Credit `to` with everything streamed since the last settle.
    /// Permissionless (anyone can poke; funds only ever go to `to`). Batches:
    /// one call collapses any elapsed time into a single balance update.
    function settleStream(uint256 id) public returns (uint256 amount) {
        Stream storage s = streams[id];
        if (s.to == address(0)) revert NoStream();
        if (s.closed) return 0;
        uint256 streamed = streamedSoFar(id);
        amount = streamed - s.settled;
        if (amount > 0) {
            s.settled = streamed;
            balanceOf[s.to] += amount; // sourced from the reserved cap
            emit StreamSettled(id, s.to, amount);
        }
        if (streamed == s.cap) {
            s.closed = true;
            emit StreamClosed(id, 0);
        }
    }

    /// @notice Stop a stream: settle accrued to `to`, return the unstreamed
    /// remainder of the reservation to the sender. Sender only.
    function cancelStream(uint256 id) external {
        Stream storage s = streams[id];
        if (s.to == address(0)) revert NoStream();
        if (s.from != msg.sender) revert NotStreamOwner();
        if (s.closed) revert StreamIsClosed();
        settleStream(id);
        if (s.closed) return; // settle auto-closed it (fully streamed); nothing to return
        uint256 remainder = s.cap - s.settled;
        s.closed = true;
        if (remainder > 0) balanceOf[s.from] += remainder;
        emit StreamClosed(id, remainder);
    }

    // ───────────────────────── accrual pools ─────────────────────────

    /// @notice Create a distribution pool. Only a registered source (e.g.
    /// MarketsV4) can create and credit pools. poolId is caller-namespaced.
    function createPool(bytes32 poolId) external {
        if (!isSource[msg.sender]) revert NotSource();
        if (pools[poolId].source != address(0)) revert PoolExists();
        pools[poolId].source = msg.sender;
        emit PoolCreated(poolId, msg.sender);
    }

    /// @notice Set a payee's share. Settles their pending first so a share change
    /// never retroactively re-weights already-accrued amounts.
    function setShares(bytes32 poolId, address payee, uint256 newShares) external {
        Pool storage p = pools[poolId];
        if (p.source != msg.sender) revert NotPoolSource();
        if (payee == address(0)) revert ZeroAddress();
        uint256 acc = p.accPerShare;
        uint256 cur = shareOf[poolId][payee];
        if (cur > 0) {
            uint256 owed = (cur * (acc - claimedPerShare[poolId][payee])) / ACC_PRECISION;
            if (owed > 0) balanceOf[payee] += owed;
        }
        claimedPerShare[poolId][payee] = acc;
        p.totalShares = p.totalShares - cur + newShares;
        shareOf[poolId][payee] = newShares;
        emit SharesSet(poolId, payee, newShares);
    }

    /// @notice Distribute `amount` (drawn from the source's own internal balance)
    /// across the pool's share-holders in ONE write. Payees claim lazily.
    function accrue(bytes32 poolId, uint256 amount) external {
        Pool storage p = pools[poolId];
        if (p.source != msg.sender) revert NotPoolSource();
        if (amount == 0) revert ZeroAmount();
        uint256 ts = p.totalShares;
        if (ts == 0) revert NoShares();
        uint256 bal = balanceOf[msg.sender];
        if (amount > bal) revert InsufficientBalance();
        unchecked { balanceOf[msg.sender] = bal - amount; }
        p.accPerShare += (amount * ACC_PRECISION) / ts; // dust (amount mod ts) stranded conservatively
        emit Accrued(poolId, amount);
    }

    function claimablePool(bytes32 poolId, address payee) public view returns (uint256) {
        Pool storage p = pools[poolId];
        return (shareOf[poolId][payee] * (p.accPerShare - claimedPerShare[poolId][payee])) / ACC_PRECISION;
    }

    function claim(bytes32 poolId) external returns (uint256 owed) {
        Pool storage p = pools[poolId];
        if (p.source == address(0)) revert NoPool();
        uint256 acc = p.accPerShare;
        owed = (shareOf[poolId][msg.sender] * (acc - claimedPerShare[poolId][msg.sender])) / ACC_PRECISION;
        claimedPerShare[poolId][msg.sender] = acc;
        if (owed > 0) {
            balanceOf[msg.sender] += owed;
            emit Claimed(poolId, msg.sender, owed);
        }
    }

    // ──────────────────────────── governor ────────────────────────────

    function setSource(address source, bool allowed) external onlyRole(GOVERNOR_ROLE) {
        if (source == address(0)) revert ZeroAddress();
        isSource[source] = allowed;
        emit SourceSet(source, allowed);
    }

    /// @notice Donations / stray USDC above what the ledger owes are skimmable to
    /// the caller-specified sink by a governor. Never touches owed balances.
    function skimSurplus(address to) external onlyRole(GOVERNOR_ROLE) returns (uint256 surplus) {
        if (to == address(0)) revert ZeroAddress();
        uint256 held = USDC.balanceOf(address(this));
        surplus = held > totalOwed ? held - totalOwed : 0;
        if (surplus == 0) revert ZeroAmount();
        USDC.safeTransfer(to, surplus);
    }
}
