// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/**
 * @title SusdsGem
 * @author amusingaxl
 * @notice Atomic converter for sUSDS <-> GEM (e.g., USDC) conversions via Sky Protocol
 * @dev This contract provides gas-efficient, atomic conversions between sUSDS and gems (stablecoins)
 *      through Sky Protocol's conversion infrastructure. All operations are non-custodial and atomic.
 *
 *      Conversion paths:
 *      - sUSDS -> GEM: sUSDS -> USDS -> DAI -> GEM
 *      - GEM -> sUSDS: GEM -> DAI -> USDS -> sUSDS
 *
 *      DAI Liquidity Management:
 *      The LitePSM uses a pre-minted DAI buffer for efficient swaps. When converting
 *      GEM -> sUSDS, if the PSM's DAI balance is insufficient, this contract will:
 *      1. Check if enough liquidity can be obtained via rush() (available minting capacity)
 *      2. Call fill() to mint additional DAI into the PSM if needed
 *      This ensures swaps can proceed even when the PSM's buffer is depleted.
 *
 *      Note: DAI-USDS conversion is always 1:1, so from a user perspective, the conversion
 *      appears as sUSDS <-> USDS <-> GEM. Error messages reference USDS instead of DAI
 *      to simplify the mental model for users.
 */
interface ERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface SUSDSLike {
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function asset() external view returns (address);
}

interface DaiUsdsLike {
    function daiToUsds(address usr, uint256 wad) external;
    function usdsToDai(address usr, uint256 wad) external;
    function usds() external view returns (address);
    function dai() external view returns (address);
}

interface LitePSMLike {
    function sellGem(address usr, uint256 gemAmt) external returns (uint256 daiAmt);
    function buyGem(address usr, uint256 gemAmt) external returns (uint256 gemBought);
    function dai() external view returns (address);
    function gem() external view returns (address);
    function to18ConversionFactor() external view returns (uint256);
    function rush() external view returns (uint256 wad);
    function fill() external returns (uint256 wad);
    function buf() external view returns (uint256);
}

/**
 * @title SusdsGem
 * @notice Non-custodial converter for atomic sUSDS <-> GEM swaps
 * @dev All state variables are immutable for gas efficiency and security
 */
