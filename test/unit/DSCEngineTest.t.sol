// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/Script.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {ERC20Mock} from "@openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {ERC20} from "@openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {MockV3Aggregator} from "../mock/MockV3Aggregator.sol";


contract DSCEngineTest is Test {
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;
    DeployDSC deployerDSC;
    HelperConfig config;

    address wETHPriceFeedInUSD;
    address wBTCPriceFeedInUSD;
    address wETH;
    address wBTC;
    address public USER = makeAddr("user");
    address public USER2 = makeAddr("user2");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant STARTING_ERC20_BALANCE = 10e18;
    uint256 public constant AMOUNT_COLLATERAL = 10e18;
    uint256 public constant AMOUNT_COLLATERAL_ZERO = 0;
    uint256 public constant AMOUNT_DSC_IN_USD_TO_MINT = 1000e18;

    function setUp() public {
        deployerDSC = new DeployDSC();
        (dsc, dscEngine, config) = deployerDSC.run();
        (wETHPriceFeedInUSD, wBTCPriceFeedInUSD, wETH, wBTC,) = config.activeNetworkConfig();
        ERC20Mock(wETH).mint(USER, STARTING_ERC20_BALANCE);
    }

    modifier depositCollateral() {
        vm.startPrank(USER);
        ERC20Mock(wETH).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(wETH, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositCollateralAndMint() {
        vm.startPrank(USER);
        ERC20Mock(wETH).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDSC(wETH, AMOUNT_COLLATERAL, AMOUNT_DSC_IN_USD_TO_MINT);
        vm.stopPrank();
        _;
    }

    /**
     * @dev Test Constructor
     */
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertIfTokenLengthDoesntMatchPriceFeed() public {
        tokenAddresses.push(wETH);
        priceFeedAddresses.push(wETHPriceFeedInUSD);
        priceFeedAddresses.push(wBTCPriceFeedInUSD);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /**
     * @dev Getters
     * "getPriceFeed(address)": "5b6cca80",
     * "getCollateralTokens()": "b58eb63f",
     * "getTokenValueInUSD(address,uint256)": "864bc419",
     * "getTokenAmountFromUSD(address,uint256)": "638ca89c",
     */

    function testGetPriceFeedAddresses() public {
        assertEq(dscEngine.getPriceFeed(wETH), wETHPriceFeedInUSD);
        assertEq(dscEngine.getPriceFeed(wBTC), wBTCPriceFeedInUSD);
    }

    function testGetCollateralToken() public {
        address[] memory tokens = dscEngine.getCollateralTokens();
        assertEq(tokens[0], wETH);
        assertEq(tokens[1], wBTC);
    }

    function testGetTokenValueInUSD() public {
        // 1 ETH = $2000 (with Aggregtorv3Interface)
        // 15 ETH = 2000 * 15 = 30,000
        uint256 amountETH = 15 ether;
        uint256 expectedAmountETHInUSD = 30_000 ether;
        uint256 amountETHInUSD = dscEngine.getTokenValueInUSD(wETH, amountETH);
        assertEq(amountETHInUSD, expectedAmountETHInUSD);
    }

    function testGetTokenAmountFromUSD() public {
        // With 1 ETH = $2000 (2000e8)
        uint256 amountETHInUSD = 100 ether; // 100 x 1 x 10^18
        uint256 expectedAmountETH = 0.05 ether;
        uint256 amountETH = dscEngine.getTokenAmountFromUSD(wETH, amountETHInUSD);
        assertEq(amountETH, expectedAmountETH);
    }

    /**
     * @dev Test depositCollateral
     */

    function testRevertsIfCollateralIsZero() public {
        // User has a balance of 10 ether
        vm.startPrank(USER);
        ERC20Mock(wETH).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(wETH, AMOUNT_COLLATERAL_ZERO);
        vm.stopPrank();
    }

    function testRevertWithUnappropriateCollateral() public {
        ERC20Mock badToken = new ERC20Mock();
        badToken.mint(USER, AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__NotAllowedToken.selector,
                badToken
            )
        );
        dscEngine.depositCollateral(address(badToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertWithInsufficientAllowance() public {
        vm.startPrank(USER2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(dscEngine), 0, AMOUNT_COLLATERAL
            )
        );
        dscEngine.depositCollateral(address(wETH), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    event CollateralDeposited(
        address indexed _sender, address indexed tokenCollateralAddress, uint256 indexed amountCollateral
    );

    function testEmitEventCollateralDeposited() public {
        vm.startPrank(USER);
        ERC20Mock(wETH).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectEmit(true, true, true, true);
        emit CollateralDeposited(address(USER), address(wETH), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(wETH, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testDepositCollateral() public {
        uint256 arg2 = 2;

        vm.startPrank(USER);
        ERC20Mock(wETH).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectEmit(true, true, true, true);
        emit CollateralDeposited(address(USER), address(wETH), arg2);
        dscEngine.depositCollateral(wETH, arg2);
        vm.stopPrank();
    }

    /**
     * Getters that needs depositCollateral state
     *
     * "getAccountCollateralValueInUSD(address)": "6615e89c",
     * "getCollateralBalanceOfUser(address,address)": "31e92b83",
     */

    function testGetAccountCollateralValueInUSD() public depositCollateral {
        // 1 ETH = 2000$
        // 10 ether = 10 * 1e18
        // 2000 * 10 * 1e18
        uint256 expectedValue = 20_000 ether;
        uint256 totalCollateralValueInUSD = dscEngine.getAccountCollateralValueInUSD(USER);
        console.log("result: ", totalCollateralValueInUSD);
        assertEq(totalCollateralValueInUSD, expectedValue);
    }

    function testGetCollateralDeposited() public depositCollateral {
        vm.startPrank(USER);
        uint256 collateralDeposited = dscEngine.getCollateralBalanceOfUser(address(USER), wETH);
        assertEq(collateralDeposited, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    /**
     * @notice Section: Test mintDSC
     */

    function testRevertMintDSCIfAmountToMintIsZero() public {
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.mintDSC(0);
    }

    function testRevertMintDSCIfHealthFactorIsBroken() public {
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 0));
        dscEngine.mintDSC(AMOUNT_DSC_IN_USD_TO_MINT);
    }

    function testMintAndGetDSCMinted() public depositCollateral {
        vm.startPrank(USER);
        uint256 maxDSCAllowedToMint = dscEngine.getMaxDSCAllowed(USER);
        dscEngine.mintDSC(maxDSCAllowedToMint);
        uint256 dscMinted = dscEngine.getDSCMinted(USER);
        assertEq(dscMinted, maxDSCAllowedToMint);
        vm.stopPrank();
    }

    /**
     * Getters that needs depositCollateral and Mint state
     *
     * "getDSCMinted(address)": "0b57837d",
     * "getAccountInformation(address)": "7be564fc",
     * "getMaxDSCAllowed(address)": "fab4a0d9",
     * "getUserHealthFactor(address)": "71cbfc98",
     * "getCalculatedHealthFactor(uint256,uint256)": "bd6639a5",
     */

    function testGetDSCMintedIsZeroByDefault() public {
        uint256 dscMinted = dscEngine.getDSCMinted(USER);
        assertEq(dscMinted, 0);
    }

    function testGetAccountInformationIsZeroByDefault() public {
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = dscEngine.getAccountInformation(USER);
        assertEq(totalDSCMinted, 0);
        assertEq(collateralValueInUSD, 0);
    }

    function testGetAccountInformationHasOnlyCollateral() public depositCollateral {
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = dscEngine.getAccountInformation(USER);
        assertEq(totalDSCMinted, 0);
        assertEq(collateralValueInUSD, 20_000 ether);
    }

    function testGetAccountInformationHasCollateralAndDSC() public depositCollateralAndMint {
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = dscEngine.getAccountInformation(USER);
        assertEq(totalDSCMinted, 1_000 ether);
        assertEq(collateralValueInUSD, 20_000 ether);
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositCollateral {
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = dscEngine.getAccountInformation(USER);
        uint256 expectedTotalDSCMinted = 0;
        uint256 expectedTokenAmountInUSD = dscEngine.getTokenAmountFromUSD(wETH, collateralValueInUSD);
        assertEq(totalDSCMinted, expectedTotalDSCMinted);
        assertEq(AMOUNT_COLLATERAL, expectedTokenAmountInUSD);
    }

    function testGetMaxDSCAllowedToMint() public depositCollateral {
        uint256 expectedDSCValue = 10_000_000_000_000_000_000_000;
        uint256 maxDSCAllowedToMint = dscEngine.getMaxDSCAllowed(USER);
        assertEq(maxDSCAllowedToMint, expectedDSCValue);
    }

    function testGetCalculatedHealthFactorIsUint256MaxWithDSCIsZero() public depositCollateral {
        uint256 expectedHealFactor = type(uint256).max;
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = dscEngine.getAccountInformation(USER);
        
        uint256 healthFactor = dscEngine.getCalculatedHealthFactor(totalDSCMinted, collateralValueInUSD);
        assertEq(healthFactor, expectedHealFactor);
    }

    function testGetCalculatedHealthFactorWithDSCMinted() public depositCollateralAndMint {
        uint256 expectedHealFactor = 10e18;
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = dscEngine.getAccountInformation(USER);
        uint256 healthFactor = dscEngine.getCalculatedHealthFactor(totalDSCMinted, collateralValueInUSD);
        assertEq(healthFactor, expectedHealFactor);
    }

    function testGetUserHealthFactorIsUint256MaxWithDSCIsZero() public depositCollateral {
        uint256 expectedHealFactor = type(uint256).max;
        uint256 healthFactor = dscEngine.getUserHealthFactor(USER);
        assertEq(healthFactor, expectedHealFactor);
    }

    function testGetUserHealthFactorWithDSCMinted() public depositCollateralAndMint() {
        uint256 expectedHealFactor = 10e18;
        uint256 healthFactor = dscEngine.getUserHealthFactor(USER);
        assertEq(healthFactor, expectedHealFactor);
    }
  

    /**
     * Deposit and mint DSC
     */
    function testRevertDepositAndMintIfHealthFactorIsBroken() public {
        // collateral in USD
        // If 1 ETH = 2000$
        //      2000 => uint256 => 2000000000000000000000
        // If Thresolhd = 50
        // Then Max DSC allowed to be mint is half of collateral in USD
        //      => 1000000000000000000000
        // Health Factor is
        //      Max DSC allow / amount of DSC to mint
        //      Must be >= 1
        //
        uint256 amountETH = 1;
        // 1 ETH
        uint256 collateralValueInUSD = dscEngine.getTokenValueInUSD(wETH, amountETH); // ex: 2000 with 1 ETH
        uint256 adjustedCollateralValueInUSD = collateralValueInUSD * 1e18; // 2000 => 2000000000000000000000
        // Amount to mint
        uint256 amountDSCInUSD = ((adjustedCollateralValueInUSD * 50) / 100) + 1;
        uint256 calculatedHealthFactor = dscEngine.getCalculatedHealthFactor(amountDSCInUSD, collateralValueInUSD);

        vm.startPrank(USER);
        ERC20Mock(wETH).approve(address(dscEngine), amountETH);
        vm.expectRevert(
            abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, calculatedHealthFactor)
        );
        dscEngine.depositCollateralAndMintDSC(wETH, amountETH, amountDSCInUSD);
        vm.stopPrank;
    }

    function testDepositCollateralAndMintDSC() public {
        uint256 amountETH = 1;
        uint256 _collateralValueInUSD = dscEngine.getTokenValueInUSD(wETH, amountETH); // ex: 2000 with 1 ETH

        // Amount to mint
        uint256 amountDSCInUSD = ((_collateralValueInUSD * 50) / 100);
        uint256 expectedCollateralValueInUSD = dscEngine.getTokenValueInUSD(wETH, amountETH);

        vm.startPrank(USER);
        ERC20Mock(wETH).approve(address(dscEngine), amountETH);

        (uint256 beforeTotalDSCMinted, uint256 beforeCollateralValueInUSD) = dscEngine.getAccountInformation(USER);
        dscEngine.depositCollateralAndMintDSC(wETH, amountETH, amountDSCInUSD);
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = dscEngine.getAccountInformation(USER);

        assertEq(beforeTotalDSCMinted, 0);
        assertEq(beforeCollateralValueInUSD, 0);
        assertEq(totalDSCMinted, amountDSCInUSD);
        assertEq(collateralValueInUSD, expectedCollateralValueInUSD);
        vm.stopPrank;
    }

    /**
     * Test redeem collateral
     */

    function testRevertRedeemCollateralIfAmountCollateralIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateral(wETH, 0);
        vm.stopPrank();
    }

    event CollateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount
    );

    function testRevertRedeemCollateralIfCollateralIsLargerThanUserHas() public depositCollateralAndMint {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__AmountCollateralIsTooHigh.selector);
        dscEngine.redeemCollateral(wETH, AMOUNT_COLLATERAL + 1);
        vm.stopPrank();
    }

    function testRedeemCollateralWithoutDSCMinted() public depositCollateral {
        vm.startPrank(USER);
        dscEngine.redeemCollateral(wETH, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRedeemCollateralWithDSCMinted() public depositCollateralAndMint {
        uint256 amountToRedeem = AMOUNT_COLLATERAL / 2;

        vm.startPrank(USER);
        uint256 beforeCollateral = dscEngine.getCollateralBalanceOfUser(USER, wETH);
        dscEngine.redeemCollateral(wETH, amountToRedeem);
        uint256 afterCollateral = dscEngine.getCollateralBalanceOfUser(USER, wETH);

        assertEq(beforeCollateral, AMOUNT_COLLATERAL);
        assertEq(afterCollateral, AMOUNT_COLLATERAL / 2);
        vm.stopPrank();
    }

    function testRevertRedeemCollateralWithHealthFactorIsBroken() public depositCollateralAndMint {
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 0));
        dscEngine.redeemCollateral(wETH, AMOUNT_COLLATERAL);

        vm.stopPrank();
    }

    
    /**
     * @dev test burnDSC
     */

    function testRevertBurnDSCWithAmountIsZero() public depositCollateralAndMint {
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.burnDSC(0);
    }

    function testRevertBurnDSCWithAmountDSCToBurnTooHigh() public {
        vm.expectRevert(DSCEngine.DSCEngine__AmountDSCToBurnIsTooHigh.selector);
        dscEngine.burnDSC(1);
    }

    function testBurnDSC() public depositCollateralAndMint {        
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), AMOUNT_DSC_IN_USD_TO_MINT);
        dscEngine.burnDSC(AMOUNT_DSC_IN_USD_TO_MINT);
        vm.stopPrank();

        (uint256 afterTotalDSCMinted,) = dscEngine.getAccountInformation(USER);
        uint256 userBalance = dsc.balanceOf(USER);

        assertEq(afterTotalDSCMinted, 0);
        assertEq(userBalance, 0);
    }


    /**
     * @dev test redeemCollateralForDSC
     * 
     */
    function testRevertRedeemCollateralForDSCWithCollateralIsZero() public depositCollateralAndMint {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), AMOUNT_DSC_IN_USD_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateralForDSC(wETH, 0, 1 ether);
        vm.stopPrank();
    }   

    function testRevertRedeemCollateralForDSCWithDSCToBurnIsZero() public depositCollateralAndMint {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), AMOUNT_DSC_IN_USD_TO_MINT);
        
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateralForDSC(wETH, AMOUNT_COLLATERAL, 0);
        vm.stopPrank();
    }

    function testRevertRedeemCollateralForDSCWithHealthFactorIsBroken() public depositCollateralAndMint {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), AMOUNT_DSC_IN_USD_TO_MINT);
        vm.expectRevert(
            abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 0)
        );
        dscEngine.redeemCollateralForDSC(wETH, AMOUNT_COLLATERAL, 10);
        vm.stopPrank();
    }

    function testRedeemCollateralAllCollateral() public depositCollateralAndMint {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), AMOUNT_DSC_IN_USD_TO_MINT);
        dscEngine.redeemCollateralForDSC(wETH, AMOUNT_COLLATERAL, AMOUNT_DSC_IN_USD_TO_MINT);

        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = dscEngine.getAccountInformation(USER);
        uint256 userBalance = dsc.balanceOf(USER);

        assertEq(totalDSCMinted, 0);
        assertEq(collateralValueInUSD, 0);
        assertEq(userBalance, 0);
        vm.stopPrank();
    }

    function testRedeemCollateralPartOfCollateral() public depositCollateralAndMint {
        uint256 expectedCollateralValueInUSD = dscEngine.getTokenValueInUSD(wETH, AMOUNT_COLLATERAL / 2);
        uint256 expectedTotalDSCMinted = AMOUNT_DSC_IN_USD_TO_MINT / 2;

        vm.startPrank(USER);
        dsc.approve(address(dscEngine), AMOUNT_DSC_IN_USD_TO_MINT);
        dscEngine.redeemCollateralForDSC(wETH, AMOUNT_COLLATERAL / 2, AMOUNT_DSC_IN_USD_TO_MINT / 2);
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = dscEngine.getAccountInformation(USER);
        uint256 userBalance = dsc.balanceOf(USER);

        assertEq(totalDSCMinted, expectedTotalDSCMinted);
        assertEq(collateralValueInUSD, expectedCollateralValueInUSD);
        assertEq(userBalance, expectedTotalDSCMinted);
        vm.stopPrank();
    }

    /**
     * @dev test liquidate
     */

    function testRevertLiquidateWithDebtToCoverIsZero() public depositCollateralAndMint {
        dsc.approve(address(dscEngine), AMOUNT_DSC_IN_USD_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.liquidate(wETH, USER, 0);
    } 

    function testRevertLiquidateWithHealthFactorNotBroken() public depositCollateralAndMint {
        vm.startPrank(LIQUIDATOR);
        dsc.approve(address(dscEngine), AMOUNT_DSC_IN_USD_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorIsOK.selector);
        dscEngine.liquidate(wETH, USER, AMOUNT_DSC_IN_USD_TO_MINT);
        vm.stopPrank();
    }

    ////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (address) {
        if (collateralSeed % 2 == 0) {
            return address(wETH);
        }
        return address(wBTC);
    }
}
