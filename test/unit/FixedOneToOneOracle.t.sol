// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FixedOneToOneOracle} from "../../src/oracle/FixedOneToOneOracle.sol";

contract FixedOneToOneOracleTest is Test {
    FixedOneToOneOracle internal oracle;

    address internal constant WTGXX = address(0xA11CE);
    address internal constant USDC = address(0xB0B);
    address internal constant OTHER = address(0xC0FFEE);

    function setUp() public {
        oracle = new FixedOneToOneOracle(WTGXX, 18, USDC, 6);
    }

    /// 1 WTGXX(18) 는 1 USDC(6) 와 같은 가치입니다.
    function test_quote_wtgxxToUsdc_oneToOne() public view {
        assertEq(oracle.getQuote(1e18, WTGXX, USDC), 1e6);
        assertEq(oracle.getQuote(100e18, WTGXX, USDC), 100e6);
    }

    function test_quote_usdcToWtgxx_oneToOne() public view {
        assertEq(oracle.getQuote(1e6, USDC, WTGXX), 1e18);
        assertEq(oracle.getQuote(100e6, USDC, WTGXX), 100e18);
    }

    /// 왕복하면 원래 값으로 돌아옵니다.
    function test_quote_roundTrip() public view {
        uint256 start = 12_345e18;
        uint256 usdc = oracle.getQuote(start, WTGXX, USDC);
        assertEq(oracle.getQuote(usdc, USDC, WTGXX), start);
    }

    /// 보정을 빠뜨리면 10^12 배 틀립니다. 그 크기를 명시적으로 박아둡니다.
    function test_quote_scaleFactorIsTenToTwelve() public view {
        assertEq(oracle.getQuote(1e18, WTGXX, USDC) * 1e12, 1e18);
    }

    /// 18 -> 6 방향은 내림입니다. 10^12 미만은 0이 됩니다.
    /// 담보 평가에서 과소 평가 방향이므로 안전한 쪽입니다.
    function test_quote_roundsDown_belowOneMicroUsdc() public view {
        assertEq(oracle.getQuote(1, WTGXX, USDC), 0);
        assertEq(oracle.getQuote(1e12 - 1, WTGXX, USDC), 0);
        assertEq(oracle.getQuote(1e12, WTGXX, USDC), 1);
    }

    function test_quote_zeroIn_returnsZero() public view {
        assertEq(oracle.getQuote(0, WTGXX, USDC), 0);
        assertEq(oracle.getQuote(0, USDC, WTGXX), 0);
    }

    function test_getQuotes_bidEqualsAsk() public view {
        (uint256 bid, uint256 ask) = oracle.getQuotes(7e18, WTGXX, USDC);
        assertEq(bid, 7e6);
        assertEq(ask, bid);
    }

    function test_quote_revertsOnUnknownPair() public {
        vm.expectRevert(abi.encodeWithSelector(FixedOneToOneOracle.PairNotSupported.selector, OTHER, USDC));
        oracle.getQuote(1e18, OTHER, USDC);
    }

    function test_quote_revertsOnSameAssetPair() public {
        vm.expectRevert(abi.encodeWithSelector(FixedOneToOneOracle.PairNotSupported.selector, WTGXX, WTGXX));
        oracle.getQuote(1e18, WTGXX, WTGXX);
    }

    function test_constructor_rejectsZeroAddress() public {
        vm.expectRevert(FixedOneToOneOracle.ZeroAddress.selector);
        new FixedOneToOneOracle(address(0), 18, USDC, 6);
    }

    function test_constructor_rejectsSameAsset() public {
        vm.expectRevert(FixedOneToOneOracle.SameAsset.selector);
        new FixedOneToOneOracle(WTGXX, 18, WTGXX, 6);
    }

    /// 같은 decimals 쌍에서는 그대로 통과해야 합니다.
    function test_quote_sameDecimals_identity() public {
        FixedOneToOneOracle flat = new FixedOneToOneOracle(WTGXX, 6, USDC, 6);
        assertEq(flat.getQuote(1234e6, WTGXX, USDC), 1234e6);
    }

    function testFuzz_roundTripNeverInflates(uint128 amount) public view {
        uint256 usdc = oracle.getQuote(amount, WTGXX, USDC);
        uint256 back = oracle.getQuote(usdc, USDC, WTGXX);
        assertLe(back, amount);
    }
}
