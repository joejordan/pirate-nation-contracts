// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.9;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {MINTER_ROLE} from "../../Constants.sol";

import {IGoldToken, ID} from "./IGoldToken.sol";
import {GameRegistryConsumer} from "../../GameRegistryConsumer.sol";

/** @title In-game Currency: Gold */
contract GoldToken is IGoldToken, GameRegistryConsumer, ERC20 {
    constructor(address gameRegistryAddress)
        ERC20("Pirate Gold", "PGLD")
        GameRegistryConsumer(gameRegistryAddress, ID)
    {
        // Do nothing
    }

    /**
     * Mint token to recipient
     *
     * @param to      The recipient of the token
     * @param amount  The amount of token to mint
     */
    function mint(address to, uint256 amount)
        external
        override
        whenNotPaused
        onlyRole(MINTER_ROLE)
    {
        _mint(to, amount);
    }

    /**
     * Burn token from holder
     *
     * @param from    The holder of the token
     * @param amount  The amount of token to burn
     */
    function burn(address from, uint256 amount)
        external
        override
        whenNotPaused
        onlyRole(MINTER_ROLE)
    {
        _burn(from, amount);
    }

    /**
     * @inheritdoc ERC20
     * @dev Note: minters can also move currency around to allow in-game actions.
     */
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public virtual override(ERC20, IERC20) returns (bool) {
        // Minters can move currency around to enable gameplay
        if (_hasAccessRole(MINTER_ROLE, _msgSender())) {
            // Note this avoids events
            _transfer(sender, recipient, amount);
            return true;
        }

        // Normal ERC20 security flow (need approval, etc.)
        return super.transferFrom(sender, recipient, amount);
    }

    /**
     * Message sender override to get Context to work with meta transactions
     *
     */
    function _msgSender()
        internal
        view
        override(Context, GameRegistryConsumer)
        returns (address)
    {
        return GameRegistryConsumer._msgSender();
    }

    /**
     * Message data override to get Context to work with meta transactions
     *
     */
    function _msgData()
        internal
        view
        override(Context, GameRegistryConsumer)
        returns (bytes memory)
    {
        return GameRegistryConsumer._msgData();
    }
}