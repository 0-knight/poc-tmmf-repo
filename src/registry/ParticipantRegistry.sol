// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IComplianceGate} from "../interfaces/IComplianceGate.sol";

/// @title ParticipantRegistry
/// @notice "이 주소가 담보 레그에 있어도 되는가"의 단일 출처.
///
/// @dev 전까지 이 판정이 `RepoOpener.open` 안에만 있었습니다. 개시는 막혔지만 그 뒤로는
///      아무도 보지 않았습니다. 구멍이 둘이었습니다.
///
///        1. 대여자가 부채 볼트에 직접 `deposit` 하면 게이트를 안 탑니다. 대여자는
///           청산 시 담보를 직접 받으므로(백서 3.5절) 그 자리에 자격 없는 주소가 앉으면
///           청산이 실패합니다.
///        2. 청산 시 담보 압류의 **수령자**를 아무도 확인하지 않았습니다. EVK 압류는
///           볼트 share만 옮기므로 WTGXX의 화이트리스트가 발동하지 않습니다. 자격 없는
///           청산인이 share를 받고, 그 다음 인출에서 처음 막힙니다 — 그때는 이미 부채를
///           인수해 버린 뒤입니다.
///
///      **게이트와 승인 목록의 OR 입니다.** 게이트는 이슈어의 실시간 판정이고, 승인
///      목록은 그것이 답하지 못할 때의 대비입니다. WTGXX의 컴플라이언스 컨트랙트가
///      제거되거나 오라클이 꺼지면 `canEnter` 는 모두에게 false 를 돌려주고, 그러면
///      진행 중인 청산이 영구히 막힙니다. 백서 6.2절이 적은 상황입니다.
///
///      **승인 목록이 불법 전송을 만들 수는 없습니다.** 승인은 볼트 share 수령만 열어
///      줍니다. 실제 WTGXX는 그 다음 `withdraw` 에서 나가고 거기서 이슈어의 화이트
///      리스트를 그대로 탑니다. 즉 이 목록은 "청구권을 들고 기다릴 수 있는 자"를 정하고,
///      "토큰을 받을 수 있는 자"는 여전히 WisdomTree가 정합니다.
///
///      게이트 주소가 0이어도 됩니다. 그 경우 승인 목록만으로 판정합니다 — 규제 자산이
///      아닌 담보로 같은 구조를 돌릴 때의 설정입니다.
contract ParticipantRegistry {
    error E_ZeroAddress();
    error E_NotAdmin();

    event ApprovalSet(address indexed who, bool approved, address indexed by);

    /// @notice 이슈어 쪽 실시간 판정. 0이면 승인 목록만 봅니다.
    IComplianceGate public immutable gate;

    /// @notice 승인 목록을 고칠 수 있는 주체.
    /// @dev PoC에서는 배포자 EOA입니다. 프로덕션에서는 운영 멀티시그 자리입니다.
    address public immutable admin;

    /// @notice 게이트가 답하지 못할 때 쓰는 대비 목록.
    mapping(address who => bool) public approved;

    constructor(address gate_, address admin_) {
        if (admin_ == address(0)) revert E_ZeroAddress();
        gate = IComplianceGate(gate_);
        admin = admin_;
    }

    function setApproved(address who, bool value) external {
        if (msg.sender != admin) revert E_NotAdmin();
        if (who == address(0)) revert E_ZeroAddress();

        approved[who] = value;
        emit ApprovalSet(who, value, msg.sender);
    }

    /// @notice 이 주소가 담보 레그에 있어도 되는지.
    /// @dev 절대 revert하지 않습니다. IComplianceGate 의 규약과 같습니다 — 이 판정이
    ///      revert하면 청산 트랜잭션 전체가 죽고 사유를 구분할 수 없습니다.
    function isEligible(address who) public view returns (bool) {
        if (who == address(0)) return false;
        if (approved[who]) return true;

        (bool answered, bool allowed) = gateSays(who);
        return answered && allowed;
    }

    /// @notice 게이트가 답했는지와 그 답을 따로 돌려줍니다. 진단용입니다.
    ///
    /// @dev 게이트 구현체는 revert하지 않기로 약속했지만, 약속에 기대지 않고 staticcall로
    ///      감쌉니다. 게이트가 교체되거나 WTGXX 쪽 인터페이스가 바뀌어도 이 레지스트리는
    ///      멈추지 않아야 합니다.
    ///
    ///      `answered == false` 는 "게이트가 고장났다"는 뜻이고, 그때 승인 목록이
    ///      유일한 판단 근거가 됩니다. 운영에서 감시할 신호입니다.
    function gateSays(address who) public view returns (bool answered, bool allowed) {
        if (address(gate) == address(0)) return (false, false);

        (bool ok, bytes memory data) =
            address(gate).staticcall(abi.encodeCall(IComplianceGate.canEnter, (who)));

        if (!ok || data.length < 32) return (false, false);
        return (true, abi.decode(data, (bool)));
    }

    /// @notice 게이트는 거부했지만 승인 목록으로 통과한 경우. 감시 항목입니다.
    function isEligibleOnlyByApproval(address who) external view returns (bool) {
        if (!approved[who]) return false;
        (bool answered, bool allowed) = gateSays(who);
        return !(answered && allowed);
    }
}
