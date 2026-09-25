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
        assertEq(h.keyOf("github:a_b/c.d"), keccak256("github:a_b/c.d"));
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
        string memory s = string.concat("domain:", _repeat("a", 122)); // 129 bytes
        vm.expectRevert(SourceKey.NotCanonical.selector);
        h.keyOf(s);
        assertEq(h.keyOf(string.concat("domain:", _repeat("a", 121))), keccak256(bytes(string.concat("domain:", _repeat("a", 121)))));
    }

    function _repeat(string memory c, uint256 n) internal pure returns (string memory out) {
        for (uint256 i; i < n; ++i) out = string.concat(out, c);
    }
}
