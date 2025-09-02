// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title SusdsGem
 * @notice Converter for sUSDS <-> GEM (e.g., USDC) conversions
 * @dev This contract handles conversions between sUSDS and various gems (stablecoins) through
 *      the following intermediary steps:
 *      - sUSDS -> GEM: sUSDS -> USDS -> DAI -> GEM
 *      - GEM -> sUSDS: GEM -> DAI -> USDS -> sUSDS
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

contract SusdsGem {
    uint256 private constant BPS = 100_00;

    address public immutable SUSDS;
    address public immutable DAI_USDS;
    address public immutable LITE_PSM;
    address public immutable USDS;
    address public immutable DAI;
    address public immutable GEM;
    uint256 public immutable CONVERSION_FACTOR;

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

    function susdsToGem(address dst, uint256 sUsdsWad) external returns (uint256 gemAmt) {
        // No slippage tolerance - expect exact 1:1:1 conversion from USDS to Dai to gem
        return _susdsToGem(dst, sUsdsWad, 0);
    }

    function susdsToGem(address dst, uint256 sUsdsWad, uint256 maxSlippageBps) external returns (uint256 gemAmt) {
        return _susdsToGem(dst, sUsdsWad, maxSlippageBps);
    }

    function allSusdsToGem(address dst) external returns (uint256 gemAmt) {
        uint256 sUsdsBalance = ERC20Like(SUSDS).balanceOf(msg.sender);
        require(sUsdsBalance > 0, "SusdsGem/no-susds-balance");
        return _susdsToGem(dst, sUsdsBalance, 0);
    }

    function allSusdsToGem(address dst, uint256 maxSlippageBps) external returns (uint256 gemAmt) {
        uint256 sUsdsBalance = ERC20Like(SUSDS).balanceOf(msg.sender);
        require(sUsdsBalance > 0, "SusdsGem/no-susds-balance");
        return _susdsToGem(dst, sUsdsBalance, maxSlippageBps);
    }

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
        uint256 maxUsableDai = usdsWad * (BPS + maxSlippageBps) / BPS;
        require(daiUsed <= maxUsableDai, "SusdsGem/too-much-usds-used");
    }

    function gemToSusds(address dst, uint256 gemAmt) external returns (uint256 susdsWad) {
        return _gemToSusds(dst, gemAmt, 0);
    }

    function gemToSusds(address dst, uint256 gemAmt, uint256 maxSlippageBps) external returns (uint256 susdsWad) {
        return _gemToSusds(dst, gemAmt, maxSlippageBps);
    }

    function allGemToSusds(address dst) external returns (uint256 susdsWad) {
        uint256 gemBalance = ERC20Like(GEM).balanceOf(msg.sender);
        require(gemBalance > 0, "SusdsGem/no-gem-balance");
        return _gemToSusds(dst, gemBalance, 0);
    }

    function allGemToSusds(address dst, uint256 maxSlippageBps) external returns (uint256 susdsWad) {
        uint256 gemBalance = ERC20Like(GEM).balanceOf(msg.sender);
        require(gemBalance > 0, "SusdsGem/no-gem-balance");
        return _gemToSusds(dst, gemBalance, maxSlippageBps);
    }

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

    function _ensureDaiLiquidity(uint256 minDai) internal {
        // Check if there's enough DAI balance in the LitePSM for the swap
        uint256 balance = ERC20Like(DAI).balanceOf(LITE_PSM);

        if (balance < minDai) {
            // Check if filling the buffer will provide enough liquidity
            uint256 rush = LitePSMLike(LITE_PSM).rush();
            require(minDai <= balance + rush, "SusdsGem/insufficient-liquidity");

            // Fill the buffer
            LitePSMLike(LITE_PSM).fill();
        }
    }
}
