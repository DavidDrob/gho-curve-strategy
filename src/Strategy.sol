// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/aave/IGhoToken.sol";
import "./interfaces/curve/ICurvePool.sol";
import "./interfaces/curve/ITriCryptoNG.sol";
import "./interfaces/curve/ICryptoSwap.sol";
import "./interfaces/convex/IConvex.sol";
import "./interfaces/convex/IConvexRewards.sol";

/**
 * The `TokenizedStrategy` variable can be used to retrieve the strategies
 * specific storage data your contract.
 *
 *       i.e. uint256 totalAssets = TokenizedStrategy.totalAssets()
 *
 * This can not be used for write functions. Any TokenizedStrategy
 * variables that need to be updated post deployment will need to
 * come from an external call from the strategies specific `management`.
 */

// NOTE: To implement permissioned functions you can use the onlyManagement, onlyEmergencyAuthorized and onlyKeepers modifiers

// Custom errors
error ZeroLP();
error NoCRVMinted();

contract Strategy is BaseStrategy {
    using SafeERC20 for ERC20;

    IGhoToken public constant GHO = IGhoToken(0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f);
    IERC20 public constant CRV_USD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IERC20 public constant CRV = IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IERC20 public constant CVX = IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IERC20 public constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    ICurvePool public constant POOL = ICurvePool(0x635EF0056A597D13863B73825CcA297236578595);
    IConvex public constant CONVEX = IConvex(0xF403C135812408BFbE8713b5A23a04b3D48AAE31);
    IConvexRewards public constant CONVEX_REWARDS = IConvexRewards(0x5eC758f79b96AE74e7F1Ba9583009aFB3fc8eACB);
    ICryptoSwap public constant CVX_ETH_POOL = ICryptoSwap(0xB576491F1E6e5E62f1d8F26062Ee822B40B0E0d4);
    ITriCryptoNG public constant REWARDS_POOL = ITriCryptoNG(0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14);

    uint256 public constant PID = 335; // convex pool id

    uint256 public constant SLIPPAGE = 9_900; // slippage in BPS
    uint256 public constant MAX_BPS = 10_000;

    uint256 public constant MIN_CVX_TO_HARVEST = 30e18; // 30 CVX
    uint256 public constant MIN_POOL_DEPOSIT = 0.1e18; // 0.10 GHO

    constructor(
        address _asset,
        string memory _name
    ) BaseStrategy(_asset, _name) {
        GHO.approve(address(POOL), type(uint256).max);
        CRV_USD.approve(address(POOL), type(uint256).max);
        POOL.approve(address(CONVEX), type(uint256).max);
        CRV.approve(address(REWARDS_POOL), type(uint256).max);
        CVX.approve(address(CVX_ETH_POOL), type(uint256).max);
        WETH.approve(address(REWARDS_POOL), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Can deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy can attempt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {
        // Deposit GHO into crvUSD/GHO pool.
        uint256[] memory _amounts = new uint256[](2);
        _amounts[0] = _amount;

        uint256 _expectedLpAmount = POOL.calc_token_amount(_amounts, true);
        uint256 _minAmountOut = Math.mulDiv(_expectedLpAmount, SLIPPAGE, MAX_BPS);

        uint256 _lpAmount = POOL.add_liquidity(_amounts, _minAmountOut);

        // Deposit crvUSDGHO LP into convex and stake.
        CONVEX.deposit(PID, _lpAmount, true);
    }

    /**
     * @dev Should attempt to free the '_amount' of 'asset'.
     *
     * NOTE: The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting purposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal override {
        // Unstake crvUSDGHO LP.
        uint256[] memory _amounts = new uint256[](2);
        _amounts[0] = _amount;
        uint256 _desired_lp_amount = POOL.calc_token_amount(
            _amounts,
            false
        );

        uint256 _staked_tokens = CONVEX_REWARDS.balanceOf(address(this));

        uint256 _lp_amount = Math.min(_desired_lp_amount, _staked_tokens);

        if (_lp_amount == 0) revert ZeroLP();
        CONVEX_REWARDS.withdrawAndUnwrap(_lp_amount, false);

        uint256 _minAmountOut = Math.mulDiv(_amount, SLIPPAGE, 10_000);

        // Withdraw GHO
        POOL.remove_liquidity_one_coin(
            _lp_amount,
            int128(0),
            _minAmountOut
        );
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    // Must be called by trusted actor to avoid MEV
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        if (!TokenizedStrategy.isShutdown()) {
            // Claim CRV rewards
            bool _claimedSucessfully = CONVEX_REWARDS.getReward();
            if (!_claimedSucessfully) revert NoCRVMinted();
            
            uint256 _dx = CRV.balanceOf(address(this));
            uint256 _amount = REWARDS_POOL.exchange(2, 0, _dx, 0);

            uint256[] memory _amounts = new uint256[](2);
            _amounts[1] = _amount;

            uint256 _lpAmount = POOL.add_liquidity(_amounts, 0);

            // Deposit crvUSDGHO LP into convex and stake.
            CONVEX.deposit(PID, _lpAmount, true);
        }

        uint256 _convexLPBalance = CONVEX_REWARDS.balanceOf(address(this));
        uint256 _ghoBalance = GHO.balanceOf(address(this));

        // `calc_withdraw_one_coin` reverts when `_burn_amount` is zero
        if (_convexLPBalance == 0) {
            _totalAssets = _ghoBalance;
        }
        else {
            _totalAssets = 
                POOL.calc_withdraw_one_coin(_convexLPBalance, int128(0)) + 
                _ghoBalance;
        }
    }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwichable strategies.
     *
     *   EX:
     *       return asset.balanceOf(yieldSource);
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
     *
     * @param . The address that is withdrawing from the strategy.
     * @return . The available amount that can be withdrawn in terms of `asset`
     */
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        // NOTE: Withdraw limitations such as liquidity constraints should be accounted for HERE
        //  rather than _freeFunds in order to not count them as losses on withdraws.

        // TODO: If desired implement withdraw limit logic and any needed state variables.

        // EX:
        // if(yieldSource.notShutdown()) {
        //    return asset.balanceOf(address(this)) + asset.balanceOf(yieldSource);
        // }
        // TODO: perhaps calculate amount via
        // preview withdraw and return that
        return type(uint256).max;
    }

    /**
     * @notice Gets the max amount of `asset` that an address can deposit.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any deposit or mints to enforce
     * any limits desired by the strategist. This can be used for either a
     * traditional deposit limit or for implementing a whitelist etc.
     *
     *   EX:
     *      if(isAllowed[_owner]) return super.availableDepositLimit(_owner);
     *
     * This does not need to take into account any conversion rates
     * from shares to assets. But should know that any non max uint256
     * amounts may be converted to shares. So it is recommended to keep
     * custom amounts low enough as not to cause overflow when multiplied
     * by `totalSupply`.
     *
     * @param . The address that is depositing into the strategy.
     * @return . The available amount the `_owner` can deposit in terms of `asset`
     *
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        TODO: If desired Implement deposit limit logic and any needed state variables .
        
        EX:    
            uint256 totalAssets = TokenizedStrategy.totalAssets();
            return totalAssets >= depositLimit ? 0 : depositLimit - totalAssets;
    }
    */

    /**
     * @dev Optional function for strategist to override that can
     *  be called in between reports.
     *
     * If '_tend' is used tendTrigger() will also need to be overridden.
     *
     * This call can only be called by a permissioned role so may be
     * through protected relays.
     *
     * This can be used to harvest and compound rewards, deposit idle funds,
     * perform needed position maintenance or anything else that doesn't need
     * a full report for.
     *
     *   EX: A strategy that can not deposit funds without getting
     *       sandwiched can use the tend when a certain threshold
     *       of idle to totalAssets has been reached.
     *
     * This will have no effect on PPS of the strategy till report() is called.
     *
     * @param _totalIdle The current amount of idle funds that are available to deploy.
     *
    */
    // swaps CVX rewards for CRV via WETH and deposit idle GHO to LP
    // call this before report to compound more rewards
    //
    // Must be called by trusted actor to avoid MEV
    function _tend(uint256 _totalIdle) internal override {
        if (_tendTrigger()) {
            uint256 _cvxBalance = CVX.balanceOf(address(this));

            // swap CVX -> WETH
            uint256 _ethAmount = CVX_ETH_POOL.exchange(1, 0, _cvxBalance, 0);

            // swap WETH -> CRV
            REWARDS_POOL.exchange(1, 2, _ethAmount, 0);
        }

        if (_totalIdle > MIN_POOL_DEPOSIT) {
            uint256[] memory _amounts = new uint256[](2);
            _amounts[0] = _totalIdle;

            uint256 _expectedLpAmount = POOL.calc_token_amount(_amounts, true);
            uint256 _minAmountOut = Math.mulDiv(_expectedLpAmount, SLIPPAGE, MAX_BPS);

            POOL.add_liquidity(_amounts, _minAmountOut);
        }
    }

    /**
     * @dev Optional trigger to override if tend() will be used by the strategy.
     * This must be implemented if the strategy hopes to invoke _tend().
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     *
    */
    function _tendTrigger() internal view override returns (bool) {
	    uint256 _cvxBalance = CVX.balanceOf(address(this));

        if (_cvxBalance == 0) return false;
	
        // CVX -> CRV via WETH
        uint256 _ethAmount = CVX_ETH_POOL.get_dy(1, 0, _cvxBalance);
        uint256 _crvOut = REWARDS_POOL.get_dy(1, 2, _ethAmount);

        return _crvOut > MIN_CVX_TO_HARVEST;
    }

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A separate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
     *
     * @param _amount The amount of asset to attempt to free.
     *
    function _emergencyWithdraw(uint256 _amount) internal override {
        TODO: If desired implement simple logic to free deployed funds.

        EX:
            _amount = min(_amount, aToken.balanceOf(address(this)));
            _freeFunds(_amount);
    }

    */
}
