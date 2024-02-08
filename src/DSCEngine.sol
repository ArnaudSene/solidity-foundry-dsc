// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
//   view
//   pure
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title A Decentralized stable coin engine (DSC).
 * @author Arnaud SENE
 * @notice System designed to be as minimal as possible,
 * and have the tokens maintain a 1 token == $1 peg.
 * This stablecoin has the properties:
 *  - Exogenous collateral
 *  - Dollar pegged
 *  - Algorithmically stable
 *
 * It is similar to DAI if it had no governance, no fees,
 * and was only backed by wETH and wBTC.
 *
 * The DSC system should always be "overcollateralized".
 * At no point, should the value of all collateral <= the $ backed value
 * of all the DSC.
 *
 * This contract is the core of the DSC system.
 * It handles all the logic for mining and redeeming DSC,
 * as well as depositing & withdrawing collateral.
 *
 * This contract is very loosely based on the MakerDAO DSS (DAI) system.
 *
 * Example:
 * --------
 * With a threshold = 150%
 * If DSC = $50 DSC
 * Then ETH = $75 ETC
 *
 *           |
 *           |
 *      |    |
 *      |    |
 *      |    |
 *      |    |
 *      |    |
 *     ---  ---
 *     DSC  ETC
 *     50   75
 *
 */

