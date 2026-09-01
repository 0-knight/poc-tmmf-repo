// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IWTGXX
/// @notice Radius가 WTGXX에서 실제로 호출하는 함수만 모은 최소 인터페이스.
/// @dev 시그니처는 Sepolia 배포분(0x0b2517ee…) 검증 소스에서 확인했습니다.
///      구현 코드를 옮겨오지 않고 선언만 독립적으로 작성했습니다.
interface IWTGXX {
    // --- ERC-20 ---
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 tokens) external returns (bool);

    // --- 컴플라이언스 확장 ---

    /// @notice from/amount는 현재 오라클 구현에서 무시되고 `to`만 판정에 쓰입니다.
    /// @dev 컴플라이언스 주소가 0이면 검사를 건너뛰고 무조건 true를 반환합니다.
    function isAddressWhitelisted(address from, address to, uint256 amount) external view returns (bool);

    function isPaused() external view returns (bool);
    function isFrozen(address account) external view returns (bool);

    /// @notice 0을 반환하면 화이트리스트 검사가 사실상 꺼진 상태입니다.
    function getCompliance() external view returns (address);

    function getImplementation() external view returns (address);
}
