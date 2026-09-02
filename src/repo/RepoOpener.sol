// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {WTGXXGate} from "../gate/WTGXXGate.sol";
import {MaturityRegistry} from "../registry/MaturityRegistry.sol";

/// @dev encodeCall 용 최소 선언. IEVault는 여러 인터페이스를 상속한 합성 타입이라
///      상속된 멤버로 함수 포인터를 만들 수 없습니다.
interface IVaultCalls {
    function deposit(uint256 amount, address receiver) external returns (uint256);
    function borrow(uint256 amount, address receiver) external returns (uint256);
    function asset() external view returns (address);
}

interface IEVCLike {
    function call(address targetContract, address onBehalfOfAccount, uint256 value, bytes calldata data)
        external
        payable
        returns (bytes memory result);

    function enableCollateral(address account, address vault) external payable;
    function enableController(address account, address vault) external payable;
    function isAccountOperatorAuthorized(address account, address operator) external view returns (bool);
    function haveCommonOwner(address account, address otherAccount) external pure returns (bool);
}

/// @title RepoOpener
/// @notice 대출 개시의 유일한 경로. 게이트 통과와 만기 기록을 강제합니다.
///
/// @dev 이 컨트랙트가 없으면 게이트가 장식입니다. 차입자가 부채 볼트의 borrow를 직접
///      부르면 화이트리스트 확인을 건너뛸 수 있고, 만기 레지스트리에 아무것도 남지 않아
///      백서 4.4절의 청산 사유가 사라집니다. 개시 경로를 여기 하나로 좁혀 그 두 가지를
///      강제합니다.
///
///      **차입자 계정의 EVC operator로 등록되어야 합니다.** EVC operator 권한은 동작별로
///      쪼갤 수 없고 계정 전체에 걸립니다(백서 7.1절). 방어는 컨트랙트를 좁게 유지하는
///      것뿐이며, 백서 4.1절이 RehypoManager에 요구한 것과 같습니다.
///
///        - 불변 배포. 업그레이드 경로 없음
///        - 노출 함수는 open 하나
///        - 호출 대상을 생성자에서 고정. 인자로 받은 임의 주소를 호출하지 않음
///        - 임의 calldata를 실행하는 경로 없음
///
///      **상환과 인출은 이 컨트랙트를 거치지 않습니다.** 백서 6.1절이 출구 무검사를
///      요구합니다. 차입자는 부채 볼트와 담보 볼트를 직접 호출해 종료하며, 이 컨트랙트에
///      버그가 있어도 담보가 갇히지 않습니다. operator 권한도 차입자가 언제든 취소할 수
///      있습니다.
contract RepoOpener {
    error E_ZeroAddress();
    error E_NotOperator(address borrower);
    error E_BorrowerNotEligible(address borrower);
    error E_LenderNotEligible(address lender);
    error E_MaturityNotInFuture(uint256 maturity);
    error E_ZeroPrincipal();
    error E_VaultMismatch(address expected, address given);

    event RepoOpened(
        address indexed borrower,
        address indexed lender,
        address collateralVault,
        uint256 collateralAmount,
        uint256 principal,
        uint256 maturity
    );

    IEVCLike public immutable evc;
    WTGXXGate public immutable gate;
    MaturityRegistry public immutable maturityRegistry;

    /// @notice 이 컨트랙트가 호출할 수 있는 유일한 부채 볼트.
    /// @dev 인자로 받지 않습니다. 임의 볼트를 차입자 권한으로 부르는 경로를 막습니다.
    address public immutable debtVault;

    /// @notice 담보 자산. 볼트가 이 자산을 담는지 확인합니다.
    address public immutable collateralAsset;

    constructor(address evc_, address gate_, address maturityRegistry_, address debtVault_, address collateralAsset_) {
        if (
            evc_ == address(0) || gate_ == address(0) || maturityRegistry_ == address(0) || debtVault_ == address(0)
                || collateralAsset_ == address(0)
        ) revert E_ZeroAddress();

        evc = IEVCLike(evc_);
        gate = WTGXXGate(gate_);
        maturityRegistry = MaturityRegistry(maturityRegistry_);
        debtVault = debtVault_;
        collateralAsset = collateralAsset_;
    }

    /// @notice 담보를 예치하고 대출을 엽니다. 게이트와 만기가 함께 강제됩니다.
    ///
    /// @param collateralVault 차입자의 담보 볼트. 팩토리가 배포한 것이어야 합니다.
    /// @param collateralAmount 예치할 담보 수량. 이 컨트랙트 호출 전에 볼트에 approve 필요.
    /// @param principal 차입할 대여 자산 수량.
    /// @param maturity 만기 타임스탬프. 절대 시각입니다. 백서 3.1절.
    ///
    /// @dev 호출자가 차입자입니다. 서브계정에서 열려면 그 서브계정이 호출해야 하며,
    ///      operator 등록도 서브계정마다 별도로 필요합니다.
    ///
    ///      대여자 자격도 확인합니다. 백서 3.5절 — 청산 시 대여자가 담보를 직접 받아야
    ///      하므로 진입 시점에 자격이 확인되어 있어야 합니다. 6.2절도 게이트 자격 집합이
    ///      이슈어 화이트리스트와 어긋나면 청산이 실패한다고 적습니다.
    function open(
        address collateralVault,
        uint256 collateralAmount,
        uint256 principal,
        uint256 maturity,
        address lender
    ) external {
        address borrower = msg.sender;

        if (principal == 0) revert E_ZeroPrincipal();
        if (maturity <= block.timestamp) revert E_MaturityNotInFuture(maturity);

        // operator가 아니면 아래 EVC 호출이 실패하지만, 사유를 명확히 하기 위해 먼저 봅니다.
        if (!evc.isAccountOperatorAuthorized(borrower, address(this))) revert E_NotOperator(borrower);

        // 볼트가 담보 자산을 담는지 확인합니다. 임의 볼트를 넘기는 것을 막습니다.
        address vaultAsset = IVaultCalls(collateralVault).asset();
        if (vaultAsset != collateralAsset) revert E_VaultMismatch(collateralAsset, vaultAsset);

        // 백서 6장. 진입에만 검사하며 출구에는 적용하지 않습니다.
        if (!gate.canEnter(borrower)) revert E_BorrowerNotEligible(borrower);
        if (!gate.canEnter(lender)) revert E_LenderNotEligible(lender);

        // 만기를 먼저 기록합니다. 개시가 실패하면 이 기록도 함께 되돌아갑니다.
        maturityRegistry.setMaturity(borrower, maturity);

        // 담보 예치. 차입자 권한으로 실행되며 훅이 소유자 여부를 확인합니다.
        if (collateralAmount > 0) {
            evc.call(collateralVault, borrower, 0, abi.encodeCall(IVaultCalls.deposit, (collateralAmount, borrower)));
        }

        evc.enableCollateral(borrower, collateralVault);
        evc.enableController(borrower, debtVault);

        evc.call(debtVault, borrower, 0, abi.encodeCall(IVaultCalls.borrow, (principal, borrower)));

        emit RepoOpened(borrower, lender, collateralVault, collateralAmount, principal, maturity);
    }
}
