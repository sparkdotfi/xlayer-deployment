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

    address internal constant ALM_PROXY    = 0x83A914C361bB729EB6BEBC8C7bA993667A0E6Df8;
    address internal constant CONTROLLER   = 0xf9187C99Ee842beABE8e2e346d958315BFc9331f;
    address internal constant EXECUTOR     = 0xCF5af6F53ceC74B791cb4182aC778ca9CD323510;
    address internal constant RATE_LIMITS  = 0x7F7E2286983994c4403Cf2B86758cE0e7bA666a8;
    address internal constant RELAYER_1    = 0x8a25A24EDE9482C4Fc0738F99611BE58F1c839AB;
    address internal constant SETTER       = 0x9449ed367C60ea757544fd990B57e1C2D0Ec3A94;
    address internal constant SPUSDT_VAULT = 0xc358c90D32375721Cb3924320Fdc2F8B694347Ca;

    address internal constant USDT = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;

    address internal USER = makeAddr("user1");

    ALMProxy          internal almProxy;
    ForeignController internal controller;
    RateLimits        internal rateLimits;
    SparkVault        internal spusdtVault;

    // > bc -l <<< 'scale=27; e( l(1.01)/(60 * 60 * 24 * 365) )'
    //   1.000000000315522921573372069
    uint256 internal constant ONE_PCT_APY = 1.000000000315522921573372069e27;

    // > bc -l <<< 'scale=27; e( l(1.06)/(60 * 60 * 24 * 365) )'
    //   1.000000001847694957439350562
    uint256 internal constant SIX_PCT_APY = 1.000000001847694957439350562e27;

    function setUp() public {
        vm.createSelectFork("https://rpc.xlayer.tech", 64662930);

        almProxy    = ALMProxy(payable(ALM_PROXY));
        controller  = ForeignController(CONTROLLER);
        rateLimits  = RateLimits(RATE_LIMITS);
        spusdtVault = SparkVault(SPUSDT_VAULT);
    }

    function test_boundary_depositCap() external {
        IERC20 usdg = IERC20(USDT);

        uint256 depositCap = 750_000_000e6;

        deal(USDT, USER, depositCap);  // SPUSDG Vault already has 8.01e6 of USDG.

        vm.startPrank(USER);
        SafeERC20.safeIncreaseAllowance(usdg, SPUSDT_VAULT, depositCap);
        vm.expectRevert("SparkVault/deposit-cap-exceeded");
        spusdtVault.deposit(depositCap, USER);
        vm.stopPrank();

        deal(USDT, USER, depositCap - 1e6);

        assertEq(usdg.balanceOf(USER),        depositCap - 1e6);
        assertEq(spusdtVault.totalAssets(),   1e6);
        assertEq(spusdtVault.totalSupply(),   1e6);
        assertEq(spusdtVault.balanceOf(USER), 0);

        vm.startPrank(USER);
        SafeERC20.safeIncreaseAllowance(usdg, SPUSDT_VAULT, depositCap - 1e6);
        spusdtVault.deposit(depositCap - 1e6, USER);
        vm.stopPrank();

        assertEq(usdg.balanceOf(USER),        0);
        assertEq(spusdtVault.totalAssets(),   depositCap);
        assertEq(spusdtVault.totalSupply(),   depositCap);
        assertEq(spusdtVault.balanceOf(USER), depositCap - 1e6);
    }

    function test_settingVsr_failsAboveMaxVsrBoundary() external {
        assertEq(spusdtVault.maxVsr(), SIX_PCT_APY);

        vm.expectRevert("SparkVault/vsr-too-high");
        vm.prank(SETTER);
        spusdtVault.setVsr(SIX_PCT_APY + 1);

        vm.prank(SETTER);
        spusdtVault.setVsr(SIX_PCT_APY);
    }

    function test_E2E() external {
        IERC20 usdt = IERC20(USDT);

        uint256 depositAmount = 1_000_000e6;

        deal(USDT, USER, depositAmount);

        // Step 1: User deposits USDG into the SPUSDG Vault

        assertEq(usdt.balanceOf(USER),        depositAmount);
        assertEq(spusdtVault.totalAssets(),   1e6);
        assertEq(spusdtVault.totalSupply(),   1e6);
        assertEq(spusdtVault.balanceOf(USER), 0);

        vm.startPrank(USER);
        SafeERC20.safeIncreaseAllowance(usdt, SPUSDT_VAULT, depositAmount);
        spusdtVault.deposit(depositAmount, USER);
        vm.stopPrank();

        assertEq(usdt.balanceOf(USER),        0);
        assertEq(spusdtVault.totalAssets(),   depositAmount + 1e6);
        assertEq(spusdtVault.totalSupply(),   depositAmount + 1e6);
        assertEq(spusdtVault.balanceOf(USER), depositAmount);

        assertEq(usdt.balanceOf(SPUSDT_VAULT),      depositAmount + 1e6);
        assertEq(usdt.balanceOf(address(almProxy)), 0);

        // Warp to show that there is no interest accruing yet.
        assertEq(spusdtVault.totalAssets(), depositAmount + 1e6);

        vm.warp(block.timestamp + 1 days);

        assertEq(spusdtVault.totalAssets(), depositAmount + 1e6);

        // Step 2: Controller takes USDT from the SPUSDT Vault

        bytes32 takeKey = RateLimitHelpers.makeAddressKey(controller.LIMIT_SPARK_VAULT_TAKE(), address(spusdtVault));

        _assertUnlimitedRateLimit(takeKey);

        vm.prank(RELAYER_1);
        controller.takeFromSparkVault(address(spusdtVault), depositAmount);

        _assertUnlimitedRateLimit(takeKey);

        assertEq(usdt.balanceOf(SPUSDT_VAULT),      1e6);
        assertEq(usdt.balanceOf(address(almProxy)), depositAmount);

        // Step 3: Set VSR and warp to show interest accrual

        vm.prank(SETTER);
        spusdtVault.setVsr(ONE_PCT_APY);

        assertEq(spusdtVault.vsr(),         ONE_PCT_APY);
        assertEq(spusdtVault.totalAssets(), depositAmount + 1e6);

        vm.warp(block.timestamp + 1 days);

        assertEq(spusdtVault.totalAssets(), depositAmount + 1e6 + 27.261579e6);

        // Step 4: Controller transfers USDG from ALMProxy to SPUSDG Vault

        // Deal 100e6 USDG to the ALMProxy to simulate accrued yield
        deal(USDT, address(almProxy), depositAmount + 100e6);

        bytes32 transferKey = RateLimitHelpers.makeAddressAddressKey(controller.LIMIT_ASSET_TRANSFER(), USDT, address(spusdtVault));

        _assertUnlimitedRateLimit(transferKey);

        assertEq(usdt.balanceOf(address(almProxy)),    depositAmount + 100e6);
        assertEq(usdt.balanceOf(address(spusdtVault)), 1e6);

        vm.startPrank(RELAYER_1);
        controller.transferAsset(USDT, address(spusdtVault), usdt.balanceOf(address(almProxy)));
        vm.stopPrank();

        _assertUnlimitedRateLimit(transferKey);

        assertEq(usdt.balanceOf(address(almProxy)),    0);
        assertEq(usdt.balanceOf(address(spusdtVault)), depositAmount + 100e6 + 1e6);

        // Step 5: User withdraws USDG from the SPUSDG Vault

        vm.startPrank(USER);
        spusdtVault.redeem(spusdtVault.balanceOf(USER), USER, USER);
        vm.stopPrank();

        assertEq(usdt.balanceOf(USER),        depositAmount + 27.261552e6);  // Accrued yield
        assertEq(spusdtVault.balanceOf(USER), 0);
    }

    function _assertUnlimitedRateLimit(
       bytes32 key
    ) internal view {
        IRateLimits.RateLimitData memory rateLimit = rateLimits.getRateLimitData(key);

        assertEq(rateLimit.maxAmount, type(uint256).max);
        assertEq(rateLimit.slope,     0);
    }

}
