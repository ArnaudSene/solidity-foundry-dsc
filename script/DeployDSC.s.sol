// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../src/DSCEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";


contract DeployDSC is Script {
    address[] public priceFeedAddresses;
    address[] public tokenAddresses;
    
    function run() external returns (DecentralizedStableCoin, DSCEngine, HelperConfig) {
        HelperConfig config = new HelperConfig();
        (
            address wETHPriceFeedInUSD, 
            address wBTCPriceFeedInUSD,
            address wETC, 
            address wBTC, 
            uint256 deployerKey
        ) = config.activeNetworkConfig();

        priceFeedAddresses = [wETHPriceFeedInUSD, wBTCPriceFeedInUSD];
        tokenAddresses = [wETC, wBTC];

        vm.startBroadcast(deployerKey);
        DecentralizedStableCoin dsc = new DecentralizedStableCoin();

        DSCEngine dscEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
        dsc.transferOwnership(address(dscEngine));

        vm.stopBroadcast();

        return (dsc, dscEngine, config);
    }
}