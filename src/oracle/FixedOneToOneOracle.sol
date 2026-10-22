// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IEulerPriceOracle} from "../interfaces/IEulerPriceOracle.sol";

interface IERC4626Minimal {
    function asset() external view returns (address);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @title FixedOneToOneOracle
/// @notice 두 자산의 가치를 1:1로 고정하고 decimals 차이만 보정하는 오라클.
///
/// @dev WTGXX와 USDC는 둘 다 $1 고정이므로 시세 조회가 필요 없습니다. 다만 decimals가
///      18과 6이라 그대로 반환하면 10^12배 틀립니다. 이 컨트랙트가 하는 일은 그 보정입니다.
///
///      EVK는 담보를 볼트 주소로 조회합니다(LiquidityUtils.sol:113 —
///      `oracle.getQuote(balance, collateral, unitOfAccount)`에서 collateral이 담보 볼트
///      주소입니다). 넘어오는 수량도 기초자산이 아니라 볼트 share입니다. 그래서 base가
///      ERC-4626이면 convertToAssets로 기초자산 수량을 구한 뒤 그 자산으로 다시 해석합니다.
///      EulerRouter의 "resolved vault" 처리와 같은 방식입니다.
///
///      2026-10-01 관측: Fund Data API의 /funddetails/nav/ 예시가 WTGXX를 1.0002로
///      보여줍니다. 액면 1 가정이 실제로 깨져 있다는 뜻이며, 아래 교체가 선택이
///      아니라는 근거입니다.
///
///      PoC 전용입니다. 프로덕션에서는 백서 4.2절이 요구하는 NAV 이탈 감시가 필요하므로
///      Dataspan의 shadowNav를 읽는 어댑터로 교체해야 합니다. 이 오라클은 WTGXX가 $1에서
///      이탈해도 알아채지 못합니다.
contract FixedOneToOneOracle is IEulerPriceOracle {
    error PairNotSupported(address base, address quote);
    error ZeroAddress();
    error SameAsset();
    error DecimalsUnavailable(address asset);
    error DecimalsOutOfRange(address asset, uint256 decimals);

    /// @dev 볼트 중첩 해석 상한. 무한 루프를 막습니다.
    uint256 private constant MAX_RESOLVE_DEPTH = 4;

    address public immutable assetA;
    address public immutable assetB;

    /// @dev 10 ** decimals. 생성자에서 고정합니다.
    uint256 public immutable scaleA;
    uint256 public immutable scaleB;

    constructor(address assetA_, address assetB_) {
        if (assetA_ == address(0) || assetB_ == address(0)) revert ZeroAddress();
        if (assetA_ == assetB_) revert SameAsset();

        assetA = assetA_;
        assetB = assetB_;
        scaleA = 10 ** _decimalsOf(assetA_);
        scaleB = 10 ** _decimalsOf(assetB_);
    }

    /// @dev 자산에서 decimals를 직접 읽습니다. 배포자가 손으로 넣던 값을 없앱니다.
    ///      틀리면 담보가 조용히 10^12배 잘못 평가되고 아무도 막지 못합니다.
    ///      못 읽거나 범위를 벗어나면 배포를 세웁니다.
    function _decimalsOf(address asset) internal view returns (uint256 d) {
        (bool ok, bytes memory ret) = asset.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || ret.length < 32) revert DecimalsUnavailable(asset);
        d = abi.decode(ret, (uint256));
        if (d > 18) revert DecimalsOutOfRange(asset, d);
    }

    function name() external pure returns (string memory) {
        return "FixedOneToOneOracle";
    }

    /// @notice base 수량을 quote 단위로 환산합니다. 가치는 1:1, decimals만 보정합니다.
    /// @dev base가 ERC-4626이면 기초자산으로 해석한 뒤 환산합니다.
    ///      내림 처리됩니다. 18 -> 6 방향에서 10^12 미만은 0이 되며,
    ///      담보 과소 평가 방향이라 안전한 쪽입니다.
    function getQuote(uint256 inAmount, address base, address quote) public view returns (uint256) {
        (uint256 amount, address resolved) = _resolve(inAmount, base);

        if (resolved == assetA && quote == assetB) {
            return (amount * scaleB) / scaleA;
        }
        if (resolved == assetB && quote == assetA) {
            return (amount * scaleA) / scaleB;
        }
        // 같은 자산끼리는 그대로 통과시킵니다. 부채 볼트가 자기 자산을
        // unitOfAccount로 조회할 때 이 경로를 씁니다.
        if (resolved == quote) {
            return amount;
        }
        revert PairNotSupported(base, quote);
    }

    function getQuotes(uint256 inAmount, address base, address quote) external view returns (uint256, uint256) {
        uint256 out = getQuote(inAmount, base, quote);
        return (out, out);
    }

    /// @dev base가 ERC-4626 볼트면 share를 기초자산 수량으로 바꾸고 기초자산 주소를 돌려줍니다.
    function _resolve(uint256 amount, address base) internal view returns (uint256, address) {
        for (uint256 i = 0; i < MAX_RESOLVE_DEPTH; ++i) {
            if (base == assetA || base == assetB || base.code.length == 0) break;

            (bool ok, bytes memory data) = base.staticcall(abi.encodeCall(IERC4626Minimal.asset, ()));
            if (!ok || data.length < 32) break;

            address underlying = abi.decode(data, (address));
            amount = IERC4626Minimal(base).convertToAssets(amount);
            base = underlying;
        }
        return (amount, base);
    }
}
