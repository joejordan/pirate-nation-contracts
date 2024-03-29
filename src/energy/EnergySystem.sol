// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {MANAGER_ROLE, GAME_NFT_CONTRACT_ROLE, GAME_LOGIC_CONTRACT_ROLE} from "../Constants.sol";
import "../libraries/GameHelperLibrary.sol";

import {IEnergySystem, ID} from "./IEnergySystem.sol";

import {IGameNFT} from "../tokens/gamenft/IGameNFT.sol";
import {IGameGlobals, ID as GAME_GLOBALS_ID} from "../gameglobals/IGameGlobals.sol";
import {ITraitsProvider, ID as TRAITS_PROVIDER_ID} from "../interfaces/ITraitsProvider.sol";
import "../GameRegistryConsumerUpgradeable.sol";

// Globals used by this contract
uint256 constant MAX_ENERGY_PER_LEVEL_ID = uint256(
    keccak256("max_energy_per_level")
);
uint256 constant ENERGY_REGEN_SECS_PER_LEVEL_ID = uint256(
    keccak256("energy_regen_secs_per_level")
);

/**
 * @title EnergySystem
 *
 * Tracks energy accumulation and spend for a given token
 * Note: Energy is measured in ETHER units so we can do fractional energy
 */
contract EnergySystem is IEnergySystem, GameRegistryConsumerUpgradeable {
    // Data for each token
    struct TokenData {
        // Last time energy was spent
        uint256 lastSpendTimestamp;
        // Energy amount at time of last spend
        uint256 lastEnergyAmount;
    }

    /// @notice All of the possible token contracts that have energy
    mapping(address => bool) private _tokenContractActive;

    /// @notice Data for each token
    mapping(address => mapping(uint256 => TokenData)) private _tokenData;

    /** EVENTS */

    /// @notice Emitted when the user has gained some energy
    event EnergyGained(
        address indexed owner,
        address indexed tokenContract,
        uint256 indexed tokenId,
        uint256 amount
    );

    /// @notice Emitted when the user has spent some energy
    event EnergySpent(
        address indexed owner,
        address indexed tokenContract,
        uint256 indexed tokenId,
        uint256 amount
    );

    /** ERRORS */

    /// @notice Emitted when a contract is not a GameNFT
    error ContractNotGameNFT(address tokenContract);

    /// @notice Emitted when a contract is not active for this system
    error ContractNotActive(address tokenContract);

    /// @notice Emitted when a token does not have enough energy
    error NotEnoughEnergy(uint256 expected, uint256 actual);

    /**
     * Initializer for this upgradeable contract
     *
     * @param gameRegistryAddress Address of the GameRegistry contract
     */
    function initialize(address gameRegistryAddress) public initializer {
        __GameRegistryConsumer_init(gameRegistryAddress, ID);
    }

    /**
     * Sets a token contract as having energy
     *
     * @param tokenContract Token contract to set milestones for
     * @param active        Whether or not the contract is active
     */
    function setContractActive(address tokenContract, bool active)
        public
        onlyRole(MANAGER_ROLE)
    {
        if (_hasAccessRole(GAME_NFT_CONTRACT_ROLE, tokenContract) == false) {
            revert ContractNotGameNFT(tokenContract);
        }

        _tokenContractActive[tokenContract] = active;
    }

    /**
     * Gets a token contract active status
     *
     * @param tokenContract Token contract to get the status
     *
     * @return bool Whether or not the contract is active
     */
    function getContractActive(address tokenContract)
        public
        view
        returns (bool)
    {
        return _tokenContractActive[tokenContract];
    }

    /**
     * Gives energy to the given token
     *
     * @param tokenContract Contract to give energy to
     * @param tokenId       Token id to give energy to
     * @param amount        Amount of energy to give
     */
    function giveEnergy(
        address tokenContract,
        uint256 tokenId,
        uint256 amount
    ) external whenNotPaused nonReentrant onlyRole(GAME_LOGIC_CONTRACT_ROLE) {
        if (_tokenContractActive[tokenContract] != true) {
            revert ContractNotActive(tokenContract);
        }

        TokenData storage tokenData = _tokenData[tokenContract][tokenId];

        // This should be okay because of the way spend energy works, it won't let the user go over their max
        uint256 maxEnergy = _maxEnergy(tokenContract, tokenId);
        tokenData.lastEnergyAmount += amount;
        if (tokenData.lastEnergyAmount > maxEnergy) {
            tokenData.lastEnergyAmount = maxEnergy;
        }

        // Emit event
        emit EnergyGained(_msgSender(), tokenContract, tokenId, amount);
    }

    /**
     * Spends energy for the given token
     *
     * @param tokenContract Contract to get milestones for
     * @param tokenId       Token id to get milestones for
     * @param amount        Amount of energy to spend
     */
    function spendEnergy(
        address tokenContract,
        uint256 tokenId,
        uint256 amount
    ) external whenNotPaused nonReentrant onlyRole(GAME_LOGIC_CONTRACT_ROLE) {
        uint256 currentEnergy = _energyForToken(tokenContract, tokenId);
        if (currentEnergy < amount) {
            revert NotEnoughEnergy(amount, currentEnergy);
        }

        if (_tokenContractActive[tokenContract] != true) {
            revert ContractNotActive(tokenContract);
        }

        TokenData storage tokenData = _tokenData[tokenContract][tokenId];

        // Store new energy info
        tokenData.lastEnergyAmount = currentEnergy - amount;
        tokenData.lastSpendTimestamp = SafeCast.toUint32(block.timestamp);

        // Emit event
        emit EnergySpent(_msgSender(), tokenContract, tokenId, amount);
    }

    /**
     * @param tokenContract Contract to get milestones for
     * @param tokenId       Token id to get milestones for
     *
     * @return The amount of maximum amount of energy for a token
     */
    function getEnergy(address tokenContract, uint256 tokenId)
        external
        view
        override
        returns (uint256)
    {
        return _energyForToken(tokenContract, tokenId);
    }

    /**
     * Retrieves all energy info for a given token
     *
     * @param tokenContract Contract to get milestones for
     * @param tokenId       Token id to get milestones for
     *
     * @return currentEnergy            Current amount of energy the token has
     * @return maxEnergy                Maximum amount of energy the token can hold at once
     * @return energyRegenPerSecond     Rate the token accumulates new energy
     * @return lastSpendTimestamp       Last time energy was spent for this token
     * @return lastEnergyAmount         How much energy was left after last spend
     */
    function getTokenData(address tokenContract, uint256 tokenId)
        external
        view
        returns (
            uint256 currentEnergy,
            uint256 maxEnergy,
            uint256 energyRegenPerSecond,
            uint256 lastSpendTimestamp,
            uint256 lastEnergyAmount
        )
    {
        TokenData storage data = _tokenData[tokenContract][tokenId];

        currentEnergy = _energyForToken(tokenContract, tokenId);
        maxEnergy = _maxEnergy(tokenContract, tokenId);
        energyRegenPerSecond = _energyRegenPerSecond(tokenContract, tokenId);
        lastEnergyAmount = data.lastEnergyAmount;
        lastSpendTimestamp = data.lastSpendTimestamp;
    }

    /** INTERNAL */

    function _maxEnergy(address tokenContract, uint256 tokenId)
        internal
        view
        returns (uint256)
    {
        IGameGlobals gameGlobals = IGameGlobals(_getSystem(GAME_GLOBALS_ID));

        uint256[] memory maxEnergyPerLevel = gameGlobals.getUint256Array(
            MAX_ENERGY_PER_LEVEL_ID
        );

        ITraitsProvider traitsProvider = ITraitsProvider(
            _getSystem(TRAITS_PROVIDER_ID)
        );

        uint256 currentLevel = GameHelperLibrary._levelForPirate(
            traitsProvider,
            tokenContract,
            tokenId
        );

        if (currentLevel < maxEnergyPerLevel.length) {
            return maxEnergyPerLevel[currentLevel];
        } else {
            return maxEnergyPerLevel[maxEnergyPerLevel.length - 1];
        }
    }

    function _energyRegenPerSecond(address tokenContract, uint256 tokenId)
        internal
        view
        returns (uint256)
    {
        IGameGlobals gameGlobals = IGameGlobals(_getSystem(GAME_GLOBALS_ID));

        uint256[] memory energyRegenSecsPerLevel = gameGlobals.getUint256Array(
            ENERGY_REGEN_SECS_PER_LEVEL_ID
        );

        ITraitsProvider traitsProvider = ITraitsProvider(
            _getSystem(TRAITS_PROVIDER_ID)
        );

        uint256 currentLevel = GameHelperLibrary._levelForPirate(
            traitsProvider,
            tokenContract,
            tokenId
        );

        uint256 regenSecs;
        if (currentLevel < energyRegenSecsPerLevel.length) {
            regenSecs = energyRegenSecsPerLevel[currentLevel];
        } else {
            regenSecs = energyRegenSecsPerLevel[
                energyRegenSecsPerLevel.length - 1
            ];
        }

        // 1 energy unit per hour
        return uint256(1 ether) / regenSecs;
    }

    function _energyForToken(address tokenContract, uint256 tokenId)
        internal
        view
        returns (uint256)
    {
        TokenData storage tokenData = _tokenData[tokenContract][tokenId];
        uint256 maxEnergy = _maxEnergy(tokenContract, tokenId);

        // Prevent overflows by defaulting to max energy if energy has never been spent before on this token
        if (tokenData.lastSpendTimestamp == 0) {
            return maxEnergy;
        }

        uint256 energyAccumulated = tokenData.lastEnergyAmount +
            (block.timestamp - tokenData.lastSpendTimestamp) *
            _energyRegenPerSecond(tokenContract, tokenId);

        if (energyAccumulated > maxEnergy) {
            return maxEnergy;
        } else {
            return energyAccumulated;
        }
    }
}