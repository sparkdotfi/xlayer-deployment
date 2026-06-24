// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { Test }   from "../lib/forge-std/src/Test.sol";

import { IERC4626 } from "../lib/forge-std/src/interfaces/IERC4626.sol";

import { Ethereum } from "../lib/spark-address-registry/src/Ethereum.sol";

import { ALMProxy }          from "../lib/spark-alm-controller/src/ALMProxy.sol";
import { ForeignController } from "../lib/spark-alm-controller/src/ForeignController.sol";
import { RateLimits }        from "../lib/spark-alm-controller/src/RateLimits.sol";
import { RateLimitHelpers }  from "../lib/spark-alm-controller/src/RateLimitHelpers.sol";

import { IRateLimits } from "../lib/spark-alm-controller/src/interfaces/IRateLimits.sol";

import { SafeERC20, IERC20 } from "../lib/spark-alm-controller/lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import { SparkVault } from "../lib/spark-vaults-v2/src/SparkVault.sol";

contract E2ETests is Test {

    address internal constant ALM_PROXY    = 0xfD2fD4B046136B540A56C11c75ac679AE7d1dB24;
    address internal constant CONTROLLER   = 0xcf8d58A6eeF2a1cae2Ce69bC463b1178FB76bA1E;
    address internal constant EXECUTOR     = 0x826AEaeee9233fA8Ba199518dd8621A5962b1D02;
    address internal constant RATE_LIMITS  = 0x5c1fDE9d4C7f1BF4bc5dEAA2a7752e56232c68a0;
    address internal constant RELAYER_1    = 0x59C85fe4385403e93877e48e5521f2F02B150359;
    address internal constant SETTER       = 0x59C85fe4385403e93877e48e5521f2F02B150359;
    address internal constant SPUSDG_VAULT = 0xde770c84FE66E063336b31737cFE9790f18c4087;

    address internal constant MORPHO_USDG_VAULT = 0xBEEff039907422219Fb367e525954DDC092854d9;

    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    address internal USER = makeAddr("user1");

    ALMProxy          internal almProxy;
    ForeignController internal controller;
    RateLimits        internal rateLimits;
    SparkVault        internal spusdgVault;

    // > bc -l <<< 'scale=27; e( l(1.01)/(60 * 60 * 24 * 365) )'
    //   1.000000000315522921573372069
    uint256 internal constant ONE_PCT_APY = 1.000000000315522921573372069e27;

    // > bc -l <<< 'scale=27; e( l(1.06)/(60 * 60 * 24 * 365) )'
    //   1.000000001847694957439350562
    uint256 internal constant SIX_PCT_APY = 1.000000001847694957439350562e27;

    function setUp() public {
        vm.createSelectFork(vm.envString("RH_RPC_URL"), _getBlock());

        almProxy    = ALMProxy(payable(ALM_PROXY));
        controller  = ForeignController(CONTROLLER);
        rateLimits  = RateLimits(RATE_LIMITS);
        spusdgVault = SparkVault(SPUSDG_VAULT);
    }

    function _getBlock() internal pure returns (uint256) {
        return 59093;  // June 16, 2026
    }

    function test_boundary_depositCap() external {
        IERC20 usdg = IERC20(USDG);

        deal(USDG, USER, 500_000_000e6);  // SPUSDG Vault already has 8.01e6 of USDG.

        vm.startPrank(USER);
        SafeERC20.safeIncreaseAllowance(usdg, SPUSDG_VAULT, 500_000_000e6);
        vm.expectRevert("SparkVault/deposit-cap-exceeded");
        spusdgVault.deposit(500_000_000e6, USER);
        vm.stopPrank();

        deal(USDG, USER, 500_000_000e6 - 8.01e6);

        assertEq(usdg.balanceOf(USER),        500_000_000e6 - 8.01e6);
        assertEq(spusdgVault.totalAssets(),   8.01e6);
        assertEq(spusdgVault.totalSupply(),   8.01e6);
        assertEq(spusdgVault.balanceOf(USER), 0);

        vm.startPrank(USER);
        SafeERC20.safeIncreaseAllowance(usdg, SPUSDG_VAULT, 500_000_000e6 - 8.01e6);
        spusdgVault.deposit(500_000_000e6 - 8.01e6, USER);
        vm.stopPrank();

        assertEq(usdg.balanceOf(USER),        0);
        assertEq(spusdgVault.totalAssets(),   500_000_000e6);
        assertEq(spusdgVault.totalSupply(),   500_000_000e6);
        assertEq(spusdgVault.balanceOf(USER), 500_000_000e6 - 8.01e6);
    }

    function test_settingVsr_failsAboveMaxVsrBoundary() external {
        assertEq(spusdgVault.maxVsr(), SIX_PCT_APY);

        vm.expectRevert("SparkVault/vsr-too-high");
        vm.prank(SETTER);
        spusdgVault.setVsr(SIX_PCT_APY + 1);

        vm.prank(SETTER);
        spusdgVault.setVsr(SIX_PCT_APY);
    }

    function test_E2E() external {
        IERC4626 morphoUsdgVault = IERC4626(MORPHO_USDG_VAULT);
        IERC20   usdg            = IERC20(USDG);

        uint256 depositAmount = 1_000_000e6;

        deal(USDG, USER, depositAmount);

        // Step 1: User deposits USDG into the SPUSDG Vault

        assertEq(usdg.balanceOf(USER),        depositAmount);
        assertEq(spusdgVault.totalAssets(),   8.01e6);
        assertEq(spusdgVault.totalSupply(),   8.01e6);
        assertEq(spusdgVault.balanceOf(USER), 0);

        vm.startPrank(USER);
        SafeERC20.safeIncreaseAllowance(usdg, SPUSDG_VAULT, depositAmount);
        spusdgVault.deposit(depositAmount, USER);
        vm.stopPrank();

        assertEq(usdg.balanceOf(USER),        0);
        assertEq(spusdgVault.totalAssets(),   depositAmount + 8.01e6);
        assertEq(spusdgVault.totalSupply(),   depositAmount + 8.01e6);
        assertEq(spusdgVault.balanceOf(USER), depositAmount);

        assertEq(usdg.balanceOf(SPUSDG_VAULT),      depositAmount + 8.01e6);
        assertEq(usdg.balanceOf(address(almProxy)), 0);

        // Warp to show that there is no interest accruing yet.
        assertEq(spusdgVault.totalAssets(), depositAmount + 8.01e6);

        vm.warp(block.timestamp + 1 days);

        assertEq(spusdgVault.totalAssets(), depositAmount + 8.01e6);

        // Step 2: Controller takes USDG from the SPUSDG Vault

        bytes32 takeKey = RateLimitHelpers.makeAddressKey(controller.LIMIT_SPARK_VAULT_TAKE(), address(spusdgVault));

        _assertUnlimitedRateLimit(takeKey);

        vm.prank(RELAYER_1);
        controller.takeFromSparkVault(address(spusdgVault), depositAmount);

        _assertUnlimitedRateLimit(takeKey);

        assertEq(usdg.balanceOf(SPUSDG_VAULT),      8.01e6);
        assertEq(usdg.balanceOf(address(almProxy)), depositAmount);

        // Step 3: Controller deposits USDG into Morpho USDG Vault

        assertEq(morphoUsdgVault.balanceOf(address(almProxy)), 0);

        bytes32 depositKey = RateLimitHelpers.makeAddressKey(controller.LIMIT_4626_DEPOSIT(), address(morphoUsdgVault));

        _assertUnlimitedRateLimit(depositKey);

        vm.prank(RELAYER_1);
        uint256 shares = controller.depositERC4626(address(morphoUsdgVault), depositAmount, 0);

        _assertUnlimitedRateLimit(depositKey);

        assertEq(usdg.balanceOf(address(almProxy)),            0);
        assertEq(morphoUsdgVault.balanceOf(address(almProxy)), shares);

        // Step 4: Set VSR and warp to show interest accrual

        vm.prank(SETTER);
        spusdgVault.setVsr(ONE_PCT_APY);

        assertEq(spusdgVault.vsr(),         ONE_PCT_APY);
        assertEq(spusdgVault.totalAssets(), depositAmount + 8.01e6);

        vm.warp(block.timestamp + 1 days);

        assertEq(spusdgVault.totalAssets(), depositAmount + 8.01e6 + 27.26177e6);

        // Step 5: Controller withdraws USDG from Morpho USDG Vault

        bytes32 redeemKey = RateLimitHelpers.makeAddressKey(controller.LIMIT_4626_WITHDRAW(), address(morphoUsdgVault));

        _assertUnlimitedRateLimit(redeemKey);

        vm.prank(RELAYER_1);
        controller.redeemERC4626(MORPHO_USDG_VAULT, shares, 0);

        _assertUnlimitedRateLimit(redeemKey);

        assertEq(morphoUsdgVault.balanceOf(address(almProxy)), 0);
        assertEq(usdg.balanceOf(address(almProxy)),            depositAmount - 1);

        // Step 6: Controller transfers USDG from ALMProxy to SPUSDG Vault

        // Deal 100e6 USDG to the ALMProxy to simulate accrued yield
        deal(USDG, address(almProxy), depositAmount + 100e6);

        bytes32 transferKey = RateLimitHelpers.makeAddressAddressKey(controller.LIMIT_ASSET_TRANSFER(), USDG, address(spusdgVault));

        _assertUnlimitedRateLimit(transferKey);

        assertEq(usdg.balanceOf(address(almProxy)),    depositAmount + 100e6);
        assertEq(usdg.balanceOf(address(spusdgVault)), 8.01e6);

        vm.startPrank(RELAYER_1);
        controller.transferAsset(USDG, address(spusdgVault), usdg.balanceOf(address(almProxy)));
        vm.stopPrank();

        _assertUnlimitedRateLimit(transferKey);

        assertEq(usdg.balanceOf(address(almProxy)),    0);
        assertEq(usdg.balanceOf(address(spusdgVault)), depositAmount + 100e6 + 8.01e6);

        // Step 7: User withdraws USDG from the SPUSDG Vault

        vm.startPrank(USER);
        spusdgVault.redeem(spusdgVault.balanceOf(USER), USER, USER);
        vm.stopPrank();

        assertEq(usdg.balanceOf(USER),        depositAmount + 27.261552e6);  // Accrued yield
        assertEq(spusdgVault.balanceOf(USER), 0);
    }

    function _assertUnlimitedRateLimit(
       bytes32 key
    ) internal view {
        IRateLimits.RateLimitData memory rateLimit = rateLimits.getRateLimitData(key);

        assertEq(rateLimit.maxAmount, type(uint256).max);
        assertEq(rateLimit.slope,     0);
    }

}
