// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SourceKey} from "../../src/perennial/SourceKey.sol";
import {SourceKeyHarness} from "./SourceKey.t.sol";

/// GENERATED from frontend/src/lib/__fixtures__/verified-builder-vectors.json (the
/// site's normalizeSource vectors): every source the site produces is canonical on
/// chain, and every github:/domain: string the site refuses is refused here too, so
/// the keeper, the site and the escrow agree on one key per project. The vectors'
/// test-only hosts (domain:localhost / 127.0.0.1, allowed by the site only under a
/// test override) are left out: on chain they are never canonical.
contract SourceKeyVectorsTest is Test {
    SourceKeyHarness h = new SourceKeyHarness();

    function test_siteCanonicalSourcesAreCanonical() public view {
        string[8] memory good = [
            string("domain:app.example.org"),
            "github:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/repo",
            "github:my-org-1/repo",
            "github:owner/.x..y.",
            "github:owner/my.repo_name-1",
            "github:owner/repo",
            "github:owner/rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr",
            "github:registrai-multichain/oracle-primitives"
        ];
        for (uint256 i; i < good.length; ++i) {
            assertEq(h.keyOf(good[i]), keccak256(bytes(good[i])));
        }
    }

    function test_siteRejectedSourcesAreRejected() public {
        string[8] memory bad = [
            string("domain:app.example.org:443"),
            "github:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/repo",
            "github:ow--ner/repo",
            "github:owner-/repo",
            "github:owner/.",
            "github:owner/..",
            "github:owner/repo.git",
            "github:owner/rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr"
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(SourceKey.NotCanonical.selector);
            h.keyOf(bad[i]);
        }
    }
}
