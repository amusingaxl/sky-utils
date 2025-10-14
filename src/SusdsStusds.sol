// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/**
 * @title SusdsStusds
 * @author amusingaxl
 * @notice Atomic converter for sUSDS <-> stUSDS conversions via Sky Protocol
 * @dev This contract provides gas-efficient, atomic conversions between sUSDS and stUSDS tokens.
 *      Both tokens are ERC4626 vaults backed by the same underlying USDS asset, allowing for
 *      seamless conversions without requiring intermediate USDS transactions.
 *
 *      Conversion paths:
 *      - sUSDS -> stUSDS: redeem sUSDS for USDS, deposit USDS into stUSDS
 *      - stUSDS -> sUSDS: redeem stUSDS for USDS, deposit USDS into sUSDS
 *      - Direct USDS conversions: withdraw/deposit directly using USDS amounts
 *
 *      All operations are non-custodial and atomic, ensuring users receive their tokens
 *      in a single transaction without holding intermediate assets.
 */
contract SusdsStusds {
    /// @notice sUSDS token contract (Savings USDS vault)
    ERC4626Like public immutable susds;

    /// @notice stUSDS token contract (Staked USDS vault)
    ERC4626Like public immutable stusds;

    /// @notice USDS token (underlying asset for both vaults)
    ERC20Like public immutable usds;

    /**
     * @notice Initializes the converter with sUSDS and stUSDS contracts
     * @dev Validates that both vaults use the same underlying USDS asset
     * @param _susds Address of the sUSDS token contract
     * @param _stusds Address of the stUSDS token contract
     */
    constructor(address _susds, address _stusds) {
        require(ERC4626Like(_susds).asset() == ERC4626Like(_stusds).asset(), "SusdsStusds/asset-mismatch");

        susds = ERC4626Like(_susds);
        stusds = ERC4626Like(_stusds);
        usds = ERC20Like(ERC4626Like(_susds).asset());

        // Set up approvals for USDS transfers to both vaults
        usds.approve(_susds, type(uint256).max);
        usds.approve(_stusds, type(uint256).max);
    }

    /**
     * @notice Converts specified amount of sUSDS to stUSDS
     * @dev Redeems sUSDS shares for USDS, then deposits USDS into stUSDS
     * @param dst Address to receive the stUSDS tokens
     * @param wad Amount of sUSDS shares to convert
     * @return usdsAmount Amount of USDS assets swapped
     */
    function susdsToStusds(address dst, uint256 wad) external returns (uint256 usdsAmount) {
        return _susdsToStusds(dst, wad);
    }

    /**
     * @notice Converts entire sUSDS balance to stUSDS
     * @dev Convenience function to convert all user's sUSDS in one transaction
     * @param dst Address to receive the stUSDS tokens
     * @return usdsAmount Amount of USDS assets swapped
     */
    function allSusdsToStusds(address dst) external returns (uint256 usdsAmount) {
        uint256 sUsdsBalance = susds.balanceOf(msg.sender);
        require(sUsdsBalance > 0, "SusdsStusds/no-susds-balance");
        return _susdsToStusds(dst, sUsdsBalance);
    }

    /**
     * @dev Internal function to handle sUSDS to stUSDS conversion
     * @param dst Destination address for stUSDS tokens
     * @param wad Amount of sUSDS shares to convert
     * @return usdsAmount Amount of USDS assets swapped
     */
    function _susdsToStusds(address dst, uint256 wad) internal returns (uint256 usdsAmount) {
        usdsAmount = susds.redeem(wad, address(this), msg.sender);
        stusds.deposit(usdsAmount, dst);
    }

    /**
     * @notice Converts specified amount of stUSDS to sUSDS
     * @dev Redeems stUSDS shares for USDS, then deposits USDS into sUSDS
     * @param dst Address to receive the sUSDS tokens
     * @param wad Amount of stUSDS shares to convert
     * @return usdsAmount Amount of USDS assets swapped
     */
    function stusdsToSusds(address dst, uint256 wad) external returns (uint256 usdsAmount) {
        return _stusdsToSusds(dst, wad);
    }

    /**
     * @notice Converts entire stUSDS balance to sUSDS
     * @dev Convenience function to convert all user's stUSDS in one transaction
     * @param dst Address to receive the sUSDS tokens
     * @return usdsAmount Amount of USDS assets swapped
     */
    function allStusdsToSusds(address dst) external returns (uint256 usdsAmount) {
        uint256 sUsdsBalance = stusds.balanceOf(msg.sender);
        require(sUsdsBalance > 0, "SusdsStusds/no-stusds-balance");
        return _stusdsToSusds(dst, sUsdsBalance);
    }

    /**
     * @dev Internal function to handle stUSDS to sUSDS conversion
     * @param dst Destination address for sUSDS tokens
     * @param wad Amount of stUSDS shares to convert
     * @return usdsAmount Amount of USDS assets swapped
     */
    function _stusdsToSusds(address dst, uint256 wad) internal returns (uint256 usdsAmount) {
        usdsAmount = stusds.redeem(wad, address(this), msg.sender);
        susds.deposit(usdsAmount, dst);
    }

    /**
     * @notice Converts USDS amount from sUSDS to stUSDS using withdraw/deposit
     * @dev Alternative conversion method using USDS amounts instead of shares
     * @param dst Address to receive the stUSDS tokens
     * @param wad Amount of USDS assets to convert
     * @return stusdsSharesOut Amount of stUSDS shares minted
     * @return susdsSharesIn Amount of sUSDS shares burned
     */
    function usdsFromSusdsToStusds(address dst, uint256 wad)
        external
        returns (uint256 stusdsSharesOut, uint256 susdsSharesIn)
    {
        susdsSharesIn = susds.withdraw(wad, address(this), msg.sender);
        stusdsSharesOut = stusds.deposit(wad, dst);
    }

    /**
     * @notice Converts USDS amount from stUSDS to sUSDS using withdraw/deposit
     * @dev Alternative conversion method using USDS amounts instead of shares
     * @param dst Address to receive the sUSDS tokens
     * @param wad Amount of USDS assets to convert
     * @return susdsSharesOut Amount of sUSDS shares minted
     * @return stusdsSharesIn Amount of stUSDS shares burned
     */
    function usdsFromStusdsToSusds(address dst, uint256 wad)
        external
        returns (uint256 susdsSharesOut, uint256 stusdsSharesIn)
    {
        stusdsSharesIn = stusds.withdraw(wad, address(this), msg.sender);
        susdsSharesOut = susds.deposit(wad, dst);
    }
}

interface ERC4626Like {
    function asset() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 assets, address receiver, address) external returns (uint256);
    function withdraw(uint256 assets, address receiver, address) external returns (uint256);
}

interface ERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