contract SusdsGem {
    /// @notice Basis points constant for percentage calculations (100.00%)
    uint256 private constant BPS = 100_00;

    /// @notice sUSDS token contract address
    address public immutable SUSDS;

    /// @notice DAI-USDS converter contract address
    address public immutable DAI_USDS;

    /// @notice LitePSM contract address for GEM swaps
    address public immutable LITE_PSM;

    /// @notice USDS token address (derived from sUSDS)
    address public immutable USDS;

    /// @notice DAI token address (derived from LitePSM)
    address public immutable DAI;

    /// @notice GEM token address (e.g., USDC, derived from LitePSM)
    address public immutable GEM;

    /// @notice Conversion factor for decimal precision adjustment between DAI (18 decimals) and GEM
    uint256 public immutable CONVERSION_FACTOR;

    /**
     * @notice Initializes the converter with Sky Protocol contracts
     * @dev Sets up all necessary approvals and validates contract compatibility
     * @param _sUSDS Address of the sUSDS token contract
     * @param _DAI_USDS Address of the DAI-USDS converter contract
     * @param _LITE_PSM Address of the LitePSM contract for the target GEM
     */
    constructor(address _sUSDS, address _DAI_USDS, address _LITE_PSM) {
        SUSDS = _sUSDS;
        DAI_USDS = _DAI_USDS;
        LITE_PSM = _LITE_PSM;

        // Get USDS from sUSDS
        USDS = SUSDSLike(_sUSDS).asset();

        // Get DAI from LitePSM
        DAI = LitePSMLike(_LITE_PSM).dai();

        // Get gem from LitePSM
        GEM = LitePSMLike(_LITE_PSM).gem();

        // Sanity check: USDS address from sUSDS must match USDS address from DAI_USDS
        require(USDS == DaiUsdsLike(_DAI_USDS).usds(), "SusdsGem/usds-mismatch");

        // Sanity check: DAI address from DAI_USDS must match DAI address from LitePSM
        require(DAI == DaiUsdsLike(_DAI_USDS).dai(), "SusdsGem/dai-mismatch");

        // Get conversion factor for DAI to gem precision conversion
        CONVERSION_FACTOR = LitePSMLike(_LITE_PSM).to18ConversionFactor();

        ERC20Like(USDS).approve(_DAI_USDS, type(uint256).max);
        ERC20Like(DAI).approve(_LITE_PSM, type(uint256).max);
        ERC20Like(GEM).approve(_LITE_PSM, type(uint256).max);
        ERC20Like(DAI).approve(_DAI_USDS, type(uint256).max);
        ERC20Like(USDS).approve(_sUSDS, type(uint256).max);
    }

    /**
     * @notice Converts sUSDS to GEM with no slippage tolerance
     * @param dst Address to receive the GEM tokens
     * @param sUsdsWad Amount of sUSDS to convert (in wad precision, 18 decimals)
     * @return gemAmt Amount of GEM tokens sent to destination
     */
    function susdsToGem(address dst, uint256 sUsdsWad) external returns (uint256 gemAmt) {
        // No slippage tolerance - expect exact 1:1:1 conversion from USDS to Dai to gem
        return _susdsToGem(dst, sUsdsWad, 0);
    }

    /**
     * @notice Converts sUSDS to GEM with custom slippage protection
     * @param dst Address to receive the GEM tokens
     * @param sUsdsWad Amount of sUSDS to convert (in wad precision, 18 decimals)
     * @param maxSlippageBps Maximum acceptable slippage in basis points (1 BPS = 0.01%)
     * @return gemAmt Amount of GEM tokens sent to destination
     */
    function susdsToGem(address dst, uint256 sUsdsWad, uint256 maxSlippageBps) external returns (uint256 gemAmt) {
        return _susdsToGem(dst, sUsdsWad, maxSlippageBps);
    }

    /**
     * @notice Converts entire sUSDS balance to GEM with no slippage tolerance
     * @param dst Address to receive the GEM tokens
     * @return gemAmt Amount of GEM tokens sent to destination
     */
    function allSusdsToGem(address dst) external returns (uint256 gemAmt) {
        uint256 sUsdsBalance = ERC20Like(SUSDS).balanceOf(msg.sender);
        require(sUsdsBalance > 0, "SusdsGem/no-susds-balance");
        return _susdsToGem(dst, sUsdsBalance, 0);
    }

    /**
     * @notice Converts entire sUSDS balance to GEM with custom slippage protection
     * @param dst Address to receive the GEM tokens
     * @param maxSlippageBps Maximum acceptable slippage in basis points (1 BPS = 0.01%)
     * @return gemAmt Amount of GEM tokens sent to destination
     */
    function allSusdsToGem(address dst, uint256 maxSlippageBps) external returns (uint256 gemAmt) {
        uint256 sUsdsBalance = ERC20Like(SUSDS).balanceOf(msg.sender);
        require(sUsdsBalance > 0, "SusdsGem/no-susds-balance");
        return _susdsToGem(dst, sUsdsBalance, maxSlippageBps);
    }

    /**
     * @dev Internal function to handle sUSDS to GEM conversion
     * @param dst Destination address for GEM tokens
     * @param sUsdsWad Amount of sUSDS to convert
     * @param maxSlippageBps Maximum acceptable slippage in basis points
     * @return gemAmt Amount of GEM tokens transferred to destination
     */
    function _susdsToGem(address dst, uint256 sUsdsWad, uint256 maxSlippageBps) internal returns (uint256 gemAmt) {
        require(maxSlippageBps <= BPS, "SusdsGem/slippage-too-high");

        // Since the user already approved this contract, we can redeem directly
        uint256 usdsWad = SUSDSLike(SUSDS).redeem(sUsdsWad, address(this), msg.sender);
        require(usdsWad > 0, "SusdsGem/redeem-failed");

        // DAI-USDS conversion is always 1:1
        DaiUsdsLike(DAI_USDS).usdsToDai(address(this), usdsWad);

        // buyGem expects amount in gem precision
        // Use CONVERSION_FACTOR to convert from DAI (18 decimals) to gem precision
        gemAmt = usdsWad / CONVERSION_FACTOR;
        require(gemAmt > 0, "SusdsGem/amount-too-small");

        // Buy gems directly to the dst address
        uint256 daiUsed = LitePSMLike(LITE_PSM).buyGem(dst, gemAmt);

        // Check slippage - daiUsed should be approximately equal to usdsWad
        // Note: Since DAI-USDS conversion is always 1:1, we treat DAI amounts as USDS for user-facing messages
        uint256 maxDai = usdsWad * (BPS + maxSlippageBps) / BPS;
        require(daiUsed <= maxDai, "SusdsGem/too-much-usds-used");
    }

    /**
     * @notice Converts GEM to sUSDS with no slippage tolerance
     * @param dst Address to receive the sUSDS tokens
     * @param gemAmt Amount of GEM to convert (in GEM precision)
     * @return susdsWad Amount of sUSDS tokens sent to destination
     */
    function gemToSusds(address dst, uint256 gemAmt) external returns (uint256 susdsWad) {
        return _gemToSusds(dst, gemAmt, 0);
    }

    /**
     * @notice Converts GEM to sUSDS with custom slippage protection
     * @param dst Address to receive the sUSDS tokens
     * @param gemAmt Amount of GEM to convert (in GEM precision)
     * @param maxSlippageBps Maximum acceptable slippage in basis points (1 BPS = 0.01%)
     * @return susdsWad Amount of sUSDS tokens sent to destination
     */
    function gemToSusds(address dst, uint256 gemAmt, uint256 maxSlippageBps) external returns (uint256 susdsWad) {
        return _gemToSusds(dst, gemAmt, maxSlippageBps);
    }

    /**
     * @notice Converts entire GEM balance to sUSDS with no slippage tolerance
     * @param dst Address to receive the sUSDS tokens
     * @return susdsWad Amount of sUSDS tokens sent to destination
     */
    function allGemToSusds(address dst) external returns (uint256 susdsWad) {
        uint256 gemBalance = ERC20Like(GEM).balanceOf(msg.sender);
        require(gemBalance > 0, "SusdsGem/no-gem-balance");
        return _gemToSusds(dst, gemBalance, 0);
    }

    /**
     * @notice Converts entire GEM balance to sUSDS with custom slippage protection
     * @param dst Address to receive the sUSDS tokens
     * @param maxSlippageBps Maximum acceptable slippage in basis points (1 BPS = 0.01%)
     * @return susdsWad Amount of sUSDS tokens sent to destination
     */
    function allGemToSusds(address dst, uint256 maxSlippageBps) external returns (uint256 susdsWad) {
        uint256 gemBalance = ERC20Like(GEM).balanceOf(msg.sender);
        require(gemBalance > 0, "SusdsGem/no-gem-balance");
        return _gemToSusds(dst, gemBalance, maxSlippageBps);
    }

    /**
     * @dev Internal function to handle GEM to sUSDS conversion
     * @param dst Destination address for sUSDS tokens
     * @param gemAmt Amount of GEM to convert
     * @param maxSlippageBps Maximum acceptable slippage in basis points
     * @return susdsWad Amount of sUSDS tokens transferred to destination
     */
    function _gemToSusds(address dst, uint256 gemAmt, uint256 maxSlippageBps) internal returns (uint256 susdsWad) {
        require(maxSlippageBps <= BPS, "SusdsGem/slippage-too-high");

        ERC20Like(GEM).transferFrom(msg.sender, address(this), gemAmt);

        // Note: Since DAI-USDS conversion is always 1:1, we treat DAI amounts as USDS for user-facing messages
        uint256 minDai = gemAmt * CONVERSION_FACTOR * (BPS - maxSlippageBps) / BPS;
        require(minDai > 0, "SusdsGem/amount-too-small");

        _ensureDaiLiquidity(minDai);

        uint256 daiReceived = LitePSMLike(LITE_PSM).sellGem(address(this), gemAmt);
        require(daiReceived >= minDai, "SusdsGem/insufficient-usds");

        // DAI-USDS conversion is always 1:1
        DaiUsdsLike(DAI_USDS).daiToUsds(address(this), daiReceived);

        // Deposit USDS to get sUSDS shares directly to dst (daiReceived == usdsWad due to 1:1)
        susdsWad = SUSDSLike(SUSDS).deposit(daiReceived, dst);
        require(susdsWad > 0, "SusdsGem/deposit-failed");
    }

    /**
     * @dev Ensures the LitePSM has sufficient DAI liquidity for the swap
     * @param minDai Minimum amount of DAI needed for the swap
     *
     * The LitePSM maintains a pre-minted DAI buffer for efficient swaps.
     * If the current balance is insufficient, this function will:
     * 1. Check available minting capacity via rush()
     * 2. Verify that current balance + rush() covers the needed amount
     * 3. Call fill() to mint additional DAI into the PSM
     *
     * Reverts with "insufficient-liquidity" if the PSM cannot provide enough DAI
     * even after filling the buffer.
     */
    function _ensureDaiLiquidity(uint256 minDai) internal {
        // Check if there's enough DAI balance in the LitePSM for the swap
        uint256 balance = ERC20Like(DAI).balanceOf(LITE_PSM);

        if (balance < minDai) {
            // Check if filling the buffer will provide enough liquidity
            // rush() returns the amount of DAI that can be minted
            uint256 rush = LitePSMLike(LITE_PSM).rush();
            require(minDai <= balance + rush, "SusdsGem/insufficient-liquidity");

            // Fill the buffer by minting DAI into the PSM
            LitePSMLike(LITE_PSM).fill();
        }
    }
}
