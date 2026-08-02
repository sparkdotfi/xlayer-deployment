// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { ScriptTools } from "../lib/dss-test/src/ScriptTools.sol";

import { IERC4626 } from "../lib/forge-std/src/interfaces/IERC4626.sol";

import { Script, stdJson } from "../lib/forge-std/src/Script.sol";

import { Ethereum } from "../lib/spark-address-registry/src/Ethereum.sol";

import { IALMProxy }         from "../lib/spark-alm-controller/src/interfaces/IALMProxy.sol";
import { IRateLimits }       from "../lib/spark-alm-controller/src/interfaces/IRateLimits.sol";
import { ForeignController } from "../lib/spark-alm-controller/src/ForeignController.sol";
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

    address internal constant DEPLOYER            = 0x23d43f3189Ab9CEBfFcC0352C0490387e3105FB3;
    address internal constant EXECUTOR            = 0xCF5af6F53ceC74B791cb4182aC778ca9CD323510;
    address internal constant FREEZER             = 0x90D8c80C028B4C09C0d8dcAab9bbB057F0513431;
    address internal constant ALM_PROXY_FREEZABLE = 0x9449ed367C60ea757544fd990B57e1C2D0Ec3A94;
    address internal constant RELAYER_1           = 0x8a25A24EDE9482C4Fc0738F99611BE58F1c839AB;
    address internal constant RELAYER_2           = 0x9330edE0Fc6E3E0D47Ebf3C145efd569796aC7F5;

    address internal constant SPUSDT_VAULT = 0xc358c90D32375721Cb3924320Fdc2F8B694347Ca;

    address internal constant USDT_OFT = 0x94BCCa6bdfd6A61817Ab0E960bFedE4984505554;

    address internal constant ALM_PROXY       = 0x83A914C361bB729EB6BEBC8C7bA993667A0E6Df8;
    address internal constant ALM_RATE_LIMITS = 0x7F7E2286983994c4403Cf2B86758cE0e7bA666a8;
    address internal constant ALM_CONTROLLER  = 0xf9187C99Ee842beABE8e2e346d958315BFc9331f;

    // > bc -l <<< 'scale=27; e( l(1.06)/(60 * 60 * 24 * 365) )'
    //   1.000000001847694957439350562
    uint256 internal constant SIX_PCT_APY = 1.000000001847694957439350562e27;

    uint32 internal constant LZ_ENDPOINT_ETHEREUM = 30101;

    function run() external {
        vm.startBroadcast();

        // Configure Spark Savings USDT Vault (SPUSDT)
        _configureVaultsV2({
            vault_        : SPUSDT_VAULT,
            supplyCap     : 750_000_000e6,
            minVsr        : 1e27,
            maxVsr        : SIX_PCT_APY
        });

        // Configure Legacy PAU ratelimits to deposit and withdraw from Spark Vault
        ISparkVaultV2     vault      = ISparkVaultV2(SPUSDT_VAULT);
        IRateLimits       rateLimits = IRateLimits(ALM_RATE_LIMITS);
        ForeignController controller = ForeignController(ALM_CONTROLLER);

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

        controller.setLayerZeroRecipient(
            LZ_ENDPOINT_ETHEREUM,
            bytes32(uint256(uint160(Ethereum.ALM_PROXY)))
        );

        rateLimits.setUnlimitedRateLimitData(
            keccak256(
                abi.encode(
                    controller.LIMIT_LAYERZERO_TRANSFER(),
                    USDT_OFT,
                    LZ_ENDPOINT_ETHEREUM
                )
            )
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

        // Grant SETTER_ROLE to ALM Proxy Freezable
        vault.grantRole(vault.SETTER_ROLE(), ALM_PROXY_FREEZABLE);

        // Grant TAKER_ROLE to Legacy PAU
        vault.grantRole(vault.TAKER_ROLE(), ALM_PROXY);

        // Set VSR bounds
        vault.setVsrBounds(minVsr, maxVsr);

        // Set the supply cap
        vault.setDepositCap(supplyCap);
    }

}
