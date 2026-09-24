// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BuilderFund} from "../../src/perennial/BuilderFund.sol";

/// @notice The launch tax schedule of the BuilderFund (spec
/// 2026-09-24-builder-income-tax-design), per builder per epoch, 6-dec USDC:
/// 0% to $1,000; 10% to $10,000; 20% to $50,000; 30% above.
library LaunchSchedule {
    function brackets() internal pure returns (BuilderFund.Bracket[] memory b) {
        b = new BuilderFund.Bracket[](4);
        b[0] = BuilderFund.Bracket({upTo: 1_000e6, rateBps: 0});
        b[1] = BuilderFund.Bracket({upTo: 10_000e6, rateBps: 1000});
        b[2] = BuilderFund.Bracket({upTo: 50_000e6, rateBps: 2000});
        b[3] = BuilderFund.Bracket({upTo: type(uint128).max, rateBps: 3000});
    }
}
