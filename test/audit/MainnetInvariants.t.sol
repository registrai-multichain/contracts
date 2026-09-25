// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Mainnet phase-1 invariant suite (BuilderRegistry + CaretakerRegistry +
/// VerifiedBuilderBadge), deployed exactly like DeployBuilders did on Arc
/// mainnet (chain 5042): the Safe holds every admin role, OPERATOR only badge
/// STATUS, ONBOARDER only badge ISSUER + caretaker GOVERNOR.
///
/// The handler drives EVERY external state-changing function of the three
/// contracts from a small pool of actors (the three role holders + users), so
/// role holders, owners, pending owners and recovery targets collide often.
/// Every protected field has a ghost that only the handler path which is
/// allowed to change it updates; the invariants compare chain state against the
/// ghosts, which proves no other path moved it.
///
/// Run deep: FOUNDRY_INVARIANT_RUNS=2000 FOUNDRY_INVARIANT_DEPTH=100 \
///   forge test --match-path test/audit/MainnetInvariants.t.sol

import {Test} from "forge-std/Test.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";
import {VerifiedBuilderBadge} from "../../src/perennial/VerifiedBuilderBadge.sol";

contract PhaseOneHandler is Test {
    BuilderRegistry public immutable builders;
    CaretakerRegistry public immutable caretakers;
    VerifiedBuilderBadge public immutable badge;

    address public immutable safe;
    address public immutable operator;
    address public immutable onboarder;
    address[] public actors; // [safe, operator, onboarder, u1..u13]

    bytes32 immutable REGISTRAR;
    bytes32 immutable GOVERNOR;
    bytes32 immutable ISSUER;
    bytes32 immutable STATUS;
    bytes32 immutable REVOKER;
    bytes32 constant DA = 0x00;

    // ── violations (must stay 0) ──
    uint256 public unauthorizedSuccess; // a gated call succeeded for a non-holder
    uint256 public soulboundBroken; // a transfer / approval succeeded
    uint256 public serialReused; // issue returned a serial seen before
    uint256 public earlyRecovery; // finishRecovery before readyAt / from start
    uint256 public hijackedRecovery; // finishRecovery moved to an unexpected wallet
    uint256 public badIssue; // issue for an inactive / project-less builder
    uint256 public syncMisrouted; // sync left the badge off the owner

    // ── ghosts ──
    mapping(uint256 => address) public gOwner; // builderId => owner
    mapping(uint256 => bool) public gActive;
    mapping(uint256 => uint256) public gEpoch; // bumps on every owner change
    mapping(uint256 => address) public gCaretaker;
    mapping(uint256 => bool) public gProjectActive;
    mapping(uint256 => address) public gPending;
    mapping(uint256 => address) public gRecTo;
    mapping(uint256 => uint256) public gRecStart; // timestamp startRecovery ran
    mapping(uint256 => address) public gPayout;
    mapping(uint256 => address) public gPayoutSetter;
    mapping(uint256 => bool) public gLapsed; // serial => flag
    mapping(uint256 => bool) public serialSeen;
    mapping(uint256 => mapping(address => bool)) public everOwned; // builderId => wallet => ever owner
    string public gImageBase;
    string public gExternalBase;
    uint256 public maxSerial;

    // call counters (coverage sanity)
    mapping(bytes32 => uint256) public ok; // keyed by keccak256(name)

    constructor(
        BuilderRegistry b,
        CaretakerRegistry c,
        VerifiedBuilderBadge v,
        address safe_,
        address operator_,
        address onboarder_,
        string memory imageBase_,
        string memory externalBase_
    ) {
        builders = b;
        caretakers = c;
        badge = v;
        safe = safe_;
        operator = operator_;
        onboarder = onboarder_;
        REGISTRAR = b.REGISTRAR_ROLE();
        GOVERNOR = c.GOVERNOR_ROLE();
        ISSUER = v.ISSUER_ROLE();
        STATUS = v.STATUS_ROLE();
        REVOKER = v.REVOKER_ROLE();
        actors.push(safe_);
        actors.push(operator_);
        actors.push(onboarder_);
        for (uint256 i = 1; i <= 13; i++) {
            actors.push(address(uint160(0xB0000 + i)));
        }
        gImageBase = imageBase_;
        gExternalBase = externalBase_;
    }

    // ───────────────────────── helpers ─────────────────────────

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    /// 0 .. nextId (includes the unregistered 0 and next ids on purpose).
    function _bid(uint256 s) internal view returns (uint256) {
        return s % (builders.nextId() + 1);
    }

    function _pid(uint256 s) internal view returns (uint256) {
        uint256 np = builders.nextProjectId();
        if (np > 1 && s % 8 != 0) return 1 + (s >> 3) % (np - 1);
        return s % (np + 1);
    }

    /// Mostly a live id (1..nextId-1), sometimes 0 / nextId.
    function _live(uint256 s) internal view returns (uint256) {
        uint256 n = builders.nextId();
        if (n > 1 && s % 8 != 0) return 1 + (s >> 3) % (n - 1);
        return _bid(s);
    }

    /// Half the time the holder of `role` on `c` (the Safe or the scoped key),
    /// otherwise anyone.
    function _roleActor(uint256 a, address alt) internal view returns (address) {
        if (a % 2 == 0) return (a >> 1) % 2 == 0 ? safe : alt;
        return _actor(a >> 1);
    }

    /// Half the time a live id with a pending recovery / pending owner.
    function _withRecovery(uint256 i) internal view returns (uint256) {
        uint256 n = builders.nextId();
        if (i % 2 == 0) {
            for (uint256 k = 1; k < n; k++) {
                uint256 id = 1 + ((i >> 1) + k) % (n - 1);
                if (gRecTo[id] != address(0)) return id;
            }
        }
        return _live(i >> 1);
    }

    function _withSerial(uint256 i) internal view returns (uint256) {
        uint256 n = builders.nextId();
        if (i % 2 == 0) {
            for (uint256 k = 1; k < n; k++) {
                uint256 id = 1 + ((i >> 1) + k) % (n - 1);
                if (badge.serialOf(id) != 0) return id;
            }
        }
        return _live(i >> 1);
    }

    function _withPending(uint256 i) internal view returns (uint256) {
        uint256 n = builders.nextId();
        if (i % 2 == 0) {
            for (uint256 k = 1; k < n; k++) {
                uint256 id = 1 + ((i >> 1) + k) % (n - 1);
                if (gPending[id] != address(0)) return id;
            }
        }
        return _live(i >> 1);
    }

    /// Half the time a wallet with no builder (a valid new owner), else anyone.
    function _freshOr(uint256 b) internal view returns (address) {
        if (b % 2 == 0) {
            uint256 n = actors.length;
            for (uint256 k; k < n; k++) {
                address c = actors[((b >> 1) + k) % n];
                if (builders.builderIdOf(c) == 0) return c;
            }
        }
        return _actor(b >> 1);
    }

    /// Half the time the current owner of `id`, otherwise anyone.
    function _ownerOr(uint256 a, uint256 id) internal view returns (address) {
        address o = builders.ownerOf(id);
        if (a % 2 == 0 && o != address(0)) return o;
        return _actor(a >> 1);
    }

    function _str(uint256 s, uint256 maxLen) internal pure returns (string memory) {
        uint256 len = s % (maxLen + 3); // sometimes over the cap
        bytes memory b = new bytes(len);
        for (uint256 i; i < len; i++) {
            b[i] = bytes1(uint8(uint256(keccak256(abi.encode(s, i)))));
        }
        return string(b);
    }

    function _onRegistered(uint256 id, address owner) internal {
        gOwner[id] = owner;
        gActive[id] = true;
        everOwned[id][owner] = true;
    }

    function _onProject(uint256 pid) internal {
        gProjectActive[pid] = true;
    }

    function _onOwnerChanged(uint256 id, address to) internal {
        gOwner[id] = to;
        gEpoch[id] += 1;
        gPending[id] = address(0);
        gRecTo[id] = address(0);
        gRecStart[id] = 0;
        everOwned[id][to] = true;
    }

    // ───────────────────────── BuilderRegistry ─────────────────────────

    function registerBuilder(uint256 a, uint256 s) external {
        if (s % 3 != 0) return; // throttle: keep fresh wallets for transfers / recoveries
        address who = _actor(a);
        vm.prank(who);
        try builders.registerBuilder(_str(s, 256)) returns (uint256 id) {
            _onRegistered(id, who);
            ok[keccak256("registerBuilder")]++;
        } catch {}
    }

    function registerBuilderWithProject(uint256 a, uint256 s, uint256 t) external {
        if (s % 3 != 0) return; // throttle: keep fresh wallets for transfers / recoveries
        address who = _actor(a);
        vm.prank(who);
        try builders.registerBuilderWithProject(_str(s, 256), _str(t, 128)) returns (uint256 id, uint256 pid) {
            _onRegistered(id, who);
            _onProject(pid);
            ok[keccak256("registerBuilderWithProject")]++;
        } catch {}
    }

    function registerFor(uint256 a, uint256 b, uint256 s) external {
        if (s % 3 != 0) return; // throttle: keep fresh wallets for transfers / recoveries
        address who = _roleActor(a, address(0xB0001));
        address target = _freshOr(b);
        bool auth = builders.hasRole(REGISTRAR, who);
        vm.prank(who);
        try builders.registerFor(target, _str(s, 256)) returns (uint256 id) {
            if (!auth) unauthorizedSuccess++;
            _onRegistered(id, target);
            ok[keccak256("registerFor")]++;
        } catch {}
    }

    function updateProfile(uint256 a, uint256 s) external {
        vm.prank(_actor(a));
        try builders.updateProfile(_str(s, 256)) {
            ok[keccak256("updateProfile")]++;
        } catch {}
    }

    function linkIdentity(uint256 a, uint256 s) external {
        vm.prank(_actor(a));
        try builders.linkIdentity(bytes(_str(s, 1024))) {
            ok[keccak256("linkIdentity")]++;
        } catch {}
    }

    function setActive(uint256 a, uint256 i, bool v) external {
        address who = _roleActor(a, address(0xB0002));
        uint256 id = _live(i);
        bool auth = builders.hasRole(REGISTRAR, who);
        vm.prank(who);
        try builders.setActive(id, v) {
            if (!auth) unauthorizedSuccess++;
            gActive[id] = v;
            ok[keccak256("setActive")]++;
        } catch {}
    }

    function addProject(uint256 a, uint256 t) external {
        vm.prank(_actor(a));
        try builders.addProject(_str(t, 128)) returns (uint256 pid) {
            _onProject(pid);
            ok[keccak256("addProject")]++;
        } catch {}
    }

    function addProjectFor(uint256 a, uint256 i, uint256 t) external {
        address who = _roleActor(a, address(0xB0003));
        bool auth = builders.hasRole(REGISTRAR, who);
        uint256 id = _live(i); // before the prank: _live makes an external call
        string memory src = _str(t, 128);
        vm.prank(who);
        try builders.addProjectFor(id, src) returns (uint256 pid) {
            if (!auth) unauthorizedSuccess++;
            _onProject(pid);
            ok[keccak256("addProjectFor")]++;
        } catch {}
    }

    function removeProject(uint256 a, uint256 p) external {
        if (a % 4 != 0) return; // keep removals rarer than adds
        uint256 pid = _pid(p);
        (uint256 bid,,,) = builders.projects(pid);
        address who = _ownerOr(a, bid);
        bool auth = bid != 0 && who == builders.ownerOf(bid);
        vm.prank(who);
        try builders.removeProject(pid) {
            if (!auth) unauthorizedSuccess++;
            gProjectActive[pid] = false;
            ok[keccak256("removeProject")]++;
        } catch {}
    }

    function setProjectActive(uint256 a, uint256 p, bool v) external {
        address who = _roleActor(a, onboarder);
        uint256 pid = _pid(p);
        bool auth = builders.hasRole(REGISTRAR, who);
        vm.prank(who);
        try builders.setProjectActive(pid, v) {
            if (!auth) unauthorizedSuccess++;
            gProjectActive[pid] = v;
            ok[keccak256("setProjectActive")]++;
        } catch {}
    }

    function proposeOwner(uint256 a, uint256 b, uint8 c) external {
        bool cancel = c % 5 == 0;
        address who = _ownerOr(a, _live(a >> 8));
        address to = cancel ? address(0) : _freshOr(b);
        uint256 id = builders.builderIdOf(who);
        vm.prank(who);
        try builders.proposeOwner(to) {
            gPending[id] = to;
            ok[keccak256("proposeOwner")]++;
        } catch {}
    }

    function acceptOwnership(uint256 a, uint256 i) external {
        uint256 id = _withPending(i);
        address who = a % 2 == 0 && gPending[id] != address(0) ? gPending[id] : _actor(a >> 1);
        bool auth = gPending[id] == who && who != address(0);
        vm.prank(who);
        try builders.acceptOwnership(id) {
            if (!auth) unauthorizedSuccess++;
            _onOwnerChanged(id, who);
            ok[keccak256("acceptOwnership")]++;
        } catch {}
    }

    function startRecovery(uint256 a, uint256 i, uint256 b) external {
        address who = _roleActor(a, address(0xB0002));
        uint256 id = _live(i);
        address to = _freshOr(b);
        bool auth = builders.hasRole(REGISTRAR, who);
        vm.prank(who);
        try builders.startRecovery(id, to) {
            if (!auth) unauthorizedSuccess++;
            gRecTo[id] = to;
            gRecStart[id] = block.timestamp;
            ok[keccak256("startRecovery")]++;
        } catch {}
    }

    function cancelRecovery(uint256 a, uint256 i) external {
        uint256 id = _withRecovery(i);
        address who = a % 3 == 1 ? safe : _ownerOr(a, id);
        bool auth = who == builders.ownerOf(id) || builders.hasRole(REGISTRAR, who);
        vm.prank(who);
        try builders.cancelRecovery(id) {
            if (!auth) unauthorizedSuccess++;
            gRecTo[id] = address(0);
            gRecStart[id] = 0;
            ok[keccak256("cancelRecovery")]++;
        } catch {}
    }

    function finishRecovery(uint256 a, uint256 i) external {
        uint256 id = _withRecovery(i);
        address expected = gRecTo[id];
        uint256 started = gRecStart[id];
        // a third of the time jump right to readyAt (or one second before it)
        if (started != 0 && a % 3 == 0) {
            uint256 target = started + builders.RECOVERY_DELAY() - ((a >> 2) % 2);
            if (target > block.timestamp) vm.warp(target);
        }
        vm.prank(_actor(a));
        try builders.finishRecovery(id) {
            if (expected == address(0) || builders.ownerOf(id) != expected) hijackedRecovery++;
            if (block.timestamp < started + builders.RECOVERY_DELAY()) earlyRecovery++;
            _onOwnerChanged(id, expected);
            ok[keccak256("finishRecovery")]++;
        } catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 10 days));
    }

    // ───────────────────────── CaretakerRegistry ─────────────────────────

    function setCaretaker(uint256 a, uint256 i, uint256 b) external {
        address who = _roleActor(a, onboarder);
        uint256 id = _live(i);
        address op = _actor(b);
        bool auth = caretakers.hasRole(GOVERNOR, who);
        vm.prank(who);
        try caretakers.setCaretaker(id, op) {
            if (!auth) unauthorizedSuccess++;
            gCaretaker[id] = op;
            ok[keccak256("setCaretaker")]++;
        } catch {}
    }

    function setPayout(uint256 a, uint256 i, uint256 b) external {
        uint256 id = _live(i);
        address who = _ownerOr(a, id);
        address p = address(uint160(0xFA0000 + (b % 7)));
        bool auth = who == builders.ownerOf(id);
        vm.prank(who);
        try caretakers.setPayout(id, p) {
            if (!auth) unauthorizedSuccess++;
            gPayout[id] = p;
            gPayoutSetter[id] = who;
            ok[keccak256("setPayout")]++;
        } catch {}
    }

    // ───────────────────────── VerifiedBuilderBadge ─────────────────────────

    function issue(uint256 a, uint256 i) external {
        address who = _roleActor(a, onboarder);
        uint256 id = _live(i);
        bool auth = badge.hasRole(ISSUER, who);
        bool eligible = builders.isActiveBuilderId(id) && builders.activeProjectCount(id) > 0;
        vm.prank(who);
        try badge.issue(id) returns (uint256 serial) {
            if (!auth) unauthorizedSuccess++;
            if (!eligible) badIssue++;
            if (serialSeen[serial] || serial == 0) serialReused++;
            serialSeen[serial] = true;
            if (serial > maxSerial) maxSerial = serial;
            ok[keccak256("issue")]++;
        } catch {}
    }

    function revoke(uint256 a, uint256 i) external {
        if (a % 3 != 0) return; // rarer than issue, so badges accumulate
        address who = _roleActor(a, onboarder);
        uint256 id = _withSerial(i);
        uint256 serial = badge.serialOf(id);
        bool auth = badge.hasRole(REVOKER, who);
        vm.prank(who);
        try badge.revoke(id) {
            if (!auth) unauthorizedSuccess++;
            gLapsed[serial] = false;
            ok[keccak256("revoke")]++;
        } catch {}
    }

    function setLapsed(uint256 a, uint256 i, bool v) external {
        address who = _roleActor(a, operator);
        uint256 id = _withSerial(i);
        bool auth = badge.hasRole(STATUS, who);
        vm.prank(who);
        try badge.setLapsed(id, v) {
            if (!auth) unauthorizedSuccess++;
            gLapsed[badge.serialOf(id)] = v;
            ok[keccak256("setLapsed")]++;
        } catch {}
    }

    function setBases(uint256 a, uint256 s, uint256 t) external {
        address who = _roleActor(a, operator);
        bool auth = badge.hasRole(DA, who);
        string memory x = _str(s, 64);
        string memory y = _str(t, 64);
        vm.prank(who);
        try badge.setBases(x, y) {
            if (!auth) unauthorizedSuccess++;
            gImageBase = x;
            gExternalBase = y;
            ok[keccak256("setBases")]++;
        } catch {}
    }

    function sync(uint256 a, uint256 i) external {
        uint256 id = _withSerial(i);
        vm.prank(_actor(a));
        try badge.sync(id) {
            if (badge.ownerOf(badge.serialOf(id)) != builders.ownerOf(id)) syncMisrouted++;
            ok[keccak256("sync")]++;
        } catch {}
    }

    /// Every ERC-721 move/approval path, from every actor (incl. the holder).
    function tryTransfer(uint256 a, uint256 s, uint256 b, uint8 path) external {
        uint256 serial = 1 + (s % (badge.nextSerial()));
        address who = _actor(a);
        address to = _actor(b);
        address holder;
        try badge.ownerOf(serial) returns (address h) {
            holder = h;
        } catch {
            return;
        }
        if (path % 2 == 0) who = holder; // half the time the real holder tries
        vm.startPrank(who);
        uint8 p = path % 5;
        if (p == 0) {
            try badge.transferFrom(holder, to, serial) {
                soulboundBroken++;
            } catch {}
        } else if (p == 1) {
            try badge.safeTransferFrom(holder, to, serial) {
                soulboundBroken++;
            } catch {}
        } else if (p == 2) {
            try badge.safeTransferFrom(holder, to, serial, "x") {
                soulboundBroken++;
            } catch {}
        } else if (p == 3) {
            try badge.approve(to, serial) {
                soulboundBroken++;
            } catch {}
        } else {
            try badge.setApprovalForAll(to, true) {
                soulboundBroken++;
            } catch {}
        }
        vm.stopPrank();
    }

    // ───────────────────────── AccessControl ─────────────────────────

    function _anyRole(uint256 r) internal view returns (bytes32) {
        bytes32[6] memory rs = [DA, REGISTRAR, GOVERNOR, ISSUER, STATUS, REVOKER];
        return rs[r % 6];
    }

    function _anyTarget(uint256 t) internal view returns (address) {
        uint256 k = t % 3;
        return k == 0 ? address(builders) : k == 1 ? address(caretakers) : address(badge);
    }

    /// Non-admins trying to grant / revoke roles anywhere (must always fail).
    function grantOrRevoke(uint256 a, uint256 t, uint256 r, uint256 b, bool grant) external {
        address who = _actor(a);
        if (who == safe) return; // the Safe's own role management is modelled in safeRotateOnboarder
        BuilderRegistry target = BuilderRegistry(_anyTarget(t)); // AccessControl ABI is shared
        bytes32 role = _anyRole(r);
        address acct = _actor(b);
        bool auth = target.hasRole(target.getRoleAdmin(role), who);
        vm.prank(who);
        if (grant) {
            try target.grantRole(role, acct) {
                if (!auth) unauthorizedSuccess++;
            } catch {}
        } else {
            try target.revokeRole(role, acct) {
                if (!auth) unauthorizedSuccess++;
            } catch {}
        }
    }

    /// Anyone may renounce its OWN role; renouncing for another must fail.
    function renounce(uint256 a, uint256 t, uint256 r, uint256 b) external {
        address who = _actor(a);
        if (who == safe) return; // a Safe renounce just bricks admin; not interesting
        BuilderRegistry target = BuilderRegistry(_anyTarget(t));
        bytes32 role = _anyRole(r);
        address acct = _actor(b);
        vm.prank(who);
        try target.renounceRole(role, acct) {
            if (acct != who) unauthorizedSuccess++;
            ok[keccak256("renounce")]++;
        } catch {}
    }

    /// The Safe's realistic role ops on mainnet: take the onboarder's two roles
    /// back, or give them again.
    function safeRotateOnboarder(bool grant) external {
        vm.startPrank(safe);
        if (grant) {
            badge.grantRole(ISSUER, onboarder);
            caretakers.grantRole(GOVERNOR, onboarder);
        } else {
            badge.revokeRole(ISSUER, onboarder);
            caretakers.revokeRole(GOVERNOR, onboarder);
        }
        vm.stopPrank();
    }
}

