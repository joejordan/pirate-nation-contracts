// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

// @title Interface the game's ACL / Management Layer
interface IGameRegistry is IERC165 {
    /**
     * @dev Returns `true` if `account` has been granted `role`.
     */
    function hasAccessRole(bytes32 role, address account)
        external
        view
        returns (bool);

    /** @return Whether or not the registry is paused */
    function paused() external view returns (bool);

    /**
     * Registers a system by id
     *
     * @param systemId          Id of the system
     * @param systemAddress     Address of the system contract
     */
    function registerSystem(uint256 systemId, address systemAddress) external;

    /** @return System based on an id */
    function getSystem(uint256 systemId) external view returns (address);

    /** @return Authorized Player account for an address
     * @param operatorAddress   Address of the Operator account
     */
    function getPlayerAccount(address operatorAddress)
        external
        view
        returns (address);
}