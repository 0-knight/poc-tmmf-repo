// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FixedOneToOneOracle} from "../../src/oracle/FixedOneToOneOracle.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract FixedOneToOneOracleTest is Test {
    FixedOneToOneOracle internal oracle;

    /// @dev 오라클이 생성자에서 decimals를 직접 읽으므로 코드 있는 주소여야 합니다.
    address internal WTGXX;
    address internal USDC;
    address internal constant OTHER = address(0xC0FFEE);

    function setUp() public {
        WTGXX = address(new MockERC20("WTGXX", "WTGXX", 18));
        USDC = address(new MockERC20("USDC", "USDC", 6));
        oracle = new FixedOneToOneOracle(WTGXX, USDC);
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

    /// base == quote 는 그대로 통과합니다.
    /// EVK 부채 볼트가 자기 자산을 unitOfAccount로 조회할 때 이 경로를 씁니다.
    /// (LiquidityUtils.sol:89 — getQuote(owedAssets, asset, unitOfAccount))
    function test_quote_sameAssetPassesThrough() public view {
        assertEq(oracle.getQuote(123e18, WTGXX, WTGXX), 123e18);
        assertEq(oracle.getQuote(456e6, USDC, USDC), 456e6);
    }

    /// 등록되지 않은 자산끼리는 여전히 막힙니다.
    function test_quote_revertsOnUnregisteredSameAsset() public {
        vm.expectRevert(abi.encodeWithSelector(FixedOneToOneOracle.PairNotSupported.selector, OTHER, USDC));
        oracle.getQuote(1e18, OTHER, USDC);
    }

    function test_constructor_rejectsZeroAddress() public {
        vm.expectRevert(FixedOneToOneOracle.ZeroAddress.selector);
        new FixedOneToOneOracle(address(0), USDC);
    }

    function test_constructor_rejectsSameAsset() public {
        vm.expectRevert(FixedOneToOneOracle.SameAsset.selector);
        new FixedOneToOneOracle(WTGXX, WTGXX);
    }

    /// 같은 decimals 쌍에서는 그대로 통과해야 합니다.
    function test_quote_sameDecimals_identity() public {
        address a = address(new MockERC20("A", "A", 6));
        address b = address(new MockERC20("B", "B", 6));
        FixedOneToOneOracle flat = new FixedOneToOneOracle(a, b);
        assertEq(flat.getQuote(1234e6, a, b), 1234e6);
    }

    /// decimals를 못 읽는 주소로는 배포되지 않습니다.
    /// 예전 생성자는 배포자가 넣은 값을 그대로 믿었고, 틀려도 조용했습니다.
    function test_constructor_rejectsAssetWithoutDecimals() public {
        vm.expectRevert(abi.encodeWithSelector(FixedOneToOneOracle.DecimalsUnavailable.selector, OTHER));
        new FixedOneToOneOracle(OTHER, USDC);
    }

    /// 18을 넘는 decimals는 보정 식이 감당하지 못합니다.
    function test_constructor_rejectsDecimalsAbove18() public {
        address big = address(new MockERC20("BIG", "BIG", 19));
        vm.expectRevert(abi.encodeWithSelector(FixedOneToOneOracle.DecimalsOutOfRange.selector, big, uint256(19)));
        new FixedOneToOneOracle(big, USDC);
    }

    function testFuzz_roundTripNeverInflates(uint128 amount) public view {
        uint256 usdc = oracle.getQuote(amount, WTGXX, USDC);
        uint256 back = oracle.getQuote(usdc, USDC, WTGXX);
        assertLe(back, amount);
    }
}
