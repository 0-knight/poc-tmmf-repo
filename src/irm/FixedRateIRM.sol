// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IIRM} from "evk/InterestRateModels/IIRM.sol";

/// @title FixedRateIRM
/// @notice 이용률과 무관하게 고정 금리를 반환합니다.
///
/// @dev EVK 기본은 이용률 기반(IRMLinearKink)입니다. Radius에서는 맞지 않습니다.
///
///      백서 3.3절이 이용률 방식을 명시적으로 거부합니다 — 기관은 자금 조달 비용을 미리
///      알아야 하는데 이용률 방식은 그것을 보장하지 않습니다. 그리고 PoC처럼 대여자가
///      한 명이면 이용률이 100%에 붙어 금리가 의미 없이 튑니다.
///
///      **PoC 한정 타협:** 백서 3.1절은 마켓 파라미터가 불변이어야 한다고 합니다. 이
///      컨트랙트는 거버너가 금리를 바꿀 수 있습니다. 만기별로 다른 금리를 시험하기 위한
///      것이며, 프로덕션에서는 immutable로 고정하거나 만기별로 별도 볼트를 배포해야
///      합니다. 알려진 제약 목록 참조.
///
///      **금리 표현:** EVK는 초당 수익률(SPY)을 1e27 스케일로 받고 복리로 누적합니다.
///      따라서 여기 설정하는 연 50%는 명목값이고 실효 수익률은 그보다 높습니다
///      (e^0.5 - 1 ≈ 64.9%). 상환액 검증 시 이 차이를 감안하세요.
contract FixedRateIRM is IIRM {
    error E_ZeroAddress();
    error E_NotGovernor();
    error E_RateTooHigh(uint256 ratePerSecond);

    /// @dev EVK Constants.sol 과 같은 값. 윤년 보정이 들어간 율리우스력 기준입니다.
    uint256 internal constant SECONDS_PER_YEAR = 365.2425 days;

    /// @dev EVK Constants.sol 의 MAX_ALLOWED_INTEREST_RATE. 초과하면 볼트가 거부합니다.
    uint256 internal constant MAX_ALLOWED_INTEREST_RATE = 291867278914945094175;

    event RateSet(uint256 ratePerSecond, uint256 nominalApr);

    address public immutable governor;

    /// @notice 초당 수익률, 1e27 스케일.
    uint256 public ratePerSecond;

    /// @param governor_ 금리를 바꿀 수 있는 주체.
    /// @param nominalApr_ 명목 연이율, 1e18 스케일. 연 50%는 0.5e18.
    constructor(address governor_, uint256 nominalApr_) {
        if (governor_ == address(0)) revert E_ZeroAddress();
        governor = governor_;
        _setRate(nominalApr_);
    }

    /// @notice 명목 연이율로 금리를 설정합니다.
    /// @param nominalApr_ 1e18 스케일. 연 50%는 0.5e18.
    function setRate(uint256 nominalApr_) external {
        if (msg.sender != governor) revert E_NotGovernor();
        _setRate(nominalApr_);
    }

    function _setRate(uint256 nominalApr_) internal {
        // 1e18 스케일 연이율을 1e27 스케일 초당 수익률로 변환합니다.
        uint256 perSecond = (nominalApr_ * 1e9) / SECONDS_PER_YEAR;
        if (perSecond > MAX_ALLOWED_INTEREST_RATE) revert E_RateTooHigh(perSecond);

        ratePerSecond = perSecond;
        emit RateSet(perSecond, nominalApr_);
    }

    /// @inheritdoc IIRM
    /// @dev EVK는 볼트 자신만 이 함수를 부르도록 요구합니다. 다른 볼트가 남의 IRM을
    ///      상태 변경 경로로 부르는 것을 막기 위한 규약입니다.
    function computeInterestRate(address vault, uint256, uint256) public view returns (uint256) {
        if (msg.sender != vault) revert E_IRMUpdateUnauthorized();
        return ratePerSecond;
    }

    /// @inheritdoc IIRM
    function computeInterestRateView(address, uint256, uint256) external view returns (uint256) {
        return ratePerSecond;
    }
}
