// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { ScriptTools } from "../lib/dss-test/src/ScriptTools.sol";

import { IERC4626 } from "../lib/forge-std/src/interfaces/IERC4626.sol";

import { Script, stdJson } from "../lib/forge-std/src/Script.sol";

import { Ethereum } from "../lib/spark-address-registry/src/Ethereum.sol";

import { IALMProxy }         from "../lib/spark-alm-controller/src/interfaces/IALMProxy.sol";
import { IRateLimits }       from "../lib/spark-alm-controller/src/interfaces/IRateLimits.sol";
import { MainnetController } from "../lib/spark-alm-controller/src/MainnetController.sol";
import { RateLimitHelpers }  from "../lib/spark-alm-controller/src/RateLimitHelpers.sol";

import { IERC20Metadata } from "../lib/spark-vaults-v2/lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { console2 } from "../lib/forge-std/src/console2.sol";

interface ISparkVaultV2 {
    function asset() external view returns (address);
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function setDepositCap(uint256 newCap) external;
    function SETTER_ROLE() external view returns (bytes32);
    function setVsrBounds(uint256 minVsr_, uint256 maxVsr_) external;
    function TAKER_ROLE() external view returns (bytes32);
}

interface IRateLimitsLike {
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
}

interface IALMProxyLike {
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
}

contract Configure is Script {

    using stdJson     for string;
    using ScriptTools for string;

    address internal constant DEPLOYER     = 0xB328BD52B61768DD525cF209ab6C1Ac688dcC547;
    address internal constant EXECUTOR     = 0x826AEaeee9233fA8Ba199518dd8621A5962b1D02;
    address internal constant FREEZER      = 0x0ca8f938Aba2214eA11eb451e795A8ef7B720C18;
    address internal constant PL_OPS_SAFE  = 0x59C85fe4385403e93877e48e5521f2F02B150359;
    address internal constant RELAYER_1    = 0x59C85fe4385403e93877e48e5521f2F02B150359;
    address internal constant RELAYER_2    = 0x0ca8f938Aba2214eA11eb451e795A8ef7B720C18;

    address internal constant SPUSDG_VAULT = 0xde770c84FE66E063336b31737cFE9790f18c4087;

    address internal constant ALM_PROXY       = 0xfD2fD4B046136B540A56C11c75ac679AE7d1dB24;
    address internal constant ALM_RATE_LIMITS = 0x5c1fDE9d4C7f1BF4bc5dEAA2a7752e56232c68a0;
    address internal constant ALM_CONTROLLER  = 0xcf8d58A6eeF2a1cae2Ce69bC463b1178FB76bA1E;

    address internal constant MORPHO_USDG_VAULT = 0x417bb610b14edF20f1357E159459DD4092E59a95;  // TODO change this

    // > bc -l <<< 'scale=27; e( l(1.06)/(60 * 60 * 24 * 365) )'
    //   1.000000001847694957439350562
    uint256 internal constant SIX_PCT_APY = 1.000000001847694957439350562e27;

    function run() external {
        vm.startBroadcast();

        // Configure Spark Savings USDG Vault (SPUSDG)
        _configureVaultsV2({
            vault_        : SPUSDG_VAULT,
            supplyCap     : 500_000_000e6,
            minVsr        : 1e27,
            maxVsr        : SIX_PCT_APY
        });

        // Configure Legacy PAU ratelimits to deposit and withdraw from Spark Vault
        ISparkVaultV2     vault      = ISparkVaultV2(SPUSDG_VAULT);
        IRateLimits       rateLimits = IRateLimits(ALM_RATE_LIMITS);
        MainnetController controller = MainnetController(ALM_CONTROLLER);

        rateLimits.setUnlimitedRateLimitData(
            RateLimitHelpers.makeAddressKey(
                controller.LIMIT_SPARK_VAULT_TAKE(),
                address(vault)
            )
        );

        rateLimits.setUnlimitedRateLimitData(
            RateLimitHelpers.makeAddressAddressKey(
                controller.LIMIT_ASSET_TRANSFER(),
                vault.asset(),
                address(vault)
            )
        );

        rateLimits.setUnlimitedRateLimitData(
            RateLimitHelpers.makeAddressKey(
                controller.LIMIT_4626_DEPOSIT(),
                MORPHO_USDG_VAULT
            )
        );

        rateLimits.setUnlimitedRateLimitData(
            RateLimitHelpers.makeAddressKey(
                controller.LIMIT_4626_WITHDRAW(),
                MORPHO_USDG_VAULT
            )
        );

        address morpho_vault = MORPHO_USDG_VAULT;
        address asset        = IERC4626(morpho_vault).asset();

        controller.setMaxExchangeRate(
            morpho_vault,
            1 * 10 ** IERC20Metadata(morpho_vault).decimals(),
            10 * 10 ** IERC20Metadata(asset).decimals()
        );

        // Transfer admin role from deployer to Executor for SPUSDG vault v2
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(),  EXECUTOR);
        vault.revokeRole(vault.DEFAULT_ADMIN_ROLE(), DEPLOYER);

        // Transfer Ratelimits, ALMProxy and Controller admin from deployer to Executor for legacy PAU
        IALMProxy almProxy = IALMProxy(ALM_PROXY);

        almProxy.grantRole(almProxy.CONTROLLER(),     address(controller));
        rateLimits.grantRole(rateLimits.CONTROLLER(), address(controller));

        controller.grantRole(controller.FREEZER(), FREEZER);
        controller.grantRole(controller.RELAYER(), RELAYER_1);
        controller.grantRole(controller.RELAYER(), RELAYER_2);

        // Start removing Deployer as admin.
        rateLimits.grantRole(IRateLimitsLike(address(rateLimits)).DEFAULT_ADMIN_ROLE(),  EXECUTOR);
        rateLimits.revokeRole(IRateLimitsLike(address(rateLimits)).DEFAULT_ADMIN_ROLE(), DEPLOYER);

        almProxy.grantRole(IALMProxyLike(address(almProxy)).DEFAULT_ADMIN_ROLE(),  EXECUTOR);
        almProxy.revokeRole(IALMProxyLike(address(almProxy)).DEFAULT_ADMIN_ROLE(), DEPLOYER);

        controller.grantRole(controller.DEFAULT_ADMIN_ROLE(),  EXECUTOR);
        controller.revokeRole(controller.DEFAULT_ADMIN_ROLE(), DEPLOYER);

        vm.stopBroadcast();
    }

    function _configureVaultsV2(
        address vault_,
        uint256 supplyCap,
        uint256 minVsr,
        uint256 maxVsr
    ) internal {
        ISparkVaultV2 vault = ISparkVaultV2(vault_);

        // Grant SETTER_ROLE to Phoenix Labs Ops Safe
        vault.grantRole(vault.SETTER_ROLE(), PL_OPS_SAFE);

        // Grant TAKER_ROLE to Legacy PAU
        vault.grantRole(vault.TAKER_ROLE(), ALM_PROXY);

        // Set VSR bounds
        vault.setVsrBounds(minVsr, maxVsr);

        // Set the supply cap
        vault.setDepositCap(supplyCap);
    }

}
