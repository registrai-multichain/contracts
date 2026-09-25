// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SourceKey. The on-chain key of a project source.
/// @notice A canonical source is `github:<owner>/<repo>` or `domain:<host>`,
/// lowercase [a-z0-9._-] (github: exactly one `/`, both parts non-empty;
/// domain: no `/`), at most 128 bytes (BuilderRegistry.MAX_SOURCE_LEN). The
/// site normalises with normalizeSource; this refuses anything else so one
/// project can never be split across spellings. Key = keccak256(bytes(source)).
library SourceKey {
    error NotCanonical();

    uint256 internal constant MAX_LEN = 128;

    function keyOf(string memory source) internal pure returns (bytes32) {
        bytes memory b = bytes(source);
        uint256 n = b.length;
        if (n <= 7 || n > MAX_LEN) revert NotCanonical();
        bool gh = _prefix(b, "github:");
        if (!gh && !_prefix(b, "domain:")) revert NotCanonical();
        uint256 slashes;
        uint256 slashAt;
        for (uint256 i = 7; i < n; ++i) {
            bytes1 c = b[i];
            if (c == "/") {
                ++slashes;
                slashAt = i;
                continue;
            }
            bool ok = (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "." || c == "-" || c == "_";
            if (!ok) revert NotCanonical();
        }
        if (gh) {
            if (slashes != 1 || slashAt == 7 || slashAt == n - 1) revert NotCanonical();
        } else if (slashes != 0) {
            revert NotCanonical();
        }
        return keccak256(b);
    }

    function _prefix(bytes memory b, bytes memory p) private pure returns (bool) {
        for (uint256 i; i < p.length; ++i) {
            if (b[i] != p[i]) return false;
        }
        return true;
    }
}
