// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {WorkDistribution} from "../src/WorkDistribution.sol";

contract WorkDistributionScript is Script {
    WorkDistribution public workDistribution;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        workDistribution = new WorkDistribution();

        vm.stopBroadcast();
    }
}
