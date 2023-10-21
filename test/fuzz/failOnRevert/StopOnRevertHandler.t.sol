// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

import {MockV3Aggregator} from "../../mocks/MockV3Aggregator.sol";
import {NESTEngine, AggregatorV3Interface} from "../../../src/NESTEngine.sol";
import {NestStableCoin} from "../../../src/NestStableCoin.sol";
import {MockV3Aggregator} from "../../mocks/MockV3Aggregator.sol";
import {console} from "forge-std/console.sol";

contract StopOnRevertHandler is Test {
    using EnumerableSet for EnumerableSet.AddressSet;

    // Deployed contracts to interact with
    NESTEngine public nestEngine;
    NestStableCoin public nest;
    MockV3Aggregator public ethUsdPriceFeed;
    MockV3Aggregator public btcUsdPriceFeed;
    ERC20Mock public weth;
    ERC20Mock public wbtc;

    // Ghost Variables
    uint96 public constant MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(NESTEngine _nestEngine, NestStableCoin _nest) {
        nestEngine = _nestEngine;
        nest = _nest;

        address[] memory collateralTokens = nestEngine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(nestEngine.getCollateralTokenPriceFeed(address(weth)));
        btcUsdPriceFeed = MockV3Aggregator(nestEngine.getCollateralTokenPriceFeed(address(wbtc)));
    }

    // FUNCTOINS TO INTERACT WITH

    ///////////////
    // NESTEngine //
    ///////////////
    function mintAndDepositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        // must be more than 0
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(nestEngine), amountCollateral);
        nestEngine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateral = nestEngine.getCollateralBalanceOfUser(msg.sender, address(collateral));

        amountCollateral = bound(amountCollateral, 0, maxCollateral);
        if (amountCollateral == 0) {
            return;
        }
        nestEngine.redeemCollateral(address(collateral), amountCollateral);
    }

    function burnNest(uint256 amountNest) public {
        // Must burn more than 0
        amountNest = bound(amountNest, 0, nest.balanceOf(msg.sender));
        if (amountNest == 0) {
            return;
        }
        nestEngine.burnNest(amountNest);
    }

    // Only the NESTEngine can mint NEST!
    // function mintNest(uint256 amountNest) public {
    //     amountNest = bound(amountNest, 0, MAX_DEPOSIT_SIZE);
    //     vm.prank(nest.owner());
    //     nest.mint(msg.sender, amountNest);
    // }

    function liquidate(uint256 collateralSeed, address userToBeLiquidated, uint256 debtToCover) public {
        uint256 minHealthFactor = nestEngine.getMinHealthFactor();
        uint256 userHealthFactor = nestEngine.getHealthFactor(userToBeLiquidated);
        if (userHealthFactor >= minHealthFactor) {
            return;
        }
        debtToCover = bound(debtToCover, 1, uint256(type(uint96).max));
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        nestEngine.liquidate(address(collateral), userToBeLiquidated, debtToCover);
    }

    /////////////////////////////
    // NestStableCoin //
    /////////////////////////////
    function transferNest(uint256 amountNest, address to) public {
        if (to == address(0)) {
            to = address(1);
        }
        amountNest = bound(amountNest, 0, nest.balanceOf(msg.sender));
        vm.prank(msg.sender);
        nest.transfer(to, amountNest);
    }

    /////////////////////////////
    // Aggregator //
    /////////////////////////////
    function updateCollateralPrice(uint96 newPrice, uint256 collateralSeed) public {
        int256 intNewPrice = int256(uint256(newPrice));
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        MockV3Aggregator priceFeed = MockV3Aggregator(nestEngine.getCollateralTokenPriceFeed(address(collateral)));

        priceFeed.updateAnswer(intNewPrice);
    }

    /// Helper Functions
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }
}
