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
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_COLLATERAL_ZERO = 0;

    function setUp() public {
        deployerDSC = new DeployDSC();
        (dsc, dscEngine, config) = deployerDSC.run();
        (wETHPriceFeedInUSD, wBTCPriceFeedInUSD, wETH, wBTC,) = config.activeNetworkConfig();
        console.log("before USER balance: ", ERC20Mock(wETH).balanceOf(USER));
        ERC20Mock(wETH).mint(USER, STARTING_ERC20_BALANCE);
        console.log("after USER balance : ", ERC20Mock(wETH).balanceOf(USER));
    }

    modifier depositiCollateral() {
        vm.startPrank(USER);
        ERC20Mock(wETH).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(wETH, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    /**
     * @notice Test summary
     *
     * Tested ✓
     *
     * Errors
     *     DSCEngine__NeedsMoreThanZero ✓
     *     DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength ✓
     *     DSCEngine__NotAllowedToken ✓
     *     DSCEngine__TransferFailed
     *     DSCEngine__BreaksHealthFactor
     *     DSCEngine__MintFailed
     *     DSCEngine__HealthFactorIsOK
     *
     * Getters for private variable
     *     s_priceFeeds => getPriceFeed ✓
     *     s_collateralDeposited => getCollateralDeposited ✓
     *     s_collateralTokens => getCollateralTokens
     *     s_DSCMinted => getDSCMinted
     * Event
     *     CollateralDeposited ✓
     *     CollateralRedeemed
     * Modifiers
     *     moreThanZero => DSCEngine__NeedsMoreThanZero ✓
     *     allowableToken => DSCEngine__NotAllowedToken ✓
     * Constructor
     *     DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength ✓
     *     s_priceFeeds => getPriceFeed ✓
     *     s_collateralTokens => getCollateralTokens
     *
     * External functions
     *     depositCollateralAndMintDSC
     *       depositCollateral ✓
     *       mintDSC
     *
     *     redeemCollateralForDSC
     *       burnDSC
     *       redeemCollateral
     *
     *     liquidate
     *       _healthFactor (private)
     *       DSCEngine__HealthFactorIsOK
     *       _redeemCollateral (private)
     *       _burnDSC (private)
     *
     *     getAccountInformation
     *       _getAccountInformation (private)
     *
     * Public functions
     *     depositCollateral
     *       moreThanZero (modifier)
     *       allowableToken (modifier)
     *       nonReentrant (modifier)
     *       DSCEngine__TransferFailed
     *       CollateralDeposited (event)
     *
     *     mintDSC
     *       moreThanZero (modifier)
     *       nonReentrant (modifier)
     *       _revertIfHealthFactorIsBroken (internal)
     *       DSCEngine__MintFailed
     *
     *     burnDSC
     *       moreThanZero (modifier)
     *       _burnDSC (private)
     *       _revertIfHealthFactorIsBroken (internal)
     *
     *     redeemCollateral
     *       moreThanZero (modifier)
     *       nonReentrant (modifier)
     *       _redeemCollateral (private)
     *       _revertIfHealthFactorIsBroken (internal)
     *
     *    getTokenAmountFromUSD ✓
     *
     *    getAccountCollateralValueInUSD
     *
     */

    /**
     * @notice Section: Test Constructor
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

    function testGetPriceFeedAddresses() public {
        assertEq(dscEngine.getPriceFeed(wETH), wETHPriceFeedInUSD);
        assertEq(dscEngine.getPriceFeed(wBTC), wBTCPriceFeedInUSD);
    }

    function testGetCollateralToken() public {
        address[] memory tokens = dscEngine.getCollateralTokens();
        assertEq(tokens[0], wETH);
        assertEq(tokens[1], wBTC);
    }

    /**
     * @notice Section: Test getTokenValueInUSD
     */

    function testGetTokenValueInUSD() public {
        // 15e18 * 2000/ETC = 30,000e18
        uint256 amountETH = 15e18;
        uint256 expectedAmountInUSD = 30000e18;
        uint256 actualValueInUSD = dscEngine.getTokenValueInUSD(wETH, amountETH);
        assertEq(actualValueInUSD, expectedAmountInUSD);
    }

    /**
     * @notice Section: Test getTokenAmountFromUSD
     */
    function testGetTokenAmountFromUSD() public {
        // With 1 ETH = $2000 (2000e8)
        uint256 amountInUSD = 100 ether; // 100 x 1 x 10^18
        uint256 expectedAmount = 0.05 ether;
        uint256 tokenAmount = dscEngine.getTokenAmountFromUSD(wETH, amountInUSD);
        assertEq(tokenAmount, expectedAmount);
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositiCollateral {
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = dscEngine.getAccountInformation(USER);
        uint256 expectedTotalDSCMinted = 0;
        uint256 expectedTokenAmountInUSD = dscEngine.getTokenAmountFromUSD(wETH, collateralValueInUSD);
        assertEq(totalDSCMinted, expectedTotalDSCMinted);
        assertEq(AMOUNT_COLLATERAL, expectedTokenAmountInUSD);
    }

    /**
     * @notice Section: Test getAccountCollateralValueInUSD
     */
    function testGetAccountCollateralValueInUSD() public depositiCollateral {
        vm.startPrank(USER);

        // uint256 totalDSCMinted = dscEngine.getDSCMinted(USER);
        // uint256 totalCollateralValueInUSD = dscEngine.getAccountCollateralValueInUSD(USER);
        vm.stopPrank();

        // assertEq(totalCollateralValueInUSD, AMOUNT_COLLATERAL);
        // uint256 LIQUIDATION_THRESHOLD = 50;
        // uint256 LIQUIDATION_PRECISION = 100;
        // uint256 PRECISION = 1e18;
        // // uint256 totalDSCMinted = 0;
        // // uint256 collateralValueInUSD = 1;
        // uint256 collateralAdjustedForThreshold = (totalCollateralValueInUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        // uint256 healthFactor = 0;
        // if (totalDSCMinted == 0) {
        //     healthFactor = (collateralAdjustedForThreshold * PRECISION);
        // } else {
        //     healthFactor = (collateralAdjustedForThreshold * PRECISION) / totalDSCMinted;
        // }
        // console.log("totalDSCMinted: ", totalDSCMinted);
        // console.log("totalCollateralValueInUSD: ", totalCollateralValueInUSD);
        // console.log("Health factor: ", healthFactor);
        // console.log("0 => ", type(uint256).max);
    }

    /**
     * @notice Section: Test depositCollateral
     *  moreThanZero => DSCEngine__NeedsMoreThanZero
     *  allowableTOken => DSCEngine__NotAllowedToken
     *
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
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
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

    function testGetCollateralDeposited() public depositiCollateral {
        vm.startPrank(USER);
        uint256 collateralDeposited = dscEngine.getCollateralBalanceOfUser(address(USER), wETH);
        assertEq(collateralDeposited, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    /**
     * @notice Section: Test mintDSC
     */
    function testMintDSC() public {}
}
