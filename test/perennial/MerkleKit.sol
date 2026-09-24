// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Test helper: a merkle tree with OpenZeppelin's sorted-pair hashing
/// (MerkleProof.verify). Odd nodes are carried up a level unchanged.
library MerkleKit {
    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _up(bytes32[] memory layer) private pure returns (bytes32[] memory next) {
        next = new bytes32[]((layer.length + 1) / 2);
        for (uint256 i; i < next.length; i++) {
            next[i] = 2 * i + 1 < layer.length ? hashPair(layer[2 * i], layer[2 * i + 1]) : layer[2 * i];
        }
    }

    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[] memory layer = leaves;
        while (layer.length > 1) {
            layer = _up(layer);
        }
        return layer[0];
    }

    function proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory p) {
        bytes32[] memory buf = new bytes32[](64);
        uint256 n;
        bytes32[] memory layer = leaves;
        while (layer.length > 1) {
            uint256 sib = index ^ 1;
            if (sib < layer.length) buf[n++] = layer[sib];
            layer = _up(layer);
            index /= 2;
        }
        p = new bytes32[](n);
        for (uint256 i; i < n; i++) {
            p[i] = buf[i];
        }
    }
}
