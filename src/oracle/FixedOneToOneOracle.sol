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
///      PoC 전용입니다. 프로덕션에서는 백서 4.2절이 요구하는 NAV 이탈 감시가 필요하므로
///      Dataspan의 shadowNav를 읽는 어댑터로 교체해야 합니다. 이 오라클은 WTGXX가 $1에서
///      이탈해도 알아채지 못합니다.
contract FixedOneToOneOracle is IEulerPriceOracle {
    error PairNotSupported(address base, address quote);
    error ZeroAddress();
    error SameAsset();

    /// @dev 볼트 중첩 해석 상한. 무한 루프를 막습니다.
    uint256 private constant MAX_RESOLVE_DEPTH = 4;

    address public immutable assetA;
    address public immutable assetB;

    /// @dev 10 ** decimals. 생성자에서 고정합니다.
    uint256 public immutable scaleA;
    uint256 public immutable scaleB;

    constructor(address assetA_, uint8 decimalsA_, address assetB_, uint8 decimalsB_) {
        if (assetA_ == address(0) || assetB_ == address(0)) revert ZeroAddress();
        if (assetA_ == assetB_) revert SameAsset();

        assetA = assetA_;
        assetB = assetB_;
        scaleA = 10 ** decimalsA_;
        scaleB = 10 ** decimalsB_;
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
