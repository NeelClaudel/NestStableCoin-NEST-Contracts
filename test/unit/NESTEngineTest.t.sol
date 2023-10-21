// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {DeployNEST} from "../../script/DeployNEST.s.sol";
import {NESTEngine} from "../../src/NESTEngine.sol";
import {NestStableCoin} from "../../src/NestStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockMoreDebtNEST} from "../mocks/MockMoreDebtNEST.sol";
import {MockFailedMintNEST} from "../mocks/MockFailedMintNEST.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {Test, console} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

contract NESTEngineTest is StdCheats, Test {
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount); // if redeemFrom != redeemedTo, then it was liquidated

    NESTEngine public neste;
    NestStableCoin public nest;
    HelperConfig public helperConfig;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;

    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;
    address public user = address(1);

    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    function setUp() external {
        DeployNEST deployer = new DeployNEST();
        (nest, neste, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();
        if (block.chainid == 31337) {
            vm.deal(user, STARTING_USER_BALANCE);
        }
        // Should we put our integration tests here?
        // else {
        //     user = vm.addr(deployerKey);
        //     ERC20Mock mockErc = new ERC20Mock("MOCK", "MOCK", user, 100e18);
        //     MockV3Aggregator aggregatorMock = new MockV3Aggregator(
        //         helperConfig.DECIMALS(),
        //         helperConfig.ETH_USD_PRICE()
        //     );
        //     vm.etch(weth, address(mockErc).code);
        //     vm.etch(wbtc, address(mockErc).code);
        //     vm.etch(ethUsdPriceFeed, address(aggregatorMock).code);
        //     vm.etch(btcUsdPriceFeed, address(aggregatorMock).code);
        // }
        ERC20Mock(weth).mint(user, STARTING_USER_BALANCE);
        ERC20Mock(wbtc).mint(user, STARTING_USER_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    address[] public tokenAddresses;
    address[] public feedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        feedAddresses.push(ethUsdPriceFeed);
        feedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(NESTEngine.NESTEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch.selector);
        new NESTEngine(tokenAddresses, feedAddresses, address(nest));
    }

    //////////////////
    // Price Tests //
    //////////////////

    function testGetTokenAmountFromUsd() public {
        // If we want $100 of WETH @ $2000/WETH, that would be 0.05 WETH
        uint256 expectedWeth = 0.05 ether;
        uint256 amountWeth = neste.getTokenAmountFromUsd(weth, 100 ether);
        assertEq(amountWeth, expectedWeth);
    }

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        // 15e18 ETH * $2000/ETH = $30,000e18
        uint256 expectedUsd = 30000e18;
        uint256 usdValue = neste.getUsdValue(weth, ethAmount);
        assertEq(usdValue, expectedUsd);
    }

    ///////////////////////////////////////
    // depositCollateral Tests //
    ///////////////////////////////////////

    // this test needs it's own setup
    function testRevertsIfTransferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockNest = new MockFailedTransferFrom();
        tokenAddresses = [address(mockNest)];
        feedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        NESTEngine mockNeste = new NESTEngine(
            tokenAddresses,
            feedAddresses,
            address(mockNest)
        );
        mockNest.mint(user, amountCollateral);

        vm.prank(owner);
        mockNest.transferOwnership(address(mockNeste));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(address(mockNest)).approve(address(mockNeste), amountCollateral);
        // Act / Assert
        vm.expectRevert(NESTEngine.NESTEngine__TransferFailed.selector);
        mockNeste.depositCollateral(address(mockNest), amountCollateral);
        vm.stopPrank();
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(neste), amountCollateral);

        vm.expectRevert(NESTEngine.NESTEngine__NeedsMoreThanZero.selector);
        neste.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randToken = new ERC20Mock("RAN", "RAN", user, 100e18);
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(NESTEngine.NESTEngine__TokenNotAllowed.selector, address(randToken)));
        neste.depositCollateral(address(randToken), amountCollateral);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(neste), amountCollateral);
        neste.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = nest.balanceOf(user);
        assertEq(userBalance, 0);
    }

    function testCanDepositedCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalNestMinted, uint256 collateralValueInUsd) = neste.getAccountInformation(user);
        uint256 expectedDepositedAmount = neste.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalNestMinted, 0);
        assertEq(expectedDepositedAmount, amountCollateral);
    }

    ///////////////////////////////////////
    // depositCollateralAndMintNest Tests //
    ///////////////////////////////////////

    function testRevertsIfMintedNestBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (amountCollateral * (uint256(price) * neste.getAdditionalFeedPrecision())) / neste.getPrecision();
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(neste), amountCollateral);

        uint256 expectedHealthFactor =
            neste.calculateHealthFactor(amountToMint, neste.getUsdValue(weth, amountCollateral));
        vm.expectRevert(abi.encodeWithSelector(NESTEngine.NESTEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        neste.depositCollateralAndMintNest(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedNest() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(neste), amountCollateral);
        neste.depositCollateralAndMintNest(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedNest {
        uint256 userBalance = nest.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // mintNest Tests //
    ///////////////////////////////////
    // This test needs it's own custom setup
    function testRevertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintNEST mockNest = new MockFailedMintNEST();
        tokenAddresses = [weth];
        feedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        NESTEngine mockNeste = new NESTEngine(
            tokenAddresses,
            feedAddresses,
            address(mockNest)
        );
        mockNest.transferOwnership(address(mockNeste));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockNeste), amountCollateral);

        vm.expectRevert(NESTEngine.NESTEngine__MintFailed.selector);
        mockNeste.depositCollateralAndMintNest(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(neste), amountCollateral);
        neste.depositCollateralAndMintNest(weth, amountCollateral, amountToMint);
        vm.expectRevert(NESTEngine.NESTEngine__NeedsMoreThanZero.selector);
        neste.mintNest(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public {
        // 0xe580cc6100000000000000000000000000000000000000000000000006f05b59d3b20000
        // 0xe580cc6100000000000000000000000000000000000000000000003635c9adc5dea00000
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (amountCollateral * (uint256(price) * neste.getAdditionalFeedPrecision())) / neste.getPrecision();

        vm.startPrank(user);
        ERC20Mock(weth).approve(address(neste), amountCollateral);
        neste.depositCollateral(weth, amountCollateral);

        uint256 expectedHealthFactor =
            neste.calculateHealthFactor(amountToMint, neste.getUsdValue(weth, amountCollateral));
        vm.expectRevert(abi.encodeWithSelector(NESTEngine.NESTEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        neste.mintNest(amountToMint);
        vm.stopPrank();
    }

    function testCanMintNest() public depositedCollateral {
        vm.prank(user);
        neste.mintNest(amountToMint);

        uint256 userBalance = nest.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // burnNest Tests //
    ///////////////////////////////////

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(neste), amountCollateral);
        neste.depositCollateralAndMintNest(weth, amountCollateral, amountToMint);
        vm.expectRevert(NESTEngine.NESTEngine__NeedsMoreThanZero.selector);
        neste.burnNest(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(user);
        vm.expectRevert();
        neste.burnNest(1);
    }

    function testCanBurnNest() public depositedCollateralAndMintedNest {
        vm.startPrank(user);
        nest.approve(address(neste), amountToMint);
        neste.burnNest(amountToMint);
        vm.stopPrank();

        uint256 userBalance = nest.balanceOf(user);
        assertEq(userBalance, 0);
    }

    ///////////////////////////////////
    // redeemCollateral Tests //
    //////////////////////////////////

    // this test needs it's own setup
    function testRevertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockNest = new MockFailedTransfer();
        tokenAddresses = [address(mockNest)];
        feedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        NESTEngine mockNeste = new NESTEngine(
            tokenAddresses,
            feedAddresses,
            address(mockNest)
        );
        mockNest.mint(user, amountCollateral);

        vm.prank(owner);
        mockNest.transferOwnership(address(mockNeste));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(address(mockNest)).approve(address(mockNeste), amountCollateral);
        // Act / Assert
        mockNeste.depositCollateral(address(mockNest), amountCollateral);
        vm.expectRevert(NESTEngine.NESTEngine__TransferFailed.selector);
        mockNeste.redeemCollateral(address(mockNest), amountCollateral);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(neste), amountCollateral);
        neste.depositCollateralAndMintNest(weth, amountCollateral, amountToMint);
        vm.expectRevert(NESTEngine.NESTEngine__NeedsMoreThanZero.selector);
        neste.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(user);
        neste.redeemCollateral(weth, amountCollateral);
        uint256 userBalance = ERC20Mock(weth).balanceOf(user);
        assertEq(userBalance, amountCollateral);
        vm.stopPrank();
    }

    function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        vm.expectEmit(true, true, true, true, address(neste));
        emit CollateralRedeemed(user, user, weth, amountCollateral);
        vm.startPrank(user);
        neste.redeemCollateral(weth, amountCollateral);
        vm.stopPrank();
    }
    ///////////////////////////////////
    // redeemCollateralForNest Tests //
    //////////////////////////////////

    function testMustRedeemMoreThanZero() public depositedCollateralAndMintedNest {
        vm.startPrank(user);
        nest.approve(address(neste), amountToMint);
        vm.expectRevert(NESTEngine.NESTEngine__NeedsMoreThanZero.selector);
        neste.redeemCollateralForNest(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(neste), amountCollateral);
        neste.depositCollateralAndMintNest(weth, amountCollateral, amountToMint);
        nest.approve(address(neste), amountToMint);
        neste.redeemCollateralForNest(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        uint256 userBalance = nest.balanceOf(user);
        assertEq(userBalance, 0);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedNest {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = neste.getHealthFactor(user);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedNest {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Rememeber, we need $150 at all times if we have $100 of debt

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = neste.getHealthFactor(user);
        // $180 collateral / 200 debt = 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    ///////////////////////
    // Liquidation Tests //
    ///////////////////////

    // This test needs it's own setup
    function testMustImproveHealthFactorOnLiquidation() public {
        // Arrange - Setup
        MockMoreDebtNEST mockNest = new MockMoreDebtNEST(ethUsdPriceFeed);
        tokenAddresses = [weth];
        feedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        NESTEngine mockNeste = new NESTEngine(
            tokenAddresses,
            feedAddresses,
            address(mockNest)
        );
        mockNest.transferOwnership(address(mockNeste));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockNeste), amountCollateral);
        mockNeste.depositCollateralAndMintNest(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        // Arrange - Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(mockNeste), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockNeste.depositCollateralAndMintNest(weth, collateralToCover, amountToMint);
        mockNest.approve(address(mockNeste), debtToCover);
        // Act
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // Act/Assert
        vm.expectRevert(NESTEngine.NESTEngine__HealthFactorNotImproved.selector);
        mockNeste.liquidate(weth, user, debtToCover);
        vm.stopPrank();
    }

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedNest {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(neste), collateralToCover);
        neste.depositCollateralAndMintNest(weth, collateralToCover, amountToMint);
        nest.approve(address(neste), amountToMint);

        vm.expectRevert(NESTEngine.NESTEngine__HealthFactorOk.selector);
        neste.liquidate(weth, user, amountToMint);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(neste), amountCollateral);
        neste.depositCollateralAndMintNest(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = neste.getHealthFactor(user);

        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(neste), collateralToCover);
        neste.depositCollateralAndMintNest(weth, collateralToCover, amountToMint);
        nest.approve(address(neste), amountToMint);
        neste.liquidate(weth, user, amountToMint); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = neste.getTokenAmountFromUsd(weth, amountToMint)
            + (neste.getTokenAmountFromUsd(weth, amountToMint) / neste.getLiquidationBonus());
        uint256 hardCodedExpected = 6111111111111111110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = neste.getTokenAmountFromUsd(weth, amountToMint)
            + (neste.getTokenAmountFromUsd(weth, amountToMint) / neste.getLiquidationBonus());

        uint256 usdAmountLiquidated = neste.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = neste.getUsdValue(weth, amountCollateral) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = neste.getAccountInformation(user);
        uint256 hardCodedExpectedValue = 70000000000000000020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorNestMinted,) = neste.getAccountInformation(liquidator);
        assertEq(liquidatorNestMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userNestMinted,) = neste.getAccountInformation(user);
        assertEq(userNestMinted, 0);
    }

    ///////////////////////////////////
    // View & Pure Function Tests //
    //////////////////////////////////
    function testGetCollateralTokenPriceFeed() public {
        address priceFeed = neste.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public {
        address[] memory collateralTokens = neste.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public {
        uint256 minHealthFactor = neste.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public {
        uint256 liquidationThreshold = neste.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = neste.getAccountInformation(user);
        uint256 expectedCollateralValue = neste.getUsdValue(weth, amountCollateral);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(neste), amountCollateral);
        neste.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        uint256 collateralBalance = neste.getCollateralBalanceOfUser(user, weth);
        assertEq(collateralBalance, amountCollateral);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(neste), amountCollateral);
        neste.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        uint256 collateralValue = neste.getAccountCollateralValue(user);
        uint256 expectedCollateralValue = neste.getUsdValue(weth, amountCollateral);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetNest() public {
        address nestAddress = neste.getNest();
        assertEq(nestAddress, address(nest));
    }

    function testLiquidationPrecision() public {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = neste.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }

    // How do we adjust our invariant tests for this?
    // function testInvariantBreaks() public depositedCollateralAndMintedNest {
    //     MockV3Aggregator(ethUsdPriceFeed).updateAnswer(0);

    //     uint256 totalSupply = nest.totalSupply();
    //     uint256 wethDeposted = ERC20Mock(weth).balanceOf(address(neste));
    //     uint256 wbtcDeposited = ERC20Mock(wbtc).balanceOf(address(neste));

    //     uint256 wethValue = neste.getUsdValue(weth, wethDeposted);
    //     uint256 wbtcValue = neste.getUsdValue(wbtc, wbtcDeposited);

    //     console.log("wethValue: %s", wethValue);
    //     console.log("wbtcValue: %s", wbtcValue);
    //     console.log("totalSupply: %s", totalSupply);

    //     assert(wethValue + wbtcValue >= totalSupply);
    // }
}
