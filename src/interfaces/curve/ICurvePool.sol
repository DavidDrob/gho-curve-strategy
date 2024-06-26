// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

interface ICurvePool is IERC20 {
    function get_virtual_price() external view returns (uint256);

    function calc_token_amount(
        uint256[] memory _amounts,
        bool _is_deposit
    ) external view returns (uint256);

    function calc_token_amount(
        address _pool,
        uint256[4] calldata _amounts,
        bool _is_deposit
    ) external view returns (uint256);

    function add_liquidity (
        uint256[] memory _amounts,
        uint256 _min_mint_amount
    ) external returns (uint256);

    function add_liquidity (
        uint256[] memory _amounts,
        uint256 _min_mint_amount,
        address receiver
    ) external returns (uint256);

    function remove_liquidity_one_coin(
        uint256 _token_amount,
        int128 i,
        uint256 _min_amount
    ) external returns (uint256);

    function exchange(
        uint128 i,
        uint128 j,
        uint256 dx,
        uint256 min_dy,
        bool use_eth
    ) external returns (uint256);

    function coins(uint256 index) external returns (address);

    function calc_withdraw_one_coin(uint256 _burn_amount, int128 i) external returns (uint256);
}

