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

interface IExecutor {

    function delay() external view returns (uint256);

    function gracePeriod() external view returns (uint256);

}

interface IReceiver {

    function l1Authority() external view returns (address);

    function target() external view returns (address);

}

contract ConfigTests is Test {

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant RELAYER_ROLE       = keccak256("RELAYER");
    bytes32 internal constant FREEZER_ROLE       = keccak256("FREEZER");
    bytes32 internal constant CONTROLLER_ROLE    = keccak256("CONTROLLER");

    address internal constant ALM_PROXY    = 0x83A914C361bB729EB6BEBC8C7bA993667A0E6Df8;
    address internal constant CONTROLLER   = 0xf9187C99Ee842beABE8e2e346d958315BFc9331f;
    address internal constant RATE_LIMITS  = 0x7F7E2286983994c4403Cf2B86758cE0e7bA666a8;
    address internal constant SPUSDT_VAULT = 0xc358c90D32375721Cb3924320Fdc2F8B694347Ca;

    address internal constant DEPLOYER  = 0x23d43f3189Ab9CEBfFcC0352C0490387e3105FB3;
    address internal constant FREEZER   = 0x90D8c80C028B4C09C0d8dcAab9bbB057F0513431;
    address internal constant EXECUTOR  = 0xCF5af6F53ceC74B791cb4182aC778ca9CD323510;
    address internal constant RECEIVER  = 0x4bd50B9c00Ae19e8B59723F27645C7A5cCe7a4A0;
    address internal constant RELAYER_1 = 0x8a25A24EDE9482C4Fc0738F99611BE58F1c839AB;
    address internal constant RELAYER_2 = 0x9330edE0Fc6E3E0D47Ebf3C145efd569796aC7F5;
    address internal constant SETTER    = 0x9449ed367C60ea757544fd990B57e1C2D0Ec3A94;

    address internal constant USDT                = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address internal constant SPARK_VAULT_V2_IMPL = 0xdCe929A335C75a1676EF5957A4D7a3b928C48820;

    ALMProxy          internal almProxy;
    ForeignController internal controller;
    RateLimits        internal rateLimits;
    SparkVault        internal spusdtVault;

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
        assertEq(spusdtVault.hasRole(DEFAULT_ADMIN_ROLE,        EXECUTOR),  true);
        assertEq(spusdtVault.hasRole(spusdtVault.SETTER_ROLE(), SETTER),    true);
        assertEq(spusdtVault.hasRole(spusdtVault.TAKER_ROLE(),  ALM_PROXY), true);

        assertEq(spusdtVault.getRoleMemberCount(spusdtVault.DEFAULT_ADMIN_ROLE()), 1);
        assertEq(spusdtVault.getRoleMemberCount(spusdtVault.SETTER_ROLE()),        1);
        assertEq(spusdtVault.getRoleMemberCount(spusdtVault.TAKER_ROLE()),         1);

        // DEPLOYER has no roles on ALMProxy, RateLimits, Controller or Spark Vault.
        assertEq(almProxy.hasRole(CONTROLLER_ROLE,    DEPLOYER), false);
        assertEq(almProxy.hasRole(DEFAULT_ADMIN_ROLE, DEPLOYER), false);

        assertEq(rateLimits.hasRole(CONTROLLER_ROLE,    DEPLOYER), false);
        assertEq(rateLimits.hasRole(DEFAULT_ADMIN_ROLE, DEPLOYER), false);

        assertEq(controller.hasRole(DEFAULT_ADMIN_ROLE, DEPLOYER), false);
        assertEq(controller.hasRole(FREEZER_ROLE,       DEPLOYER), false);
        assertEq(controller.hasRole(RELAYER_ROLE,       DEPLOYER), false);

        assertEq(spusdtVault.hasRole(DEFAULT_ADMIN_ROLE,        DEPLOYER), false);
        assertEq(spusdtVault.hasRole(spusdtVault.SETTER_ROLE(), DEPLOYER), false);
        assertEq(spusdtVault.hasRole(spusdtVault.TAKER_ROLE(),  DEPLOYER), false);
    }

    function test_vault_config() external view {
        assertEq(spusdtVault.asset(),             USDT);
        assertEq(spusdtVault.name(),              "Spark Savings USDT");
        assertEq(spusdtVault.symbol(),            "spUSDT");
        assertEq(spusdtVault.decimals(),          6);
        assertEq(spusdtVault.maxVsr(),            SIX_PCT_APY);
        assertEq(spusdtVault.depositCap(),        750_000_000e6);
        assertEq(spusdtVault.getImplementation(), SPARK_VAULT_V2_IMPL);
        assertEq(spusdtVault.rho(),               1783422453);
        assertEq(spusdtVault.chi(),               1e27);
        assertEq(spusdtVault.vsr(),               1e27);
        assertEq(spusdtVault.minVsr(),            1e27);
    }

    function test_rateLimits_config() external view {
        bytes32 takeKey = RateLimitHelpers.makeAddressKey(controller.LIMIT_SPARK_VAULT_TAKE(), address(spusdtVault));

        IRateLimits.RateLimitData memory rateLimit = rateLimits.getRateLimitData(takeKey);

        assertEq(rateLimit.maxAmount, type(uint256).max);
        assertEq(rateLimit.slope,     0);

        bytes32 transferKey = RateLimitHelpers.makeAddressAddressKey(controller.LIMIT_ASSET_TRANSFER(), USDT, address(spusdtVault));

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

    function test_executor_config() external view {
        assertEq(IExecutor(EXECUTOR).delay(),       0);
        assertEq(IExecutor(EXECUTOR).gracePeriod(), 7 days);
    }

    function test_receiver_config() external view {
        assertEq(IReceiver(RECEIVER).l1Authority(), Ethereum.SPARK_PROXY);
        assertEq(IReceiver(RECEIVER).target(),      EXECUTOR);
    }

}