contract MainnetInvariantsTest is Test {
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    VerifiedBuilderBadge badge;
    PhaseOneHandler h;

    address safe = makeAddr("safe (2-of-3)");
    address operator = makeAddr("operator");
    address onboarder = makeAddr("onboarder");
    address deployer = makeAddr("deployer");

    function setUp() public {
        // Mirror DeployBuilders' mainnet path (ONBOARDER set) exactly.
        vm.startPrank(deployer);
        builders = new BuilderRegistry(safe);
        caretakers = new CaretakerRegistry(builders, deployer);
        caretakers.grantRole(0x00, safe);
        caretakers.grantRole(caretakers.GOVERNOR_ROLE(), safe);
        caretakers.grantRole(caretakers.GOVERNOR_ROLE(), onboarder);
        caretakers.renounceRole(caretakers.GOVERNOR_ROLE(), deployer);
        caretakers.renounceRole(0x00, deployer);
        badge = new VerifiedBuilderBadge(
            builders,
            deployer,
            operator,
            "Arc Mainnet",
            "https://builder.registrai.cc/badge/arc/",
            "https://builder.registrai.cc/builders/?builder="
        );
        badge.grantRole(0x00, safe);
        badge.grantRole(badge.ISSUER_ROLE(), safe);
        badge.grantRole(badge.REVOKER_ROLE(), safe);
        badge.grantRole(badge.ISSUER_ROLE(), onboarder);
        badge.renounceRole(badge.ISSUER_ROLE(), deployer);
        badge.renounceRole(badge.REVOKER_ROLE(), deployer);
        badge.renounceRole(0x00, deployer);
        vm.stopPrank();

        h = new PhaseOneHandler(
            builders,
            caretakers,
            badge,
            safe,
            operator,
            onboarder,
            "https://builder.registrai.cc/badge/arc/",
            "https://builder.registrai.cc/builders/?builder="
        );
        targetContract(address(h));
    }

    // ───────────────────────── violation counters ─────────────────────────

    function invariant_noUnauthorizedSuccess() public view {
        assertEq(h.unauthorizedSuccess(), 0, "a gated call succeeded for a non-holder");
    }

    function invariant_soulbound() public view {
        assertEq(h.soulboundBroken(), 0, "a badge moved or was approved");
    }

    function invariant_serialsNeverReused() public view {
        assertEq(h.serialReused(), 0, "serial reused");
        assertEq(badge.nextSerial(), h.maxSerial() + 1, "nextSerial != last issued + 1");
    }

    function invariant_recoveryNotEarlyNorHijacked() public view {
        assertEq(h.earlyRecovery(), 0, "recovery finished before RECOVERY_DELAY");
        assertEq(h.hijackedRecovery(), 0, "recovery moved the builder to an unexpected wallet");
    }

    function invariant_issueOnlyEligible() public view {
        assertEq(h.badIssue(), 0, "badge issued to an inactive / project-less builder");
        assertEq(h.syncMisrouted(), 0, "sync left the badge off the owner");
    }

    // ───────────────────────── registry ─────────────────────────

    /// One builder per address; builderIdOf / ownerOf consistent both ways;
    /// owner / active / pending / recovery equal the ghosts (so only
    /// acceptOwnership / finishRecovery moved ownership, only setActive flipped
    /// active, ...).
    function invariant_registryConsistency() public view {
        uint256 n = builders.nextId();
        for (uint256 id = 1; id < n; id++) {
            address o = builders.ownerOf(id);
            assertTrue(o != address(0), "registered builder with no owner");
            assertEq(o, h.gOwner(id), "owner moved outside accept/finishRecovery");
            assertEq(builders.builderIdOf(o), id, "builderIdOf(owner) != id");
            assertEq(builders.isActiveBuilderId(id), h.gActive(id), "active flipped outside setActive");
            assertEq(builders.pendingOwner(id), h.gPending(id), "pendingOwner drift");
            (address rTo, uint64 readyAt) = builders.recoveryOf(id);
            assertEq(rTo, h.gRecTo(id), "recovery target drift");
            if (rTo != address(0)) {
                assertEq(uint256(readyAt), h.gRecStart(id) + builders.RECOVERY_DELAY(), "readyAt drift");
            }
            for (uint256 j = id + 1; j < n; j++) {
                assertTrue(builders.ownerOf(j) != o, "two builders share an owner");
            }
        }
        assertEq(builders.ownerOf(0), address(0), "id 0 has an owner");
        assertEq(builders.ownerOf(n), address(0), "unissued id has an owner");
        uint256 na = h.actorCount();
        for (uint256 k; k < na; k++) {
            address a = h.actors(k);
            uint256 id = builders.builderIdOf(a);
            if (id != 0) assertEq(builders.ownerOf(id), a, "stale builderIdOf");
            assertTrue(id < n, "builderIdOf out of range");
        }
    }

    /// activeProjectCount == #active projects; never more than 16 ever added;
    /// every listed project belongs to its builder; project active == ghost.
    function invariant_projects() public view {
        uint256 n = builders.nextId();
        uint256 seen;
        for (uint256 id = 1; id < n; id++) {
            uint256[] memory ps = builders.projectsOf(id);
            assertLe(ps.length, builders.MAX_PROJECTS_PER_BUILDER(), "project cap exceeded");
            uint256 active;
            for (uint256 k; k < ps.length; k++) {
                (uint256 bid,, bool act,) = builders.projects(ps[k]);
                assertEq(bid, id, "project listed under the wrong builder");
                assertTrue(ps[k] > 0 && ps[k] < builders.nextProjectId(), "project id out of range");
                assertEq(act, h.gProjectActive(ps[k]), "project active drift");
                if (act) active++;
            }
            assertEq(builders.activeProjectCount(id), active, "activeProjectCount != active projects");
            assertEq(builders.hasActiveProject(id), active > 0, "hasActiveProject drift");
            seen += ps.length;
        }
        assertEq(seen, builders.nextProjectId() - 1, "a project is listed under no builder / twice");
        assertEq(builders.activeProjectCount(0), 0, "id 0 has projects");
    }

    // ───────────────────────── caretaker ─────────────────────────

    /// payoutOf is either the current owner or a payout the CURRENT owner set;
    /// caretaker only moved by setCaretaker.
    function invariant_payoutNeverFromPreviousOwner() public view {
        uint256 n = builders.nextId();
        for (uint256 id = 0; id <= n; id++) {
            address o = builders.ownerOf(id);
            address p = caretakers.payoutOf(id);
            (address raw, address setBy) = caretakers.payoutRecord(id);
            assertEq(raw, h.gPayout(id), "payout moved outside setPayout");
            assertEq(setBy, h.gPayoutSetter(id), "payout setter drift");
            if (p != o) {
                assertEq(setBy, o, "payoutOf returned an address set by a non-owner");
                assertEq(p, raw, "payoutOf is neither owner nor stored payout");
            }
            if (raw != address(0) && setBy != o) assertEq(p, o, "stale payout honoured");
            assertEq(caretakers.caretakerOf(id), h.gCaretaker(id), "caretaker moved outside setCaretaker");
        }
    }

    // ───────────────────────── badge ─────────────────────────

    /// serialOf / builderOf are mutual inverses; live serials exist, retired
    /// ones are burned; lapsed only moved by setLapsed; the holder is the owner
    /// or a wallet that owned that builder before (awaiting sync).
    function invariant_badgeBookkeeping() public view {
        uint256 ns = badge.nextSerial();
        uint256 live;
        for (uint256 s = 1; s < ns; s++) {
            uint256 bid = badge.builderOf(s);
            if (bid == 0) {
                assertEq(badge.issuedAt(s), 0, "retired serial keeps issuedAt");
                (bool okCall,) = address(badge).staticcall(abi.encodeCall(badge.ownerOf, (s)));
                assertFalse(okCall, "retired serial still owned");
                continue;
            }
            live++;
            assertEq(badge.serialOf(bid), s, "serialOf(builderOf(s)) != s");
            address holder = badge.ownerOf(s);
            assertTrue(h.everOwned(bid, holder), "badge held by a wallet that never owned the builder");
            assertEq(badge.lapsed(s), h.gLapsed(s), "lapsed moved outside setLapsed");
            assertTrue(badge.locked(s), "not locked");
            assertEq(badge.getApproved(s), address(0), "approval exists");
            // metadata stays renderable for every live badge
            bytes memory uri = bytes(badge.tokenURI(s));
            assertGt(uri.length, 29, "empty tokenURI");
        }
        uint256 n = builders.nextId();
        uint256 withSerial;
        for (uint256 id = 0; id <= n; id++) {
            uint256 s = badge.serialOf(id);
            if (s != 0) {
                withSerial++;
                assertEq(badge.builderOf(s), id, "builderOf(serialOf(id)) != id");
                assertLt(s, ns, "serial beyond nextSerial");
            }
        }
        assertEq(withSerial, live, "live serial count mismatch");
        assertEq(badge.serialOf(0), 0, "builder 0 has a badge");
        assertEq(badge.imageBase(), h.gImageBase(), "imageBase moved outside setBases");
        assertEq(badge.externalBase(), h.gExternalBase(), "externalBase moved outside setBases");
        assertEq(badge.chainLabel(), "Arc Mainnet", "chainLabel changed");
        // balanceOf sums to live supply across the actor pool (every holder is an actor)
        uint256 sum;
        uint256 na = h.actorCount();
        for (uint256 k; k < na; k++) {
            sum += badge.balanceOf(h.actors(k));
        }
        assertEq(sum, live, "balances do not sum to live supply");
    }

    /// After everyone's badge is synced: each holder is the registry owner and
    /// no wallet holds more than one badge. (Snapshot: the sync is not kept.)
    function invariant_afterSyncAll_holderIsOwner_balanceLeOne() public {
        uint256 snap = vm.snapshotState();
        uint256 n = builders.nextId();
        for (uint256 id = 1; id < n; id++) {
            if (badge.serialOf(id) != 0) badge.sync(id);
        }
        for (uint256 id = 1; id < n; id++) {
            uint256 s = badge.serialOf(id);
            if (s != 0) assertEq(badge.ownerOf(s), builders.ownerOf(id), "holder != owner after sync");
        }
        uint256 na = h.actorCount();
        for (uint256 k; k < na; k++) {
            assertLe(badge.balanceOf(h.actors(k)), 1, "a wallet holds >1 badge after sync");
        }
        vm.revertToState(snap);
    }

    /// INV_COVERAGE=1 prints how many calls of each kind SUCCEEDED per run, to
    /// show the fuzzer reaches deep states (not just reverts).
    function afterInvariant() public {
        if (!vm.envOr("INV_COVERAGE", false)) return;
        string[22] memory k = [
            "registerBuilder", "registerBuilderWithProject", "registerFor", "updateProfile", "linkIdentity",
            "setActive", "addProject", "addProjectFor", "removeProject", "setProjectActive", "proposeOwner",
            "acceptOwnership", "startRecovery", "cancelRecovery", "finishRecovery", "setCaretaker", "setPayout",
            "issue", "revoke", "setLapsed", "setBases", "sync"
        ];
        string memory line = "ok:";
        for (uint256 i; i < k.length; i++) {
            line = string.concat(line, " ", k[i], "=", vm.toString(h.ok(keccak256(bytes(k[i])))));
        }
        emit log(string.concat(line, " builders=", vm.toString(builders.nextId() - 1), " serials=", vm.toString(badge.nextSerial() - 1)));
    }

    /// Role holder sets are exactly the mainnet layout, modulo the Safe
    /// rotating the onboarder and self-renounces by non-Safe holders.
    function invariant_roleLayout() public view {
        bytes32 da = 0x00;
        assertTrue(builders.hasRole(da, safe) && builders.hasRole(builders.REGISTRAR_ROLE(), safe), "safe lost BR roles");
        assertTrue(caretakers.hasRole(da, safe) && caretakers.hasRole(caretakers.GOVERNOR_ROLE(), safe), "safe lost CR roles");
        assertTrue(badge.hasRole(da, safe) && badge.hasRole(badge.REVOKER_ROLE(), safe), "safe lost badge roles");
        uint256 na = h.actorCount();
        for (uint256 k; k < na; k++) {
            address a = h.actors(k);
            if (a == safe) continue;
            assertFalse(builders.hasRole(da, a) || caretakers.hasRole(da, a) || badge.hasRole(da, a), "admin escalated");
            assertFalse(builders.hasRole(builders.REGISTRAR_ROLE(), a), "registrar escalated");
            assertFalse(badge.hasRole(badge.REVOKER_ROLE(), a), "revoker escalated");
            if (a != onboarder) {
                assertFalse(badge.hasRole(badge.ISSUER_ROLE(), a), "issuer escalated");
                assertFalse(caretakers.hasRole(caretakers.GOVERNOR_ROLE(), a), "governor escalated");
            }
            if (a != operator) assertFalse(badge.hasRole(badge.STATUS_ROLE(), a), "status escalated");
        }
        assertFalse(badge.hasRole(da, deployer) || caretakers.hasRole(da, deployer), "deployer holds admin");
    }
}
