// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/math/Math.sol";

import {ILevelSystem, ID} from "./ILevelSystem.sol";
import {IGameNFT} from "../tokens/gamenft/IGameNFT.sol";
import {IGameCurrency} from "../tokens/IGameCurrency.sol";
import {ID as GOLD_TOKEN_ID} from "../tokens/goldtoken/IGoldToken.sol";
import {IGameGlobals, ID as GAME_GLOBALS_ID} from "../gameglobals/IGameGlobals.sol";
import {ICaptainSystem, ID as CAPTAIN_SYSTEM_ID} from "../captain/ICaptainSystem.sol";
import {PERCENTAGE_RANGE, GAME_LOGIC_CONTRACT_ROLE, LEVEL_TRAIT_ID, XP_TRAIT_ID} from "../Constants.sol";
import {ITraitsProvider, ID as TRAITS_PROVIDER_ID} from "../interfaces/ITraitsProvider.sol";

import "../GameRegistryConsumerUpgradeable.sol";

// Globals used by this contract
uint256 constant TOTAL_XP_FOR_LEVEL_ID = uint256(
    keccak256("total_xp_to_level_up")
);
uint256 constant GOLD_TO_LEVEL_UP_ID = uint256(keccak256("gold_to_level_up"));
uint256 constant CAPTAIN_XP_BONUS_PERCENT_ID = uint256(
    keccak256("captain_xp_bonus_percent")
);

/// @title LevelSystem
/// Lets the player level up
contract LevelSystem is ILevelSystem, GameRegistryConsumerUpgradeable {
    /** EVENTS **/

    /// @notice Emitted when a pirates level is upgraded
    event UpgradePirateLevel(
        address indexed tokenContract,
        uint256 indexed tokenId,
        uint256 newLevel
    );

    /** ERRORS **/

    /// @notice Origin is not the owner of the specified NFT
    error NotOwner();

    /// @notice Cannot upgrade to same or lower level
    error MustUpgradeToHigherLevel();

    /// @notice Need more XP to upgrade level
    error NeedMoreXP();

    /// @notice Trying to level past max level
    error DesiredLevelExceedsMaxLevel(uint256 maxLevel, uint256 desiredLevel);

    /** SETUP **/

    /**
     * Initializer for this upgradeable contract
     *
     * @param gameRegistryAddress Address of the GameRegistry contract
     */
    function initialize(address gameRegistryAddress) public initializer {
        __GameRegistryConsumer_init(gameRegistryAddress, ID);
    }

    /** EXTERNAL **/

    /**
     * Upgrades a pirate's level based on their XP
     *
     * @param nftContract   Address of the pirate NFT contract
     * @param nftTokenId    Token id of the pirate
     * @param desiredLevel  Desired level of the pirate
     */
    function upgradePirateLevel(
        address nftContract,
        uint256 nftTokenId,
        uint32 desiredLevel
    ) external whenNotPaused nonReentrant {
        address account = _getPlayerAccount(_msgSender());
        ITraitsProvider traitsProvider = ITraitsProvider(
            _getSystem(TRAITS_PROVIDER_ID)
        );

        // Owner check
        if (IGameNFT(nftContract).ownerOf(nftTokenId) != account) {
            revert NotOwner();
        }

        uint256 currentLevel = traitsProvider.getTraitUint256(
            nftContract,
            nftTokenId,
            LEVEL_TRAIT_ID
        );

        if (currentLevel >= desiredLevel) {
            revert MustUpgradeToHigherLevel();
        }

        // Check XP
        IGameGlobals gameGlobals = IGameGlobals(_getSystem(GAME_GLOBALS_ID));

        uint256[] memory xpTable = gameGlobals.getUint256Array(
            TOTAL_XP_FOR_LEVEL_ID
        );

        if (desiredLevel >= xpTable.length) {
            revert DesiredLevelExceedsMaxLevel(xpTable.length, desiredLevel);
        }

        uint256 xpRequired = xpTable[desiredLevel];
        uint256 xpForPirate = traitsProvider.getTraitUint256(
            nftContract,
            nftTokenId,
            XP_TRAIT_ID
        );

        if (xpForPirate < xpRequired) {
            revert NeedMoreXP();
        }

        // Burn the gold needed to upgrade
        _burnGold(account, gameGlobals, currentLevel, desiredLevel);

        // Increment level trait
        traitsProvider.incrementTrait(
            nftContract,
            nftTokenId,
            LEVEL_TRAIT_ID,
            desiredLevel - currentLevel
        );

        // Emit event
        emit UpgradePirateLevel(nftContract, nftTokenId, desiredLevel);
    }

    /**
     * Grants XP to the given token
     *
     * @param tokenContract Address of the NFT
     * @param tokenId       Id of the NFT token
     * @param amount        Amount of XP to grant
     */
    function grantXP(
        address tokenContract,
        uint256 tokenId,
        uint256 amount
    ) external onlyRole(GAME_LOGIC_CONTRACT_ROLE) {
        address owner = IGameNFT(tokenContract).ownerOf(tokenId);

        ICaptainSystem captainSystem = ICaptainSystem(
            _getSystem(CAPTAIN_SYSTEM_ID)
        );

        // Apply XP modifier for captain
        (address captainTokenContract, uint256 captainTokenId) = captainSystem
            .getCaptainNFT(owner);

        // If NFT is the captain, grant bonus XP
        if (
            captainTokenContract == tokenContract && captainTokenId == tokenId
        ) {
            IGameGlobals gameGlobals = IGameGlobals(
                _getSystem(GAME_GLOBALS_ID)
            );

            amount =
                amount +
                (amount * gameGlobals.getUint256(CAPTAIN_XP_BONUS_PERCENT_ID)) /
                PERCENTAGE_RANGE;
        }

        ITraitsProvider traitsProvider = ITraitsProvider(
            _getSystem(TRAITS_PROVIDER_ID)
        );
        traitsProvider.incrementTrait(
            tokenContract,
            tokenId,
            XP_TRAIT_ID,
            amount
        );
    }

    /** INTERNAL **/
    function _burnGold(
        address account,
        IGameGlobals gameGlobals,
        uint256 currentLevel,
        uint256 desiredLevel
    ) internal {
        uint256 goldRequired = 0;
        uint256[] memory goldTable = gameGlobals.getUint256Array(
            GOLD_TO_LEVEL_UP_ID
        );

        if (desiredLevel >= goldTable.length) {
            revert DesiredLevelExceedsMaxLevel(goldTable.length, desiredLevel);
        }

        IGameCurrency goldToken = IGameCurrency(_getSystem(GOLD_TOKEN_ID));

        for (uint256 idx = currentLevel + 1; idx <= desiredLevel; ++idx) {
            goldRequired += goldTable[idx];
        }
        goldToken.burn(account, goldRequired);
    }
}