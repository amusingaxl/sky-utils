// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {SusdsStusds} from "./SusdsStusds.sol";

contract SusdsStusdsTest is Test {
    SusdsStusds public converter;

    ChainlogLike constant chainlog = ChainlogLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    address public susds;
    address public stusds;
    address public usds;

    address public user = address(0x1);
    address public destination = address(0x2);

    using stdStorage for StdStorage;

    function setUp() public {
        // Fork mainnet
        vm.createSelectFork("mainnet");

        // Use known mainnet addresses directly
        // These are the current production addresses on Ethereum mainnet
        susds = chainlog.getAddress("SUSDS"); // sUSDS
        usds = chainlog.getAddress("USDS"); // USDS
        stusds = chainlog.getAddress("STUSDS"); // stUSDS

        // Deploy converter with real addresses
        converter = new SusdsStusds(susds, stusds);

        // Deal sUSDS tokens to user
        deal(susds, user, 10000e18);

        // Deal stUSDS tokens to user for reverse testing
        deal(stusds, user, 10000e18);

        // IMPORTANT: Both vaults need underlying USDS to back the shares
        deal(usds, susds, 100_000_000e18); // Fund sUSDS vault with 100M USDS
        deal(usds, stusds, 500_000_000e18); // Fund stUSDS vault with 500M USDS (more backing needed)

        // User approves converter for both directions
        vm.startPrank(user);
        ERC20Like(susds).approve(address(converter), type(uint256).max);
        ERC20Like(stusds).approve(address(converter), type(uint256).max);
        vm.stopPrank();
    }

    function testConstructorWithRealAddresses() public view {
        assertEq(address(converter.susds()), susds, "SUSDS address mismatch");
        assertEq(address(converter.stusds()), stusds, "STUSDS address mismatch");
        assertEq(address(converter.usds()), usds, "USDS address mismatch");

        // Verify both use the same underlying asset
        assertEq(ERC4626Like(susds).asset(), usds, "sUSDS should use USDS as asset");
        assertEq(ERC4626Like(stusds).asset(), usds, "stUSDS should use USDS as asset");
    }

    function testSusdsToStusdsConversion() public {
        uint256 susdsWad = 100e18;

        // Ensure stUSDS deposits can succeed by increasing cap
        _enableStusdsDeposits();

        uint256 initialSusdsBalance = ERC20Like(susds).balanceOf(user);
        uint256 initialStusdsBalance = ERC20Like(stusds).balanceOf(destination);

        vm.prank(user);
        uint256 usdsAmount = converter.susdsToStusds(destination, susdsWad);

        uint256 finalSusdsBalance = ERC20Like(susds).balanceOf(user);
        uint256 finalStusdsBalance = ERC20Like(stusds).balanceOf(destination);

        // Check sUSDS was transferred from user
        assertEq(initialSusdsBalance - finalSusdsBalance, susdsWad, "Incorrect sUSDS amount transferred from user");

        // Check stUSDS was received
        uint256 actualStusdsReceived = finalStusdsBalance - initialStusdsBalance;
        assertGt(actualStusdsReceived, 0, "Destination should have received stUSDS");

        // Check that the returned USDS amount makes sense
        assertGt(usdsAmount, 0, "Should return positive USDS amount");
        uint256 expectedUsdsAmount = ERC4626Like(susds).convertToAssets(susdsWad);
        assertApproxEqRel(
            usdsAmount, expectedUsdsAmount, 0.01e18, "Returned USDS amount should match sUSDS asset value"
        );

        // Compare underlying USDS asset values instead of share amounts
        uint256 susdsUsdsValue = ERC4626Like(susds).convertToAssets(susdsWad);
        uint256 stusdsUsdsValue = ERC4626Like(stusds).convertToAssets(actualStusdsReceived);

        // The underlying USDS values should be approximately equal (allowing for small rounding differences)
        assertApproxEqRel(stusdsUsdsValue, susdsUsdsValue, 0.01e18, "Underlying USDS values outside 1% tolerance");
    }

    function testAllSusdsToStusds() public {
        uint256 initialStusdsBalance = ERC20Like(stusds).balanceOf(destination);

        vm.prank(user);
        converter.allSusdsToStusds(destination);

        assertEq(ERC20Like(susds).balanceOf(user), 0, "User should have no sUSDS left after converting all");

        uint256 actualStusdsReceived = ERC20Like(stusds).balanceOf(destination) - initialStusdsBalance;
        assertGt(actualStusdsReceived, 0, "Destination should have received stUSDS");
    }

    function testStusdsToSusdsConversion() public {
        uint256 stusdsWad = 100e18;

        // Enable stUSDS withdrawals by reducing Art in Vat
        _enableStusdsWithdrawals();

        uint256 initialStusdsBalance = ERC20Like(stusds).balanceOf(user);
        uint256 initialSusdsBalance = ERC20Like(susds).balanceOf(destination);

        vm.prank(user);
        uint256 usdsSwapped = converter.stusdsToSusds(destination, stusdsWad);

        uint256 finalStusdsBalance = ERC20Like(stusds).balanceOf(user);
        uint256 finalSusdsBalance = ERC20Like(susds).balanceOf(destination);

        // Check stUSDS was transferred from user
        assertEq(initialStusdsBalance - finalStusdsBalance, stusdsWad, "Incorrect stUSDS amount transferred from user");

        // Check sUSDS was received
        uint256 actualSusdsReceived = finalSusdsBalance - initialSusdsBalance;
        assertGt(actualSusdsReceived, 0, "Destination should have received sUSDS");

        // Check that usdsSwapped matches the expected USDS value
        uint256 expectedUsdsValue = ERC4626Like(stusds).convertToAssets(stusdsWad);
        assertApproxEqRel(
            usdsSwapped, expectedUsdsValue, 0.01e18, "Swapped USDS amount should match stUSDS asset value"
        );

        // Compare underlying USDS asset values instead of share amounts
        uint256 stusdsUsdsValue = ERC4626Like(stusds).convertToAssets(stusdsWad);
        uint256 susdsUsdsValue = ERC4626Like(susds).convertToAssets(actualSusdsReceived);

        // The underlying USDS values should be approximately equal (allowing for small rounding differences)
        assertApproxEqRel(susdsUsdsValue, stusdsUsdsValue, 0.01e18, "Underlying USDS values outside 1% tolerance");
    }

    function testRevert_stusdsToSusds_insufficientFunds() public {
        uint256 stusdsWad = 100e18;

        // Force stUSDS to have insufficient funds by maximizing Art in Vat
        _forceStusdsInsufficientFunds();

        vm.prank(user);
        vm.expectRevert("StUsds/insufficient-unused-funds");
        converter.stusdsToSusds(destination, stusdsWad);
    }

    function testAllStusdsToSusds() public {
        // Enable stUSDS withdrawals by reducing Art in Vat
        _enableStusdsWithdrawals();

        uint256 initialSusdsBalance = ERC20Like(susds).balanceOf(destination);

        vm.prank(user);
        uint256 usdsSwapped = converter.allStusdsToSusds(destination);

        assertEq(ERC20Like(stusds).balanceOf(user), 0, "User should have no stUSDS left after converting all");

        uint256 actualSusdsReceived = ERC20Like(susds).balanceOf(destination) - initialSusdsBalance;
        assertGt(actualSusdsReceived, 0, "Destination should have received sUSDS");
        assertGt(usdsSwapped, 0, "Should return positive USDS amount swapped");
    }

    function testRevert_allStusdsToSusds_insufficientFunds() public {
        // Force stUSDS to have insufficient funds by maximizing Art in Vat
        _forceStusdsInsufficientFunds();

        vm.prank(user);
        vm.expectRevert("StUsds/insufficient-unused-funds");
        converter.allStusdsToSusds(destination);
    }

    function testUsdsFromSusdsToStusds() public {
        uint256 usdsWad = 100e18;
        uint256 initialStusdsBalance = ERC20Like(stusds).balanceOf(destination);
        uint256 initialSusdsBalance = ERC20Like(susds).balanceOf(user);

        vm.prank(user);
        (uint256 stusdsSharesOut, uint256 susdsSharesIn) = converter.usdsFromSusdsToStusds(destination, usdsWad);

        uint256 finalStusdsBalance = ERC20Like(stusds).balanceOf(destination);
        uint256 finalSusdsBalance = ERC20Like(susds).balanceOf(user);

        uint256 actualStusdsReceived = finalStusdsBalance - initialStusdsBalance;
        uint256 actualSusdsSpent = initialSusdsBalance - finalSusdsBalance;

        assertGt(actualStusdsReceived, 0, "Destination should have received stUSDS");
        assertGt(actualSusdsSpent, 0, "User should have spent sUSDS");

        // Verify return values match actual balance changes
        assertEq(stusdsSharesOut, actualStusdsReceived, "stUSDS return value should match actual received");
        assertEq(susdsSharesIn, actualSusdsSpent, "sUSDS return value should match actual spent");

        // Since we're working with USDS amounts directly, the conversion should be more predictable
        uint256 expectedStusdsShares = ERC4626Like(stusds).convertToShares(usdsWad);
        assertApproxEqRel(actualStusdsReceived, expectedStusdsShares, 0.005e18, "USDS conversion outside 0.5% tolerance");
    }

    function testUsdsFromStusdsToSusds() public {
        uint256 usdsWad = 100e18;

        // Enable stUSDS withdrawals by reducing Art in Vat
        _enableStusdsWithdrawals();

        uint256 initialSusdsBalance = ERC20Like(susds).balanceOf(destination);

        vm.prank(user);
        (uint256 susdsSharesOut, uint256 stusdsSharesIn) = converter.usdsFromStusdsToSusds(destination, usdsWad);

        uint256 finalSusdsBalance = ERC20Like(susds).balanceOf(destination);
        uint256 actualSusdsReceived = finalSusdsBalance - initialSusdsBalance;

        assertGt(actualSusdsReceived, 0, "Destination should have received sUSDS");
        assertGt(stusdsSharesIn, 0, "Should have burned stUSDS shares");
        assertEq(susdsSharesOut, actualSusdsReceived, "Should return correct sUSDS shares minted");

        // Since we're working with USDS amounts directly, the conversion should be more predictable
        uint256 expectedSusdsShares = ERC4626Like(susds).convertToShares(usdsWad);
        assertApproxEqRel(actualSusdsReceived, expectedSusdsShares, 0.005e18, "USDS conversion outside 0.5% tolerance");
    }

    function testRevert_usdsFromStusdsToSusds_insufficientFunds() public {
        uint256 usdsWad = 100e18;

        // Force stUSDS to have insufficient funds by maximizing Art in Vat
        _forceStusdsInsufficientFunds();

        vm.prank(user);
        vm.expectRevert("StUsds/insufficient-unused-funds");
        converter.usdsFromStusdsToSusds(destination, usdsWad);
    }

    function testLargeConversion() public {
        // Test with a larger amount
        uint256 largeSusdsWad = 1000000e18; // 1M sUSDS

        // Ensure stUSDS deposits can succeed for large amounts
        _enableStusdsDeposits();

        deal(susds, user, largeSusdsWad);

        vm.prank(user);
        ERC20Like(susds).approve(address(converter), largeSusdsWad);

        uint256 initialStusdsBalance = ERC20Like(stusds).balanceOf(destination);

        vm.prank(user);
        converter.susdsToStusds(destination, largeSusdsWad);

        uint256 stusdsReceived = ERC20Like(stusds).balanceOf(destination) - initialStusdsBalance;

        // Should receive a reasonable amount of stUSDS (accounting for very different yield rates)
        assertGt(stusdsReceived, 900000e18, "Large conversion: stUSDS received below 900k minimum");
        assertLt(stusdsReceived, 1200000e18, "Large conversion: stUSDS received above 1.2M maximum");
    }

    function testMultipleUsersConversion() public {
        address user2 = address(0x3);
        address user3 = address(0x4);

        // Setup multiple users with sUSDS
        deal(susds, user2, 500e18);
        deal(stusds, user3, 750e18);

        vm.prank(user2);
        ERC20Like(susds).approve(address(converter), type(uint256).max);

        vm.prank(user3);
        ERC20Like(stusds).approve(address(converter), type(uint256).max);

        // User 2 converts sUSDS to stUSDS - this should work
        vm.prank(user2);
        converter.susdsToStusds(user2, 500e18);

        // User 3 converts stUSDS to sUSDS - this should revert due to insufficient funds
        vm.prank(user3);
        vm.expectRevert("StUsds/insufficient-unused-funds");
        converter.stusdsToSusds(user3, 750e18);

        // Check that user2 got stUSDS successfully
        assertGt(ERC20Like(stusds).balanceOf(user2), 490e18, "User2 should have received at least 490 stUSDS");
    }

    function testRoundTripConversion() public {
        // Enable stUSDS withdrawals by reducing Art in Vat
        _enableStusdsWithdrawals();

        // First convert sUSDS to stUSDS
        uint256 susdsWad = 1000e18;
        uint256 initialSusdsBalance = ERC20Like(susds).balanceOf(user);

        vm.prank(user);
        converter.susdsToStusds(user, susdsWad); // Convert to self

        // Then convert the received stUSDS back to sUSDS
        vm.prank(user);
        converter.allStusdsToSusds(user); // Convert all stUSDS back

        uint256 finalSusdsBalance = ERC20Like(susds).balanceOf(user);

        // With round trip, should recover some reasonable amount (allowing for large yield differences due to mocking)
        uint256 susdsRecovered = finalSusdsBalance - (initialSusdsBalance - susdsWad);
        assertGt(susdsRecovered, 0, "Should recover some sUSDS from round trip");
        // Note: Due to mocking stUSDS rates, the recovery ratio can vary significantly
    }

    function testRevert_roundTripConversion_insufficientFunds() public {
        // First convert sUSDS to stUSDS - this should work
        uint256 susdsWad = 1000e18;

        vm.prank(user);
        converter.susdsToStusds(user, susdsWad); // Convert to self

        // Force stUSDS to have insufficient funds by maximizing Art in Vat
        _forceStusdsInsufficientFunds();

        // Then convert the received stUSDS back to sUSDS - this should revert
        vm.prank(user);
        vm.expectRevert("StUsds/insufficient-unused-funds");
        converter.allStusdsToSusds(user); // Convert all stUSDS back
    }

    // ============ Fuzz Tests ============

    function testFuzzSusdsToStusds(uint256 susdsAmount) public {
        // Bound the input to reasonable values (0.01 to 1M sUSDS)
        susdsAmount = bound(susdsAmount, 1e16, 1_000_000e18);

        // Ensure stUSDS deposits can succeed for any fuzzed amount
        _enableStusdsDeposits();

        // Setup user with the fuzzed amount
        deal(susds, user, susdsAmount);

        uint256 initialSusdsBalance = ERC20Like(susds).balanceOf(user);
        uint256 initialStusdsBalance = ERC20Like(stusds).balanceOf(destination);

        vm.prank(user);
        converter.susdsToStusds(destination, susdsAmount);

        uint256 finalSusdsBalance = ERC20Like(susds).balanceOf(user);
        uint256 finalStusdsBalance = ERC20Like(stusds).balanceOf(destination);

        // Verify sUSDS was transferred
        assertEq(initialSusdsBalance - finalSusdsBalance, susdsAmount, "Incorrect sUSDS transferred");

        // Verify stUSDS was received
        uint256 actualStusdsReceived = finalStusdsBalance - initialStusdsBalance;
        assertGt(actualStusdsReceived, 0, "Should receive some stUSDS");

        // Compare underlying USDS asset values instead of share amounts
        uint256 susdsUsdsValue = ERC4626Like(susds).convertToAssets(susdsAmount);
        uint256 stusdsUsdsValue = ERC4626Like(stusds).convertToAssets(actualStusdsReceived);
        assertApproxEqRel(stusdsUsdsValue, susdsUsdsValue, 0.01e18, "Underlying USDS values outside 1% tolerance");
    }

    function testFuzzRevert_stusdsToSusds_insufficientFunds(uint256 stusdsAmount) public {
        // Bound the input to reasonable values (0.01 to 1M stUSDS)
        stusdsAmount = bound(stusdsAmount, 1e16, 1_000_000e18);

        // Setup user with the fuzzed amount
        deal(stusds, user, stusdsAmount);

        // Force stUSDS to have insufficient funds by maximizing Art in Vat
        _forceStusdsInsufficientFunds();

        vm.prank(user);
        vm.expectRevert("StUsds/insufficient-unused-funds");
        converter.stusdsToSusds(destination, stusdsAmount);
    }

    function testFuzzUsdsConversions(uint256 usdsAmount) public {
        // Bound the input to reasonable values (0.01 to 10k USDS to fit within user's sUSDS balance)
        usdsAmount = bound(usdsAmount, 1e16, 10_000e18);

        // Test USDS from sUSDS to stUSDS - this should work (deposits into stUSDS have capacity)
        uint256 initialStusdsBalance = ERC20Like(stusds).balanceOf(destination);

        vm.prank(user);
        converter.usdsFromSusdsToStusds(destination, usdsAmount);

        uint256 stusdsReceived = ERC20Like(stusds).balanceOf(destination) - initialStusdsBalance;
        assertGt(stusdsReceived, 0, "Should receive some stUSDS from USDS conversion");

        // Test USDS from stUSDS to sUSDS - this should revert due to capacity constraints
        address user2 = address(0x1001);
        deal(stusds, user2, 10000e18);
        vm.prank(user2);
        ERC20Like(stusds).approve(address(converter), type(uint256).max);

        // Force stUSDS to have insufficient funds by maximizing Art in Vat
        _forceStusdsInsufficientFunds();

        vm.prank(user2);
        vm.expectRevert("StUsds/insufficient-unused-funds");
        converter.usdsFromStusdsToSusds(user2, usdsAmount);
    }

    function testFuzzAllConversions(uint256 userSusds, uint256 userStusds) public {
        // Test the "all" functions with fuzzed balances
        userSusds = bound(userSusds, 1e18, 100_000e18);
        userStusds = bound(userStusds, 1e18, 100_000e18);

        // Test allSusdsToStusds - this should work (deposits into stUSDS)
        address user1 = address(0x1001);
        deal(susds, user1, userSusds);
        vm.startPrank(user1);
        ERC20Like(susds).approve(address(converter), type(uint256).max);
        converter.allSusdsToStusds(user1);
        vm.stopPrank();

        assertEq(ERC20Like(susds).balanceOf(user1), 0, "Should have no sUSDS left");
        assertGt(ERC20Like(stusds).balanceOf(user1), 0, "Should have received stUSDS");

        // Test allStusdsToSusds - this should revert due to insufficient funds
        address user2 = address(0x1002);
        deal(stusds, user2, userStusds);
        vm.startPrank(user2);
        ERC20Like(stusds).approve(address(converter), type(uint256).max);

        // Force stUSDS to have insufficient funds by maximizing Art in Vat
        _forceStusdsInsufficientFunds();

        vm.expectRevert("StUsds/insufficient-unused-funds");
        converter.allStusdsToSusds(user2);
        vm.stopPrank();
    }

    function testFuzzRevert_roundTrip_insufficientFunds(uint256 startAmount) public {
        // Start with sUSDS, convert to stUSDS, then back to sUSDS
        startAmount = bound(startAmount, 100e18, 10_000e18);

        deal(susds, user, startAmount);

        // Convert sUSDS to stUSDS - this should work
        vm.prank(user);
        converter.susdsToStusds(user, startAmount);

        // Force stUSDS to have insufficient funds by maximizing Art in Vat
        _forceStusdsInsufficientFunds();

        // Convert stUSDS back to sUSDS - this should revert due to insufficient funds
        vm.prank(user);
        vm.expectRevert("StUsds/insufficient-unused-funds");
        converter.allStusdsToSusds(user);
    }

    function testErrorConditions() public {
        // Test no sUSDS balance
        address emptyUser = address(0x999);
        vm.prank(emptyUser);
        vm.expectRevert("SusdsStusds/no-susds-balance");
        converter.allSusdsToStusds(destination);

        // Test no stUSDS balance
        vm.prank(emptyUser);
        vm.expectRevert("SusdsStusds/no-stusds-balance");
        converter.allStusdsToSusds(destination);
    }

    function testRevert_constructor_whenAssetMismatch() public {
        // Create a fake address for different asset
        address fakeAsset = address(0x999);

        // Mock stusds.asset() to return a different asset
        vm.mockCall(stusds, abi.encodeWithSignature("asset()"), abi.encode(fakeAsset));

        // Constructor should revert with asset mismatch
        vm.expectRevert("SusdsStusds/asset-mismatch");
        new SusdsStusds(susds, stusds);
    }

    // Helper function to ensure stUSDS deposits can succeed by removing the cap
    function _enableStusdsDeposits() internal {
        // Set stUSDS cap to max to ensure deposits never hit the supply limit
        stdstore.target(stusds).sig("cap()").checked_write(type(uint256).max);
    }

    // Helper function to enable stUSDS withdrawals by reducing Art in the Vat
    function _enableStusdsWithdrawals() internal {
        address vat = StUsdsLike(stusds).vat();
        bytes32 ilk = StUsdsLike(stusds).ilk();

        // Note: We only modify Art, other ilk data (rate, spot, line, dust) remain unchanged

        // Set Art (debt) to a very low value (1 wad) to ensure capacity constraint passes:
        // Art * rate + clip.Due() + assets * RAY <= totalSupply * chi
        stdstore.target(vat).sig("ilks(bytes32)").with_key(ilk).depth(0) // Art is the first element in the ilks struct
            .checked_write(1e18); // 1 wad of debt (very low)
    }

    // Helper function to force stUSDS withdrawals to fail by maximizing Art in the Vat
    function _forceStusdsInsufficientFunds() internal {
        address vat = StUsdsLike(stusds).vat();
        bytes32 ilk = StUsdsLike(stusds).ilk();

        // Set Art (debt) to a high value to ensure capacity constraint fails:
        // Art * rate + clip.Due() + assets * RAY > totalSupply * chi
        // From analysis: current Art ~49M, totalSupply * chi ~47M
        // We'll set Art to 200M to definitely exceed capacity
        uint256 targetArt = 2_000_000_000e18; // 2 billion wads - should exceed capacity

        stdstore.target(vat).sig("ilks(bytes32)").with_key(ilk).depth(0) // Art is the first element in the ilks struct
            .checked_write(targetArt);
    }
}

interface ChainlogLike {
    function getAddress(bytes32) external view returns (address);
}

interface ERC20Like {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface ERC4626Like {
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function asset() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface StUsdsLike {
    function jug() external view returns (address);
    function vat() external view returns (address);
    function clip() external view returns (address);
    function ilk() external view returns (bytes32);
    function chi() external view returns (uint256);
    function cap() external view returns (uint256);
}

interface VatLike {
    function ilks(bytes32) external view returns (uint256, uint256, uint256, uint256, uint256);
}
