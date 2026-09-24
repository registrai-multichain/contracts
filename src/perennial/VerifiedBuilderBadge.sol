// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {BuilderRegistry} from "./BuilderRegistry.sol";

/// @dev ERC-5192 minimal soulbound interface.
interface IERC5192 {
    event Locked(uint256 tokenId);
    event Unlocked(uint256 tokenId);

    function locked(uint256 tokenId) external view returns (bool);
}

/// @title VerifiedBuilderBadge. Soulbound "Registrai Verified Builder" badge.
/// @notice One non-transferable token per verified builder, held by the
/// builder's BuilderRegistry owner (which never changes). Token ids are serials
/// in issue order ("No. 007") and are never reused.
///
/// Trust split: the ISSUER (the admin Safe, in the same onboarding batch that
/// assigns the caretaker) is the only one who can create or revoke a badge. The
/// STATUS role (the keeper's operator key) can only flip an issued badge between
/// verified and lapsed as the builder's off-chain proof comes and goes — a
/// leaked keeper key cannot mint a single badge.
///
/// Metadata is fully on-chain (data: JSON); only the artwork is hosted:
/// `imageBase + serial + ("-lapsed")? + ".jpg"`.
contract VerifiedBuilderBadge is ERC721, AccessControl, IERC5192 {
    using Strings for uint256;

    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    bytes32 public constant STATUS_ROLE = keccak256("STATUS_ROLE");

    BuilderRegistry public immutable BUILDERS;
    string public chainLabel; // e.g. "Arc Mainnet"
    string public imageBase; // e.g. "https://registrai.cc/badge/arc/"
    string public externalBase; // e.g. "https://registrai.cc/perennial/?builder="

    uint256 public nextSerial = 1;
    mapping(uint256 => uint256) public serialOf; // builderId => serial (0 = none)
    mapping(uint256 => uint256) public builderOf; // serial => builderId
    mapping(uint256 => bool) public lapsed; // serial => proof currently lapsed
    mapping(uint256 => uint64) public issuedAt; // serial => timestamp

    event Issued(uint256 indexed builderId, uint256 indexed serial, address indexed owner);
    event Revoked(uint256 indexed builderId, uint256 indexed serial);
    event LapsedSet(uint256 indexed builderId, uint256 indexed serial, bool lapsed);
    event BasesSet(string imageBase, string externalBase);
    /// @dev ERC-4906 (metadata refresh hints for indexers).
    event MetadataUpdate(uint256 _tokenId);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    error ZeroAddress();
    error NotRegistered();
    error InactiveBuilder();
    error AlreadyIssued();
    error NoBadge();
    error Soulbound();

    constructor(
        BuilderRegistry builders_,
        address admin,
        address statusOperator,
        string memory chainLabel_,
        string memory imageBase_,
        string memory externalBase_
    ) ERC721("Registrai Verified Builder", "RVB") {
        if (address(builders_) == address(0) || admin == address(0) || statusOperator == address(0)) {
            revert ZeroAddress();
        }
        BUILDERS = builders_;
        chainLabel = chainLabel_;
        imageBase = imageBase_;
        externalBase = externalBase_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ISSUER_ROLE, admin);
        _grantRole(STATUS_ROLE, statusOperator);
    }

    // ───────────────────────────── issuer ─────────────────────────────

    /// @notice Issue the next serial to `builderId`'s registry owner.
    function issue(uint256 builderId) external onlyRole(ISSUER_ROLE) returns (uint256 serial) {
        address owner = BUILDERS.ownerOf(builderId);
        if (owner == address(0)) revert NotRegistered();
        if (!BUILDERS.isActiveBuilderId(builderId)) revert InactiveBuilder();
        if (serialOf[builderId] != 0) revert AlreadyIssued();
        serial = nextSerial++;
        serialOf[builderId] = serial;
        builderOf[serial] = builderId;
        issuedAt[serial] = uint64(block.timestamp);
        _mint(owner, serial);
        emit Locked(serial);
        emit Issued(builderId, serial, owner);
    }

    /// @notice Burn a badge (e.g. a claim found to be fraudulent). The serial is
    /// retired for good; a later re-issue gets a new serial.
    function revoke(uint256 builderId) external onlyRole(ISSUER_ROLE) {
        uint256 serial = serialOf[builderId];
        if (serial == 0) revert NoBadge();
        delete serialOf[builderId];
        delete lapsed[serial];
        _burn(serial);
        emit Revoked(builderId, serial);
    }

    function setBases(string calldata imageBase_, string calldata externalBase_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        imageBase = imageBase_;
        externalBase = externalBase_;
        emit BasesSet(imageBase_, externalBase_);
        if (nextSerial > 1) emit BatchMetadataUpdate(1, nextSerial - 1);
    }

    // ───────────────────────────── status ─────────────────────────────

    /// @notice Mark an issued badge lapsed (proof gone) or verified again.
    /// Idempotent; cannot create, move or burn anything.
    function setLapsed(uint256 builderId, bool isLapsed) external onlyRole(STATUS_ROLE) {
        uint256 serial = serialOf[builderId];
        if (serial == 0) revert NoBadge();
        if (lapsed[serial] == isLapsed) return;
        lapsed[serial] = isLapsed;
        emit LapsedSet(builderId, serial, isLapsed);
        emit MetadataUpdate(serial);
    }

    // ───────────────────────────── soulbound ─────────────────────────────

    function locked(uint256 serial) external view returns (bool) {
        _requireOwned(serial);
        return true;
    }

    /// @dev Only mint (from 0) and burn (to 0) move a token.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert Soulbound();
        return super._update(to, tokenId, auth);
    }

    function approve(address, uint256) public pure override {
        revert Soulbound();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert Soulbound();
    }

    // ───────────────────────────── metadata ─────────────────────────────

    /// @notice The builder's claimed source ("github:owner/repo" / "domain:host"),
    /// read live from the registry profile link; "" if it is not a registrai: link.
    function sourceOf(uint256 builderId) public view returns (string memory) {
        (, string memory uri,,,) = BUILDERS.builders(builderId);
        bytes memory b = bytes(uri);
        bytes memory prefix = "registrai:";
        if (b.length <= prefix.length) return "";
        for (uint256 i; i < prefix.length; i++) {
            if (b[i] != prefix[i]) return "";
        }
        bytes memory out = new bytes(b.length - prefix.length);
        for (uint256 i; i < out.length; i++) {
            out[i] = b[i + prefix.length];
        }
        return string(out);
    }

    function tokenURI(uint256 serial) public view override returns (string memory) {
        _requireOwned(serial);
        uint256 builderId = builderOf[serial];
        bool isLapsed = lapsed[serial];
        string memory no = _pad3(serial);
        string memory status = isLapsed ? "Lapsed" : "Verified";
        string memory json = string.concat(
            '{"name":"Registrai Verified Builder No. ',
            no,
            '","description":"Soulbound badge for a builder who proved control of their project to Registrai. ',
            "Non-transferable. Shows Lapsed while the builder's proof is missing.",
            '","image":"',
            _escape(string.concat(imageBase, serial.toString(), isLapsed ? "-lapsed" : "", ".jpg")),
            '","external_url":"',
            _escape(string.concat(externalBase, builderId.toString())),
            '","attributes":[',
            _attributes(builderId, serial, status),
            "]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _attributes(uint256 builderId, uint256 serial, string memory status)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            '{"trait_type":"Status","value":"',
            status,
            '"},{"trait_type":"Serial","display_type":"number","value":',
            serial.toString(),
            '},{"trait_type":"Builder ID","display_type":"number","value":',
            builderId.toString(),
            '},{"trait_type":"Source","value":"',
            _escape(sourceOf(builderId)),
            '"},{"trait_type":"Chain","value":"',
            _escape(chainLabel),
            '"},{"trait_type":"Issued","display_type":"date","value":',
            uint256(issuedAt[serial]).toString(),
            "}"
        );
    }

    /// @dev "7" → "007"; ≥1000 unpadded.
    function _pad3(uint256 n) internal pure returns (string memory) {
        string memory s = n.toString();
        if (n < 10) return string.concat("00", s);
        if (n < 100) return string.concat("0", s);
        return s;
    }

    /// @dev JSON string escaping: the profile link is builder-controlled.
    function _escape(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 extra;
        for (uint256 i; i < b.length; i++) {
            bytes1 c = b[i];
            if (c == '"' || c == "\\") extra += 1;
            else if (uint8(c) < 0x20 || uint8(c) == 0x7f) extra += 5;
        }
        if (extra == 0) return s;
        bytes memory out = new bytes(b.length + extra);
        bytes16 hexChars = "0123456789abcdef";
        uint256 j;
        for (uint256 i; i < b.length; i++) {
            bytes1 c = b[i];
            if (c == '"' || c == "\\") {
                out[j++] = "\\";
                out[j++] = c;
            } else if (uint8(c) < 0x20 || uint8(c) == 0x7f) {
                out[j++] = "\\";
                out[j++] = "u";
                out[j++] = "0";
                out[j++] = "0";
                out[j++] = hexChars[uint8(c) >> 4];
                out[j++] = hexChars[uint8(c) & 0x0f];
            } else {
                out[j++] = c;
            }
        }
        return string(out);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControl)
        returns (bool)
    {
        return interfaceId == type(IERC5192).interfaceId || interfaceId == bytes4(0x49064906)
            || super.supportsInterface(interfaceId);
    }
}
