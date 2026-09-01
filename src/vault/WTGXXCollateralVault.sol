// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {EVault} from "evk/EVault/EVault.sol";

/// @title WTGXXCollateralVault
/// @notice WTGXX를 담는 담보 볼트. EVault에 ERC-721 수신 능력만 더했습니다.
///
/// @dev WisdomTree KYC NFT는 `safeMint(address to)`로만 발행되며, 수신자가 컨트랙트면
///      `onERC721Received`를 호출하고 매직값이 아니면 revert합니다. EVault 원본에는 그
///      함수가 없어 발행이 실패하고, 볼트가 화이트리스트 자격을 얻지 못합니다.
///      백서 Layer 1이 성립하지 않는 상태입니다.
///
///      EVault의 모듈 구조를 건드릴 필요가 없습니다. BeaconProxy의 fallback이 모든
///      셀렉터를 구현으로 delegatecall하고, EVault는 Solidity 기본 디스패치를 쓰므로
///      상속만으로 함수가 추가됩니다. EVK 소스를 한 줄도 고치지 않습니다.
///
///      크기 주의: EVault 구현이 이미 23,119바이트로 24,576 한계에 근접해 있습니다.
///      이 함수가 약 220바이트를 쓰며 여유가 1,200바이트 남짓입니다. 여기에 로직을
///      더 얹을 여지가 거의 없습니다.
contract WTGXXCollateralVault is EVault {
    /// @dev bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))
    bytes4 private constant ERC721_RECEIVED = 0x150b7a02;

    constructor(Integrations memory integrations, DeployedModules memory modules) EVault(integrations, modules) {}

    /// @notice ERC-721 수신을 승인합니다.
    /// @dev 무조건 승인합니다. 발신자나 tokenId를 검사하지 않습니다.
    ///
    ///      검사하지 않는 이유가 둘입니다. 첫째, WisdomTree의 safeMint는 tokenId를
    ///      인자로 받지 않고 내부에서 채번하므로 볼트가 어떤 ID를 받을지 미리 알 수
    ///      없습니다. 둘째, 발신자를 KYC NFT 주소로 제한하면 그 컨트랙트가 비콘
    ///      업그레이드로 교체될 때 발행이 막힙니다.
    ///
    ///      NFT를 받는 것 자체는 볼트 상태에 아무 영향이 없습니다. 원치 않는 NFT가
    ///      들어와도 담보 회계나 건전성 계산과 무관합니다.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return ERC721_RECEIVED;
    }
}
