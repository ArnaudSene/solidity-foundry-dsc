// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title A Decentralized stable coin engine (DSC).
 * @author Arnaud SENE
 */

contract DSCEngine is ReentrancyGuard {
    ////////////////////////
    /// Errors
    ////////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken(address token);
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorIsOK();
    error DSCEngine__AmountCollateralIsTooHigh();
    error DSCEngine__AmountDSCToBurnIsTooHigh();

    ////////////////////////
    /// Type declarations
    ////////////////////////
    using OracleLib for AggregatorV3Interface;

    ////////////////////////
    /// State variables
    ////////////////////////
    DecentralizedStableCoin private immutable i_dsc;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% over-collateralized needed
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10; // get assets at a 10% discount when liquidating
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256)) private s_collateralDeposited;
    mapping(address user => uint256 amountDSCMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    ////////////////////////
    /// Events
    ////////////////////////
    event CollateralDeposited(
        address indexed _sender, 
        address indexed tokenCollateralAddress, 
        uint256 indexed amountCollateral
    );

    event CollateralRedeemed(
        address indexed redeemFrom, 
        address indexed redeemTo, 
        address indexed token, 
        uint256 amount
    );

    ////////////////////////
    /// Modifiers
    ////////////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier allowableToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken(token);
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
    /// External functions
    ////////////////////////
    /**
     * @notice This function will deposit collateral and mint DSC in one transation
     * @param tokenCollateralAddress The ERC20 token address of collateral to deposit
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDSCToMint The amount of DSC to mint
     */
    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDSCToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountDSCToMint);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice This function redeems underlying collateral and burns DSC in one transaction
     * @param tokenCollateralAddress The ERC20 token address of the collateral to redeem
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDSCToBurn The amount of DSC to burn
     */
    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDSCToBurn) 
        external 
        moreThanZero(amountCollateral) 
        allowableToken(tokenCollateralAddress) 
    {
        burnDSC(amountDSCToBurn);
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Redeem an amount of collateral from an address.
     * @param tokenCollateralAddress The address of the token collateral
     * @param amountCollateral The amount of collateral to redeem
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        nonReentrant
        allowableToken(tokenCollateralAddress)
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice You can partially liquidate a user.
     *         You will get a liquidation bonus for taking the user's funds.
     *         This function working assumes the protocol will be roughly 200%
     *         overcollateralized in order for this to work.
     * @param tokenCollateralAddress The ERC20 collateral address to liquidate from the user
     * @param user The user who has broken the health factor.
     * @param debtToCover The amount of DSC you want to burn to improve the user's heal factor.
     */
    function liquidate(address tokenCollateralAddress, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _getUserHealthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsOK();
        }

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUSD(tokenCollateralAddress, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        _redeemCollateral(tokenCollateralAddress, tokenAmountFromDebtCovered + bonusCollateral, user, msg.sender);
        _burnDSC(debtToCover, user, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //////////////////////////////
    /// External functions (view)
    //////////////////////////////

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getPriceFeed(address token) public view returns (address) {
        return s_priceFeeds[token];
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }


    function getDSCMinted(address user) external view returns (uint256) {
        return s_DSCMinted[user];
    }

    function getAccountInformation(address user)
        external 
        view 
        returns (uint256 totalDSCMinted, uint256 collateralValueInUSD)
    {
        return _getAccountInformation(user);
    }

    function getMaxDSCAllowed(address user) external view returns (uint256) {
        return _getMaxDSCAllowed(user);
    }

    function getUserHealthFactor(address user) external view returns (uint256) {
        return _getUserHealthFactor(user);
    }

    //////////////////////////////
    /// External functions (pure)
    //////////////////////////////

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    /**
     * @notice Calculate the health factor. 
     * @param totalDSCMinted The total collateral DSC minted.
     * @param collateralValueInUSD The collateral value in USD.
     */
    function getCalculatedHealthFactor(uint256 totalDSCMinted, uint256 collateralValueInUSD) 
        external 
        pure 
        returns (uint256) 
    {
        return _calculateHealthFactor(totalDSCMinted, collateralValueInUSD);
    }

    /**
     * @notice Get the amount of DSC per the collateral value in USD.
     * @param collateralValueInUSD The collateral value in USD.
     */
    function getAmountDSCPerCollateralInUSD(uint256 collateralValueInUSD) external pure returns (uint256) {
        return _calculAmountDSCPerCollateralInUSD(collateralValueInUSD);
    }

    ////////////////////////
    /// Public functions
    ////////////////////////

    /**
     * @notice Burn an amount of DSC.
     * @param amountDSCToBurn The amount of DSC to burn.
     */
    function burnDSC(uint256 amountDSCToBurn) public moreThanZero(amountDSCToBurn) {
        _burnDSC(amountDSCToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // just a backup, should not been hit
    }

    /**
     * @notice Deposit an amount of collateral to an address.
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        allowableToken(tokenCollateralAddress)
        moreThanZero(amountCollateral)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(
            msg.sender, 
            tokenCollateralAddress, 
            amountCollateral
        );

        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender, 
            address(this), 
            amountCollateral
        );

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }   

    /**
     * @notice Mint an amount of DSC.
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
    
    ////////////////////////////
    /// Public functions (view)
    ////////////////////////////

    /**
     * @notice Get the token amount from a value in USD.
     *
     * example:
     *  If price feed for ETH in USD is 1 ETH = $2000
     *  If user has an amount of $100 in ETH (0.05 ETH = 100 / 2000)
     *  Then the token amount is 0.05
     *
     * @param token The address of the token.
     * @param amountInUSD The token amount in USD.
     * @return The token amount in USD.
     */
    function getTokenAmountFromUSD(address token, uint256 amountInUSD) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (amountInUSD * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    /**
     * @notice Returns the price value in USD for a collateral token
     * If 1 ETH = $2000
     * The returned value from ChainLink will be 2000 * 1e8
     *
     * @param token The token e.g. wETH, wBTC
     * @param amount The token amount
     * @return The USD value of the token
     * If 1 ETH = $2000
     * If amount = 1000
     * value = (((2000 * 1e8) * 1e10) * (1000 * 1e18)) / 1e18
     * value = 2000
     */
    function getTokenValueInUSD(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    /**
     * @notice Returns the collateral value in USD for a user.
     * 1. Loop through each collateral token
     * 2. Get the amount the user has deposited
     * 3. Map it to the price
     * 4. Get the USD value e.g. 2000$ for 1 ETH
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

    //////////////////////////////
    /// Internal functions (view)
    //////////////////////////////

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

    /**
     * @notice Burn the amount of DSC
     * @param amountDSCToBurn The amount of DSC stablecoin to burn
     * @param onBehalf The user address holding the DSC stablecoin
     * @param from The user address initiating the burn, can be a third party in case of liquidation
     */
    function _burnDSC(uint256 amountDSCToBurn, address onBehalf, address from) private {
        if (amountDSCToBurn > s_DSCMinted[onBehalf]) {
            revert DSCEngine__AmountDSCToBurnIsTooHigh();
        }

        s_DSCMinted[onBehalf] -= amountDSCToBurn;
        bool success = i_dsc.transferFrom(from, address(this), amountDSCToBurn);
        
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDSCToBurn);
    }

    /**
     * @notice Redeem a collateral amount
     * @param collateralAddress The collateral address to redeem
     * @param amountCollateral The amount of collateral to redeem
     * @param from The user holding the DSC stablecoin
     * @param to The user initiating the redeem, can be a third party in case of liquidation
     */
    function _redeemCollateral(address collateralAddress, uint256 amountCollateral, address from, address to) private {
        if (amountCollateral > s_collateralDeposited[from][collateralAddress]) {
            revert DSCEngine__AmountCollateralIsTooHigh();
        }

        s_collateralDeposited[from][collateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, collateralAddress, amountCollateral);
        bool success = IERC20(collateralAddress).transfer(to, amountCollateral);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }
    
    /////////////////////////////
    /// Private functions (view)
    /////////////////////////////

    /**
     * @notice Get the max DSC allowed to mint based on total collateral in USD.
     * @param user The address of the user.
     * @return The max DSC allowed to mint.
     *   e.g. with total collateral in USD is : 2000
     *      max DSC allowed to mint is : 1000
     */
    function _getMaxDSCAllowed(address user) private view returns (uint256) {
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = _getAccountInformation(user);
        uint256 amountDSCPerCollateralInUSD = _calculAmountDSCPerCollateralInUSD(collateralValueInUSD);
        return amountDSCPerCollateralInUSD - totalDSCMinted;
    }

    /**
     * @notice Get the information of the user account.
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

    /////////////////////////////
    /// Private functions (pure)
    ///////////////////////////// 

    /**
     * @notice Returns the user Health factor.
     * @param user The user
     * @return The health factor
     */
    function _getUserHealthFactor(address user) private view returns (uint256) {
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDSCMinted, collateralValueInUSD);
    }

    /**
     * @notice Calculate the amount of DSC per collateral in USD.
     * @param collateralValueInUSD An amount of collateral in USD.
     */
    function _calculAmountDSCPerCollateralInUSD(uint256 collateralValueInUSD) private pure returns (uint256) {
        return (collateralValueInUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
    }

    /**
     * @notice Calculte the user's health factor.
     * @param totalDSCMinted The total collateral DSC minted.
     * @param collateralValueInUSD The collateral value in USD (e.g. 2000$).
     */
    function _calculateHealthFactor(uint256 totalDSCMinted, uint256 collateralValueInUSD) 
        private 
        pure 
        returns (uint256) 
    {
        if (totalDSCMinted == 0) return type(uint256).max;
        uint256 amountDSCPerCollateralInUSD = _calculAmountDSCPerCollateralInUSD(collateralValueInUSD);
        return (amountDSCPerCollateralInUSD * PRECISION) / totalDSCMinted;
    }
}
