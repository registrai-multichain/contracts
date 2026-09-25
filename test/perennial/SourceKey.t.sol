// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SourceKey} from "../../src/perennial/SourceKey.sol";

contract SourceKeyHarness {
    function keyOf(string memory s) external pure returns (bytes32) {
        return SourceKey.keyOf(s);
    }
}

contract SourceKeyTest is Test {
    SourceKeyHarness h = new SourceKeyHarness();

    function test_acceptsCanonical() public view {
        assertEq(h.keyOf("github:foundry-rs/foundry"), keccak256("github:foundry-rs/foundry"));
        assertEq(h.keyOf("domain:registrai.cc"), keccak256("domain:registrai.cc"));
        assertEq(h.keyOf("domain:app.acme-x.dev"), keccak256("domain:app.acme-x.dev"));
        assertEq(h.keyOf("github:a-b/c.d"), keccak256("github:a-b/c.d"));
    }

    function test_rejectsNonCanonical() public {
        string[10] memory bad = [
            string("github:Foo/Bar"),
            "github:foo/bar ",
            "https://github.com/foo/bar",
            "github:foo",
            "github:foo/bar/baz",
            "domain:foo/bar",
            "domain:",
            "gitlab:foo/bar",
            "domain:exa mple.com",
            "github:/bar"
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(SourceKey.NotCanonical.selector);
            h.keyOf(bad[i]);
        }
    }

    function test_rejectsTooLong() public {
        // 128 bytes is the most a source may have (BuilderRegistry.MAX_SOURCE_LEN)
        string memory host128 = string.concat(_repeat("a", 60), ".", _repeat("b", 56), ".dev"); // 7 + 121
        assertEq(h.keyOf(string.concat("domain:", host128)), keccak256(bytes(string.concat("domain:", host128))));
        string memory host129 = string.concat(_repeat("a", 60), ".", _repeat("b", 57), ".dev");
        vm.expectRevert(SourceKey.NotCanonical.selector);
        h.keyOf(string.concat("domain:", host129));
    }

    function _repeat(string memory c, uint256 n) internal pure returns (string memory out) {
        for (uint256 i; i < n; ++i) out = string.concat(out, c);
    }
}

/// Final-review M1: exactly the site's normalizeSource grammar (verified-builders.ts):
/// github owner [a-z0-9](-?[a-z0-9])*, repo [a-z0-9._-]{1,100} not "."/".." nor ending
/// ".git"; host = >= 2 labels [a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?, TLD not all digits.
contract SourceKeyGrammarTest is Test {
    SourceKeyHarness h = new SourceKeyHarness();

    function test_rejectsWhatTheSiteRejects() public {
        string[14] memory bad = [
            string("domain:acme.dev."),
            "domain:.acme.dev",
            "domain:acme..dev",
            "domain:-acme.dev",
            "domain:acme-.dev",
            "domain:localhost",
            "domain:acme.123",
            "domain:acme_x.dev",
            "github:acme/tool.git",
            "github:-acme/tool",
            "github:acme-/tool",
            "github:ac--me/tool",
            "github:acme/..",
            "github:ac.me/tool"
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(SourceKey.NotCanonical.selector);
            h.keyOf(bad[i]);
        }
    }

    function test_acceptsWhatTheSiteAccepts() public view {
        h.keyOf("github:a-b/c.d_e-f");
        h.keyOf("github:a/.github");
        h.keyOf("domain:x.co");
        h.keyOf("domain:a-b.c-d.io");
        h.keyOf("domain:app.acme2.dev");
    }
}
