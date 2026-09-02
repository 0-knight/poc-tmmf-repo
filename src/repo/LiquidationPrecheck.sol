// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IWTGXX} from "../interfaces/IWTGXX.sol";

/// @title LiquidationPrecheck
/// @notice 청산 전에 WTGXX가 실제로 움직일 수 있는지 확인합니다.
///
/// @dev EVK의 청산은 담보 볼트 share를 이전할 뿐 WTGXX를 만지지 않습니다. 화이트리스트도
///      동결도 일시정지도 타지 않습니다. **청산이 성공했다는 것이 담보를 확보했다는 뜻이
///      아닙니다.** 실제 토큰은 그다음 인출에서 나오고, 거기서 처음 규제 자산 제약에
///      부딪힙니다.
///
///      확인하지 않고 청산하면 대여자가 share만 들고 앉게 됩니다. 청산은 이미 끝났고
///      되돌릴 방법이 없습니다. 그래서 청산 전과 인출 직전 두 번 봅니다.
///
///      검사 항목은 검증 소스에서 확인한 가드 배치를 따릅니다.
///
///        transfer(to, value)  notPaused · notFrozen(msg.sender) · notFrozen(to)
///                             + 오라클 화이트리스트는 to 만
///
///      담보 볼트가 발신자이고 대여자가 수신자이므로 셋을 봅니다. 동결은 세 주소를 다
///      보지만 화이트리스트는 목적지 하나만 봅니다. 층이 다릅니다.
contract LiquidationPrecheck {
    error E_ZeroAddress();

    /// @notice 인출이 막히는 사유. UI 표시와 로그용입니다.
    enum Blocker {
        None,
        TokenPaused,
        VaultFrozen,
        RecipientFrozen,
        RecipientNotWhitelisted,
        ComplianceRemoved,
        CallFailed
    }

    IWTGXX public immutable token;

    constructor(address token_) {
        if (token_ == address(0)) revert E_ZeroAddress();
        token = IWTGXX(token_);
    }

    /// @notice 담보 볼트에서 수령자로 WTGXX가 나갈 수 있는지 봅니다.
    /// @dev 어떤 경우에도 revert하지 않습니다. 판정 결과로만 답합니다.
    function canSettle(address collateralVault, address recipient) external view returns (bool) {
        return check(collateralVault, recipient) == Blocker.None;
    }

    /// @notice canSettle 과 같은 판정에 사유를 함께 돌려줍니다.
    function check(address collateralVault, address recipient) public view returns (Blocker) {
        if (collateralVault == address(0) || recipient == address(0)) return Blocker.CallFailed;

        (bool ok, uint256 word) = _staticWord(abi.encodeCall(IWTGXX.isPaused, ()));
        if (!ok) return Blocker.CallFailed;
        if (word != 0) return Blocker.TokenPaused;

        (ok, word) = _staticWord(abi.encodeCall(IWTGXX.isFrozen, (collateralVault)));
        if (!ok) return Blocker.CallFailed;
        if (word != 0) return Blocker.VaultFrozen;

        (ok, word) = _staticWord(abi.encodeCall(IWTGXX.isFrozen, (recipient)));
        if (!ok) return Blocker.CallFailed;
        if (word != 0) return Blocker.RecipientFrozen;

        // 오라클이 제거되면 화이트리스트가 무조건 통과합니다. 그 상태를 구분해 알립니다.
        // 청산 경로에서는 통과가 유리하지만, 게이트 무력화 신호이므로 사유로 남깁니다.
        (ok, word) = _staticWord(abi.encodeCall(IWTGXX.getCompliance, ()));
        if (!ok) return Blocker.CallFailed;
        bool complianceRemoved = address(uint160(word)) == address(0);

        (ok, word) = _staticWord(abi.encodeCall(IWTGXX.isAddressWhitelisted, (collateralVault, recipient, 0)));
        if (!ok) return Blocker.CallFailed;
        if (word == 0) return Blocker.RecipientNotWhitelisted;

        return complianceRemoved ? Blocker.ComplianceRemoved : Blocker.None;
    }

    function _staticWord(bytes memory callData) internal view returns (bool ok, uint256 word) {
        address target = address(token);
        if (target.code.length == 0) return (false, 0);

        (bool success, bytes memory ret) = target.staticcall(callData);
        if (!success || ret.length < 32) return (false, 0);

        return (true, abi.decode(ret, (uint256)));
    }
}
