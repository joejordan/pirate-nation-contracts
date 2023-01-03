// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {GAME_NFT_CONTRACT_ROLE, GAME_ITEMS_CONTRACT_ROLE, MANAGER_ROLE, GAME_LOGIC_CONTRACT_ROLE} from "./Constants.sol";
import "./libraries/UtilLibrary.sol";

import "./interfaces/ITraitsProvider.sol";
import "./GameRegistryConsumerUpgradeable.sol";

/** @title Holds static and dynamic traits for a given NFT or ERC1155 token type */
contract TraitsProvider is GameRegistryConsumerUpgradeable, ITraitsProvider {
    using Strings for uint256;

    /// @notice Meta data for each type of trait and its expected behavior
    mapping(uint256 => TraitMetadata) private _traitMetadata;

    /// @notice Mapping of address/tokenId to traits for that token
    mapping(address => mapping(uint256 => uint256[])) private tokenTraitIds;

    /// @notice Mapping of address/tokenId/traitId to the datatype that has been set for that trait
    mapping(address => mapping(uint256 => mapping(uint256 => TraitDataType)))
        private tokenTraitDataTypes;

    /// @notice Mapping of address/tokenId/traitId to the abi-encoded bytes value for a trait
    mapping(address => mapping(uint256 => mapping(uint256 => bytes)))
        private tokenTraitValue;

    /** EVENTS **/

    /// @notice Emitted when a given trait's metadata has changed
    event TraitMetadataSet(uint256 indexed traitId);

    /// @notice Emitted when a token has had it's traits updated.
    event TraitsUpdated(address tokenContract, uint256 tokenId);

    /** ERRORS **/

    /// @notice TraitMetadata has already been initialized
    error MetadataAlreadyInitialized();

    /// @notice TraitMetadata must have a name
    error MustSetTraitName();

    /// @notice Trait behavior must be a value other than NOT_INITIALIZED
    error MustSetTraitBehavior();

    /// @notice TraitMetadata must have a dataType set
    error MustSetTraitDataType();

    /// @notice When the trait uri generation is passed an invalid datatype
    error InvalidTraitDataType(TraitDataType dataType);

    /// @notice String behavior must be immutable or unrestricted
    error InvalidStringBehavior();

    /// @notice Array lengths are either zero or don't match
    error InvalidArrayLengths();

    /// @notice Need non-zero amount
    error InvalidAmount();

    /// @notice Trait behavior does not support incrementing value
    error NotIncrementable();

    /// @notice Trait behavior does not support decrementing value
    error NotDecrementable();

    /// @notice Decrementing below zero
    error DecrementingBelowZero();

    /// @notice Trait has not been initialized to the proper type
    error DataTypeMismatch(TraitDataType expected, TraitDataType actual);

    /// @notice tokenContract has not been allowlisted for gameplay
    error TokenNotAllowlisted();

    /// @notice Trait has already been initialized
    error TraitAlreadyInitialized();

    /// @notice TraitMetadata has not been initialized
    error TraitNotInitialized();

    /** SETUP **/

    /** Initializer function for upgradeable contract */
    function initialize(address gameRegistryAddress) public initializer {
        __GameRegistryConsumer_init(gameRegistryAddress, ID);
    }

    /** EXTERNAL **/

    /**
     * Sets the metadata for the Trait
     *
     * @param traitId         Id of the trait type to set
     * @param traitMetadata   Metadata of the trait to set
     */
    function setTraitMetadata(
        uint256 traitId,
        TraitMetadata calldata traitMetadata
    ) external onlyRole(MANAGER_ROLE) {
        // Trait types can only be set once!
        if (_traitMetadata[traitId].behavior != TraitBehavior.NOT_INITIALIZED) {
            revert MetadataAlreadyInitialized();
        }

        if (traitMetadata.behavior == TraitBehavior.NOT_INITIALIZED) {
            revert MustSetTraitBehavior();
        }

        if (bytes(traitMetadata.name).length == 0) {
            revert MustSetTraitName();
        }

        if (traitMetadata.dataType == TraitDataType.NOT_INITIALIZED) {
            revert MustSetTraitDataType();
        }

        // Extra behavior check for string datatypes
        if (traitMetadata.dataType == TraitDataType.STRING) {
            if (
                traitMetadata.behavior != TraitBehavior.UNRESTRICTED &&
                traitMetadata.behavior != TraitBehavior.IMMUTABLE
            ) {
                revert InvalidStringBehavior();
            }
        }

        _traitMetadata[traitId] = traitMetadata;

        emit TraitMetadataSet(traitId);
    }

    /**
     * Sets the value for the string trait of a token, also checks to make sure trait can be modified
     *
     * @param tokenContract  Address of the token's contract
     * @param tokenId        NFT tokenId or ERC1155 token type id
     * @param traitId        Id of the trait to modify
     * @param value          New value for the given trait
     */
    function setTraitString(
        address tokenContract,
        uint256 tokenId,
        uint256 traitId,
        string calldata value
    ) external override onlyRole(GAME_LOGIC_CONTRACT_ROLE) {
        _requireAllowlistedTokenContract(tokenContract);
        _setTraitBytes(
            tokenContract,
            tokenId,
            traitId,
            abi.encode(value),
            TraitDataType.STRING
        );

        emit TraitsUpdated(tokenContract, tokenId);
    }

    /**
     * Sets several string traits for a given token
     *
     * @param tokenContract Address of the token's contract
     * @param tokenIds       Id of the token to set traits for
     * @param traitIds      Ids of traits to set
     * @param values         Value of traits to set
     */
    function batchSetTraitString(
        address tokenContract,
        uint256[] calldata tokenIds,
        uint256[] calldata traitIds,
        string[] calldata values
    ) external override onlyRole(GAME_LOGIC_CONTRACT_ROLE) {
        _requireAllowlistedTokenContract(tokenContract);

        if (
            traitIds.length == 0 ||
            traitIds.length != values.length ||
            traitIds.length != tokenIds.length
        ) {
            revert InvalidArrayLengths();
        }

        uint256 lastTokenId = 0;

        for (uint256 idx; idx < traitIds.length; ++idx) {
            uint256 tokenId = tokenIds[idx];

            _setTraitBytes(
                tokenContract,
                tokenId,
                traitIds[idx],
                abi.encode(values[idx]),
                TraitDataType.STRING
            );

            // Presumably we will be packing traits for the same token consecutively, so we can only emit one event for when the tokenId changes
            if (lastTokenId != tokenId) {
                emit TraitsUpdated(tokenContract, tokenId);
                lastTokenId = tokenId;
            }
        }
    }

    /**
     * Sets the value for the uint256 trait of a token, also checks to make sure trait can be modified
     *
     * @param tokenContract  Address of the token's contract
     * @param tokenId        NFT tokenId or ERC1155 token type id
     * @param traitId        Id of the trait to modify
     * @param value          New value for the given trait
     */
    function setTraitUint256(
        address tokenContract,
        uint256 tokenId,
        uint256 traitId,
        uint256 value
    ) external override onlyRole(GAME_LOGIC_CONTRACT_ROLE) {
        _requireAllowlistedTokenContract(tokenContract);
        _setTraitBytes(
            tokenContract,
            tokenId,
            traitId,
            abi.encode(value),
            TraitDataType.UINT
        );

        emit TraitsUpdated(tokenContract, tokenId);
    }

    /**
     * Sets several uint256 traits for a given token
     *
     * @param tokenContract Address of the token's contract
     * @param tokenIds       Id of the token to set traits for
     * @param traitIds       Ids of traits to set
     * @param values         Value of traits to set
     */
    function batchSetTraitUint256(
        address tokenContract,
        uint256[] calldata tokenIds,
        uint256[] calldata traitIds,
        uint256[] calldata values
    ) external override onlyRole(GAME_LOGIC_CONTRACT_ROLE) {
        _requireAllowlistedTokenContract(tokenContract);
        if (
            traitIds.length == 0 ||
            traitIds.length != values.length ||
            traitIds.length != tokenIds.length
        ) {
            revert InvalidArrayLengths();
        }

        uint256 lastTokenId = 0;

        for (uint256 idx; idx < traitIds.length; ++idx) {
            uint256 tokenId = tokenIds[idx];
            _setTraitBytes(
                tokenContract,
                tokenId,
                traitIds[idx],
                abi.encode(values[idx]),
                TraitDataType.UINT
            );

            // Presumably we will be packing traits for the same token consecutively, so we can only emit one event for when the tokenId changes
            if (lastTokenId != tokenId) {
                emit TraitsUpdated(tokenContract, tokenId);
                lastTokenId = tokenId;
            }
        }
    }

    /**
     * Sets the value for the int256 trait of a token, also checks to make sure trait can be modified
     *
     * @param tokenContract  Address of the token's contract
     * @param tokenId        NFT tokenId or ERC1155 token type id
     * @param traitId        Id of the trait to modify
     * @param value          New value for the given trait
     */
    function setTraitInt256(
        address tokenContract,
        uint256 tokenId,
        uint256 traitId,
        int256 value
    ) external override onlyRole(GAME_LOGIC_CONTRACT_ROLE) {
        _requireAllowlistedTokenContract(tokenContract);
        _setTraitBytes(
            tokenContract,
            tokenId,
            traitId,
            abi.encode(value),
            TraitDataType.INT
        );

        emit TraitsUpdated(tokenContract, tokenId);
    }

    /**
     * Sets several int256 traits for a given token
     *
     * @param tokenContract Address of the token's contract
     * @param tokenIds       Id of the token to set traits for
     * @param traitIds       Ids of traits to set
     * @param values         Value of traits to set
     */
    function batchSetTraitInt256(
        address tokenContract,
        uint256[] calldata tokenIds,
        uint256[] calldata traitIds,
        int256[] calldata values
    ) external override onlyRole(GAME_LOGIC_CONTRACT_ROLE) {
        _requireAllowlistedTokenContract(tokenContract);
        if (
            traitIds.length == 0 ||
            traitIds.length != values.length ||
            traitIds.length != tokenIds.length
        ) {
            revert InvalidArrayLengths();
        }

        uint256 lastTokenId = 0;

        for (uint256 idx; idx < traitIds.length; ++idx) {
            uint256 tokenId = tokenIds[idx];
            _setTraitBytes(
                tokenContract,
                tokenId,
                traitIds[idx],
                abi.encode(values[idx]),
                TraitDataType.INT
            );

            // Presumably we will be packing traits for the same token consecutively, so we can only emit one event for when the tokenId changes
            if (lastTokenId != tokenId) {
                emit TraitsUpdated(tokenContract, tokenId);
                lastTokenId = tokenId;
            }
        }
    }

    /**
     * Sets the value for the bool trait of a token, also checks to make sure trait can be modified
     *
     * @param tokenContract  Address of the token's contract
     * @param tokenId        NFT tokenId or ERC1155 token type id
     * @param traitId        Id of the trait to modify
     * @param value          New value for the given trait
     */
    function setTraitBool(
        address tokenContract,
        uint256 tokenId,
        uint256 traitId,
        bool value
    ) external override onlyRole(GAME_LOGIC_CONTRACT_ROLE) {
        _requireAllowlistedTokenContract(tokenContract);

        _setTraitBytes(
            tokenContract,
            tokenId,
            traitId,
            abi.encode(value),
            TraitDataType.BOOL
        );

        emit TraitsUpdated(tokenContract, tokenId);
    }

    /**
     * Sets several bool traits for a given token
     *
     * @param tokenContract Address of the token's contract
     * @param tokenIds       Id of the token to set traits for
     * @param traitIds       Ids of traits to set
     * @param values         Value of traits to set
     */
    function batchSetTraitBool(
        address tokenContract,
        uint256[] calldata tokenIds,
        uint256[] calldata traitIds,
        bool[] calldata values
    ) external override onlyRole(GAME_LOGIC_CONTRACT_ROLE) {
        _requireAllowlistedTokenContract(tokenContract);
        if (
            traitIds.length == 0 ||
            traitIds.length != values.length ||
            traitIds.length != tokenIds.length
        ) {
            revert InvalidArrayLengths();
        }

        uint256 lastTokenId = 0;

        for (uint256 idx; idx < traitIds.length; ++idx) {
            uint256 tokenId = tokenIds[idx];
            _setTraitBytes(
                tokenContract,
                tokenId,
                traitIds[idx],
                abi.encode(values[idx]),
                TraitDataType.BOOL
            );

            // Presumably we will be packing traits for the same token consecutively, so we can only emit one event for when the tokenId changes
            if (lastTokenId != tokenId) {
                emit TraitsUpdated(tokenContract, tokenId);
                lastTokenId = tokenId;
            }
        }
    }

    /**
     * Increments the trait for a token by the given amount
     *
     * @param tokenContract  Address of the token's contract
     * @param tokenId        NFT tokenId or ERC1155 token type id
     * @param traitId        Id of the trait to modify
     * @param amount         Amount to increment trait by
     */
    function incrementTrait(
        address tokenContract,
        uint256 tokenId,
        uint256 traitId,
        uint256 amount
    ) external override onlyRole(GAME_LOGIC_CONTRACT_ROLE) {
        _requireAllowlistedTokenContract(tokenContract);

        if (amount == 0) {
            revert InvalidAmount();
        }

        TraitMetadata memory traitMetadata = _requireTraitMetadata(traitId);
        if (
            traitMetadata.behavior != TraitBehavior.INCREMENT_ONLY &&
            traitMetadata.behavior != TraitBehavior.UNRESTRICTED
        ) {
            revert NotIncrementable();
        }

        // Make sure that the trait wasn't previously initialized to another data type
        TraitDataType dataType = tokenTraitDataTypes[tokenContract][tokenId][
            traitId
        ];
        if (dataType != traitMetadata.dataType) {
            revert DataTypeMismatch(traitMetadata.dataType, dataType);
        }

        mapping(uint256 => bytes) storage traitValues = tokenTraitValue[
            tokenContract
        ][tokenId];

        if (dataType == TraitDataType.UINT) {
            uint256 newValue = abi.decode(traitValues[traitId], (uint256)) +
                uint256(amount);
            traitValues[traitId] = abi.encode(newValue);
        } else if (dataType == TraitDataType.INT) {
            int256 newValue = abi.decode(traitValues[traitId], (int256)) +
                int256(amount);
            traitValues[traitId] = abi.encode(newValue);
        } else {
            revert NotIncrementable();
        }

        emit TraitsUpdated(tokenContract, tokenId);
    }

    /**
     * Decrements the trait for a token by the given amount
     *
     * @param tokenContract  Address of the token's contract
     * @param tokenId        NFT tokenId or ERC1155 token type id
     * @param traitId        Id of the trait to modify
     * @param amount         Amount to decrement trait by
     */
    function decrementTrait(
        address tokenContract,
        uint256 tokenId,
        uint256 traitId,
        uint256 amount
    ) external override onlyRole(GAME_LOGIC_CONTRACT_ROLE) {
        _requireAllowlistedTokenContract(tokenContract);

        if (amount == 0) {
            revert InvalidAmount();
        }

        TraitMetadata memory traitMetadata = _requireTraitMetadata(traitId);
        if (
            traitMetadata.behavior != TraitBehavior.DECREMENT_ONLY &&
            traitMetadata.behavior != TraitBehavior.UNRESTRICTED
        ) {
            revert NotDecrementable();
        }

        TraitDataType dataType = tokenTraitDataTypes[tokenContract][tokenId][
            traitId
        ];

        if (dataType != traitMetadata.dataType) {
            revert DataTypeMismatch(traitMetadata.dataType, dataType);
        }

        mapping(uint256 => bytes) storage traitValues = tokenTraitValue[
            tokenContract
        ][tokenId];

        if (dataType == TraitDataType.UINT) {
            uint256 oldValue = abi.decode(traitValues[traitId], (uint256));
            if (amount > oldValue) {
                revert DecrementingBelowZero();
            }

            uint256 newValue = oldValue - amount;
            traitValues[traitId] = abi.encode(newValue);
        } else if (dataType == TraitDataType.INT) {
            int256 newValue = abi.decode(traitValues[traitId], (int256)) -
                int256(amount);
            traitValues[traitId] = abi.encode(newValue);
        } else {
            revert NotDecrementable();
        }

        emit TraitsUpdated(tokenContract, tokenId);
    }

    /**
     * Returns the trait data for a given token
     *
     * @param tokenContract  Address of the token's contract
     * @param tokenId        NFT tokenId or ERC1155 token type id
     *
     * @return A struct containing all traits for the token
     */
    function getTraitIds(address tokenContract, uint256 tokenId)
        external
        view
        override
        returns (uint256[] memory)
    {
        return tokenTraitIds[tokenContract][tokenId];
    }

    /**
     * Returns the trait data for a given token
     *
     * @param tokenContract  Address of the token's contract
     * @param tokenId        NFT tokenId or ERC1155 token type id
     * @param traitId        Id of the trait to retrieve
     *
     * @return Trait value as abi-encoded bytes
     */
    function getTraitBytes(
        address tokenContract,
        uint256 tokenId,
        uint256 traitId
    ) external view override returns (bytes memory) {
        TraitDataType dataType = tokenTraitDataTypes[tokenContract][tokenId][
            traitId
        ];
        if (dataType == TraitDataType.NOT_INITIALIZED) {
            revert DataTypeMismatch(TraitDataType.INT, dataType);
        }

        return tokenTraitValue[tokenContract][tokenId][traitId];
    }

    /**
     * Returns the trait data for a given token
     *
     * @param tokenContract  Address of the token's contract
     * @param tokenId        NFT tokenId or ERC1155 token type id
     * @param traitId        Id of the trait to retrieve
     *
     * @return Trait value as a int256
     */
    function getTraitInt256(
        address tokenContract,
        uint256 tokenId,
        uint256 traitId
    ) external view override returns (int256) {
        TraitDataType dataType = tokenTraitDataTypes[tokenContract][tokenId][
            traitId
        ];
        if (
            dataType == TraitDataType.STRING ||
            dataType == TraitDataType.NOT_INITIALIZED
        ) {
            revert DataTypeMismatch(TraitDataType.INT, dataType);
        }

        return
            abi.decode(
                tokenTraitValue[tokenContract][tokenId][traitId],
                (int256)
            );
    }

    /**
     * Returns the trait data for a given token
     *
     * @param tokenContract  Address of the token's contract
     * @param tokenId        NFT tokenId or ERC1155 token type id
     * @param traitId        Id of the trait to retrieve
     *
     * @return Trait value as a uint256
     */
    function getTraitUint256(
        address tokenContract,
        uint256 tokenId,
        uint256 traitId
    ) external view override returns (uint256) {
        return
            SafeCast.toUint256(
                this.getTraitInt256(tokenContract, tokenId, traitId)
            );
    }

    /**
     * Returns the trait data for a given token
     *
     * @param tokenContract  Address of the token's contract
     * @param tokenId        NFT tokenId or ERC1155 token type id
     * @param traitId        Id of the trait to retrieve
     *
     * @return Trait value as a bool
     */
    function getTraitBool(
        address tokenContract,
        uint256 tokenId,
        uint256 traitId
    ) external view override returns (bool) {
        return this.getTraitInt256(tokenContract, tokenId, traitId) == 1;
    }

    /**
     * Returns the trait data for a given token
     *
     * @param tokenContract  Address of the token's contract
     * @param tokenId        NFT tokenId or ERC1155 token type id
     * @param traitId        Id of the trait to retrieve
     *
     * @return Trait value as a string
     */
    function getTraitString(
        address tokenContract,
        uint256 tokenId,
        uint256 traitId
    ) external view override returns (string memory) {
        TraitDataType dataType = tokenTraitDataTypes[tokenContract][tokenId][
            traitId
        ];

        if (dataType != TraitDataType.STRING) {
            revert DataTypeMismatch(TraitDataType.STRING, dataType);
        }

        return
            abi.decode(
                tokenTraitValue[tokenContract][tokenId][traitId],
                (string)
            );
    }

    /**
     * @param traitId  Id of the trait to get metadata for
     * @return Metadata for the given trait
     */
    function getTraitMetadata(uint256 traitId)
        external
        view
        override
        returns (TraitMetadata memory)
    {
        return _traitMetadata[traitId];
    }

    /**
     * Returns whether or not the given token has a trait
     *
     * @param tokenContract  Address of the token's contract
     * @param tokenId        NFT tokenId or ERC1155 token type id
     * @param traitId        Id of the trait to retrieve
     *
     * @return Whether or not the token has the trait
     */
    function hasTrait(
        address tokenContract,
        uint256 tokenId,
        uint256 traitId
    ) external view override returns (bool) {
        return
            tokenTraitDataTypes[tokenContract][tokenId][traitId] !=
            TraitDataType.NOT_INITIALIZED;
    }

    /**
     * Generate a tokenURI based on a set of global properties and traits
     *
     * @param tokenContract     Address of the token contract
     * @param tokenId           Id of the token to generate traits for
     *
     * @return base64-encoded fully-formed tokenURI
     */
    function generateTokenURI(
        address tokenContract,
        uint256 tokenId,
        TokenURITrait[] memory extraTraits
    ) external view returns (string memory) {
        // Gather all dynamic trait ids
        uint256[] memory traitIds = this.getTraitIds(tokenContract, tokenId);

        // Fetch and process dynamic traits for this token
        TokenURITrait[] memory allTraits = new TokenURITrait[](
            traitIds.length + extraTraits.length
        );

        for (uint256 idx; idx < traitIds.length; ++idx) {
            uint256 traitId = traitIds[idx];
            TraitMetadata memory traitMetadata = this.getTraitMetadata(traitId);

            allTraits[idx].name = traitMetadata.name;
            allTraits[idx].dataType = traitMetadata.dataType;
            allTraits[idx].isTopLevelProperty = traitMetadata
                .isTopLevelProperty;
            allTraits[idx].value = this.getTraitBytes(
                tokenContract,
                tokenId,
                traitId
            );
        }

        // Append the extra traits onto the allTraits array
        for (uint256 idx; idx < extraTraits.length; ++idx) {
            allTraits[traitIds.length + idx] = extraTraits[idx];
        }

        // Generate JSON strings
        string memory propertiesJSON = _generatePropertiesJSON(allTraits);
        string memory attributesJSON = _generateAttributesJSON(allTraits);
        string memory comma = bytes(propertiesJSON).length > 0 ? "," : "";

        string memory metadata = string(
            abi.encodePacked(
                "{",
                propertiesJSON,
                comma,
                '"attributes":[',
                attributesJSON,
                "]}"
            )
        );

        return
            string(
                abi.encodePacked(
                    "data:application/json;base64,",
                    Base64.encode(bytes(metadata))
                )
            );
    }

    /**
     * @inheritdoc IERC165
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override
        returns (bool)
    {
        return
            interfaceId == type(ITraitsProvider).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

    /** PRIVATE **/

    /**
     * Sets a abi-encoded bytes trait value
     * @dev It's not recommended to use this function as it doesn't have type safety
     */
    function _setTraitBytes(
        address tokenContract,
        uint256 tokenId,
        uint256 traitId,
        bytes memory value,
        TraitDataType encodedType
    ) private {
        TraitMetadata memory traitMetadata = _requireTraitMetadata(traitId);

        if (
            encodedType != TraitDataType.NOT_INITIALIZED &&
            traitMetadata.dataType != encodedType
        ) {
            revert DataTypeMismatch(traitMetadata.dataType, encodedType);
        }

        TraitDataType dataType = tokenTraitDataTypes[tokenContract][tokenId][
            traitId
        ];

        if (
            dataType != TraitDataType.NOT_INITIALIZED &&
            traitMetadata.behavior != TraitBehavior.UNRESTRICTED
        ) {
            revert TraitAlreadyInitialized();
        }

        // Set new trait
        if (dataType == TraitDataType.NOT_INITIALIZED) {
            tokenTraitDataTypes[tokenContract][tokenId][traitId] = traitMetadata
                .dataType;
            tokenTraitIds[tokenContract][tokenId].push(traitId);
        }

        tokenTraitValue[tokenContract][tokenId][traitId] = value;
    }

    /** Reverts if the tokenContract is not allowlisted */
    function _requireAllowlistedTokenContract(address tokenContract)
        private
        view
    {
        if (
            _hasAccessRole(GAME_NFT_CONTRACT_ROLE, tokenContract) == false &&
            _hasAccessRole(GAME_ITEMS_CONTRACT_ROLE, tokenContract) == false
        ) {
            revert TokenNotAllowlisted();
        }
    }

    /** Reverts if the trait has not been initialized yet */
    function _requireTraitMetadata(uint256 traitId)
        private
        view
        returns (TraitMetadata memory)
    {
        TraitMetadata memory traitMetadata = _traitMetadata[traitId];
        if (traitMetadata.behavior == TraitBehavior.NOT_INITIALIZED) {
            revert TraitNotInitialized();
        }
        return traitMetadata;
    }

    /** INTERNAL **/

    function _generatePropertiesJSON(TokenURITrait[] memory allTraits)
        internal
        pure
        returns (string memory)
    {
        string memory propertiesJSON = "";
        bool isFirstElement = true;
        for (uint256 idx; idx < allTraits.length; ++idx) {
            TokenURITrait memory trait = allTraits[idx];
            if (trait.isTopLevelProperty == false) {
                continue;
            }

            string memory value = _traitValueToString(trait);
            string memory comma = isFirstElement ? "" : ",";

            propertiesJSON = string(
                abi.encodePacked(
                    propertiesJSON,
                    comma,
                    '"',
                    trait.name,
                    '":',
                    value
                )
            );
            isFirstElement = false;
        }

        return propertiesJSON;
    }

    /**
     * @param allTraits  All of the traits for a given token to use to generate a attributes JSON array
     * @return a JSON string for all of the attributes for the given token
     */
    function _generateAttributesJSON(TokenURITrait[] memory allTraits)
        internal
        view
        virtual
        returns (string memory)
    {
        string memory finalString = "";

        bool isFirstElement = true;
        for (uint256 idx; idx < allTraits.length; ++idx) {
            TokenURITrait memory trait = allTraits[idx];

            // Skip if its not an attribute type
            if (trait.isTopLevelProperty == true) {
                continue;
            }

            // Skip including attribute if the string value is empty
            if (
                trait.dataType == TraitDataType.STRING &&
                bytes(abi.decode(trait.value, (string))).length == 0
            ) {
                continue;
            }

            string memory json = _attributeJSON(trait);
            string memory comma = isFirstElement ? "" : ",";
            finalString = string(abi.encodePacked(finalString, comma, json));
            isFirstElement = false;
        }

        return finalString;
    }

    /** @return Token metadata attribute JSON string */
    function _attributeJSON(TokenURITrait memory trait)
        internal
        pure
        returns (string memory)
    {
        string memory value = _traitValueToString(trait);
        return
            string(
                abi.encodePacked(
                    '{"trait_type":"',
                    trait.name,
                    '","value":',
                    value,
                    "}"
                )
            );
    }

    /** Converts a trait's numeric or string value into a printable JSON string value */
    function _traitValueToString(TokenURITrait memory trait)
        internal
        pure
        returns (string memory)
    {
        TraitDataType dataType = trait.dataType;

        if (dataType == TraitDataType.STRING) {
            string memory value = abi.decode(trait.value, (string));
            return string(abi.encodePacked('"', value, '"'));
        } else if (dataType == TraitDataType.BOOL) {
            bool value = abi.decode(trait.value, (bool));
            return value ? "true" : "false";
        } else if (dataType == TraitDataType.UINT) {
            uint256 value = abi.decode(trait.value, (uint256));
            return value.toString();
        } else if (dataType == TraitDataType.INT) {
            int256 value = abi.decode(trait.value, (int256));
            return UtilLibrary.int2str(value); // Convert int256 to string
        }

        revert InvalidTraitDataType(trait.dataType);
    }
}