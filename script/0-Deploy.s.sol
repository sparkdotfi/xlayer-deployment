// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { ScriptTools } from "../lib/dss-test/src/ScriptTools.sol";

import { Script, stdJson } from "../lib/forge-std/src/Script.sol";

import { ALMProxy }   from "../lib/spark-alm-controller/src/ALMProxy.sol";
import { RateLimits } from "../lib/spark-alm-controller/src/RateLimits.sol";

import { ControllerInstance }      from "../lib/spark-alm-controller/deploy/ControllerInstance.sol";
import { ForeignControllerDeploy } from "../lib/spark-alm-controller/deploy/ControllerDeploy.sol";

import { SparkVault } from "../lib/spark-vaults-v2/src/SparkVault.sol";

import { ERC1967Proxy }   from "../lib/spark-vaults-v2/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20Metadata } from "../lib/spark-vaults-v2/lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { console2 } from "../lib/forge-std/src/console2.sol";

contract DeployLegacyPAU is Script {

    using stdJson     for string;
    using ScriptTools for string;

    function run() external {
        vm.startBroadcast();

        ControllerInstance memory instance = ForeignControllerDeploy.deployFull({
            admin : msg.sender,
            psm   : address(0),
            usdc  : address(0),
            cctp  : address(0)
        });

        vm.stopBroadcast();

        console2.log("ALMProxy   deployed at", instance.almProxy);
        console2.log("Controller deployed at", instance.controller);
        console2.log("RateLimits deployed at", instance.rateLimits);
    }

}

contract DeploySparkVaultImpl is Script {

    using ScriptTools for string;
    using stdJson     for string;

    function run() public {
        vm.setEnv("FOUNDRY_EXPORTS_OVERWRITE_LATEST", "true");

        // TODO: Figure out why this doesn't work. Until then, --rpc-url must be passed to `forge
        // script` manually
        // vm.createSelectFork(getChain("mainnet").rpcUrl);

        // Deploy SparkVault implementation
        vm.startBroadcast();
        // NOTE: By itself, the Vault has nobody in a privileged role, depositCap and vsr are 0 and
        // initializers are disabled (`constructor() { _disableInitializers(); }`). It is not
        // possible for an outside party to interact with this contract in any way.
        address impl = address(new SparkVault());
        vm.stopBroadcast();

        console2.log("Deployed SparkVault implementation:");
        console2.log("  impl: ",            impl);
        console2.log("  block.chainId: ",   block.chainid);
        console2.log("  block.timestamp: ", block.timestamp);
        console2.log("  block.number ",     block.number);
    }

}

contract DeploySparkVaultProxy is Script {

    using ScriptTools for string;
    using stdJson     for string;

    address impl  = 0x797c58C9779D46a437D8f57908D6d56371A55F02;

    function run() public {
        vm.setEnv("FOUNDRY_EXPORTS_OVERWRITE_LATEST", "true");

        address admin         = msg.sender;
        address asset         = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
        string  memory name   = "Spark Savings USDG";
        string  memory symbol = "spUSDG";

        // Deploy SparkVault proxy
        vm.startBroadcast();
        SparkVault proxy = SparkVault(address(new ERC1967Proxy(
            impl,
            abi.encodeCall(
                SparkVault.initialize,
                (asset, name, symbol, admin)
            )
        )));
        vm.stopBroadcast();

        // Check
        require(proxy.asset() == asset, "asset");

        require(proxy.decimals() == IERC20Metadata(asset).decimals(), "decimals");

        require(keccak256(bytes(proxy.name()))   == keccak256(bytes(name)),   "name");
        require(keccak256(bytes(proxy.symbol())) == keccak256(bytes(symbol)), "symbol");

        require(proxy.getRoleMemberCount(proxy.DEFAULT_ADMIN_ROLE()) == 1, "admin count");
        require(proxy.hasRole(proxy.DEFAULT_ADMIN_ROLE(), admin),          "admin role");

        require(proxy.getRoleMemberCount(proxy.SETTER_ROLE()) == 0, "setter count");
        require(proxy.getRoleMemberCount(proxy.TAKER_ROLE())  == 0, "taker count");

        require(proxy.chi()        == 1e27,            "chi");
        require(proxy.rho()        == block.timestamp, "rho");
        require(proxy.vsr()        == 1e27,            "vsr");
        require(proxy.minVsr()     == 1e27,            "minVsr");
        require(proxy.maxVsr()     == 1e27,            "maxVsr");
        require(proxy.depositCap() == 0,               "depositCap");

        // Log
        console2.log("Deployed SparkVault proxy:");
        console2.log("  proxy: ",     address(proxy));
        console2.log("  impl:  ",     impl);
        console2.log("  asset: ",     asset);
        console2.log("  name:  ",     name);
        console2.log("  symbol:",     symbol);
    }

}
