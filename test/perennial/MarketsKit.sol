// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {VerifiedBuilderBadge} from "../../src/perennial/VerifiedBuilderBadge.sol";

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
}
