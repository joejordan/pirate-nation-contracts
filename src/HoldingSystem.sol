// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.9;

import {MANAGER_ROLE, GAME_NFT_CONTRACT_ROLE} from "./Constants.sol";

import {IGameNFT} from "./tokens/gamenft/IGameNFT.sol";
import {IGameItems} from "./tokens/gameitems/IGameItems.sol";

import {ILootSystem} from "./loot/ILootSystem.sol";

import "./GameRegistryConsumerUpgradeable.sol";

uint256 constant ID = uint256(keccak256("game.piratenation.holdingsystem"));

/**
 * @title HoldingSystem
 *
 * Grants the user rewards based on how long they've held a given NFT
 */
contract HoldingSystem is GameRegistryConsumerUpgradeable {
    // Milestone that maps time an NFT was held for to a loot table to grant loot from
    struct Milestone {
        // Amount of seconds the token needs to be held for to unlock milestone
        uint256 timeHeldSeconds;
        // Loot to grant once the milestone has been unlocked and claimed
        ILootSystem.Loot[] loots;
    }

    struct TokenContractInformation {
        // Which tokens have claimed which milestones
        mapping(uint256 => mapping(uint16 => bool)) claimed;
        // All of the milestones for this token contract
        Milestone[] milestones;
    }

    /// @notice  All of the possible token contracts with milestones associated with them
    mapping(address => TokenContractInformation) private _tokenContracts;

    /** EVENTS **/

    /// @notice Emitted when milestones have been set
    event MilestonesSet(address indexed tokenContract);

    /// @notice Emitted when a milestone has been claimed
    event MilestoneClaimed(
        address indexed owner,
        address indexed tokenContract,
        uint256 indexed tokenId,
        uint16 milestoneIndex
    );

    /** ERRORS **/

    /// @notice tokenContract has not been allowlisted for gameplay
    error ContractNotAllowlisted(address tokenContract);

    /// @notice Milestone has already been claimed
    error MilestoneAlreadyClaimed();

    /// @notice Milestone can only be claimed by token owner
    error NotOwner();

    /// @notice Milestone index is invalid (greater than number of milestones)
    error InvalidMilestoneIndex();

    /// @notice NFT has not been held long enough
    error MilestoneNotUnlocked();

    /** SETUP **/

    /**
     * Initializer for this upgradeable contract
     *
     * @param gameRegistryAddress Address of the GameRegistry contract
     */
    function initialize(address gameRegistryAddress) public initializer {
        __GameRegistryConsumer_init(gameRegistryAddress, ID);
    }

    /** PUBLIC **/

    /**
     * Sets the milestones for the given token contract
     *
     * @param tokenContract Token contract to set milestones for
     * @param milestones   New holding milestones for the contract
     */
    function setMilestones(
        address tokenContract,
        Milestone[] calldata milestones
    ) public onlyRole(MANAGER_ROLE) {
        if (_hasAccessRole(GAME_NFT_CONTRACT_ROLE, tokenContract) != true) {
            revert ContractNotAllowlisted(tokenContract);
        }

        TokenContractInformation storage tokenContractInfo = _tokenContracts[
            tokenContract
        ];

        // Reset array
        delete tokenContractInfo.milestones;

        ILootSystem lootSystem = _lootSystem();

        for (uint16 idx; idx < milestones.length; ++idx) {
            Milestone calldata milestone = milestones[idx];
            tokenContractInfo.milestones.push(milestones[idx]);
            lootSystem.validateLoots(milestone.loots);
        }

        // Emit event
        emit MilestonesSet(tokenContract);
    }

    /**
     * Claims a token milestone for a given token
     *
     * @param tokenContract     Contract of the token that is being held
     * @param tokenId           Id of the token that is being held
     * @param milestoneIndex    Index of the milestone to claim for this token
     */
    function claimMilestone(
        address tokenContract,
        uint256 tokenId,
        uint16 milestoneIndex
    ) external whenNotPaused nonReentrant {
        TokenContractInformation storage tokenContractInfo = _tokenContracts[
            tokenContract
        ];

        if (milestoneIndex >= tokenContractInfo.milestones.length) {
            revert InvalidMilestoneIndex();
        }

        if (tokenContractInfo.claimed[tokenId][milestoneIndex] == true) {
            revert MilestoneAlreadyClaimed();
        }

        Milestone storage milestone = tokenContractInfo.milestones[
            milestoneIndex
        ];
        IGameNFT nftContract = IGameNFT(tokenContract);
        address owner = nftContract.ownerOf(tokenId);
        address account = _getPlayerAccount(_msgSender());

        if (account != owner) {
            revert NotOwner();
        }

        if (
            _isMilestoneUnlocked(milestone, owner, tokenContract, tokenId) !=
            true
        ) {
            revert MilestoneNotUnlocked();
        }

        // Mark as claimed
        tokenContractInfo.claimed[tokenId][milestoneIndex] = true;

        // Grant loot
        _lootSystem().grantLoot(owner, milestone.loots);

        // Emit event
        emit MilestoneClaimed(owner, tokenContract, tokenId, milestoneIndex);
    }

    /**
     * Get all milestone info for a given token and account
     *
     * @param account       Account to get info for
     * @param tokenContract Contract to get milestones for
     * @param tokenId       Token id to get milestones for
     *
     * @return unlocked Whether or not the milestone is unlocked
     * @return claimed Whether or not the milestone is unlocked
     */
    function getTokenStatus(
        address account,
        address tokenContract,
        uint256 tokenId
    )
        external
        view
        returns (
            bool[] memory unlocked,
            bool[] memory claimed,
            uint256[] memory timeLeftSeconds
        )
    {
        TokenContractInformation storage contractInfo = _tokenContracts[
            tokenContract
        ];
        Milestone[] storage milestones = contractInfo.milestones;
        unlocked = new bool[](milestones.length);
        claimed = new bool[](milestones.length);
        timeLeftSeconds = new uint256[](milestones.length);

        for (uint16 idx; idx < milestones.length; ++idx) {
            Milestone storage milestone = milestones[idx];
            unlocked[idx] = _isMilestoneUnlocked(
                milestones[idx],
                account,
                tokenContract,
                tokenId
            );

            if (
                milestone.timeHeldSeconds >
                IGameNFT(tokenContract).getTimeHeld(account, tokenId)
            ) {
                timeLeftSeconds[idx] =
                    milestone.timeHeldSeconds -
                    IGameNFT(tokenContract).getTimeHeld(account, tokenId);
            } else {
                timeLeftSeconds[idx] = 0;
            }

            claimed[idx] = contractInfo.claimed[tokenId][idx];
        }
    }

    /**
     * Return milestones for a given token contract
     *
     * @param tokenContract Contract to get milestones for
     *
     * @return All milestones for the given token contract
     */
    function getTokenContractMilestones(address tokenContract)
        external
        view
        returns (Milestone[] memory)
    {
        return _tokenContracts[tokenContract].milestones;
    }

    /** INTERNAL */

    function _isMilestoneUnlocked(
        Milestone storage milestone,
        address owner,
        address tokenContract,
        uint256 tokenId
    ) internal view returns (bool) {
        return
            IGameNFT(tokenContract).getTimeHeld(owner, tokenId) >=
            milestone.timeHeldSeconds;
    }
}