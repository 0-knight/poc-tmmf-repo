// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IEulerPriceOracle} from "../interfaces/IEulerPriceOracle.sol";

/// @title FixedOneToOneOracle
/// @notice 두 자산의 가치를 1:1로 고정하고 decimals 차이만 보정하는 오라클.
///
/// @dev WTGXX와 USDC는 둘 다 $1 고정이므로 시세 조회가 필요 없습니다. 다만 decimals가
///      18과 6이라 그대로 반환하면 10^12배 틀립니다. 이 컨트랙트가 하는 일은 그 보정뿐입니다.
///
///      PoC 전용입니다. 프로덕션에서는 백서 4.2절이 요구하는 NAV 이탈 감시가 필요하므로
///      Dataspan의 shadowNav를 읽는 어댑터로 교체해야 합니다. 이 오라클은 WTGXX가 $1에서
///      이탈해도 알아채지 못합니다.
contract FixedOneToOneOracle is IEulerPriceOracle {
    error PairNotSupported(address base, address quote);
    error ZeroAddress();
    error SameAsset();

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
    /// @dev 내림 처리됩니다. 18 -> 6 방향에서 10^12 미만은 0이 됩니다.
    ///      담보 평가에서는 과소 평가 방향이라 안전한 쪽입니다.
    function getQuote(uint256 inAmount, address base, address quote) public view returns (uint256) {
        if (base == assetA && quote == assetB) {
            return (inAmount * scaleB) / scaleA;
        }
        if (base == assetB && quote == assetA) {
            return (inAmount * scaleA) / scaleB;
        }
        revert PairNotSupported(base, quote);
    }

    function getQuotes(uint256 inAmount, address base, address quote) external view returns (uint256, uint256) {
        uint256 out = getQuote(inAmount, base, quote);
        return (out, out);
    }
}
