// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BeaconProxy} from "euler-vault-kit/src/GenericFactory/BeaconProxy.sol";

interface IInitializable {
    function initialize(address proxyCreator) external;
}

/// @title CollateralVaultFactory
/// @notice 담보 볼트를 CREATE2로 배포해 주소를 사전에 알 수 있게 합니다.
///
/// @dev EVK의 GenericFactory는 `new BeaconProxy(...)`를 쓰므로 주소가 팩토리 nonce로
///      정해집니다. 몇 번째 볼트인지에 따라 달라지고, 누가 먼저 배포하느냐에 따라
///      바뀝니다. 그러면 투자자가 자기 이름으로 명부에 오를 컨트랙트를 배포 전에 확인할
///      방법이 없고, 백서 2.2절의 "등록에는 투자자 서명이 필요하다"가 형식만 남습니다.
///      투자자는 Radius가 알려준 주소를 믿는 수밖에 없게 됩니다.
///
///      이 팩토리는 CREATE2로 배포합니다. 주소가 (팩토리, salt, initCode)의 함수이므로
///      투자자가 같은 계산을 독립적으로 수행해 대조할 수 있습니다.
///
///      **이 팩토리가 비콘을 겸합니다.** BeaconProxy는 생성자에서 `beacon = msg.sender`로
///      배포자를 비콘으로 삼고, 호출마다 비콘에 `implementation()`을 staticcall합니다.
///      public 변수 `implementation`이 그 셀렉터(0x5c60da1b)를 제공합니다.
///
///      **implementation은 immutable입니다.** 비콘 패턴은 구현 교체로 모든 프록시를 한 번에
///      바꿀 수 있는데, 백서 2.2절의 불변 볼트 요구와 정면으로 충돌합니다. 교체 함수를
///      아예 두지 않아 그 경로를 닫습니다. EVK의 GenericFactory는 관리자가
///      setImplementation을 호출할 수 있으므로, 이 팩토리가 그보다 엄격합니다.
///
///      **GenericFactory 레지스트리에는 등록되지 않습니다.** proxyLookup과 isProxy에서
///      빠지지만 EVK 코드가 이를 확인하지 않아 담보로 인정받는 데 문제가 없습니다
///      (src 전체에서 isProxy 사용처가 없음). 다만 Euler 생태계 도구가 이 볼트를 찾지
///      못합니다.
contract CollateralVaultFactory {
    error E_AlreadyDeployed(address borrower, address asset, address vault);
    error E_ZeroAddress();
    error E_DeploymentFailed();

    event VaultDeployed(address indexed borrower, address indexed asset, address vault, bytes32 salt);

    /// @notice 볼트 구현. BeaconProxy가 이 값을 읽어갑니다. 교체 함수는 없습니다.
    address public immutable implementation;

    /// @notice 볼트가 참조할 오라클. 라우터를 두어 어댑터 교체 시 주소가 바뀌지 않게 합니다.
    address public immutable oracle;

    /// @notice 담보 평가 단위.
    address public immutable unitOfAccount;

    /// @notice (차입자, 자산) 쌍에서 배포된 볼트로의 역조회.
    mapping(address borrower => mapping(address asset => address vault)) public vaultOf;

    constructor(address implementation_, address oracle_, address unitOfAccount_) {
        if (implementation_ == address(0) || oracle_ == address(0) || unitOfAccount_ == address(0)) {
            revert E_ZeroAddress();
        }
        implementation = implementation_;
        oracle = oracle_;
        unitOfAccount = unitOfAccount_;
    }

    /// @notice salt는 차입자와 자산의 쌍입니다.
    /// @dev 자산을 포함시키는 이유는 확장 때문입니다. 차입자 주소만 쓰면 자산이 늘 때
    ///      새 팩토리를 배포해야 하고, 팩토리 주소가 바뀌면 기존 볼트 주소 계산이 전부
    ///      무효가 됩니다. 자산을 salt에 넣으면 같은 팩토리에서 계속 확장됩니다.
    ///
    ///      대여자는 salt에 넣지 않습니다. 담보 볼트는 자산별로 하나면 되고, 여러
    ///      대여자와의 동시 거래는 EVC 서브계정으로 가릅니다(백서 7.1절).
    function saltFor(address borrower, address asset) public pure returns (bytes32) {
        return keccak256(abi.encode(borrower, asset));
    }

    /// @notice 배포될 볼트의 주소를 미리 계산합니다.
    /// @dev 투자자가 이 함수 없이 오프체인에서 같은 계산을 수행해 대조할 수 있어야 합니다.
    ///      필요한 값은 팩토리 주소, salt, BeaconProxy creationCode, trailingData입니다.
    function computeAddress(address borrower, address asset) public view returns (address) {
        bytes32 salt = saltFor(borrower, asset);
        bytes memory trailingData = abi.encodePacked(bytes4(0), asset, oracle, unitOfAccount);
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(trailingData)));

        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    /// @notice 볼트를 배포합니다. 누구나 호출할 수 있습니다.
    /// @dev 주소가 (차입자, 자산)으로 결정되므로 제3자가 대신 배포해도 결과가 같습니다.
    ///      Radius 백엔드가 온보딩 중에 대신 부르는 경우를 위해 열어둡니다.
    ///      배포 자체는 아무 권한도 만들지 않습니다. 명부 등록과 KYC NFT 발행은 별개이며
    ///      투자자 서명이 필요합니다.
    function deploy(address borrower, address asset) external returns (address vault) {
        if (borrower == address(0) || asset == address(0)) revert E_ZeroAddress();

        address existing = vaultOf[borrower][asset];
        if (existing != address(0)) revert E_AlreadyDeployed(borrower, asset, existing);

        bytes32 salt = saltFor(borrower, asset);
        bytes memory trailingData = abi.encodePacked(bytes4(0), asset, oracle, unitOfAccount);

        vault = address(new BeaconProxy{salt: salt}(trailingData));
        if (vault == address(0)) revert E_DeploymentFailed();

        vaultOf[borrower][asset] = vault;

        // 볼트 거버넌스는 호출자에게 갑니다. 훅 설정과 초기 구성에 필요합니다.
        IInitializable(vault).initialize(msg.sender);

        emit VaultDeployed(borrower, asset, vault, salt);
    }

    /// @notice 오프체인 검증용. BeaconProxy 바이트코드 해시를 노출합니다.
    /// @dev 투자자가 이 값을 독립적으로 계산해 대조하면 팩토리가 다른 코드를 배포하지
    ///      않는다는 것을 확인할 수 있습니다.
    function proxyInitCodeHash(address asset) external view returns (bytes32) {
        bytes memory trailingData = abi.encodePacked(bytes4(0), asset, oracle, unitOfAccount);
        return keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(trailingData)));
    }
}
