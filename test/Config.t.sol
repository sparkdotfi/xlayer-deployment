// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { Test }   from "../lib/forge-std/src/Test.sol";
import { VmSafe } from "../lib/forge-std/src/Vm.sol";

import { Ethereum } from "../lib/spark-address-registry/src/Ethereum.sol";

import { ALMProxy }          from "../lib/spark-alm-controller/src/ALMProxy.sol";
import { ForeignController } from "../lib/spark-alm-controller/src/ForeignController.sol";
import { RateLimits }        from "../lib/spark-alm-controller/src/RateLimits.sol";
import { RateLimitHelpers }  from "../lib/spark-alm-controller/src/RateLimitHelpers.sol";

import { IRateLimits } from "../lib/spark-alm-controller/src/interfaces/IRateLimits.sol";

import { IAccessControl } from "../lib/spark-alm-controller/lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";

import { SparkVault } from "../lib/spark-vaults-v2/src/SparkVault.sol";

contract ConfigTests is Test {

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant RELAYER_ROLE       = keccak256("RELAYER");
    bytes32 internal constant FREEZER_ROLE       = keccak256("FREEZER");
    bytes32 internal constant CONTROLLER_ROLE    = keccak256("CONTROLLER");

    address internal constant ALM_PROXY    = 0xfD2fD4B046136B540A56C11c75ac679AE7d1dB24;
    address internal constant CONTROLLER   = 0xcf8d58A6eeF2a1cae2Ce69bC463b1178FB76bA1E;
    address internal constant RATE_LIMITS  = 0x5c1fDE9d4C7f1BF4bc5dEAA2a7752e56232c68a0;
    address internal constant SPUSDG_VAULT = 0xde770c84FE66E063336b31737cFE9790f18c4087;

    address internal constant MORPHO_USDG_VAULT = 0xBEEff039907422219Fb367e525954DDC092854d9;

    address internal constant DEPLOYER  = 0xB328BD52B61768DD525cF209ab6C1Ac688dcC547;
    address internal constant FREEZER   = 0x59C85fe4385403e93877e48e5521f2F02B150359;
    address internal constant EXECUTOR  = 0x826AEaeee9233fA8Ba199518dd8621A5962b1D02;
    address internal constant RELAYER_1 = 0x59C85fe4385403e93877e48e5521f2F02B150359;
    address internal constant RELAYER_2 = 0x0ca8f938Aba2214eA11eb451e795A8ef7B720C18;
    address internal constant SETTER    = 0x59C85fe4385403e93877e48e5521f2F02B150359;

    address internal constant USDG                = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant SPARK_VAULT_V2_IMPL = 0x797c58C9779D46a437D8f57908D6d56371A55F02;

    ALMProxy          internal almProxy;
    ForeignController internal controller;
    RateLimits        internal rateLimits;
    SparkVault        internal spusdgVault;

    // > bc -l <<< 'scale=27; e( l(1.06)/(60 * 60 * 24 * 365) )'
    //   1.000000001847694957439350562
    uint256 internal constant SIX_PCT_APY = 1.000000001847694957439350562e27;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), _getBlock());

        almProxy    = ALMProxy(payable(ALM_PROXY));
        controller  = ForeignController(CONTROLLER);
        rateLimits  = RateLimits(RATE_LIMITS);
        spusdgVault = SparkVault(SPUSDG_VAULT);
    }

    function _getBlock() internal pure returns (uint256) {
        return 59093;  // June 16, 2026
    }

    function test_postDeployState() external view {
        // ALMProxy/RateLimits roles
        assertEq(almProxy.hasRole(DEFAULT_ADMIN_ROLE, EXECUTOR),   true);
        assertEq(almProxy.hasRole(CONTROLLER_ROLE,    CONTROLLER), true);

        assertEq(rateLimits.hasRole(DEFAULT_ADMIN_ROLE, EXECUTOR),   true);
        assertEq(rateLimits.hasRole(CONTROLLER_ROLE,    CONTROLLER), true);

        // Controller roles
        assertEq(controller.hasRole(DEFAULT_ADMIN_ROLE, EXECUTOR),  true);
        assertEq(controller.hasRole(FREEZER_ROLE,       FREEZER),   true);
        assertEq(controller.hasRole(RELAYER_ROLE,       RELAYER_1), true);
        assertEq(controller.hasRole(RELAYER_ROLE,       RELAYER_2), true);

        assertEq(controller.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);
        assertEq(controller.getRoleMemberCount(FREEZER_ROLE),       1);
        assertEq(controller.getRoleMemberCount(RELAYER_ROLE),       2);

        // Spark Savings USDG Vault roles
        assertEq(spusdgVault.hasRole(DEFAULT_ADMIN_ROLE,        EXECUTOR),  true);
        assertEq(spusdgVault.hasRole(spusdgVault.SETTER_ROLE(), SETTER),    true);
        assertEq(spusdgVault.hasRole(spusdgVault.TAKER_ROLE(),  ALM_PROXY), true);

        assertEq(spusdgVault.getRoleMemberCount(spusdgVault.DEFAULT_ADMIN_ROLE()), 1);
        assertEq(spusdgVault.getRoleMemberCount(spusdgVault.SETTER_ROLE()),        1);
        assertEq(spusdgVault.getRoleMemberCount(spusdgVault.TAKER_ROLE()),         1);

        // DEPLOYER has no roles on ALMProxy, RateLimits, Controller or Spark Vault.
        assertEq(almProxy.hasRole(CONTROLLER_ROLE,    DEPLOYER), false);
        assertEq(almProxy.hasRole(DEFAULT_ADMIN_ROLE, DEPLOYER), false);

        assertEq(rateLimits.hasRole(CONTROLLER_ROLE,    DEPLOYER), false);
        assertEq(rateLimits.hasRole(DEFAULT_ADMIN_ROLE, DEPLOYER), false);

        assertEq(controller.hasRole(DEFAULT_ADMIN_ROLE, DEPLOYER), false);
        assertEq(controller.hasRole(FREEZER_ROLE,       DEPLOYER), false);
        assertEq(controller.hasRole(RELAYER_ROLE,       DEPLOYER), false);

        assertEq(spusdgVault.hasRole(DEFAULT_ADMIN_ROLE,        DEPLOYER), false);
        assertEq(spusdgVault.hasRole(spusdgVault.SETTER_ROLE(), DEPLOYER), false);
        assertEq(spusdgVault.hasRole(spusdgVault.TAKER_ROLE(),  DEPLOYER), false);
    }

    function test_vault_config() external view {
        assertEq(spusdgVault.asset(),             USDG);
        assertEq(spusdgVault.name(),              "Spark Savings USDG");
        assertEq(spusdgVault.symbol(),            "spUSDG");
        assertEq(spusdgVault.decimals(),          6);
        assertEq(spusdgVault.maxVsr(),            SIX_PCT_APY);
        assertEq(spusdgVault.depositCap(),        500_000_000e6);
        assertEq(spusdgVault.getImplementation(), SPARK_VAULT_V2_IMPL);
        assertEq(spusdgVault.rho(),               1780669356);
        assertEq(spusdgVault.chi(),               1e27);
        assertEq(spusdgVault.vsr(),               1e27);
        assertEq(spusdgVault.minVsr(),            1e27);
    }

    function test_rateLimits_config() external view {
        bytes32 takeKey = RateLimitHelpers.makeAddressKey(controller.LIMIT_SPARK_VAULT_TAKE(), address(spusdgVault));

        IRateLimits.RateLimitData memory rateLimit = rateLimits.getRateLimitData(takeKey);

        assertEq(rateLimit.maxAmount, type(uint256).max);
        assertEq(rateLimit.slope,     0);

        bytes32 depositKey = RateLimitHelpers.makeAddressKey(controller.LIMIT_4626_DEPOSIT(), MORPHO_USDG_VAULT);

        rateLimit = rateLimits.getRateLimitData(depositKey);

        assertEq(rateLimit.maxAmount, type(uint256).max);
        assertEq(rateLimit.slope,     0);

        bytes32 redeemKey = RateLimitHelpers.makeAddressKey(controller.LIMIT_4626_WITHDRAW(), MORPHO_USDG_VAULT);

        rateLimit = rateLimits.getRateLimitData(redeemKey);

        assertEq(rateLimit.maxAmount, type(uint256).max);
        assertEq(rateLimit.slope,     0);
        
        bytes32 transferKey = RateLimitHelpers.makeAddressAddressKey(controller.LIMIT_ASSET_TRANSFER(), USDG, address(spusdgVault));

        rateLimit = rateLimits.getRateLimitData(transferKey);

        assertEq(rateLimit.maxAmount, type(uint256).max);
        assertEq(rateLimit.slope,     0);
    }

    function test_controller_config() external view {
        assertEq(address(controller.proxy()),      ALM_PROXY);
        assertEq(address(controller.rateLimits()), RATE_LIMITS);
        assertEq(address(controller.psm()),        address(0));
        assertEq(address(controller.usdc()),       address(0));
        assertEq(address(controller.cctp()),       address(0));
    }

}
