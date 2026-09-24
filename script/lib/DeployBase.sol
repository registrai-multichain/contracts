// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";

/// @notice Shared guard rails for every mainnet-path deploy script.
///
/// - Only Arc mainnet (5042), Arc testnet (5042002) and a local anvil (31337)
///   are accepted; anything else reverts before a transaction is built.
/// - Owner decisions are read with `_uintReq` / `_addrReq` / `_strReq`: on
///   mainnet the env var MUST be set (there is no default to fall back on); on
///   testnet and local the historical default applies, so demos keep working.
/// - Each script splits `run()` (env -> Config) from a public entry that takes
///   the Config explicitly, so tests can drive the exact deployment logic
///   without touching process env.
abstract contract DeployBase is Script {
    uint256 internal constant ARC_MAINNET = 5042;
    uint256 internal constant ARC_TESTNET = 5042002;
    uint256 internal constant LOCAL = 31337;
    address internal constant ARC_USDC = 0x3600000000000000000000000000000000000000;

    function _guardChain() internal view {
        require(
            block.chainid == ARC_MAINNET || block.chainid == ARC_TESTNET || block.chainid == LOCAL,
            "unsupported chain: only Arc mainnet 5042, Arc testnet 5042002, local 31337"
        );
    }

    function _isMainnet() internal view returns (bool) {
        return block.chainid == ARC_MAINNET;
    }

    function _requireSet(string memory name) internal view {
        require(vm.envExists(name), string.concat("mainnet: required env var not set: ", name));
    }

    function _uintReq(string memory name, uint256 testnetDefault) internal view returns (uint256) {
        if (_isMainnet()) {
            _requireSet(name);
            return vm.envUint(name);
        }
        return vm.envOr(name, testnetDefault);
    }

    function _addrReq(string memory name, address testnetDefault) internal view returns (address) {
        if (_isMainnet()) {
            _requireSet(name);
            return vm.envAddress(name);
        }
        return vm.envOr(name, testnetDefault);
    }

    function _strReq(string memory name, string memory testnetDefault) internal view returns (string memory) {
        if (_isMainnet()) {
            _requireSet(name);
            return vm.envString(name);
        }
        return vm.envOr(name, testnetDefault);
    }
}
