// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ReceiverProbe
/// @notice M8-B 교란 변수를 제거하는 일회용 프로브.
///
/// @dev 기존 실험의 두 주소(GATE, BADGATE)는 WTGXXGate 인스턴스라
///      onERC721Received가 없습니다. WisdomTree의 safeMint는 수신자가
///      컨트랙트면 이 훅을 부르고 매직값이 아니면 revert하므로, 민팅이
///      시도됐더라도 실패했을 것이고 "컨트랙트는 화이트리스트 불가"와
///      구별되지 않습니다.
///
///      이 컨트랙트는 훅 하나만 가집니다. 다른 변수를 전부 없앴습니다.
contract ReceiverProbe {
    /// @dev bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }
}