// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Halmos symbolic checks for mainnet phase 1. `check_*` functions are proven
/// for ALL inputs (within the loop bounds), not sampled:
///   halmos --contract HalmosPhaseOne --loop 16 --solver-timeout-assertion 0
/// They also run as ordinary fuzz tests under `forge test` (prefix test_ via
/// the wrappers at the bottom are not needed: forge ignores check_*).

import {Test} from "forge-std/Test.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";
import {VerifiedBuilderBadge} from "../../src/perennial/VerifiedBuilderBadge.sol";

contract EscapeProbe is VerifiedBuilderBadge {
    constructor(BuilderRegistry b) VerifiedBuilderBadge(b, address(1), address(2), "", "", "") {}

    function escape(string memory s) external pure returns (string memory) {
        return _escape(s);
    }
}

contract HalmosPhaseOne is Test {
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    VerifiedBuilderBadge badge;
    EscapeProbe probe;

    address constant SAFE = address(0x5AFE);
    address constant OPERATOR = address(0x0FE8);
    address constant ALICE = address(0xA11CE);
    uint256 aliceId;
    uint256 serial;

    function setUp() public {
        builders = new BuilderRegistry(SAFE);
        caretakers = new CaretakerRegistry(builders, SAFE);
        badge = new VerifiedBuilderBadge(builders, SAFE, OPERATOR, "Arc Mainnet", "i/", "e/");
        probe = new EscapeProbe(builders);
        vm.prank(ALICE);
        (aliceId,) = builders.registerBuilderWithProject("p", "github:a/b");
        vm.prank(SAFE);
        serial = badge.issue(aliceId);
    }

    // ───────────────────────── JSON escaping ─────────────────────────

    function _hex(bytes1 c) internal pure returns (bool ok, uint8 v) {
        uint8 x = uint8(c);
        if (x >= 0x30 && x <= 0x39) return (true, x - 0x30);
        if (x >= 0x61 && x <= 0x66) return (true, x - 0x61 + 10);
        return (false, 0);
    }

    /// Parses `out` as the body of a JSON string ("..." without the quotes)
    /// and returns the decoded bytes; reverts-by-assert on anything a JSON
    /// parser would reject or that could terminate the string early.
    function _jsonDecode(bytes memory out) internal pure returns (bytes memory dec) {
        dec = new bytes(out.length);
        uint256 n;
        uint256 i;
        while (i < out.length) {
            bytes1 c = out[i];
            assert(c != '"'); // an unescaped quote would close the string
            assert(uint8(c) >= 0x20); // raw control chars are invalid JSON
            if (c == "\\") {
                assert(i + 1 < out.length);
                bytes1 e = out[i + 1];
                if (e == '"' || e == "\\") {
                    dec[n++] = e;
                    i += 2;
                } else {
                    assert(e == "u" && i + 5 < out.length);
                    (bool o1, uint8 h1) = _hex(out[i + 2]);
                    (bool o2, uint8 h2) = _hex(out[i + 3]);
                    (bool o3, uint8 h3) = _hex(out[i + 4]);
                    (bool o4, uint8 h4) = _hex(out[i + 5]);
                    assert(o1 && o2 && o3 && o4 && h1 == 0 && h2 == 0);
                    dec[n++] = bytes1(h3 * 16 + h4);
                    i += 6;
                }
            } else {
                dec[n++] = c;
                i += 1;
            }
        }
        assembly {
            mstore(dec, n)
        }
    }

    /// For every 6-byte admin string: the escaped form is a valid JSON string
    /// body (no early quote, no raw control char, only \" \\ \u00XX escapes)
    /// and decodes back to exactly the input.
    function check_escape_roundTrips(bytes6 raw) public view {
        bytes memory s = abi.encodePacked(raw);
        bytes memory out = bytes(probe.escape(string(s)));
        bytes memory dec = _jsonDecode(out);
        assert(keccak256(dec) == keccak256(s));
    }

    /// Adversarial shape: a quote/backslash-heavy prefix plus symbolic bytes.
    function check_escape_injectionShape(bytes4 raw) public view {
        bytes memory s = abi.encodePacked('\\"},{', raw);
        bytes memory out = bytes(probe.escape(string(s)));
        bytes memory dec = _jsonDecode(out);
        assert(keccak256(dec) == keccak256(s));
    }

    // ───────────────────────── soulbound ─────────────────────────

    /// No caller can move the badge to any address by any transfer path.
    function check_soulbound_noTransfer(address caller, address to, uint8 path, bytes memory data) public {
        vm.assume(to != address(0));
        vm.prank(caller);
        bool ok;
        if (path % 3 == 0) {
            (ok,) = address(badge).call(abi.encodeCall(badge.transferFrom, (ALICE, to, serial)));
        } else if (path % 3 == 1) {
            (ok,) = address(badge).call(
                abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", ALICE, to, serial)
            );
        } else {
            (ok,) = address(badge).call(
                abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", ALICE, to, serial, data)
            );
        }
        assert(!ok);
        assert(badge.ownerOf(serial) == ALICE);
        assert(badge.balanceOf(ALICE) == 1);
    }

    function check_soulbound_noApproval(address caller, address to, bool all) public {
        vm.prank(caller);
        (bool ok,) = all
            ? address(badge).call(abi.encodeCall(badge.setApprovalForAll, (to, true)))
            : address(badge).call(abi.encodeCall(badge.approve, (to, serial)));
        assert(!ok);
    }

    /// sync by anyone never moves a badge that already sits with its owner.
    function check_sync_noopWhenSynced(address caller) public {
        vm.prank(caller);
        badge.sync(aliceId);
        assert(badge.ownerOf(serial) == ALICE);
    }

    // ───────────────────────── recovery ─────────────────────────

    /// finishRecovery succeeds iff at least RECOVERY_DELAY passed, and then
    /// moves the builder exactly to the chosen wallet.
    function check_recovery_delayBoundary(uint32 dt, address caller, address newOwner) public {
        vm.assume(newOwner != address(0) && newOwner != ALICE);
        vm.prank(SAFE);
        builders.startRecovery(aliceId, newOwner);
        vm.warp(block.timestamp + dt);
        vm.prank(caller);
        (bool ok,) = address(builders).call(abi.encodeCall(builders.finishRecovery, (aliceId)));
        assert(ok == (dt >= 7 days));
        assert(builders.ownerOf(aliceId) == (ok ? newOwner : ALICE));
    }

    /// Only the owner or the REGISTRAR can cancel a recovery.
    function check_recovery_cancelOnlyOwnerOrRegistrar(address caller) public {
        vm.prank(SAFE);
        builders.startRecovery(aliceId, address(0xBEEF));
        vm.prank(caller);
        (bool ok,) = address(builders).call(abi.encodeCall(builders.cancelRecovery, (aliceId)));
        assert(ok == (caller == ALICE || caller == SAFE));
    }

    // ───────────────────────── payout ─────────────────────────

    /// After ANY owner change, a payout set by the old owner is never returned.
    function check_payout_fallsBackAfterTransfer(address p, address newOwner) public {
        vm.assume(p != address(0) && newOwner != address(0) && newOwner != ALICE);
        vm.prank(ALICE);
        caretakers.setPayout(aliceId, p);
        vm.prank(ALICE);
        builders.proposeOwner(newOwner);
        vm.prank(newOwner);
        builders.acceptOwnership(aliceId);
        assert(caretakers.payoutOf(aliceId) == newOwner);
    }

    /// Only the current owner can set a payout.
    function check_payout_onlyOwner(address caller, address p) public {
        vm.assume(p != address(0));
        vm.prank(caller);
        (bool ok,) = address(caretakers).call(abi.encodeCall(caretakers.setPayout, (aliceId, p)));
        assert(ok == (caller == ALICE));
    }
}
