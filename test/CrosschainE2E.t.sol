// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { Test } from "../lib/forge-std/src/Test.sol";

import { Domain, DomainHelpers } from "../lib/xchain-helpers/src/testing/Domain.sol";
import { Bridge }                from "../lib/xchain-helpers/src/testing/Bridge.sol";
import { OptimismBridgeTesting } from "../lib/xchain-helpers/src/testing/bridges/OptimismBridgeTesting.sol";
import { OptimismForwarder }     from "../lib/xchain-helpers/src/forwarders/OptimismForwarder.sol";

import { Ethereum } from "../lib/spark-address-registry/src/Ethereum.sol";

import { IExecutor } from "../lib/spark-gov-relay/src/interfaces/IExecutor.sol";

interface IL1Executor {

    function exec(address target, bytes calldata args) external payable returns (bytes memory out);

}

interface ISparkVaultLike {

    function maxVsr() external view returns (uint256);

    function minVsr() external view returns (uint256);

    function setVsrBounds(uint256 minVsr_, uint256 maxVsr_) external;

}

contract SetVsrBoundsPayload {

    address public immutable vault;
    uint256 public immutable newMinVsr;
    uint256 public immutable newMaxVsr;

    constructor(address _vault, uint256 _newMinVsr, uint256 _newMaxVsr) {
        vault     = _vault;
        newMinVsr = _newMinVsr;
        newMaxVsr = _newMaxVsr;
    }

    function execute() external {
        ISparkVaultLike(vault).setVsrBounds(newMinVsr, newMaxVsr);
    }

}

contract XLayerCrosschainPayload {

    address public immutable targetPayload;
    address public immutable bridgeReceiver;

    constructor(address _targetPayload, address _bridgeReceiver) {
        targetPayload  = _targetPayload;
        bridgeReceiver = _bridgeReceiver;
    }

    function execute() external {
        OptimismForwarder.sendMessageL1toL2(
            OptimismForwarder.L1_CROSS_DOMAIN_XLAYER,
            bridgeReceiver,
            _encodeCrosschainExecutionMessage(),
            1_000_000
        );
    }

    function _encodeCrosschainExecutionMessage() internal view returns (bytes memory) {
        address[] memory targets = new address[](1);
        targets[0] = targetPayload;

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        string[] memory signatures = new string[](1);
        signatures[0] = 'execute()';

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = '';

        bool[] memory withDelegatecalls = new bool[](1);
        withDelegatecalls[0] = true;

        return abi.encodeWithSelector(
            IExecutor.queue.selector,
            targets,
            values,
            signatures,
            calldatas,
            withDelegatecalls
        );
    }

}

contract CrosschainE2ETest is Test {

    using DomainHelpers         for Domain;
    using OptimismBridgeTesting for Bridge;

    // Ethereum mainnet governance contracts
    address constant L1_EXECUTOR    = 0x3300f198988e4C9C63F75dF86De36421f06af8c4;
    address constant L1_PAUSE_PROXY = 0xBE8E3e3618f7474F8cB1d074A26afFef007E98FB;

    // XLayer deployed contracts
    address constant EXECUTOR        = 0xCF5af6F53ceC74B791cb4182aC778ca9CD323510;
    address constant BRIDGE_RECEIVER = 0x4bd50B9c00Ae19e8B59723F27645C7A5cCe7a4A0;
    address constant SPUSDT_VAULT    = 0xc358c90D32375721Cb3924320Fdc2F8B694347Ca;

    // > bc -l <<< 'scale=27; e( l(1.06)/(60 * 60 * 24 * 365) )'
    //   1.000000001847694957439350562
    uint256 constant SIX_PCT_APY = 1.000000001847694957439350562e27;

    // > bc -l <<< 'scale=27; e( l(1.03)/(60 * 60 * 24 * 365) )'
    //   1.000000000936749144827786671
    uint256 constant THREE_PCT_APY = 1.000000000936749144827786671e27;

    Domain mainnet;
    Domain xlayer;
    Bridge bridge;

    function setUp() public {
        mainnet = DomainHelpers.createFork(getChain("mainnet"));

        setChain("xlayer", ChainData({
            name:    "X Layer",
            chainId: 196,
            rpcUrl:  "https://rpc.xlayer.tech"
        }));

        xlayer = DomainHelpers.createFork(getChain("xlayer"));

        mainnet.selectFork();

        bridge = OptimismBridgeTesting.createNativeBridge(mainnet, xlayer);
    }

    function test_crosschainE2E_setVsrBounds() public {
        // Step 1: Deploy the payload on XLayer that will call setVsrBounds when executed

        xlayer.selectFork();

        SetVsrBoundsPayload xlayerPayload = new SetVsrBoundsPayload(
            SPUSDT_VAULT,
            1e27,
            THREE_PCT_APY
        );

        // Step 2: Deploy the crosschain payload on mainnet that sends the message through the bridge

        mainnet.selectFork();

        XLayerCrosschainPayload crosschainPayload = new XLayerCrosschainPayload(
            address(xlayerPayload),
            BRIDGE_RECEIVER
        );

        // Step 3: L1_PAUSE_PROXY triggers L1_EXECUTOR to execute the crosschain payload.

        vm.prank(L1_PAUSE_PROXY);
        IL1Executor(Ethereum.SPARK_PROXY).exec(
            address(crosschainPayload),
            abi.encodeWithSelector(XLayerCrosschainPayload.execute.selector)
        );

        // Step 4: Relay the message to XLayer

        bridge.relayMessagesToDestination(true);

        // Step 5: Advance past the Executor's delay

        skip(0);  // Executor delay is 0

        // Step 6: Execute the queued message.

        assertEq(ISparkVaultLike(SPUSDT_VAULT).minVsr(), 1e27);
        assertEq(ISparkVaultLike(SPUSDT_VAULT).maxVsr(), SIX_PCT_APY);

        IExecutor(EXECUTOR).execute(0);  // Execute the first action in the set.

        assertEq(ISparkVaultLike(SPUSDT_VAULT).minVsr(), 1e27);
        assertEq(ISparkVaultLike(SPUSDT_VAULT).maxVsr(), THREE_PCT_APY);
    }

}
