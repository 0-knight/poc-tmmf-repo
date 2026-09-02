// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IHookTarget} from "evk/interfaces/IHookTarget.sol";

interface IEVCLike {
    function haveCommonOwner(address account, address otherAccount) external pure returns (bool);

    /// @notice 등록된 컨트롤러가 담보를 압류하는 중인지 알려줍니다.
    function isControlCollateralInProgress() external view returns (bool);
}

/// @title CollateralVaultHook
/// @notice 담보 볼트의 ERC-4626 성질 중 두 가지를 막습니다.
///
/// @dev 담보 볼트가 EVK인 이유는 부채 볼트와 붙기 위해서입니다. 그 대가로 ERC-4626이
///      딸려오고, 그대로 두면 백서 두 조항이 깨집니다.
///
///      **share 전송** — share는 전송 가능한 ERC-20입니다. 차입자가 이를 비인가 주소에
///      넘기면 WTGXX의 경제적 소유가 이전 대리인 명부 밖으로 나갑니다. 토큰은 볼트에
///      그대로 있어 화이트리스트도 게이트도 감지하지 못합니다. 백서 2.1절이 거부한
///      "자유롭게 유통되는 래퍼 토큰"이 의도치 않게 생깁니다.
///
///      **타인 예치** — 볼트는 투자자 한 명 전용이어야 합니다. 백서 2.2절의 "투자자당
///      식별 가능한 주소 하나"가 깨지면 이전 대리인이 누가 얼마를 보유하는지 알 수
///      없습니다. 공유 풀이 규제 자산을 담보로 못 쓰는 이유와 같습니다(1.1절).
///
///      단, EVC 서브계정은 허용해야 합니다. 계정당 컨트롤러가 하나뿐이라 차입자가 동시에
///      여러 대여자와 거래하려면 서브계정을 나눠야 합니다(백서 7.1절). 서브계정은 주소
///      하위 1바이트를 XOR한 것이므로 haveCommonOwner로 판별합니다. 서브계정은 볼트
///      share만 보유하고 WTGXX를 직접 만지지 않으므로 별도 화이트리스트가 필요 없습니다.
///
///      출금은 막지 않습니다. 백서 6.1절이 출구 무검사를 요구합니다. 부채가 남아 있으면
///      EVC의 계정 상태 검사가 막으며, 이 훅이 판단할 일이 아닙니다.
///
///      **청산 시 담보 압류도 막으면 안 됩니다.** EVK는 압류를
///      `evc.controlCollateral(collateral, violator, 0, transfer(receiver, amount))`로
///      수행합니다(EVCClient.sol:102). share 전송을 무조건 막으면 이 경로가 함께 막혀
///      대여자가 담보를 회수할 방법이 사라집니다. 백서 6.1절이 "collateral recovery still
///      go through"라고 못박은 지점입니다.
///
///      EVC의 `isControlCollateralInProgress()`가 이 문맥을 구분합니다. 참이면 등록된
///      컨트롤러가 압류하는 중이고, EVC가 이미 자격을 검증했습니다. 임의 전송은 이
///      플래그가 거짓이므로 계속 막힙니다.
contract CollateralVaultHook is IHookTarget {
    error E_ShareTransferDisabled();
    error E_DepositorNotOwner(address caller);
    error E_ZeroAddress();

    /// @notice 이 볼트를 소유한 투자자. 서브계정은 이 주소에서 파생됩니다.
    address public immutable owner;

    IEVCLike internal immutable evc;

    constructor(address evc_, address owner_) {
        if (evc_ == address(0) || owner_ == address(0)) revert E_ZeroAddress();
        evc = IEVCLike(evc_);
        owner = owner_;
    }

    function isHookTarget() external pure returns (bytes4) {
        return this.isHookTarget.selector;
    }

    /// @notice 훅으로 걸린 모든 호출이 여기로 들어옵니다.
    ///
    /// @dev EVK는 원래 calldata 뒤에 caller(20바이트)를 붙여 이 컨트랙트를 call합니다
    ///      (`Base.sol` invokeHookTarget). 셀렉터로 분기하고, 거부할 때 revert하면 볼트
    ///      작업 전체가 취소됩니다.
    ///
    ///      정상 통과는 조용히 반환합니다. EVK는 반환값을 보지 않고 성공 여부만 봅니다.
    fallback() external {
        bytes4 selector = bytes4(msg.data[0:4]);

        // share 전송은 막되, 컨트롤러의 담보 압류는 통과시킵니다.
        if (
            selector == bytes4(keccak256("transfer(address,uint256)"))
                || selector == bytes4(keccak256("transferFrom(address,address,uint256)"))
                || selector == bytes4(keccak256("transferFromMax(address,address)"))
        ) {
            if (!evc.isControlCollateralInProgress()) revert E_ShareTransferDisabled();
            return;
        }

        // 예치는 소유자와 그 서브계정만 허용합니다.
        if (
            selector == bytes4(keccak256("deposit(uint256,address)"))
                || selector == bytes4(keccak256("mint(uint256,address)"))
                || selector == bytes4(keccak256("skim(uint256,address)"))
        ) {
            address caller = _caller();
            if (!evc.haveCommonOwner(caller, owner)) revert E_DepositorNotOwner(caller);
        }
    }

    /// @dev EVK가 calldata 맨 뒤에 붙인 20바이트를 읽습니다.
    function _caller() internal pure returns (address account) {
        assembly {
            account := shr(96, calldataload(sub(calldatasize(), 20)))
        }
    }
}
