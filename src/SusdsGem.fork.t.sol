// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./SusdsGem.sol";

interface IChangelog {
    function getAddress(bytes32) external view returns (address);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface ISUSDS {
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}

interface IDeal {
    function deal(address, address, uint256) external;
}

interface ILitePSM {
    function rush() external view returns (uint256);
    function fill() external returns (uint256);
    function buf() external view returns (uint256);
    function pocket() external view returns (address);
    function vat() external view returns (address);
    function ilk() external view returns (bytes32);
    function trim() external returns (uint256);
    function tin() external view returns (uint256);
    function file(bytes32, uint256) external;
    function wards(address) external view returns (uint256);
}

interface IVat {
    function ilks(bytes32)
        external
        view
        returns (uint256 Art, uint256 rate, uint256 spot, uint256 line, uint256 dust);
    function urns(bytes32, address) external view returns (uint256 ink, uint256 art);
    function frob(bytes32, address, address, address, int256, int256) external;
}

contract SusdsGemTest is Test {
    SusdsGem public converter;

    IChangelog constant changelog = IChangelog(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    address public susds;
    address public daiUsds;
    address public litePsmUsdc;
    address public usds;
    address public dai;
    address public usdc;

    address public user = address(0x1);
    address public destination = address(0x2);

    uint256 constant FORK_BLOCK = 21000000; // Recent mainnet block
    uint256 constant BPS = 10000;

    function setUp() public {
        // Fork mainnet
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string("https://eth.public-rpc.com"));
        vm.createSelectFork(rpcUrl, FORK_BLOCK);

        // Use known mainnet addresses directly
        // These are the current production addresses on Ethereum mainnet
        susds = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD; // sUSDS
        usds = 0xdC035D45d973E3EC169d2276DDab16f1e407384F; // USDS
        dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // DAI
        usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
        daiUsds = 0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A; // DAI-USDS converter
        litePsmUsdc = 0xf6e72Db5454dd049d0788e411b06CfAF16853042; // LITE_PSM_USDC_A

        // Deploy converter with real addresses
        converter = new SusdsGem(susds, daiUsds, litePsmUsdc);

        // Deal sUSDS tokens to user
        deal(susds, user, 10000e18);

        // Deal USDC tokens to user for reverse testing
        deal(usdc, user, 10000e6);

        // IMPORTANT: The sUSDS contract needs underlying USDS to back the shares
        // When we deal sUSDS shares, we also need to ensure the vault has assets
        deal(usds, susds, 100_000_000e18); // Fund sUSDS vault with 100M USDS

        // Check if PSM needs filling and fill it if necessary
        if (ILitePSM(litePsmUsdc).rush() > 0) {
            // PSM needs liquidity - fund it with USDC and call fill
            deal(usdc, litePsmUsdc, 100_000_000e6); // 100M USDC
            ILitePSM(litePsmUsdc).fill();
        }

        // User approves converter for both directions
        vm.startPrank(user);
        IERC20(susds).approve(address(converter), type(uint256).max);
        IERC20(usdc).approve(address(converter), type(uint256).max);
        vm.stopPrank();
    }

    function testConstructorWithRealAddresses() public view {
        assertEq(converter.SUSDS(), susds, "SUSDS address mismatch");
        assertEq(converter.DAI_USDS(), daiUsds, "DAI_USDS address mismatch");
        assertEq(converter.LITE_PSM(), litePsmUsdc, "LITE_PSM address mismatch");
        assertEq(converter.USDS(), usds, "USDS address mismatch");
        assertEq(converter.DAI(), dai, "DAI address mismatch");
        assertEq(converter.GEM(), usdc, "GEM (USDC) address mismatch");

        // USDC has 6 decimals, so conversion factor should be 1e12
        assertEq(converter.CONVERSION_FACTOR(), 1e12, "Incorrect conversion factor for USDC (6 decimals)");
    }

    function testSusdsToUsdcConversion() public {
        uint256 susdsWad = 100e18;
        uint256 initialSusdsBalance = IERC20(susds).balanceOf(user);
        uint256 initialUsdcBalance = IERC20(usdc).balanceOf(destination);

        vm.prank(user);
        uint256 usdcReceived = converter.susdsToGem(destination, susdsWad);

        uint256 finalSusdsBalance = IERC20(susds).balanceOf(user);
        uint256 finalUsdcBalance = IERC20(usdc).balanceOf(destination);

        // Check sUSDS was transferred from user
        assertEq(initialSusdsBalance - finalSusdsBalance, susdsWad, "Incorrect sUSDS amount transferred from user");

        // Check USDC was received
        uint256 actualUsdcReceived = finalUsdcBalance - initialUsdcBalance;

        // Verify return value matches actual balance change
        assertEq(usdcReceived, actualUsdcReceived, "Return value doesn't match actual USDC received");

        // Expected: ~100 USDC (with 6 decimals = 100e6)
        // Allow for small variations due to sUSDS appreciation
        assertGt(actualUsdcReceived, 99e6, "USDC received less than minimum expected (99 USDC)");
        assertLt(actualUsdcReceived, 101e6, "USDC received more than maximum expected (101 USDC)");
    }

    function testSusdsToUsdcWithSlippage() public {
        uint256 susdsWad = 100e18;
        uint256 maxSlippageBps = 100; // 1% slippage tolerance

        uint256 initialUsdcBalance = IERC20(usdc).balanceOf(destination);

        vm.prank(user);
        uint256 returnedAmount = converter.susdsToGem(destination, susdsWad, maxSlippageBps);

        uint256 finalUsdcBalance = IERC20(usdc).balanceOf(destination);
        uint256 usdcReceived = finalUsdcBalance - initialUsdcBalance;

        // Verify return value matches actual balance change
        assertEq(returnedAmount, usdcReceived, "Return value doesn't match actual USDC received");

        // With 1% slippage tolerance, minimum should be ~99 USDC
        assertGt(usdcReceived, 98e6, "USDC received below minimum with 1% slippage tolerance");
        assertLt(usdcReceived, 101e6, "USDC received above maximum expected");
    }

    function testAllSusdsToUsdc() public {
        uint256 initialUsdcBalance = IERC20(usdc).balanceOf(destination);

        vm.prank(user);
        uint256 usdcReceived = converter.allSusdsToGem(destination);

        assertEq(IERC20(susds).balanceOf(user), 0, "User should have no sUSDS left after converting all");

        uint256 actualUsdcReceived = IERC20(usdc).balanceOf(destination) - initialUsdcBalance;
        assertEq(usdcReceived, actualUsdcReceived, "Return value doesn't match actual USDC received");
        assertGt(actualUsdcReceived, 0, "Destination should have received USDC");
    }

    function testLargeSusdsConversion() public {
        // Test with a larger amount
        uint256 largeSusdsWad = 1000000e18; // 1M sUSDS
        deal(susds, user, largeSusdsWad);

        vm.prank(user);
        IERC20(susds).approve(address(converter), largeSusdsWad);

        uint256 initialUsdcBalance = IERC20(usdc).balanceOf(destination);

        vm.prank(user);
        converter.susdsToGem(destination, largeSusdsWad);

        uint256 usdcReceived = IERC20(usdc).balanceOf(destination) - initialUsdcBalance;

        // Should receive approximately 1M USDC (give or take for sUSDS appreciation)
        assertGt(usdcReceived, 990000e6, "Large conversion: USDC received below 990k minimum");
        assertLt(usdcReceived, 1010000e6, "Large conversion: USDC received above 1.01M maximum");
    }

    function testMultipleUsersConversion() public {
        address user2 = address(0x3);
        address user3 = address(0x4);

        // Setup multiple users with sUSDS
        deal(susds, user2, 500e18);
        deal(susds, user3, 750e18);

        vm.prank(user2);
        IERC20(susds).approve(address(converter), type(uint256).max);

        vm.prank(user3);
        IERC20(susds).approve(address(converter), type(uint256).max);

        // User 2 converts
        vm.prank(user2);
        converter.susdsToGem(user2, 500e18);

        // User 3 converts
        vm.prank(user3);
        converter.susdsToGem(user3, 750e18);

        // Check balances
        assertGt(IERC20(usdc).balanceOf(user2), 499e6, "User2 should have received at least 499 USDC");
        assertGt(IERC20(usdc).balanceOf(user3), 749e6, "User3 should have received at least 749 USDC");
    }

    function testRealSlippageProtection() public {
        uint256 susdsWad = 100e18;
        uint256 tightSlippageBps = 1; // 0.01% - very tight slippage

        // This should work in normal conditions
        vm.prank(user);
        converter.susdsToGem(destination, susdsWad, tightSlippageBps);

        // Verify it worked
        assertGt(
            IERC20(usdc).balanceOf(destination), 0, "Conversion should succeed with tight 0.01% slippage tolerance"
        );
    }

    function testSmallAmountConversion() public {
        // Test with amount just above conversion factor
        uint256 smallAmount = 2e12; // Just above 1e12 conversion factor
        deal(susds, user, smallAmount);

        vm.prank(user);
        IERC20(susds).approve(address(converter), smallAmount);

        vm.prank(user);
        converter.susdsToGem(destination, smallAmount);

        // Should receive at least 1 USDC unit (1e0 = 1 smallest unit)
        assertGt(IERC20(usdc).balanceOf(destination), 0, "Small amount conversion should yield at least 1 USDC unit");
    }

    function testGasUsage() public {
        uint256 susdsWad = 100e18;

        uint256 gasBefore = gasleft();
        vm.prank(user);
        converter.susdsToGem(destination, susdsWad);
        uint256 gasUsed = gasBefore - gasleft();

        // Ensure gas usage is reasonable (less than 500k)
        assertLt(gasUsed, 500000, "Gas usage exceeds 500k limit");
    }

    function testGemToSusdsConversion() public {
        uint256 usdcAmt = 100e6; // 100 USDC
        uint256 initialUsdcBalance = IERC20(usdc).balanceOf(user);
        uint256 initialSusdsBalance = IERC20(susds).balanceOf(destination);

        vm.prank(user);
        uint256 susdsReceived = converter.gemToSusds(destination, usdcAmt);

        uint256 finalUsdcBalance = IERC20(usdc).balanceOf(user);
        uint256 finalSusdsBalance = IERC20(susds).balanceOf(destination);

        // Check USDC was transferred from user
        assertEq(initialUsdcBalance - finalUsdcBalance, usdcAmt, "Incorrect USDC amount transferred from user");

        // Check sUSDS was received
        uint256 actualSusdsReceived = finalSusdsBalance - initialSusdsBalance;

        // Verify return value matches actual balance change
        assertEq(susdsReceived, actualSusdsReceived, "Return value doesn't match actual sUSDS received");

        // Expected: ~100 sUSDS (accounting for share conversion)
        assertGt(actualSusdsReceived, 98e18, "sUSDS received less than minimum expected");
        assertLt(actualSusdsReceived, 102e18, "sUSDS received more than maximum expected");
    }

    function testGemToSusdsWithSlippage() public {
        uint256 usdcAmt = 100e6;
        uint256 initialSusdsBalance = IERC20(susds).balanceOf(destination);

        vm.prank(user);
        uint256 returnedSusds = converter.gemToSusds(destination, usdcAmt, 100); // 1% slippage

        uint256 susdsReceived = IERC20(susds).balanceOf(destination) - initialSusdsBalance;

        // Verify return value matches actual balance change
        assertEq(returnedSusds, susdsReceived, "Return value doesn't match actual sUSDS received");

        // With 1% slippage tolerance, minimum should be ~99 sUSDS worth
        assertGt(susdsReceived, 97e18, "sUSDS received below minimum with 1% slippage tolerance");
        assertLt(susdsReceived, 102e18, "sUSDS received above maximum expected");
    }

    function testAllGemToSusds() public {
        uint256 initialSusdsBalance = IERC20(susds).balanceOf(destination);

        vm.prank(user);
        uint256 susdsReceived = converter.allGemToSusds(destination);

        assertEq(IERC20(usdc).balanceOf(user), 0, "User should have no USDC left");

        uint256 actualSusdsReceived = IERC20(susds).balanceOf(destination) - initialSusdsBalance;
        assertEq(susdsReceived, actualSusdsReceived, "Return value doesn't match actual sUSDS received");
        assertGt(actualSusdsReceived, 0, "Destination should have received sUSDS");
    }

    function testRoundTripConversion() public {
        // First convert sUSDS to USDC
        uint256 susdsWad = 1000e18;
        uint256 initialSusdsBalance = IERC20(susds).balanceOf(user);
        uint256 initialUsdcBalance = IERC20(usdc).balanceOf(user);

        vm.prank(user);
        uint256 usdcReceivedFromConversion = converter.susdsToGem(user, susdsWad); // Convert to self

        uint256 midUsdcBalance = IERC20(usdc).balanceOf(user);
        uint256 actualUsdcReceived = midUsdcBalance - initialUsdcBalance;
        assertEq(usdcReceivedFromConversion, actualUsdcReceived, "Return value doesn't match USDC received");

        // Then convert only the received USDC back to sUSDS
        vm.prank(user);
        uint256 susdsReceivedBack = converter.gemToSusds(user, actualUsdcReceived);

        uint256 finalSusdsBalance = IERC20(susds).balanceOf(user);

        // Verify the return value matches the actual sUSDS received
        assertEq(
            susdsReceivedBack,
            finalSusdsBalance - (initialSusdsBalance - susdsWad),
            "Return value doesn't match sUSDS received back"
        );

        // With 0 slippage, the round trip amount should be very close to original (only rounding loss)
        // Compare the net change: we spent susdsWad and got back susdsReceivedBack
        assertGe(susdsReceivedBack, susdsWad * 9999 / 10000, "Lost more than 0.01% in round trip");
        assertApproxEqRel(susdsReceivedBack, susdsWad, 0.0001e18, "Round trip outside 0.01% tolerance");
    }

    // ============ Fuzz Tests ============

    function testFuzzSusdsToGem(uint256 susdsAmount) public {
        // Bound the input to reasonable values (0.01 to 1M sUSDS)
        susdsAmount = bound(susdsAmount, 1e16, 1_000_000e18);

        // Setup user with the fuzzed amount
        deal(susds, user, susdsAmount);

        uint256 initialSusdsBalance = IERC20(susds).balanceOf(user);
        uint256 initialGemBalance = IERC20(usdc).balanceOf(destination);

        vm.prank(user);
        uint256 gemReceived = converter.susdsToGem(destination, susdsAmount);

        uint256 finalSusdsBalance = IERC20(susds).balanceOf(user);
        uint256 finalGemBalance = IERC20(usdc).balanceOf(destination);

        // Verify sUSDS was transferred
        assertEq(initialSusdsBalance - finalSusdsBalance, susdsAmount, "Incorrect sUSDS transferred");

        // Verify gem was received and matches return value
        uint256 actualGemReceived = finalGemBalance - initialGemBalance;
        assertEq(gemReceived, actualGemReceived, "Return value mismatch");

        // Verify amount is reasonable (accounting for conversion factor)
        uint256 expectedGemApprox = susdsAmount / converter.CONVERSION_FACTOR();
        assertApproxEqRel(actualGemReceived, expectedGemApprox, 0.02e18, "Gem amount outside 2% tolerance");
    }

    function testFuzzGemToSusds(uint256 gemAmount) public {
        // Bound the input to reasonable values (0.01 to 1M USDC)
        gemAmount = bound(gemAmount, 1e4, 1_000_000e6);

        // Setup user with the fuzzed amount
        deal(usdc, user, gemAmount);

        uint256 initialGemBalance = IERC20(usdc).balanceOf(user);
        uint256 initialSusdsBalance = IERC20(susds).balanceOf(destination);

        vm.prank(user);
        uint256 susdsReceived = converter.gemToSusds(destination, gemAmount);

        uint256 finalGemBalance = IERC20(usdc).balanceOf(user);
        uint256 finalSusdsBalance = IERC20(susds).balanceOf(destination);

        // Verify gem was transferred
        assertEq(initialGemBalance - finalGemBalance, gemAmount, "Incorrect gem transferred");

        // Verify sUSDS was received and matches return value
        uint256 actualSusdsReceived = finalSusdsBalance - initialSusdsBalance;
        assertEq(susdsReceived, actualSusdsReceived, "Return value mismatch");

        // Verify amount is reasonable
        uint256 expectedSusdsApprox = gemAmount * converter.CONVERSION_FACTOR();
        assertApproxEqRel(actualSusdsReceived, expectedSusdsApprox, 0.02e18, "sUSDS amount outside 2% tolerance");
    }

    function testFuzzSlippageProtection(uint256 susdsAmount, uint256 slippageBps) public {
        // Bound inputs
        susdsAmount = bound(susdsAmount, 1e18, 10_000e18);
        slippageBps = bound(slippageBps, 0, 10000); // 0 to 100%

        deal(susds, user, susdsAmount);

        if (slippageBps > 10000) {
            // Should revert if slippage > 100%
            vm.prank(user);
            vm.expectRevert("SusdsGem/slippage-too-high");
            converter.susdsToGem(destination, susdsAmount, slippageBps);
        } else {
            // Should succeed with valid slippage
            vm.prank(user);
            uint256 gemReceived = converter.susdsToGem(destination, susdsAmount, slippageBps);

            // Verify we got at least the minimum expected after slippage
            uint256 expectedMin = (susdsAmount / converter.CONVERSION_FACTOR()) * (10000 - slippageBps) / 10000;
            assertGe(gemReceived, expectedMin * 98 / 100, "Received less than minimum after slippage");
        }
    }

    function testFuzzRoundTrip(uint256 startAmount) public {
        // Start with sUSDS, convert to gem, then back to sUSDS
        startAmount = bound(startAmount, 100e18, 10_000e18);

        deal(susds, user, startAmount);
        uint256 initialSusds = IERC20(susds).balanceOf(user);

        // Convert sUSDS to gem
        vm.prank(user);
        uint256 gemReceived = converter.susdsToGem(user, startAmount);

        // Approve and convert gem back to sUSDS
        vm.startPrank(user);
        IERC20(usdc).approve(address(converter), gemReceived);
        uint256 susdsRecovered = converter.gemToSusds(user, gemReceived);
        vm.stopPrank();

        uint256 finalSusds = IERC20(susds).balanceOf(user);

        // With 0 slippage, should recover almost all (only rounding losses, < 0.1%)
        assertGe(finalSusds, initialSusds * 999 / 1000, "Lost more than 0.1% in round trip");
        assertApproxEqRel(finalSusds, initialSusds, 0.001e18, "Round trip outside 0.1% tolerance");
        assertEq(susdsRecovered, finalSusds - (initialSusds - startAmount), "Return value mismatch in round trip");
    }

    function testFuzzAllConversions(uint256 userSusds, uint256 userGem) public {
        // Test the "all" functions with fuzzed balances
        userSusds = bound(userSusds, 1e18, 100_000e18);
        userGem = bound(userGem, 1e6, 100_000e6);

        // Test allSusdsToGem
        address user1 = address(0x1001);
        deal(susds, user1, userSusds);
        vm.startPrank(user1);
        IERC20(susds).approve(address(converter), type(uint256).max);
        uint256 gemFromAll = converter.allSusdsToGem(user1);
        vm.stopPrank();

        assertEq(IERC20(susds).balanceOf(user1), 0, "Should have no sUSDS left");
        assertEq(IERC20(usdc).balanceOf(user1), gemFromAll, "Gem balance mismatch");

        // Test allGemToSusds
        address user2 = address(0x1002);
        deal(usdc, user2, userGem);
        vm.startPrank(user2);
        IERC20(usdc).approve(address(converter), type(uint256).max);
        uint256 susdsFromAll = converter.allGemToSusds(user2);
        vm.stopPrank();

        assertEq(IERC20(usdc).balanceOf(user2), 0, "Should have no gem left");
        assertEq(IERC20(susds).balanceOf(user2), susdsFromAll, "sUSDS balance mismatch");
    }

    function testFuzzMinimumAmounts(uint256 tinyAmount) public {
        // Test behavior with very small amounts
        // The check happens on the USDS amount after redeeming sUSDS, not on the sUSDS input
        // We need to ensure the redeemed USDS amount is less than CONVERSION_FACTOR

        // Calculate a sUSDS amount that will redeem to less than CONVERSION_FACTOR USDS
        // Account for sUSDS appreciation by using convertToAssets
        uint256 maxUsdsForTest = converter.CONVERSION_FACTOR() - 1; // Just under the limit
        uint256 maxSusdsShares = maxUsdsForTest * 1e18 / (ISUSDS(susds).convertToAssets(1e18) + 1); // Conservative estimate

        tinyAmount = bound(tinyAmount, 1, maxSusdsShares);

        deal(susds, user, tinyAmount);

        // Check if this amount would produce less than CONVERSION_FACTOR USDS
        uint256 expectedUsds = ISUSDS(susds).convertToAssets(tinyAmount);

        if (expectedUsds < converter.CONVERSION_FACTOR()) {
            // Should revert for amounts too small to convert
            vm.prank(user);
            vm.expectRevert("SusdsGem/amount-too-small");
            converter.susdsToGem(destination, tinyAmount);
        } else {
            // Amount is actually large enough to convert
            vm.prank(user);
            uint256 gemReceived = converter.susdsToGem(destination, tinyAmount);
            assertGt(gemReceived, 0, "Should receive some gem");
        }
    }

    function testFuzzSlippageGemToSusds(uint256 gemAmount, uint256 slippageBps) public {
        // Test slippage protection for gem to sUSDS conversion
        gemAmount = bound(gemAmount, 100e6, 10_000e6); // 100 to 10k USDC
        slippageBps = bound(slippageBps, 0, 10001); // Allow testing above 10000

        deal(usdc, user, gemAmount);

        if (slippageBps > 10000) {
            vm.prank(user);
            vm.expectRevert("SusdsGem/slippage-too-high");
            converter.gemToSusds(destination, gemAmount, slippageBps);
        } else {
            // Check if amount is too small after slippage
            uint256 minAcceptableDai = gemAmount * converter.CONVERSION_FACTOR() * (10000 - slippageBps) / 10000;
            if (minAcceptableDai == 0) {
                vm.prank(user);
                vm.expectRevert("SusdsGem/amount-too-small");
                converter.gemToSusds(destination, gemAmount, slippageBps);
            } else {
                vm.prank(user);
                uint256 susdsReceived = converter.gemToSusds(destination, gemAmount, slippageBps);

                // Verify slippage protection works
                uint256 expectedMin = (gemAmount * converter.CONVERSION_FACTOR()) * (10000 - slippageBps) / 10000;
                assertGe(susdsReceived, expectedMin * 98 / 100, "Received less than minimum after slippage");
            }
        }
    }

    function testFuzzBoundaryValues(uint256 amount) public {
        // Test exact multiples of conversion factor
        uint256 multiplier = bound(amount, 1, 1000);
        uint256 exactAmount = multiplier * converter.CONVERSION_FACTOR();

        deal(susds, user, exactAmount);

        vm.prank(user);
        uint256 gemReceived = converter.susdsToGem(destination, exactAmount);

        // Should get approximately the multiplier amount in gem (within 1% due to sUSDS appreciation)
        assertApproxEqRel(gemReceived, multiplier, 0.01e18, "Boundary value conversion outside 1% tolerance");

        // Ensure we at least get the minimum expected
        assertGe(gemReceived, multiplier * 99 / 100, "Got less than 99% of expected");
        assertLe(gemReceived, multiplier * 101 / 100, "Got more than 101% of expected");
    }

    function testErrorConditions() public {
        // Test slippage too high for susdsToGem
        vm.prank(user);
        vm.expectRevert("SusdsGem/slippage-too-high");
        converter.susdsToGem(destination, 100e18, 10001);

        // Test slippage too high for gemToSusds
        vm.prank(user);
        vm.expectRevert("SusdsGem/slippage-too-high");
        converter.gemToSusds(destination, 100e6, 10001);

        // Test no SUSDS balance
        address emptyUser = address(0x999);
        vm.prank(emptyUser);
        vm.expectRevert("SusdsGem/no-susds-balance");
        converter.allSusdsToGem(destination);

        // Test no GEM balance
        vm.prank(emptyUser);
        vm.expectRevert("SusdsGem/no-gem-balance");
        converter.allGemToSusds(destination);
    }

    // ============ Dai Liquidity Tests ============

    function testDaiFillWhenNeeded() public {
        // This test verifies that the converter calls fill() when the PSM lacks DAI but rush is available

        address pocket = ILitePSM(litePsmUsdc).pocket();

        // First, create rush by adding gems to the pocket
        // This increases target debt (tArt = gem.balanceOf(pocket) * to18ConversionFactor + buf)
        uint256 currentGemInPocket = IERC20(usdc).balanceOf(pocket);
        deal(usdc, pocket, currentGemInPocket + 10_000_000e6); // Add 10M USDC to pocket

        // Verify we now have rush
        uint256 rushBefore = ILitePSM(litePsmUsdc).rush();
        assertGt(rushBefore, 1000e18, "Should have created significant rush availability");

        // Drain PSM's DAI balance to force buffer filling
        uint256 psmDaiBalance = IERC20(dai).balanceOf(litePsmUsdc);
        vm.prank(litePsmUsdc);
        IERC20(dai).transfer(address(0x999), psmDaiBalance);

        // Verify PSM has no DAI
        assertEq(IERC20(dai).balanceOf(litePsmUsdc), 0, "PSM should have no DAI");

        // Now try to convert - should trigger fill
        uint256 usdcAmt = 100e6;
        uint256 initialDestBalance = IERC20(susds).balanceOf(destination);

        vm.prank(user);
        uint256 susdsReceived = converter.gemToSusds(destination, usdcAmt);

        // Verify conversion succeeded
        assertGt(susdsReceived, 0, "Should have received sUSDS after buffer fill");
        assertEq(
            IERC20(susds).balanceOf(destination) - initialDestBalance,
            susdsReceived,
            "Balance change should match return"
        );

        // Verify buffer was filled
        uint256 finalPsmDaiBalance = IERC20(dai).balanceOf(litePsmUsdc);
        assertGt(finalPsmDaiBalance, 0, "PSM should have DAI after fill");

        // Verify rush decreased
        uint256 rushAfter = ILitePSM(litePsmUsdc).rush();
        assertLt(rushAfter, rushBefore, "Rush should have decreased after fill");
    }

    function testRevertDaiFillWhenInsufficientLiquidity() public {
        // Drain PSM DAI balance
        uint256 psmDaiBalance = IERC20(dai).balanceOf(litePsmUsdc);
        vm.prank(litePsmUsdc);
        IERC20(dai).transfer(address(0x999), psmDaiBalance);

        // Drain rush by removing USDC from pocket (pocket holds gems, not DAI)
        address pocket = ILitePSM(litePsmUsdc).pocket();
        uint256 pocketUsdcBalance = IERC20(usdc).balanceOf(pocket);
        vm.prank(pocket);
        IERC20(usdc).transfer(address(0x999), pocketUsdcBalance);

        // Verify rush is now 0 (no USDC in pocket means no ability to mint DAI)
        uint256 rushAvailable = ILitePSM(litePsmUsdc).rush();
        assertEq(rushAvailable, 0, "Rush should be 0 after draining pocket USDC");

        // Now try conversion - should fail due to insufficient rush
        uint256 usdcAmt = 100e6; // Even small amount should fail

        vm.prank(user);
        vm.expectRevert("SusdsGem/insufficient-liquidity");
        converter.gemToSusds(destination, usdcAmt);
    }

    function testDaiNotFilledWhenSufficientLiquidity() public {
        // Ensure PSM has plenty of DAI
        deal(dai, litePsmUsdc, 10_000_000e18);

        // Record initial state
        uint256 initialPsmDai = IERC20(dai).balanceOf(litePsmUsdc);

        // Small conversion that doesn't need fill
        uint256 usdcAmt = 100e6;
        vm.prank(user);
        converter.gemToSusds(destination, usdcAmt);

        // PSM balance should have decreased by roughly the amount used
        uint256 finalPsmDai = IERC20(dai).balanceOf(litePsmUsdc);
        assertApproxEqAbs(
            finalPsmDai, initialPsmDai - usdcAmt * 1e12, converter.CONVERSION_FACTOR(), "PSM DAI should decrease"
        );
    }

    function testDaiFillWithSlippage() public {
        // This test verifies that when tin fee is enabled in LitePSM,
        // the buffer check correctly accounts for the reduced DAI needed

        address pauseProxy = 0xBE8E3e3618f7474F8cB1d074A26afFef007E98FB;
        address pocket = ILitePSM(litePsmUsdc).pocket();

        // Set tin to 2% (0.02 * 1e18)
        uint256 tinFee = 0.02e18;
        vm.prank(pauseProxy);
        ILitePSM(litePsmUsdc).file(bytes32("tin"), tinFee);

        // Verify tin was set
        assertEq(ILitePSM(litePsmUsdc).tin(), tinFee, "tin should be set to 2%");

        // For 1000 USDC with 2% tin fee:
        // - User sells 1000 USDC
        // - PSM gives back 980 DAI (1000 * 1e12 * 0.98)
        // - So buffer only needs 980 DAI, not 1000 DAI
        uint256 usdcAmt = 1000e6;
        uint256 slippageBps = 2_00; // 2% slippage tolerance in our contract
        uint256 minDaiNeeded = usdcAmt * 1e12 * (10000 - slippageBps) / 10000; // 980e18

        // Create rush by adding gems to pocket
        uint256 currentGemInPocket = IERC20(usdc).balanceOf(pocket);
        deal(usdc, pocket, currentGemInPocket + 2_000_000e6); // Add 2M USDC

        // Verify we have enough rush
        uint256 rushAvailable = ILitePSM(litePsmUsdc).rush();
        assertGt(rushAvailable, minDaiNeeded, "Should have enough rush for swap with fee");

        // Drain PSM's DAI balance to force buffer filling
        uint256 psmDaiBalance = IERC20(dai).balanceOf(litePsmUsdc);
        vm.prank(litePsmUsdc);
        IERC20(dai).transfer(address(0x999), psmDaiBalance);

        // Verify PSM has no DAI
        assertEq(IERC20(dai).balanceOf(litePsmUsdc), 0, "PSM should have no DAI");

        // Convert with slippage tolerance - should succeed because buffer check accounts for the fee
        vm.prank(user);
        uint256 susdsReceived = converter.gemToSusds(destination, usdcAmt, slippageBps);

        // Verify conversion succeeded
        assertGt(susdsReceived, 0, "Should have received sUSDS");

        // The buffer should have been filled with at least minDaiNeeded (980 DAI)
        uint256 finalPsmDaiBalance = IERC20(dai).balanceOf(litePsmUsdc);
        assertGe(finalPsmDaiBalance, minDaiNeeded, "PSM should have enough DAI for swap with fee");

        // Verify the actual USDS/DAI value underlying the sUSDS received is exactly 980 DAI
        // With 2% tin fee, selling 1000 USDC yields exactly 980 DAI
        uint256 expectedDaiReceived = usdcAmt * 1e12 * (1e18 - tinFee) / 1e18; // 980e18
        uint256 actualUsdsValue = ISUSDS(susds).convertToAssets(susdsReceived);
        // Allow for 1 gwei rounding difference due to sUSDS share conversion
        assertApproxEqAbs(
            actualUsdsValue,
            expectedDaiReceived,
            converter.CONVERSION_FACTOR(),
            "sUSDS shares should convert to exactly 980 USDS/DAI assets after tin fee"
        );
    }
}
