// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";
import {BuilderFund} from "../../src/perennial/BuilderFund.sol";
import {SeasonPool} from "../../src/perennial/SeasonPool.sol";
import {LaunchSchedule} from "../../script/lib/LaunchSchedule.sol";

/// Test helper: the phase-2 income stack (SeasonPool + BuilderFund on the
/// launch schedule), admin = the calling test contract. Internal library
/// functions run in the caller's context, so the caller holds every admin role.
library FundKit {
    function deploy(NanoLedger ledger, BuilderRegistry builders, CaretakerRegistry caretakers, address treasury, uint256 epochLength)
        internal
        returns (SeasonPool pool, BuilderFund fund)
    {
        pool = new SeasonPool(ledger, builders, caretakers, address(this));
        fund = new BuilderFund(
            ledger, builders, caretakers, pool, treasury, address(this), epochLength, 0, LaunchSchedule.brackets()
        );
        pool.grantRole(pool.FUNDER_ROLE(), address(fund));
    }

    /// Make `markets` the fund's income writer.
    function wire(BuilderFund fund, address markets) internal {
        fund.grantRole(fund.MARKETS_ROLE(), markets);
    }

    /// The WonderEscrow writes income (current epoch) and late income (ended epochs).
    function wireEscrow(BuilderFund fund, address escrow) internal {
        fund.grantRole(fund.MARKETS_ROLE(), escrow);
        fund.grantRole(fund.LATE_ROLE(), escrow);
    }
}
