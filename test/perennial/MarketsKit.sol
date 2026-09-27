// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {VerifiedBuilderBadge} from "../../src/perennial/VerifiedBuilderBadge.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {MarketsPerennial} from "../../src/nanopay/MarketsPerennial.sol";
import {BuilderFund} from "../../src/perennial/BuilderFund.sol";
import {WonderEscrow} from "../../src/perennial/WonderEscrow.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// Test helper for the badge-gated market stack. Internal library functions run
/// in the caller's context, so the calling test holds REGISTRAR and every badge role.
library MarketsKit {
    function deployBadge(BuilderRegistry builders) internal returns (VerifiedBuilderBadge badge) {
        badge = new VerifiedBuilderBadge(builders, address(this), address(this), "Test", "https://x/badge/", "https://x/b?id=");
    }

    /// Register `owner` (if new), add `source` as a project, issue the badge (if none).
    function onboard(BuilderRegistry builders, VerifiedBuilderBadge badge, address owner, string memory source)
        internal
        returns (uint256 builderId, uint256 projectId)
    {
        builderId = builders.builderIdOf(owner);
        if (builderId == 0) builderId = builders.registerFor(owner, "");
        projectId = builders.addProjectFor(builderId, source);
        if (badge.serialOf(builderId) == 0) badge.issue(builderId);
    }

    /// Deploy the escrow and the markets (settlement window 1 hour, grace 1 day)
    /// and wire them: markets credit the escrow and the fund, the escrow the fund.
    function deployMarkets(
        NanoLedger ledger,
        Registry registry,
        Attestation attestation,
        BuilderRegistry builders,
        BuilderFund fund,
        VerifiedBuilderBadge badge,
        uint256 expiry
    ) internal returns (MarketsPerennial markets, WonderEscrow escrow) {
        escrow = new WonderEscrow(ledger, fund, badge, address(this), expiry);
        markets = new MarketsPerennial(
            ledger, registry, attestation, builders, address(this), fund, 1 hours, 1 days, badge, escrow
        );
        escrow.grantRole(escrow.MARKETS_ROLE(), address(markets));
        fund.grantRole(fund.MARKETS_ROLE(), address(markets));
        fund.grantRole(fund.MARKETS_ROLE(), address(escrow));
        fund.grantRole(fund.LATE_ROLE(), address(escrow));
    }

    /// Drop-in for the pre-wonder constructor: deploys a badge and an escrow
    /// (both administered by the caller), then the markets with `admin`. The
    /// caller still wires the fund (FundKit.wire) as before.
    function perennial(
        NanoLedger ledger,
        Registry registry,
        Attestation attestation,
        BuilderRegistry builders,
        address admin,
        BuilderFund fund,
        uint256 settlementWindow,
        uint256 resolutionGrace
    ) internal returns (MarketsPerennial markets) {
        VerifiedBuilderBadge badge = deployBadge(builders);
        WonderEscrow escrow = new WonderEscrow(ledger, fund, badge, address(this), 180 days);
        markets = new MarketsPerennial(
            ledger, registry, attestation, builders, admin, fund, settlementWindow, resolutionGrace, badge, escrow
        );
        escrow.grantRole(escrow.MARKETS_ROLE(), address(markets));
    }

    /// Give `builderId` an active project (if it has none) and a badge (if none),
    /// so markets can be opened on it.
    function certify(MarketsPerennial markets, uint256 builderId) internal {
        BuilderRegistry builders = markets.BUILDERS();
        if (builders.activeProjectCount(builderId) == 0) {
            builders.addProjectFor(builderId, string.concat("github:test/b", Strings.toString(builderId)));
        }
        VerifiedBuilderBadge badge = markets.BADGE();
        if (badge.serialOf(builderId) == 0) badge.issue(builderId);
    }

    /// Bind `feedId` to `builderId`: markets opened on it afterwards pay that builder.
    /// The caller must hold FEED_ROLE (the markets admin).
    function bindBuilder(MarketsPerennial markets, bytes32 feedId, uint256 builderId) internal {
        markets.setFeedSubject(
            feedId, MarketsPerennial.Subject(MarketsPerennial.SubjectKind.Builder, builderId, bytes32(0))
        );
    }
}
