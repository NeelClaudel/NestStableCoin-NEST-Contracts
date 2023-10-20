// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {NestStableCoin} from "../src/NestStableCoin.sol";
import {NESTEngine} from "../src/NESTEngine.sol";

contract DeployNEST is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run() external returns (NestStableCoin, NESTEngine, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig(); // This comes with our mocks!

        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) =
            helperConfig.activeNetworkConfig();
        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        vm.startBroadcast(deployerKey);
        NestStableCoin nest = new NestStableCoin();
        NESTEngine nestEngine = new NESTEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(nest)
        );
        nest.transferOwnership(address(nestEngine));
        vm.stopBroadcast();
        return (nest, nestEngine, helperConfig);
    }
}
