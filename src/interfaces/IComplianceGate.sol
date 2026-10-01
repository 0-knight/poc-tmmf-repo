// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IComplianceGate
/// @notice 진입 자격 판정의 최소 계약.
///
/// @dev **구현체는 어떤 경우에도 revert하지 않습니다.** 판정은 반환값으로만 답합니다.
///      게이트가 revert하면 호출 트랜잭션 전체가 죽고, 청산 경로에서 사유를 구분할
///      방법이 사라집니다. WTGXXGate가 모든 외부 호출을 staticcall로 감싸는 이유가
///      이것이며, 다른 구현체도 같은 규약을 지켜야 합니다.
///
///      사유(enum)는 여기 넣지 않습니다. WTGXXGate의 Reason은 WTGXX의 컴플라이언스
///      모양에 묶여 있고, 래퍼 토큰이나 오프체인 커스터디로 가면 사유 집합이 통째로
///      달라집니다. 불린만 계약으로 두고 사유는 구현체별 진단으로 남깁니다.
interface IComplianceGate {
    /// @notice 이 주소가 담보 레그에 진입할 수 있는지 판정합니다.
    /// @dev 출구(상환·인출) 경로에서는 호출하지 마세요. 백서 6.1절.
    function canEnter(address who) external view returns (bool);
}
