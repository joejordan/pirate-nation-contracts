// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

import "@opengsn/contracts/src/interfaces/IERC2771Recipient.sol";

import {PAUSER_ROLE, RANDOMIZER_ROLE, DEPOSITOR_ROLE, MANAGER_ROLE, MINTER_ROLE, GAME_CURRENCY_CONTRACT_ROLE, GAME_NFT_CONTRACT_ROLE, GAME_ITEMS_CONTRACT_ROLE, GAME_LOGIC_CONTRACT_ROLE, TRUSTED_FORWARDER_ROLE} from "./Constants.sol";

import "./interfaces/IGameRegistry.sol";

/** @title Contract to track and limit access by accounts in the same block */
contract GameRegistry is
    AccessControlUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    IERC2771Recipient,
    IGameRegistry
{
    /// @notice Block limit on transmitting a signed operator registration message
    uint256 public constant OPERATOR_MESSAGE_BLOCK_LIMIT = 30; // 30 blocks

    /// @notice Operator registration cooldown time in secons
    uint256 public constant REGISTER_OPERATOR_COOLDOWN_LIMIT = 60 * 2; // 2 minutes

    /// @notice Last time the player registered an operator wallet
    mapping(address => uint256) public lastRegisterOperatorTime;

    /** LIBRARY METHODS **/

    using EnumerableSet for EnumerableSet.AddressSet;

    /** TYPES **/

    /// @notice Player Account structure
    struct PlayerAccount {
        address playerAddress;
        uint256 expiration;
    }

    /** MEMBERS **/

    /// @notice System registry
    mapping(uint256 => address) private _systemRegistry;

    /// @notice Registry of current operator address to the player account
    mapping(address => PlayerAccount) private _operatorToPlayerAccount;

    /// @notice Registry of player account mapped to authorized operators
    mapping(address => EnumerableSet.AddressSet)
        private _playerToOperatorAddresses;

    /** EVENTS **/

    /// @notice Emitted when an Operator address is registered
    event OperatorRegistered(
        address player,
        address operator,
        uint256 expiration
    );

    /// @notice Emitted when a System address is registered
    event SystemRegistered(uint256 indexed id, address indexed systemAddress);

    /// @notice Emitted when an Operator address is removed
    event OperatorDeregistered(address operator, address player);

    /** ERRORS **/

    /// @notice Operator
    error InvalidOperatorAddress();

    /// @notice Operator address must send transaction
    error InvalidCaller();

    /// @notice Player does not match signature
    error PlayerSignerMismatch(address expected, address actual);

    /// @notice Operator is registered to a different address, deregister first
    error OperatorAlreadyRegistered();

    /// @notice Invalid expiration timestamp provided
    error InvalidExpirationTimestamp();

    /// @notice Invalid block number (future block)
    error InvalidBlockNumber();

    /// @notice Invalid block number (expired)
    error InvalidExpirationBlockNumber();

    /// @notice Degregister request must come from player or operator
    error InvalidDeregisterCaller();

    /// @notice Operator has already expired
    error OperatorExpired();

    /// @notice Operator was not registered
    error OperatorNotRegistered();

    /// @notice Register operator in cooldown
    error RegisterOperatorInCooldown();

    /// @notice Deregister operator in cooldown
    error DeregisterOperatorInCooldown();

    /// @notice Not authorized to perform action
    error MissingRole(address account, bytes32 expectedRole);

    /** SETUP **/

    /**
     * Initializer for this upgradeable contract
     */
    function initialize() public initializer {
        __AccessControl_init();
        __Ownable_init();
        __Pausable_init();

        // Give admin access role to owner
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());

        _setRoleAdmin(PAUSER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(RANDOMIZER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(DEPOSITOR_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(MINTER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(MANAGER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(GAME_NFT_CONTRACT_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(GAME_CURRENCY_CONTRACT_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(GAME_ITEMS_CONTRACT_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(GAME_LOGIC_CONTRACT_ROLE, DEFAULT_ADMIN_ROLE);

        _pause();
    }

    /** EXTERNAL **/

    /**
     * Pause/Unpause the game and ALL the systems that utilize this game
     *
     * @param _paused Whether or pause or unpause
     */
    function setPaused(bool _paused) external {
        if (_msgSender() == owner() || hasRole(PAUSER_ROLE, _msgSender())) {
            if (_paused) {
                _pause();
            } else {
                _unpause();
            }
        } else {
            revert MissingRole(_msgSender(), PAUSER_ROLE);
        }
    }

    /** @return Whether or not the registry is paused */
    function paused()
        public
        view
        override(IGameRegistry, PausableUpgradeable)
        returns (bool)
    {
        return PausableUpgradeable.paused();
    }

    /**
     * Registers a system by id
     *
     * @param systemId          Id of the system
     * @param systemAddress     Address of the system contract
     */
    function registerSystem(uint256 systemId, address systemAddress)
        external
        onlyOwner
    {
        _systemRegistry[systemId] = systemAddress;

        emit SystemRegistered(systemId, systemAddress);
    }

    /** @return System based on an id */
    function getSystem(uint256 systemId) external view returns (address) {
        return _systemRegistry[systemId];
    }

    /**
     * @inheritdoc IERC165
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(IERC165, AccessControlUpgradeable)
        returns (bool)
    {
        return
            interfaceId == type(IGameRegistry).interfaceId ||
            interfaceId == type(IERC165).interfaceId ||
            AccessControlUpgradeable.supportsInterface(interfaceId);
    }

    /**
     * @dev Returns `true` if `account` has been granted `role`.
     */
    function hasAccessRole(bytes32 role, address account)
        public
        view
        override
        returns (bool)
    {
        return AccessControlUpgradeable.hasRole(role, account);
    }

    /**
     * Returns the address of the account the operatorAddress is authorized to
     *
     * @param operatorAddress Address the sending controller
     */
    function getPlayerAccount(address operatorAddress)
        external
        view
        returns (address)
    {
        if (operatorAddress == address(0)) {
            revert InvalidOperatorAddress();
        }

        PlayerAccount memory account = _operatorToPlayerAccount[
            operatorAddress
        ];

        address playerAddress = account.playerAddress;

        if (playerAddress != address(0)) {
            if (
                account.expiration < block.timestamp && account.expiration != 0
            ) {
                revert OperatorExpired();
            }
        } else {
            return operatorAddress;
        }

        return playerAddress;
    }

    /**
     * Called in order to retrieve message to sign to register an oeperator
     *
     * @param player address operator is being registered for
     * @param operator address of operator being registered
     * @param expiration block time for registration (or 0 for infinite)
     * @param blockNumber the message was signed at
     */
    function getOperatorAccountRegistrationMessageToSign(
        address player,
        address operator,
        uint256 expiration,
        uint256 blockNumber
    ) public pure returns (bytes memory) {
        return
            abi.encodePacked(
                "Authorize operator account ",
                Strings.toHexString(uint256(uint160(operator)), 20),
                " to perform gameplay actions on behalf of player account ",
                Strings.toHexString(uint256(uint160(player)), 20),
                " with expiration ",
                Strings.toString(expiration),
                " signed at block ",
                Strings.toString(blockNumber)
            );
    }

    /**
     * Called by an Operator Address with a signature from a Player Address authorizing it until a given expiration time
     *
     * @param signature from signer/player address authorizing operator until expiration time
     * @param player address of player being registered
     * @param operator address of operator being registered
     * @param expiration block time for registration (or 0 for infinite)
     * @param blockNumber the message was signed at
     */
    function registerOperator(
        bytes calldata signature,
        address player,
        address operator,
        uint256 expiration,
        uint256 blockNumber
    ) external whenNotPaused {
        if (_msgSender() != operator) {
            revert InvalidCaller();
        }
        if (
            (block.timestamp - lastRegisterOperatorTime[player]) <
            REGISTER_OPERATOR_COOLDOWN_LIMIT
        ) {
            revert RegisterOperatorInCooldown();
        }
        if (operator == player || operator == address(0)) {
            revert InvalidOperatorAddress();
        }
        if (expiration < block.timestamp && expiration != 0) {
            revert InvalidExpirationTimestamp();
        }
        if (blockNumber > block.number) {
            revert InvalidBlockNumber();
        }
        if (block.number > blockNumber + OPERATOR_MESSAGE_BLOCK_LIMIT) {
            revert InvalidExpirationBlockNumber();
        }

        PlayerAccount memory currentAccount = _operatorToPlayerAccount[
            operator
        ];

        if (
            currentAccount.playerAddress != address(0) &&
            currentAccount.playerAddress != player
        ) {
            revert OperatorAlreadyRegistered();
        }

        bytes memory message = getOperatorAccountRegistrationMessageToSign(
            player,
            operator,
            expiration,
            blockNumber
        );
        bytes32 digest = ECDSA.toEthSignedMessageHash(message);
        address recoveredSigner = ECDSA.recover(digest, signature);

        if (player != recoveredSigner) {
            revert PlayerSignerMismatch(player, recoveredSigner);
        }

        _operatorToPlayerAccount[operator] = PlayerAccount({
            playerAddress: player,
            expiration: expiration
        });

        _playerToOperatorAddresses[player].add(operator);

        // Track cooldown timer
        lastRegisterOperatorTime[player] = block.timestamp;

        emit OperatorRegistered(player, operator, expiration);
    }

    /**
     * Called by an Operator or Player to deregister an Operator account
     *
     * @param operatorToDeregister address of operator to deregister
     */
    function deregisterOperator(address operatorToDeregister) external {
        address playerAddress = _operatorToPlayerAccount[operatorToDeregister]
            .playerAddress;

        if (playerAddress == address(0)) {
            revert OperatorNotRegistered();
        }
        if (
            operatorToDeregister != _msgSender() &&
            playerAddress != _msgSender()
        ) {
            revert InvalidDeregisterCaller();
        }

        delete _operatorToPlayerAccount[operatorToDeregister];

        bool operatorRemovedFromPlayer = _playerToOperatorAddresses[
            playerAddress
        ].remove(operatorToDeregister);

        if (operatorRemovedFromPlayer != true) {
            revert OperatorNotRegistered();
        }

        emit OperatorDeregistered(operatorToDeregister, playerAddress);
    }

    /**
     * Returns an array of registered Operators for a Player address
     *
     * @param player address to retrieve operators for
     */
    function getRegisteredOperators(address player)
        external
        view
        returns (address[] memory)
    {
        return _playerToOperatorAddresses[player].values();
    }

    /// @inheritdoc IERC2771Recipient
    function isTrustedForwarder(address forwarder)
        public
        view
        virtual
        override
        returns (bool)
    {
        return hasAccessRole(TRUSTED_FORWARDER_ROLE, forwarder);
    }

    /// @inheritdoc IERC2771Recipient
    function _msgSender()
        internal
        view
        virtual
        override(ContextUpgradeable, IERC2771Recipient)
        returns (address ret)
    {
        if (msg.data.length >= 20 && isTrustedForwarder(msg.sender)) {
            assembly {
                ret := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            ret = msg.sender;
        }
    }

    /// @inheritdoc IERC2771Recipient
    function _msgData()
        internal
        view
        virtual
        override(ContextUpgradeable, IERC2771Recipient)
        returns (bytes calldata ret)
    {
        if (msg.data.length >= 20 && isTrustedForwarder(msg.sender)) {
            return msg.data[0:msg.data.length - 20];
        } else {
            return msg.data;
        }
    }
}