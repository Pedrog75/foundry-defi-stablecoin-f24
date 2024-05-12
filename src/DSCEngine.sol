// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
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
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { OracleLib, AggregatorV3Interface } from "./libraries/OracleLib.sol";

/**
 * @title DecentralizedStableCoin Engine
 * @author Pedro
 * the system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 value pegged
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * Our DSC system should always be 'overcollateralized'.
 * At no point, should the value of all collateral <= the $ backed value of all the DSC
 *
 * It is similar to dAI if DAI had no governance, no fess, and was only backed by WEth and WBTC.
 * @notice This contract is the core of the DSC System. It handles all the logic for mining
 * and redeeming DSC, as well as despositing and withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    ////////////////
    // Errors   ///
    ///////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken(address token);
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();
    ////////////////
    // State variables///
    ///////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant FEED_PRECISION = 1e8;

    mapping(address collateralToken => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address collateralToken => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint amountDscminted) private s_DSCMinted;
    address[] private s_collateralTokens;

    using OracleLib for AggregatorV3Interface;

    DecentralizedStableCoin private immutable i_dsc;

     ////////////////
    // Events///
    ///////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedto,
    address indexed token, uint256 amount);

    ////////////////
    // Modifiers///
    ///////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken(token);
        }
        _;
    }

    ////////////////
    // Functions ///
    ///////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddress, address dscAddress) {
        // USD Price Feed
        if (tokenAddresses.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        // For ETH / USD, BTC / USD, etc
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }
    /////////////////////////
    // External Functions ///
    /////////////////////////
    /**
     *
     * @param tokenCollateralAddress Thhe address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint Te amount of decentralized stablecoin to mint
     * @notice this function will deposit your collateral and mint DSC in one transaction
     */

    function depositCollateralAndMintDsc(
      address tokenCollateralAddress,
      uint256 amountCollateral,
      uint256 amountDscToMint
    ) external {
      depositCollateral(tokenCollateralAddress,amountCollateral);
      mintDsc(amountDscToMint);
    }


    /**
     *
     * @param tokenCollateralAddress The collateral address to redeem
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToBurn  The amount of DSC to burn
     * This function burns DSC and redeem underlying collateral in one transaction
     */

    function redeemCollateralForDsc(
      address tokenCollateralAddress,
      uint256 amountCollateral,
      uint256 amountDscToBurn
    ) external
      moreThanZero(amountCollateral)
      isAllowedToken(tokenCollateralAddress)
    {
      _burnDsc(amountDscToBurn, msg.sender, msg.sender);
      _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
      revertIfHealthFactorIsBroken(msg.sender);
      // redeemCollateral already checks helath factor
    }
    // in order to redeem collateral :
    // 1. health factor must be over 1 AFTER collateral pulled
    // 2.
   function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        external
        moreThanZero(amountCollateral)
        nonReentrant
        isAllowedToken(tokenCollateralAddress)
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        revertIfHealthFactorIsBroken(msg.sender);
    }
    /*
     * @notice careful! You'll burn your DSC here! Make sure you want to do this...
     * @dev you might want to use this if you're nervous you might get liquidated and want to just burn
     * you DSC but keep your collateral in.
     */
    function burnDsc(uint256 amount) public moreThanZero(amount){
        _burnDsc(amount, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender);
    }

    // If someone is almost undercollateralized, we will pay you to liquidate them!
    /**
     *
     * @param collateral The erc20 collateral address to liquidate from the user
     * @param user  The user who has broken the health factor. Their _healthFactor should
     * be MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the user health factor
     * @notice You can partially liquidate a user.
     *  You will get a liquidation bonus for taking the users funds. The protocol will
     * be roughly 200% overcollateralizedin order for this to work
     * @notice A know bug would be if the protocoal were 100% or less collateralized,
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
    external moreThanZero(debtToCover) nonReentrant{
        uint256 startingUserHealthFactor = _healthFactor(user);
        if(startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // we want to burn their DSC debt
        // Take their collateral
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        // uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, tokenAmountFromDebtCovered + bonusCollateral);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if(endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        revertIfHealthFactorIsBroken(msg.sender);
    }


    ////////////////////////
    // Public Functions ///
    ////////////////////////

    /**
     * @notice follows CEI pattern
     * @param amountDscToMint The amount of DSC to mint
     * @notice they must have enough collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if(!minted){
          revert DSCEngine__MintFailed();
        }
    }

    /**
     * @notice follows CEI pattern
     * @param tokenCollateralAddress The address of the collateral token
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
    }



    ////////////////////////
    // Private functions ///
    ////////////////////////
    function _redeemCollateral(
      address from,
      address to,
      address tokenCollateralAddress,
      uint256 amountCollateral
      ) private{
      s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
      emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
      bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
      if(!success) {
          revert DSCEngine__TransferFailed();
      }
    }

    // function getHealthFactor() external view {}
    /*
    * Returns how close to liquidation a userr is
    * if a user goes below 1, they can get liquidated
    */

    /**
     * @dev Low-Level internal function, do not call unless the function calling it,
     * is checking for health factior being borken
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom)private {
      s_DSCMinted[onBehalfOf] -= amountDscToBurn;
      bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
      if(!success) {
          revert DSCEngine__TransferFailed();
      }
        i_dsc.burn(amountDscToBurn);
    }

      ///////////////////////////////////////
    // Private & Internal View Functions ///
    /////////////////////////////////////////


   function _getAccountInformation(address user) private view
   returns(uint256 totalDscMinted, uint256 collateralValueInUsd){
    totalDscMinted = s_DSCMinted[user];
    collateralValueInUsd = getAccountCollateralValue(user);
   }

    function _healthFactor(address user) private view returns (uint256) {
      // total DSC minted
        // total collateral VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH = 1000 USD
        // The returned value from Chainlink will be 1000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        // We want to have everything in terms of WEI, so we add 10 zeros at the end
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function _calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    )
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function revertIfHealthFactorIsBroken(address user) internal view {
      uint256 userHealthFactor = _healthFactor(user);
      if(userHealthFactor < MIN_HEALTH_FACTOR) {
          revert DSCEngine__BreaksHealthFactor(userHealthFactor);
      }
    }

    ///////////////////////////////////////
    // Public & External View Functions ///
    /////////////////////////////////////////
    function calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    )
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getAccountInformation(address user) external view
   returns(uint256 totalDscMinted, uint256 collateralValueInUsd)
   {
    (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
   }


    function getAccountCollateralValue(address user) public view returns(uint256 totalCollateralValueInUsd){
      // loop through each collateral token, get the amount they jave deposited and map it to
      // the price, the get the USD total value
      for(uint256 i = 0; i < s_collateralTokens.length; i++) {
          address token = s_collateralTokens[i];
          uint256 amount = s_collateralDeposited[user][token];
          totalCollateralValueInUsd += getUsdValue(token, amount);
      }
      return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns(uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.latestRoundData();
        return((uint256(price) * ADDITIONAL_FEED_PRECISION)*amount) / PRECISION;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns(uint256){
        //price of ETH (token)
        // $/ETH
        // $2000 / ETH $1000 = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
}
