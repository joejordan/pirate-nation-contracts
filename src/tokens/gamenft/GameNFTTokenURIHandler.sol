// SPDX-License-Identifier: MIT LICENSE
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/Strings.sol";

import {ITokenURIHandler} from "../ITokenURIHandler.sol";
import {ITraitsConsumer} from "../../interfaces/ITraitsConsumer.sol";
import {ITraitsProvider, TokenURITrait, TraitDataType} from "../../interfaces/ITraitsProvider.sol";
import {IGameNFT} from "./IGameNFT.sol";
import {GameRegistryConsumerUpgradeable} from "../../GameRegistryConsumerUpgradeable.sol";
import {ContractTraits} from "../ContractTraits.sol";
import {MANAGER_ROLE} from "../../Constants.sol";

uint256 constant ID = uint256(
    keccak256("game.piratenation.gamenfttokenurihandler")
);

contract GameNFTTokenURIHandler is
    GameRegistryConsumerUpgradeable,
    ContractTraits,
    ITokenURIHandler
{
    using Strings for uint256;

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
     * @notice Generates metadata for the given tokenId
     * @param
     * @param tokenId  Token to generate metadata for
     * @return A normal URI
     */
    function tokenURI(
        address,
        address tokenContract,
        uint256 tokenId
    ) external view virtual override returns (string memory) {
        return
            _traitsProvider().generateTokenURI(
                tokenContract,
                tokenId,
                getExtraTraits(tokenContract, tokenId)
            );
    }

    /**
     * @dev This override includes the locked and soulbound traits
     * @param tokenId  Token to generate extra traits array for
     * @return Extra traits to include in the tokenURI metadata
     */
    function getExtraTraits(address tokenContract, uint256 tokenId)
        public
        view
        returns (TokenURITrait[] memory)
    {
        ITraitsConsumer traitsConsumer = ITraitsConsumer(tokenContract);

        ContractInfo storage contractInfo = _contracts[tokenContract];
        uint256[] memory assetIds = this.getAssetTraitIds(tokenContract);

        uint8 numStaticTraits = 5;
        TokenURITrait[] memory extraTraits = new TokenURITrait[](
            numStaticTraits + assetIds.length
        );

        // Name
        extraTraits[0] = TokenURITrait({
            name: "name",
            value: abi.encode(traitsConsumer.tokenName(tokenId)),
            dataType: TraitDataType.STRING,
            isTopLevelProperty: true
        });

        // Image
        extraTraits[1] = TokenURITrait({
            name: "image",
            value: abi.encode(traitsConsumer.imageURI(tokenId)),
            dataType: TraitDataType.STRING,
            isTopLevelProperty: true
        });

        // Description
        extraTraits[2] = TokenURITrait({
            name: "description",
            value: abi.encode(traitsConsumer.tokenDescription(tokenId)),
            dataType: TraitDataType.STRING,
            isTopLevelProperty: true
        });

        // External URL
        extraTraits[3] = TokenURITrait({
            name: "external_url",
            value: abi.encode(traitsConsumer.externalURI(tokenId)),
            dataType: TraitDataType.STRING,
            isTopLevelProperty: true
        });

        // Locked
        extraTraits[4] = TokenURITrait({
            name: "locked",
            isTopLevelProperty: false,
            dataType: TraitDataType.BOOL,
            value: abi.encode(
                _lockingSystem().isNFTLocked(tokenContract, tokenId)
            )
        });

        for (uint256 idx = 0; idx < assetIds.length; idx++) {
            Asset storage asset = contractInfo.assets[assetIds[idx]];

            extraTraits[numStaticTraits + idx] = TokenURITrait({
                name: asset.traitName,
                isTopLevelProperty: true,
                dataType: TraitDataType.STRING,
                value: abi.encode(
                    string(abi.encodePacked(asset.uri, tokenId.toString()))
                )
            });
        }

        return extraTraits;
    }

    /**
     * Adds a new asset type for a contract
     *
     * @param tokenContract Contract to add asset types for
     * @param asset         Asset to add to the contract
     */
    function addAsset(address tokenContract, Asset calldata asset)
        external
        onlyRole(MANAGER_ROLE)
    {
        _addAsset(tokenContract, asset);
    }

    /**
     * Removes an asset from a contract
     *
     * @param tokenContract Contract to remove asset from
     * @param traitId       Keccak256 traitId of the asset to remove
     */
    function removeAsset(address tokenContract, uint256 traitId)
        external
        onlyRole(MANAGER_ROLE)
    {
        _removeAsset(tokenContract, traitId);
    }
}