// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SourceKey. The on-chain key of a project source.
/// @notice A canonical source is exactly what the site's normalizeSource produces
/// (frontend/src/lib/verified-builders.ts), so one project can never be split
/// across spellings:
///   github:<owner>/<repo>  owner [a-z0-9](-?[a-z0-9])*, <= 39 chars (no leading,
///                          trailing or double hyphen); repo [a-z0-9._-]{1,100}, not "." or
///                          "..", not ending in ".git"
///   domain:<host>          >= 2 labels [a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?, the
///                          last label not all digits (no IP, no trailing dot)
/// at most 128 bytes (BuilderRegistry.MAX_SOURCE_LEN). Key = keccak256(bytes(source)).
library SourceKey {
    error NotCanonical();

    uint256 internal constant MAX_LEN = 128;
    uint256 internal constant PREFIX = 7; // "github:" / "domain:"

    function keyOf(string memory source) internal pure returns (bytes32) {
        bytes memory b = bytes(source);
        uint256 n = b.length;
        if (n <= PREFIX || n > MAX_LEN) revert NotCanonical();
        if (_prefix(b, "github:")) {
            _github(b, n);
        } else if (_prefix(b, "domain:")) {
            _domain(b, n);
        } else {
            revert NotCanonical();
        }
        return keccak256(b);
    }

    function _github(bytes memory b, uint256 n) private pure {
        uint256 slash;
        for (uint256 i = PREFIX; i < n; ++i) {
            if (b[i] == "/") {
                if (slash != 0) revert NotCanonical();
                slash = i;
            }
        }
        if (slash == 0) revert NotCanonical();
        // owner: [a-z0-9](-?[a-z0-9])*, at most 39 characters (GitHub's limit)
        if (slash == PREFIX || slash - PREFIX > 39) revert NotCanonical();
        for (uint256 i = PREFIX; i < slash; ++i) {
            bytes1 c = b[i];
            if (c == "-") {
                if (i == PREFIX || i == slash - 1 || b[i + 1] == "-") revert NotCanonical();
            } else if (!_alnum(c)) {
                revert NotCanonical();
            }
        }
        // repo: [a-z0-9._-]{1,100}, not "." / "..", not ending ".git"
        uint256 len = n - slash - 1;
        if (len == 0 || len > 100) revert NotCanonical();
        for (uint256 i = slash + 1; i < n; ++i) {
            bytes1 c = b[i];
            if (!_alnum(c) && c != "." && c != "_" && c != "-") revert NotCanonical();
        }
        if (len == 1 && b[n - 1] == ".") revert NotCanonical();
        if (len == 2 && b[n - 1] == "." && b[n - 2] == ".") revert NotCanonical();
        if (len >= 4 && b[n - 4] == "." && b[n - 3] == "g" && b[n - 2] == "i" && b[n - 1] == "t") revert NotCanonical();
    }

    function _domain(bytes memory b, uint256 n) private pure {
        uint256 labels;
        uint256 start = PREFIX;
        bool allDigits;
        for (uint256 i = PREFIX; i <= n; ++i) {
            if (i == n || b[i] == ".") {
                uint256 len = i - start;
                if (len == 0 || len > 63) revert NotCanonical();
                if (b[start] == "-" || b[i - 1] == "-") revert NotCanonical();
                allDigits = true;
                for (uint256 j = start; j < i; ++j) {
                    bytes1 c = b[j];
                    if (!_alnum(c) && c != "-") revert NotCanonical();
                    if (c < "0" || c > "9") allDigits = false;
                }
                ++labels;
                start = i + 1;
            }
        }
        if (labels < 2 || allDigits) revert NotCanonical();
    }

    function _alnum(bytes1 c) private pure returns (bool) {
        return (c >= "a" && c <= "z") || (c >= "0" && c <= "9");
    }

    function _prefix(bytes memory b, bytes memory p) private pure returns (bool) {
        for (uint256 i; i < p.length; ++i) {
            if (b[i] != p[i]) return false;
        }
        return true;
    }
}
