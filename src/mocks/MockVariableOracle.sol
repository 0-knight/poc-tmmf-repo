// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IEulerPriceOracle} from "../interfaces/IEulerPriceOracle.sol";

/// @title MockVariableOracle
/// @notice `FixedOneToOneOracle` 과 같은 쌍을 다루되 가격을 움직일 수 있습니다.
///
/// @dev 데모와 테스트 전용입니다. 왜 필요한가 —
///
///      `FixedOneToOneOracle` 은 WTGXX를 $1에 못 박습니다. 그래서 담보 가치가 부채
///      아래로 내려가는 상황을 만들 수 없고, **부족분이 생기는 경로를 시험할 수
///      없습니다.** 이자로 부채를 키워 넘기는 방법도 있지만 7일 repo에서 130일을
///      기다려야 해서 보여줄 수 있는 그림이 아닙니다.
///
///      가격을 한 번 내리면 그 자리에서 부족분이 생깁니다. 설계 문서에서 "부도 유발
///      방법"으로 고른 것이 이 길입니다.
///
///      **프로덕션에 올라갈 물건이 아닙니다.** 실물에서는 백서 4.2절이 요구하는 NAV
///      이탈 감시가 필요하고, Dataspan의 shadowNav를 읽는 어댑터가 그 자리에 옵니다.
///      여기서 중요한 것은 가격이 **어떻게** 정해지느냐가 아니라, 가격이 내려갔을 때
///      시스템이 무엇을 하느냐입니다.
contract MockVariableOracle is IEulerPriceOracle {
    error PairNotSupported(address base, address quote);
    error ZeroAddress();
    error SameAsset();
    error NotGovernor();
    error DecimalsUnavailable(address asset);

    event PriceSet(uint256 priceWad);

    /// @dev 1e18 = assetA 한 단위가 assetB 한 단위와 같은 가치.
    uint256 internal constant ONE = 1e18;

    address public immutable assetA;
    address public immutable assetB;
    uint256 public immutable scaleA;
    uint256 public immutable scaleB;
    address public immutable governor;

    /// @notice assetA 한 단위의 가치, assetB 기준, 1e18 스케일. 처음에는 1:1입니다.
    uint256 public priceWad = ONE;

    /// @inheritdoc IEulerPriceOracle
    function name() external pure returns (string memory) {
        return "MockVariableOracle";
    }

    constructor(address governor_, address assetA_, address assetB_) {
        if (governor_ == address(0) || assetA_ == address(0) || assetB_ == address(0)) revert ZeroAddress();
        if (assetA_ == assetB_) revert SameAsset();

        governor = governor_;
        assetA = assetA_;
        assetB = assetB_;
        scaleA = 10 ** _decimalsOf(assetA_);
        scaleB = 10 ** _decimalsOf(assetB_);
    }

    /// @notice 가격을 옮깁니다. 0.70e18 이면 WTGXX 한 개가 USDC 0.70 가치입니다.
    function setPrice(uint256 priceWad_) external {
        if (msg.sender != governor) revert NotGovernor();
        priceWad = priceWad_;
        emit PriceSet(priceWad_);
    }

    function _decimalsOf(address asset) internal view returns (uint256) {
        (bool ok, bytes memory ret) = asset.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || ret.length < 32) revert DecimalsUnavailable(asset);
        return abi.decode(ret, (uint256));
    }

    /// @notice base 수량을 quote 단위로 환산합니다. decimals 보정 + 가격.
    function getQuote(uint256 inAmount, address base, address quote) public view returns (uint256) {
        if (base == assetA && quote == assetB) {
            return (inAmount * priceWad * scaleB) / (scaleA * ONE);
        }
        if (base == assetB && quote == assetA) {
            if (priceWad == 0) return 0;
            return (inAmount * ONE * scaleA) / (scaleB * priceWad);
        }
        revert PairNotSupported(base, quote);
    }

    function getQuotes(uint256 inAmount, address base, address quote) external view returns (uint256, uint256) {
        uint256 q = getQuote(inAmount, base, quote);
        return (q, q);
    }
}
