// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

contract AddressProvider {
    address public constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address public constant WBTC_HOLDER =
        0x489ee077994B6658eAfA855C308275EAd8097C4A;
    address public constant rWBTC = 0x727354712BDFcd8596a3852Fd2065b3C34F4F770;
    address public constant rWBTC_HOLDER =
        0x38e481367E0c50f4166AD2A1C9fde0E3c662CFBa;
    uint24 public constant WBTC_POOL_FEE = 500;
    uint256 public constant WBTC_SWAP_THRESHOLD = 0.01 ether;

    address public constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address public constant USDT_HOLDER =
        0x62383739D68Dd0F844103Db8dFb05a7EdED5BBE6;
    address public constant rUSDT = 0xd69D402D1bDB9A2b8c3d88D98b9CEaf9e4Cd72d9;
    address public constant rUSDT_HOLDER =
        0xA0076833d8316521E3ba4628AD84de11830aa813;
    uint24 public constant USDT_POOL_FEE = 500;
    uint256 public constant USDT_SWAP_THRESHOLD = 100000000;

    address public constant USDC = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
    address public constant USDC_HOLDER =
        0x62383739D68Dd0F844103Db8dFb05a7EdED5BBE6;
    address public constant rUSDC = 0x48a29E756CC1C097388f3B2f3b570ED270423b3d;
    address public constant rUSDC_HOLDER =
        0xA0076833d8316521E3ba4628AD84de11830aa813;
    uint24 public constant USDC_POOL_FEE = 500;
    uint256 public constant USDC_SWAP_THRESHOLD = 100000000;

    address public constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    address public constant DAI_HOLDER =
        0x2d070ed1321871841245D8EE5B84bD2712644322;
    address public constant rDAI = 0x0D914606f3424804FA1BbBE56CCC3416733acEC6;
    address public constant rDAI_HOLDER =
        0x64b6eBE0A55244f09dFb1e46Fe59b74Ab94F8BE1;
    uint24 public constant DAI_POOL_FEE = 3000;
    uint256 public constant DAI_SWAP_THRESHOLD = 100 ether;

    address public constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address public constant WETH_HOLDER =
        0x1eED63EfBA5f81D95bfe37d82C8E736b974F477b;
    address public constant rWETH = 0x0dF5dfd95966753f01cb80E76dc20EA958238C46;
    address public constant rWETH_HOLDER =
        0xBf891E7eFCC98A8239385D3172bA10AD593c7886;
    uint256 public constant WETH_SWAP_THRESHOLD = 0.1 ether;

    address public constant rARB = 0x2dADe5b7df9DA3a7e1c9748d169Cd6dFf77e3d01;
    uint24 public constant ARB_POOL_FEE = 500;
    uint256 public constant ARB_SWAP_THRESHOLD = 100 ether;

    address public constant rwstETH =
        0x42C248D137512907048021B30d9dA17f48B5b7B2;
    uint24 public constant WSTETH_POOL_FEE = 100;
    uint256 public constant WSTETH_SWAP_THRESHOLD = 0.1 ether;

    address public constant RDNT = 0x3082CC23568eA640225c2467653dB90e9250AaA0;
    address public constant DLP = 0x32dF62dc3aEd2cD6224193052Ce665DC18165841;
    address public constant DLP_HOLDER =
        0x76ba3eC5f5adBf1C58c91e86502232317EeA72dE;
}
