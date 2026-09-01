// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IWTGXX} from "../interfaces/IWTGXX.sol";

/// @title WTGXXGate
/// @notice 백서 6장의 게이트. 진입만 막고 출구는 통과시킵니다.
///
/// @dev 이 컨트랙트를 쓰는 이유는 하나입니다. WisdomTree가 토큰의 컴플라이언스 주소를
///      0으로 지우면 isAddressWhitelisted가 무조건 true를 반환합니다(검증 소스 251~257행).
///      토큰만 믿으면 그 순간 게이트가 무력화됩니다. 여기서 getCompliance() != 0을
///      먼저 확인해 그 경로를 막습니다.
///
///      상환·인출 경로에서는 호출하지 마세요. 백서 6.1절은 출구 무검사를 요구합니다.
///      참여자가 나중에 화이트리스트에서 빠져도 담보를 되찾을 수 있어야 합니다.
///      그렇지 않으면 접근 통제가 아니라 수탁이 됩니다.
///
///      모든 외부 호출을 staticcall로 처리합니다. 고수준 호출은 코드 없는 주소에 대해
///      extcodesize 검사에서 revert하며 try/catch로 잡히지 않습니다. 게이트가 revert하면
///      호출한 트랜잭션 전체가 죽으므로 판정 결과로만 답해야 합니다.
contract WTGXXGate {
    error ZeroAddress();

    /// @notice canEnter가 false를 반환한 이유. 진단과 UI 표시용입니다.
    enum Reason {
        Allowed,
        ZeroTarget,
        ComplianceRemoved,
        TokenPaused,
        AccountFrozen,
        NotWhitelisted,
        CallFailed
    }

    IWTGXX public immutable token;

    constructor(address token_) {
        if (token_ == address(0)) revert ZeroAddress();
        token = IWTGXX(token_);
    }

    /// @notice 진입 자격을 판정합니다. 어떤 경우에도 revert하지 않습니다.
    function canEnter(address who) external view returns (bool) {
        return checkEntry(who) == Reason.Allowed;
    }

    /// @notice canEnter와 같은 판정에 사유를 함께 돌려줍니다.
    function checkEntry(address who) public view returns (Reason) {
        // 오라클이 to == address(0)에 revert하므로 먼저 걸러냅니다.
        if (who == address(0)) return Reason.ZeroTarget;

        // 이 검사가 이 컨트랙트의 존재 이유입니다. 토큰은 이 상태에서 true를 반환합니다.
        (bool ok, uint256 word) = _staticWord(abi.encodeCall(IWTGXX.getCompliance, ()));
        if (!ok) return Reason.CallFailed;
        if (address(uint160(word)) == address(0)) return Reason.ComplianceRemoved;

        (ok, word) = _staticWord(abi.encodeCall(IWTGXX.isPaused, ()));
        if (!ok) return Reason.CallFailed;
        if (word != 0) return Reason.TokenPaused;

        (ok, word) = _staticWord(abi.encodeCall(IWTGXX.isFrozen, (who)));
        if (!ok) return Reason.CallFailed;
        if (word != 0) return Reason.AccountFrozen;

        // from과 amount는 현재 오라클 구현에서 무시됩니다. 자리만 채웁니다.
        (ok, word) = _staticWord(abi.encodeCall(IWTGXX.isAddressWhitelisted, (address(0), who, 0)));
        if (!ok) return Reason.CallFailed;

        return word != 0 ? Reason.Allowed : Reason.NotWhitelisted;
    }

    /// @dev 한 워드를 반환하는 view 호출. 실패·빈 응답·코드 없는 주소를 전부 흡수합니다.
    function _staticWord(bytes memory callData) internal view returns (bool ok, uint256 word) {
        address target = address(token);
        if (target.code.length == 0) return (false, 0);

        (bool success, bytes memory ret) = target.staticcall(callData);
        if (!success || ret.length < 32) return (false, 0);

        word = abi.decode(ret, (uint256));
        return (true, word);
    }
}
