// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Echidna property harness for mainnet phase 1 (BuilderRegistry +
/// CaretakerRegistry + VerifiedBuilderBadge), deployed with the mainnet role
/// layout. Actors are proxy contracts so the Safe, the operator, the onboarder
/// and users are distinct callers; echidna's own senders only choose which
/// actor acts. Echidna warps time between calls (maxTimeDelay), which drives
/// the 7-day recovery.
///
///   echidna test/audit/echidna/PhaseOneEchidna.sol --contract PhaseOneEchidna \
///     --config test/audit/echidna/echidna.yaml
/// (see echidna.yaml for the solc/remapping args).

import {BuilderRegistry} from "../../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../../src/perennial/CaretakerRegistry.sol";
import {VerifiedBuilderBadge} from "../../../src/perennial/VerifiedBuilderBadge.sol";

contract EchidnaActor {
    function exec(address target, bytes calldata data) external returns (bool ok, bytes memory ret) {
        (ok, ret) = target.call(data);
    }
}

contract PhaseOneEchidna {
    BuilderRegistry public builders;
    CaretakerRegistry public caretakers;
    VerifiedBuilderBadge public badge;

    EchidnaActor[] internal actors; // 0 safe, 1 operator, 2 onboarder, 3.. users
    uint256 internal constant N = 10;

    // violations
    bool internal soulboundBroken;
    bool internal serialReused;
    bool internal earlyRecovery;
    bool internal hijackedRecovery;
    bool internal unauthorized;

    // ghosts
    mapping(uint256 => bool) internal serialSeen;
    mapping(uint256 => address) internal recTo;
    mapping(uint256 => uint256) internal recStart;
    mapping(uint256 => mapping(address => bool)) internal everOwned;

    constructor() {
        for (uint256 i; i < N; i++) {
            actors.push(new EchidnaActor());
        }
        address safe = address(actors[0]);
        address operator = address(actors[1]);
        address onboarder = address(actors[2]);
        // DeployBuilders' mainnet path; this harness plays the deployer.
        builders = new BuilderRegistry(safe);
        caretakers = new CaretakerRegistry(builders, address(this));
        caretakers.grantRole(0x00, safe);
        caretakers.grantRole(caretakers.GOVERNOR_ROLE(), safe);
        caretakers.grantRole(caretakers.GOVERNOR_ROLE(), onboarder);
        caretakers.renounceRole(caretakers.GOVERNOR_ROLE(), address(this));
        caretakers.renounceRole(0x00, address(this));
        badge = new VerifiedBuilderBadge(
            builders,
            address(this),
            operator,
            "Arc Mainnet",
            "https://builder.registrai.cc/badge/arc/",
            "https://builder.registrai.cc/builders/?builder="
        );
        badge.grantRole(0x00, safe);
        badge.grantRole(badge.ISSUER_ROLE(), safe);
        badge.grantRole(badge.REVOKER_ROLE(), safe);
        badge.grantRole(badge.ISSUER_ROLE(), onboarder);
        badge.renounceRole(badge.ISSUER_ROLE(), address(this));
        badge.renounceRole(badge.REVOKER_ROLE(), address(this));
        badge.renounceRole(0x00, address(this));
    }

    // ───────────────────────── helpers ─────────────────────────

    function _a(uint8 i) internal view returns (EchidnaActor) {
        return actors[i % N];
    }

    function _id(uint256 i) internal view returns (uint256) {
        return i % (builders.nextId() + 1);
    }

    function _src(uint8 len) internal pure returns (string memory) {
        bytes memory b = new bytes(len % 140);
        for (uint256 i; i < b.length; i++) {
            b[i] = bytes1(uint8(0x61 + (i % 26)));
        }
        return string(b);
    }

    function _do(uint8 who, address target, bytes memory data) internal returns (bool ok, bytes memory ret) {
        return _a(who).exec(target, data);
    }

    // ───────────────────────── registry ─────────────────────────

    function registerBuilder(uint8 who) external {
        (bool ok, bytes memory r) = _do(who, address(builders), abi.encodeCall(builders.registerBuilder, ("p")));
        if (ok) everOwned[abi.decode(r, (uint256))][address(_a(who))] = true;
    }

    function registerBuilderWithProject(uint8 who, uint8 len) external {
        (bool ok, bytes memory r) =
            _do(who, address(builders), abi.encodeCall(builders.registerBuilderWithProject, ("p", _src(len))));
        if (ok) {
            (uint256 id,) = abi.decode(r, (uint256, uint256));
            everOwned[id][address(_a(who))] = true;
        }
    }

    function registerFor(uint8 who, uint8 target) external {
        bool auth = builders.hasRole(builders.REGISTRAR_ROLE(), address(_a(who)));
        (bool ok, bytes memory r) =
            _do(who, address(builders), abi.encodeCall(builders.registerFor, (address(_a(target)), "p")));
        if (ok) {
            if (!auth) unauthorized = true;
            everOwned[abi.decode(r, (uint256))][address(_a(target))] = true;
        }
    }

    function setActive(uint8 who, uint256 id, bool v) external {
        bool auth = builders.hasRole(builders.REGISTRAR_ROLE(), address(_a(who)));
        (bool ok,) = _do(who, address(builders), abi.encodeCall(builders.setActive, (_id(id), v)));
        if (ok && !auth) unauthorized = true;
    }

    function addProject(uint8 who, uint8 len) external {
        _do(who, address(builders), abi.encodeCall(builders.addProject, (_src(len))));
    }

    function addProjectFor(uint8 who, uint256 id, uint8 len) external {
        bool auth = builders.hasRole(builders.REGISTRAR_ROLE(), address(_a(who)));
        (bool ok,) = _do(who, address(builders), abi.encodeCall(builders.addProjectFor, (_id(id), _src(len))));
        if (ok && !auth) unauthorized = true;
    }

    function removeProject(uint8 who, uint256 pid) external {
        pid = pid % (builders.nextProjectId() + 1);
        (uint256 bid,,,) = builders.projects(pid);
        bool auth = bid != 0 && address(_a(who)) == builders.ownerOf(bid);
        (bool ok,) = _do(who, address(builders), abi.encodeCall(builders.removeProject, (pid)));
        if (ok && !auth) unauthorized = true;
    }

    function setProjectActive(uint8 who, uint256 pid, bool v) external {
        bool auth = builders.hasRole(builders.REGISTRAR_ROLE(), address(_a(who)));
        pid = pid % (builders.nextProjectId() + 1);
        (bool ok,) = _do(who, address(builders), abi.encodeCall(builders.setProjectActive, (pid, v)));
        if (ok && !auth) unauthorized = true;
    }

    function proposeOwner(uint8 who, uint8 to, bool cancel) external {
        address t = cancel ? address(0) : address(_a(to));
        _do(who, address(builders), abi.encodeCall(builders.proposeOwner, (t)));
    }

    function acceptOwnership(uint8 who, uint256 id) external {
        id = _id(id);
        bool auth = builders.pendingOwner(id) == address(_a(who));
        (bool ok,) = _do(who, address(builders), abi.encodeCall(builders.acceptOwnership, (id)));
        if (ok) {
            if (!auth) unauthorized = true;
            everOwned[id][address(_a(who))] = true;
            recTo[id] = address(0);
        }
    }

    function startRecovery(uint8 who, uint256 id, uint8 to) external {
        id = _id(id);
        bool auth = builders.hasRole(builders.REGISTRAR_ROLE(), address(_a(who)));
        (bool ok,) = _do(who, address(builders), abi.encodeCall(builders.startRecovery, (id, address(_a(to)))));
        if (ok) {
            if (!auth) unauthorized = true;
            recTo[id] = address(_a(to));
            recStart[id] = block.timestamp;
        }
    }

    function cancelRecovery(uint8 who, uint256 id) external {
        id = _id(id);
        address w = address(_a(who));
        bool auth = w == builders.ownerOf(id) || builders.hasRole(builders.REGISTRAR_ROLE(), w);
        (bool ok,) = _do(who, address(builders), abi.encodeCall(builders.cancelRecovery, (id)));
        if (ok) {
            if (!auth) unauthorized = true;
            recTo[id] = address(0);
        }
    }

    function finishRecovery(uint8 who, uint256 id) external {
        id = _id(id);
        address expected = recTo[id];
        uint256 started = recStart[id];
        (bool ok,) = _do(who, address(builders), abi.encodeCall(builders.finishRecovery, (id)));
        if (ok) {
            if (expected == address(0) || builders.ownerOf(id) != expected) hijackedRecovery = true;
            if (block.timestamp < started + 7 days) earlyRecovery = true;
            everOwned[id][builders.ownerOf(id)] = true;
            recTo[id] = address(0);
        }
    }

    // ───────────────────────── caretaker ─────────────────────────

    function setCaretaker(uint8 who, uint256 id, uint8 op) external {
        bool auth = caretakers.hasRole(caretakers.GOVERNOR_ROLE(), address(_a(who)));
        (bool ok,) = _do(who, address(caretakers), abi.encodeCall(caretakers.setCaretaker, (_id(id), address(_a(op)))));
        if (ok && !auth) unauthorized = true;
    }

    function setPayout(uint8 who, uint256 id, uint8 p) external {
        id = _id(id);
        bool auth = address(_a(who)) == builders.ownerOf(id);
        (bool ok,) = _do(
            who, address(caretakers), abi.encodeCall(caretakers.setPayout, (id, address(uint160(0xFA00 + (p % 5)))))
        );
        if (ok && !auth) unauthorized = true;
    }

    // ───────────────────────── badge ─────────────────────────

    function issue(uint8 who, uint256 id) external {
        bool auth = badge.hasRole(badge.ISSUER_ROLE(), address(_a(who)));
        (bool ok, bytes memory r) = _do(who, address(badge), abi.encodeCall(badge.issue, (_id(id))));
        if (ok) {
            if (!auth) unauthorized = true;
            uint256 s = abi.decode(r, (uint256));
            if (serialSeen[s]) serialReused = true;
            serialSeen[s] = true;
        }
    }

    function revoke(uint8 who, uint256 id) external {
        bool auth = badge.hasRole(badge.REVOKER_ROLE(), address(_a(who)));
        (bool ok,) = _do(who, address(badge), abi.encodeCall(badge.revoke, (_id(id))));
        if (ok && !auth) unauthorized = true;
    }

    function setLapsed(uint8 who, uint256 id, bool v) external {
        bool auth = badge.hasRole(badge.STATUS_ROLE(), address(_a(who)));
        (bool ok,) = _do(who, address(badge), abi.encodeCall(badge.setLapsed, (_id(id), v)));
        if (ok && !auth) unauthorized = true;
    }

    function setBases(uint8 who, uint8 len) external {
        bool auth = badge.hasRole(0x00, address(_a(who)));
        (bool ok,) = _do(who, address(badge), abi.encodeCall(badge.setBases, (_src(len), "\"q\\")));
        if (ok && !auth) unauthorized = true;
    }

    function sync(uint8 who, uint256 id) external {
        _do(who, address(badge), abi.encodeCall(badge.sync, (_id(id))));
    }

    function tryTransfer(uint8 who, uint256 serial, uint8 to, uint8 path) external {
        serial = serial % (badge.nextSerial() + 1);
        address holder;
        try badge.ownerOf(serial) returns (address h) {
            holder = h;
        } catch {
            return;
        }
        // act as the real holder half the time
        EchidnaActor actor = _a(who);
        for (uint256 k; k < N && path % 2 == 0; k++) {
            if (address(actors[k]) == holder) actor = actors[k];
        }
        address dst = address(_a(to));
        bytes memory data;
        uint8 p = path % 5;
        if (p == 0) data = abi.encodeCall(badge.transferFrom, (holder, dst, serial));
        else if (p == 1) data = abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", holder, dst, serial);
        else if (p == 2) data = abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", holder, dst, serial, "");
        else if (p == 3) data = abi.encodeCall(badge.approve, (dst, serial));
        else data = abi.encodeCall(badge.setApprovalForAll, (dst, true));
        (bool ok,) = actor.exec(address(badge), data);
        if (ok) soulboundBroken = true;
    }

    function grantRole(uint8 who, uint8 target, uint8 r, uint8 acct) external {
        if (who % N == 0) return; // only non-admins
        address t = target % 3 == 0 ? address(builders) : target % 3 == 1 ? address(caretakers) : address(badge);
        bytes32[6] memory rs = [
            bytes32(0x00),
            builders.REGISTRAR_ROLE(),
            caretakers.GOVERNOR_ROLE(),
            badge.ISSUER_ROLE(),
            badge.STATUS_ROLE(),
            badge.REVOKER_ROLE()
        ];
        (bool ok,) = _do(who, t, abi.encodeWithSignature("grantRole(bytes32,address)", rs[r % 6], address(_a(acct))));
        if (ok) unauthorized = true;
    }

    // ───────────────────────── properties ─────────────────────────

    function echidna_soulbound() external view returns (bool) {
        return !soulboundBroken;
    }

    function echidna_serials_never_reused() external view returns (bool) {
        return !serialReused;
    }

    function echidna_recovery_not_early_nor_hijacked() external view returns (bool) {
        return !earlyRecovery && !hijackedRecovery;
    }

    function echidna_only_role_holders() external view returns (bool) {
        return !unauthorized;
    }

    function echidna_one_builder_per_address() external view returns (bool) {
        uint256 n = builders.nextId();
        for (uint256 id = 1; id < n; id++) {
            address o = builders.ownerOf(id);
            if (o == address(0) || builders.builderIdOf(o) != id) return false;
        }
        for (uint256 k; k < N; k++) {
            uint256 id = builders.builderIdOf(address(actors[k]));
            if (id != 0 && builders.ownerOf(id) != address(actors[k])) return false;
        }
        return true;
    }

    function echidna_project_counts() external view returns (bool) {
        uint256 n = builders.nextId();
        for (uint256 id = 1; id < n; id++) {
            uint256[] memory ps = builders.projectsOf(id);
            if (ps.length > 16) return false;
            uint256 active;
            for (uint256 k; k < ps.length; k++) {
                (uint256 bid,, bool act,) = builders.projects(ps[k]);
                if (bid != id) return false;
                if (act) active++;
            }
            if (active != builders.activeProjectCount(id)) return false;
        }
        return true;
    }

    function echidna_payout_never_from_previous_owner() external view returns (bool) {
        uint256 n = builders.nextId();
        for (uint256 id; id <= n; id++) {
            address o = builders.ownerOf(id);
            address p = caretakers.payoutOf(id);
            (address raw, address setBy) = caretakers.payoutRecord(id);
            if (p != o && (setBy != o || p != raw)) return false;
        }
        return true;
    }

    function echidna_badge_bookkeeping() external view returns (bool) {
        uint256 ns = badge.nextSerial();
        uint256 live;
        for (uint256 s = 1; s < ns; s++) {
            uint256 bid = badge.builderOf(s);
            if (bid == 0) continue;
            live++;
            if (badge.serialOf(bid) != s) return false;
            address h = badge.ownerOf(s);
            if (!everOwned[bid][h]) return false; // held by an owner, current or awaiting sync
        }
        uint256 sum;
        for (uint256 k; k < N; k++) {
            sum += badge.balanceOf(address(actors[k]));
        }
        return sum == live;
    }

    /// When every badge sits with its current owner, nobody holds two.
    function echidna_synced_implies_balance_le_one() external view returns (bool) {
        uint256 n = builders.nextId();
        for (uint256 id = 1; id < n; id++) {
            uint256 s = badge.serialOf(id);
            if (s != 0 && badge.ownerOf(s) != builders.ownerOf(id)) return true; // not all synced: vacuous
        }
        for (uint256 k; k < N; k++) {
            if (badge.balanceOf(address(actors[k])) > 1) return false;
        }
        return true;
    }

    function echidna_roles_fixed() external view returns (bool) {
        for (uint256 k = 1; k < N; k++) {
            address a = address(actors[k]);
            if (builders.hasRole(0x00, a) || caretakers.hasRole(0x00, a) || badge.hasRole(0x00, a)) return false;
            if (builders.hasRole(builders.REGISTRAR_ROLE(), a) || badge.hasRole(badge.REVOKER_ROLE(), a)) return false;
        }
        return true;
    }
}
