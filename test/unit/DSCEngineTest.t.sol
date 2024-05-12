// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.18;

import {Test} from 'forge-std/Test.sol';
import {DeployDSC} from '../../script/DeployDSC.s.sol';
import {DecentralizedStableCoin} from '../../src/DecentralizedStableCoin.sol';
import {DSCEngine} from '../../src/DSCEngine.sol';
import {HelperConfig} from '../../script/HelperConfig.s.sol';
import {ERC20Mock} from '@openzeppelin/contracts/mocks/ERC20Mock.sol';

contract DSCEngineTest is Test {
  DeployDSC deployer;
  DecentralizedStableCoin dsc;
  DSCEngine dsce;
  HelperConfig config;

  address ethUsdPriceFeed;
  address btcUsdPriceFeed;

  address weth;

  address public USER = makeAddr('user');
  uint256 public constant AMOUNT_COLLATERAL = 10 ether;

  function setUp() public{
    deployer = new DeployDSC();
    (dsc, dsce, config) = deployer.run();
    (ethUsdPriceFeed, btcUsdPriceFeed, weth, ,) = config.activeNetworkConfig();
  }

   /////////////////////
  // Constructor Tests/
  /////////////////////
  address[] public tokenAddresses;
  address[] public priceFeedAddresses;
  function testRevertIfTokenLengthDoesntMatchPriceFeeds() public {
    tokenAddresses.push(weth);
    priceFeedAddresses.push(ethUsdPriceFeed);
    priceFeedAddresses.push(btcUsdPriceFeed);

    vm.expectRevert(DSCEngine.
    DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);

    new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
   }


  ///////////////
  // Price Tests/
  ///////////////

  function testGetUsdValue() public view {
      uint256 ethAmount = 15e18;
      uint256 expectedUsd = 30000e18;
      uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
      assertEq(expectedUsd,actualUsd);
  }

  function testGetTokenAmountFromUsd() public view {
    uint256 usdAmount = 100 ether;
    uint256 expectedWeth = 0.05 ether;
    uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
    assertEq(expectedWeth, actualWeth);
  }
    //////////////////////////
  // depositCollateral Tests/
  //////////////////////////
  function testRevertsIfCollateralZero() public {
    vm.startPrank(USER);
    ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

    vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
    dsce.depositCollateral(weth,0);
    vm.stopPrank();
  }

  function testRevertsWithUnapprovedCollateral() public {
    ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
    vm.startPrank(USER);
    vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
    dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
    vm.stopPrank();
  }

  modifier depositCollaterral(){
    vm.startPrank(USER);
    ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
    dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
    vm.stopPrank();
    _;
  }

  function testCanDepositCollateralAndGetAccountInfo() public view {
    (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
    uint256 expectedTotalDscMinted = 0;
    uint256 expectedDepositamount =
      dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
    assertEq(totalDscMinted, expectedTotalDscMinted);
    assertEq(collateralValueInUsd, expectedDepositamount);
  }

  ////////////////
  // Fuzz tests //
  ////////////////
}
