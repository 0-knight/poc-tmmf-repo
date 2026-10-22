// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IHookTarget} from "evk/interfaces/IHookTarget.sol";

import {ParticipantRegistry} from "../registry/ParticipantRegistry.sol";
import {MaturityRegistry} from "../registry/MaturityRegistry.sol";

/// @title DebtVaultAccessHook
/// @notice 부채 볼트의 **입구**에 자격 검사를 붙입니다. 출구에는 붙이지 않습니다.
///
/// @dev 전까지 부채 볼트는 훅이 없었습니다(`setHookConfig(address(0), 0)`). 그래서
///      `RepoOpener` 가 "개시의 유일한 경로"라고 적혀 있어도 코드로는 그렇지 않았습니다.
///
///        - 대여자가 `deposit` 을 직접 불러 자격 검사 없이 자금을 넣을 수 있었습니다.
///          대여자는 청산 시 담보를 직접 받으므로(백서 3.5절) 그 자리에 자격 없는
///          주소가 앉으면 청산이 인출 단계에서 실패합니다.
///        - 차입자가 `borrow` 를 직접 불러 게이트와 만기 기록을 건너뛸 수 있었습니다.
///          `DeployStack.t.sol` 의 `test_openAndRepay` 가 실제로 그렇게 돌고 있었습니다.
///          기록이 남지 않으면 백서 4.4절의 청산 사유가 사라집니다.
///
///      막는 연산은 넷입니다 — 입금·발행·스킴·차입. **상환·청산·인출·환매는 건드리지
///      않습니다.** 백서 6.1절의 출구 무검사이며, 자격을 잃은 참여자도 빠져나올 수
///      있어야 접근 통제이고 수탁이 아닙니다.
///
///      입금 계열은 호출자와 **수령자 둘 다** 봅니다. 자격 있는 주소가 자격 없는 주소에
///      share를 발행해 주면 검사를 한 바퀴 돌아 무력화됩니다.
///
///      차입은 자격 외에 **만기 기록**도 봅니다. 자격만 보면 자격 있는 차입자가
///      `RepoOpener` 를 건너뛰고 직접 빌릴 수 있고, 그러면 만기 레지스트리에 아무것도
///      남지 않아 `MaturityController` 가 발동할 근거가 사라집니다. 그래서 차입 시점에
///      그 계정의 기록이 시장 만기와 일치하는지 확인합니다. `RepoOpener.open` 이 같은
///      트랜잭션에서 차입보다 **먼저** 기록하므로 정상 경로는 그대로 통과합니다.
///
///      차입으로 나가는 USDC의 수령자는 보지 않습니다. 그쪽에는 제약이 없습니다.
///
///      **만기 후에는 이 훅이 비켜납니다.** `MaturityController` 가 시장을 닫을 때
///      `setHookConfig(address(0), CLOSED_OPS)` 로 같은 연산들을 아예 비활성화합니다.
///      두 설정의 연산 집합이 같아야 하며, 어긋나면 만기에 일부 입구가 다시 열립니다.
///      `DeployStack._verify` 가 그 일치를 확인합니다.
contract DebtVaultAccessHook is IHookTarget {
    error E_NotEligible(address who);
    error E_NoMaturityRecord(address borrower);
    error E_MaturityRecordMismatch(address borrower, uint256 recorded, uint256 market);
    error E_ZeroAddress();

    ParticipantRegistry public immutable registry;
    MaturityRegistry public immutable maturities;

    /// @notice 이 훅이 붙은 부채 볼트. 시장 만기를 찾는 열쇠입니다.
    address public immutable debtVault;

    constructor(address registry_, address maturities_, address debtVault_) {
        if (registry_ == address(0) || maturities_ == address(0) || debtVault_ == address(0)) {
            revert E_ZeroAddress();
        }
        registry = ParticipantRegistry(registry_);
        maturities = MaturityRegistry(maturities_);
        debtVault = debtVault_;
    }

    function isHookTarget() external pure returns (bytes4) {
        return this.isHookTarget.selector;
    }

    fallback() external {
        bytes4 selector = bytes4(msg.data[0:4]);

        address caller = _caller();
        if (!registry.isEligible(caller)) revert E_NotEligible(caller);

        // 입금 계열은 수령자도 봅니다. `(uint256 amount, address receiver)` 형태라
        // 두 번째 워드가 수령자입니다.
        if (
            selector == bytes4(keccak256("deposit(uint256,address)"))
                || selector == bytes4(keccak256("mint(uint256,address)"))
                || selector == bytes4(keccak256("skim(uint256,address)"))
        ) {
            address receiver = _secondAddressArg();
            if (!registry.isEligible(receiver)) revert E_NotEligible(receiver);
            return;
        }

        // 차입은 만기 기록도 봅니다. RepoOpener 를 건너뛴 직접 차입을 막습니다.
        if (selector == bytes4(keccak256("borrow(uint256,address)"))) {
            uint256 recorded = maturities.maturityOf(caller);
            if (recorded == 0) revert E_NoMaturityRecord(caller);

            uint256 market = maturities.marketMaturity(debtVault);
            if (recorded != market) revert E_MaturityRecordMismatch(caller, recorded, market);
        }
    }

    /// @dev EVK가 calldata 맨 뒤에 붙인 20바이트. EVC 경유 호출이면 onBehalfOfAccount
    ///      입니다(`Base.initOperation` 이 `EVCAuthenticateDeferred` 의 결과를 넘깁니다).
    ///      그래서 `RepoOpener` 가 operator로 대신 부른 차입도 차입자로 판정됩니다.
    function _caller() internal pure returns (address account) {
        assembly {
            account := shr(96, calldataload(sub(calldatasize(), 20)))
        }
    }

    /// @dev 셀렉터 뒤 두 번째 32바이트 워드의 하위 20바이트.
    function _secondAddressArg() internal pure returns (address arg) {
        assembly {
            arg := and(calldataload(36), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }
}
