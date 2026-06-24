// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { Test } from "../lib/forge-std/src/Test.sol";

import { Domain, DomainHelpers } from "../lib/private-xchain-helpers/src/testing/Domain.sol";
import { Bridge }                from "../lib/private-xchain-helpers/src/testing/Bridge.sol";
import { ArbitrumBridgeTesting } from "../lib/private-xchain-helpers/src/testing/bridges/ArbitrumBridgeTesting.sol";
import { ArbitrumForwarder }     from "../lib/private-xchain-helpers/src/forwarders/ArbitrumForwarder.sol";

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

interface IInbox {

    function setAllowListEnabled(bool enabled) external;

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

contract RobinhoodCrosschainPayload {

    address public immutable targetPayload;
    address public immutable bridgeReceiver;

    constructor(address _targetPayload, address _bridgeReceiver) {
        targetPayload  = _targetPayload;
        bridgeReceiver = _bridgeReceiver;
    }

    address constant L1_CROSS_DOMAIN_ROBINHOOD_CHAIN = 0x1A07cc4BD17E0118BdB54D70990D2158AbAD7a2D;

    function execute() external {
        ArbitrumForwarder.sendMessageL1toL2(
            L1_CROSS_DOMAIN_ROBINHOOD_CHAIN,
            bridgeReceiver,
            _encodeCrosschainExecutionMessage(),
            1_000_000,
            1 gwei,
            block.basefee + 10 gwei
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
    using ArbitrumBridgeTesting for Bridge;

    // Ethereum mainnet governance contracts
    address constant L1_EXECUTOR    = 0x3300f198988e4C9C63F75dF86De36421f06af8c4;
    address constant L1_PAUSE_PROXY = 0xBE8E3e3618f7474F8cB1d074A26afFef007E98FB;

    // Robinhood chain deployed contracts
    address constant EXECUTOR        = 0x826AEaeee9233fA8Ba199518dd8621A5962b1D02;
    address constant BRIDGE_RECEIVER = 0xc12B1e59c5E337d5Acd2b4f0A9a27d9E5D7387E8;
    address constant SPUSDG_VAULT    = 0xde770c84FE66E063336b31737cFE9790f18c4087;

    // > bc -l <<< 'scale=27; e( l(1.06)/(60 * 60 * 24 * 365) )'
    //   1.000000001847694957439350562
    uint256 constant SIX_PCT_APY = 1.000000001847694957439350562e27;

    // > bc -l <<< 'scale=27; e( l(1.03)/(60 * 60 * 24 * 365) )'
    //   1.000000000936749144827786671
    uint256 constant THREE_PCT_APY = 1.000000000936749144827786671e27;

    uint256 constant ROBINHOOD_BLOCK_NUMBER = 59093;

    Domain mainnet;
    Domain robinhood;
    Bridge bridge;

    function setUp() public {
        mainnet = DomainHelpers.createFork(getChain("mainnet"));

        setChain("robinhood_chain", ChainData({
            name:    "Robinhood Chain",
            chainId: 4663,
            rpcUrl:  vm.envString("RH_RPC_URL")
        }));

        robinhood = DomainHelpers.createFork(getChain("robinhood_chain"), ROBINHOOD_BLOCK_NUMBER);

        mainnet.selectFork();
        vm.deal(L1_EXECUTOR, 0.01 ether);

        bridge = ArbitrumBridgeTesting.createNativeBridge(mainnet, robinhood);
    }

    function test_crosschainE2E_setVsrBounds() public {
        // Step 1: Deploy the payload on Robinhood that will call setVsrBounds when executed

        robinhood.selectFork();

        SetVsrBoundsPayload robinhoodChainPayload = new SetVsrBoundsPayload(
            SPUSDG_VAULT,
            1e27,
            THREE_PCT_APY
        );

        uint256 executorDelay = IExecutor(EXECUTOR).delay();
        uint256 actionsSetId  = IExecutor(EXECUTOR).actionsSetCount();

        assertEq(ISparkVaultLike(SPUSDG_VAULT).minVsr(), 1e27);
        assertEq(ISparkVaultLike(SPUSDG_VAULT).maxVsr(), SIX_PCT_APY);

        // Step 2: Deploy the crosschain payload on mainnet that sends the message through the bridge

        mainnet.selectFork();

        RobinhoodCrosschainPayload crosschainPayload = new RobinhoodCrosschainPayload(
            address(robinhoodChainPayload),
            BRIDGE_RECEIVER
        );

        // Step 3: L1_PAUSE_PROXY triggers L1_EXECUTOR to execute the crosschain payload.

        address inbox = 0x1A07cc4BD17E0118BdB54D70990D2158AbAD7a2D;

        vm.prank(0x552603b4bc1f5E896AF2854548D6380f45f1B4bf);
        IInbox(inbox).setAllowListEnabled(false);

        vm.prank(L1_PAUSE_PROXY);
        IL1Executor(Ethereum.SPARK_PROXY).exec(
            address(crosschainPayload),
            abi.encodeWithSelector(RobinhoodCrosschainPayload.execute.selector)
        );

        // Step 4: Relay the message to Robinhood

        bridge.relayMessagesToDestination(true);

        // Step 5: Advance past the Executor's delay

        skip(executorDelay);

        // Step 6: Execute the queued message.

        IExecutor(EXECUTOR).execute(actionsSetId);

        assertEq(ISparkVaultLike(SPUSDG_VAULT).minVsr(), 1e27);
        assertEq(ISparkVaultLike(SPUSDG_VAULT).maxVsr(), THREE_PCT_APY);
    }

}