contract DSCEngine is ReentrancyGuard {
    ////////////////////////
    /// Errors
    ////////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorIsOK();

    ////////////////////////
    /// Type declarations
    ////////////////////////

    ////////////////////////
    /// State variables
    ////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% over-collateralized needed
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10; // get assets at a 10% discount when liquidating
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    DecentralizedStableCoin private immutable i_dsc;
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256)) private s_collateralDeposited;
    mapping(address user => uint256 amountDSCMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    ////////////////////////
    /// Events
    ////////////////////////
    event CollateralDeposited(
        address indexed _sender, address indexed tokenCollateralAddress, uint256 indexed amountCollateral
    );

    event CollateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount
    );

    ////////////////////////
    /// Modifiers
    ////////////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier allowableToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ////////////////////////
    /// Constructor
    ////////////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Price feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////
    /// Function
    ////////////////////////

    ////////////////////////
    /// External functions
    ////////////////////////
    /**
     * @notice This function will deposit collateral and mint DSC in one transation
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDSCToMint The amount of decentralized stablecoin to mint
     */
    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDSCToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountDSCToMint);
    }

    /**
     * @notice This function burns DSC and redeems underlying collateral in one transaction
     * @param tokenCollateralAddress The address of the token to redeem as collateral
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDSCToBurn The amount of stablecoin to burn
     */
    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDSCToBurn)
        external
    {
        burnDSC(amountDSCToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    /**
     * @notice You can partially liquidate a user.
     *         You will get a liquidation bonus for taking the user's funds.
     *         This function working assumes the protocol will be roughly 200%
     *         overcollateralized in order for this to work.
     *
     * example:
     *  $100 ETH backing $50 DSC
     *
     *         A known bug would be:
     *          if the protocol were 100% or less collateralized,
     *          then we wouldn't be able to incendive the liquidators.
     * example:
     *  Il the price of the collateral plummeted before anyone could be liquidated.
     *
     * @param collateralAddress The ERC20 collateral address to liquidate from the user
     * @param user The user who has broken the health factor.
     *      Their _healthFactor should be beloww MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the user's heal factor.
     */
    function liquidate(address collateralAddress, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsOK();
        }

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUSD(collateralAddress, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        _redeemCollateral(collateralAddress, tokenAmountFromDebtCovered + bonusCollateral, user, msg.sender);
        _burnDSC(debtToCover, user, msg.sender);
    }

    // function getHealthFactor() external {}

    //////////////////////////////
    /// External functions (view)
    //////////////////////////////

    function getPriceFeed(address token) public view returns (address) {
        return s_priceFeeds[token];
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUSD)
    {
        return _getAccountInformation(user);
    }

    function getCollateralBalanceOfUser(
        address user, 
        address token
    ) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDSCMinted(address user) external view returns (uint256) {
        return s_DSCMinted[user];
    }

    //////////////////////////////
    /// External functions (pure)
    //////////////////////////////

    /**
     *
     * @param totalDSCMinted The total collateral DSC minted.
     * @param collateralValueInUSD The collateral value in USD.
     */
    function calculateHealthFactor(uint256 totalDSCMinted, uint256 collateralValueInUSD)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDSCMinted, collateralValueInUSD);
    }

    ////////////////////////
    /// Public functions
    ////////////////////////
    /**
     * @dev follow CEI (Check-Effect-Interaction) pattern
     * Deposit an amount of collateral to an address.
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        allowableToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     *
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to redeem
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Mint Decentralized stable coin (DSC).
     * @param amountDSCToMint The amount of DSC to mint.
     */
    function mintDSC(uint256 amountDSCToMint) public moreThanZero(amountDSCToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDSCToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDSCToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    /**
     * @notice Burn DCS.
     * @param amountDSCToBurn The amount of DSC to burn.
     */
    function burnDSC(uint256 amountDSCToBurn) public moreThanZero(amountDSCToBurn) {
        _burnDSC(amountDSCToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // just a backup, should not been hit
    }

    ////////////////////////
    /// Public functions
    ///     1. view
    ////////////////////////

    /**
     * @notice Get the token amount from a value in USD.
     *
     * example:
     *  If price feed for ETH in USD is 1 ETH = $2000
     *  If amount is $100
     *      1 ether = 1e18 (1 x 10^18)
     *      100 ether = 100 x 1 x 10^18 = 10^20 ou 1e20
     *  Then the token amount is 0.05
     *
     * @param token The address of the token.
     * @param amountInUSD The token amount in USD.
     * @return The token amount in USD.
     */
    function getTokenAmountFromUSD(address token, uint256 amountInUSD) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (amountInUSD * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    /**
     * @notice Returns the USD value
     * If 1 ETH = $1000
     * The returned value from ChainLink will be 1000 * 1e8
     *
     * @param token The token e.g. wETH, wBTC
     * @param amount The token amount
     * @return The USD value of the token
     * If 1 ETH = $1000
     * value = (((1000 * 1e8) * 1e10) * (1000 * 1e18)) / 1e18
     */
    function getTokenValueInUSD(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    /**
     * @notice Returns the collateral value in USD for a user.
     * 1. Loop through each collateral token
     * 2. Get the amount the user has deposited
     * 3. Map it to the price
     * 4. Get the USD value
     *
     * @param user The user
     * @return totalCollateralValueInUSD The total collateral value in USD
     */
    function getAccountCollateralValueInUSD(address user) public view returns (uint256 totalCollateralValueInUSD) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUSD += getTokenValueInUSD(token, amount);
        }
        return totalCollateralValueInUSD;
    }

    ////////////////////////
    /// Internal functions
    ///     1. view
    ///     2. pure
    ////////////////////////

    /**
     * @notice Revert if Health Factor (Hf) is threshold
     * @param user The user
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _getUserHealthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ////////////////////////
    /// Private functions
    ////////////////////////

    function _burnDSC(uint256 amountDSCToBurn, address onBehalf, address from) private {
        s_DSCMinted[onBehalf] -= amountDSCToBurn;
        bool success = i_dsc.transferFrom(from, address(this), amountDSCToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _redeemCollateral(address collateralAddress, uint256 amountCollateral, address from, address to) private {
        s_collateralDeposited[from][collateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, collateralAddress, amountCollateral);
        bool success = IERC20(collateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     *
     * @param user The user
     * @return totalDSCMinted The total of DSC minted
     * @return collateralValueInUSD The collateral value in USD
     */
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUSD)
    {
        totalDSCMinted = s_DSCMinted[user];
        collateralValueInUSD = getAccountCollateralValueInUSD(user);
    }

    /**
     *
     * @param user The user.
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDSCMinted, collateralValueInUSD);
    }

    /**
     *
     * @param totalDSCMinted The total collateral DSC minted.
     * @param collateralValueInUSD The collateral value in USD.
     */
    function _calculateHealthFactor(uint256 totalDSCMinted, uint256 collateralValueInUSD)
        private
        pure
        returns (uint256)
    {
        if (totalDSCMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDSCMinted;
    }

    /**
     * @notice Returns the user Health factor.
     * If a user goes down below 1, then they can get liquidated.
     * Hf = (Sum of collateral * Liquidation Threshold) / Borrowed (DSC minted)
     * e.g.
     *      threshold = 50
     *      precision = 100
     *
     *      collateral = 1000 ETH
     *      DSCMinted = 101 DSC
     *      1000 * 50 = 50,000
     *      50,000 / 100 = 500
     *      500 / 101 = 4,9 > 1  => Ok
     *
     *      collateral = 150 ETH
     *      DSCMinted = 101 DSC
     *      150 * 50 = 7500
     *      7500 / 100 = 75
     *      75 / 101 = 0,74 < 1  => Not Ok => liquidation
     *
     * @param user The user
     * @return The health factor
     */
    function _getUserHealthFactor(address user) private view returns (uint256) {
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDSCMinted, collateralValueInUSD);
        // uint256 collateralAdjustedForThreshold = (collateralValueInUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        // if (totalDSCMinted == 0 ) {
        //     return (collateralAdjustedForThreshold * PRECISION);
        // }
        // return (collateralAdjustedForThreshold * PRECISION) / totalDSCMinted;
    }
}
