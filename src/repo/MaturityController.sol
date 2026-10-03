// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MaturityRegistry} from "../registry/MaturityRegistry.sol";

// 만기에 비활성화되는 연산 집합. EVK Constants.sol 의 비트와 같습니다 —
// OP_DEPOSIT | OP_MINT | OP_SKIM | OP_BORROW.
//
// 파일 레벨 상수인 이유는 배포 스크립트와 테스트가 이 이름 하나를 함께 쓰기
// 때문입니다. DebtVaultAccessHook 이 만기 전에 자격 검사로 거르는 연산 집합과
// **정확히 같아야** 하며, 어긋나면 시장을 닫는 순간 일부 입구가 자격 검사 없이
// 다시 열립니다. DeployStack._verify 가 그 일치를 봅니다.
//
// 상환·청산·인출·환매는 빠져 있습니다. 백서 6.1절의 출구 무검사입니다.
uint32 constant MATURITY_CLOSED_OPS = (1 << 0) | (1 << 1) | (1 << 5) | (1 << 6);

/// @dev 부채 볼트의 거버넌스 표면 중 이 컨트랙트가 쓰는 부분만 선언합니다. IEVault는 여러
///      인터페이스를 상속한 합성 타입이라 그대로 들고 오면 불필요한 의존이 붙습니다.
interface IDebtVaultGovernance {
    function LTVBorrow(address collateral) external view returns (uint16);
    function LTVLiquidation(address collateral) external view returns (uint16);
    function setLTV(address collateral, uint16 borrowLTV, uint16 liquidationLTV, uint32 rampDuration) external;
    function setInterestRateModel(address newModel) external;
    function setHookConfig(address newHookTarget, uint32 newHookedOps) external;
    function governorAdmin() external view returns (address);
    function interestRateModel() external view returns (address);
    function hookConfig() external view returns (address, uint32);
}

/// @dev 통지 권한 판정에 쓰는 EVC 표면만 선언합니다.
interface IEVCLike {
    function haveCommonOwner(address account, address otherAccount) external pure returns (bool);
    function isAccountOperatorAuthorized(address account, address operator) external view returns (bool);
}

/// @dev 차입자가 그 담보 볼트의 지분을 들고 있는지 확인합니다.
interface IShares {
    function balanceOf(address account) external view returns (uint256);
}

/// @title MaturityController
/// @notice 만기 경과를 EVK가 알아듣는 동작으로 바꿉니다. 백서 4.4절.
///
/// @dev **이 컨트랙트가 부채 볼트의 거버너입니다.** 그래야 setLTV를 부를 수 있습니다.
///      전까지는 배포자 EOA가 거버너였고, 테스트가 `setLTV(담보, 0.7, 0.7, 0)`을 직접
///      불러 청산을 열었습니다. 사람이 손으로 내리는 숫자였으니 "만기가 지나면 청산된다"가
///      아니라 "거버너가 마음먹으면 청산된다"였습니다.
///
///      **시장을 닫는 것과 부도를 선언하는 것은 다릅니다.** 함수가 둘인 이유입니다.
///
///        closeMarket()                  누구나, 만기 즉시
///                                       부채 정지 + 신규 진입 차단
///        triggerMaturity(담보, 차입자)     통지 창 안에는 상대방만, 그 뒤 누구나
///                                       사다리 시작
///
///      부채를 멈추는 것은 **차입자에게 유리한** 조치라 아무나 불러도 됩니다 — 갚아야 할
///      금액이 그 순간 고정되고, 거기서부터 cure period가 시작됩니다. 반면 부도를
///      선언하는 것은 **대여자의 권리**입니다.
///
///      **백서 4.4절을 EVK 언어로 옮긴 방식.** 4.4절은 셋을 요구합니다 — 만기 경과 자체가
///      청산 사유이고, 할인은 0에서 시작해 선형으로 오르며, 연체 이자는 없다.
///
///        1. `setLTV(담보, 0, 개시LTV, 0)` — 청산선을 개시 한도까지 즉시 내립니다.
///           한도까지 끌어 쓴 포지션은 이 순간 담보와 부채가 같아지므로 **그 블록부터
///           청산 대상이고 할인은 0입니다.** 시작점을 상수로 박지 않고 볼트에서 읽는
///           이유가 여기 있습니다. 사다리의 출발점은 그 시장이 허용한 차입 한도입니다.
///        2. `setLTV(담보, 0, 0, rampDuration)` — 거기서 0까지 선형으로 내립니다. EVK가
///           시간에 비례해 청산선을 깎고(LTVConfig.getLTV), 청산 할인은
///           `1 - 조정담보/부채`이므로 할인도 선형으로 오릅니다.
///        3. 이자율 모델을 0 반환 모델로 바꿉니다. `setInterestRateModel`이 먼저
///           `updateVault()`로 그 시점까지 이자를 확정한 뒤 모델을 갈아끼우므로, 만기까지의
///           이자는 그대로 남고 이후만 멈춥니다. 소급이 없습니다.
///        4. 신규 진입을 막습니다. `setHookConfig(address(0), ...)`는 그 연산을 비활성화
///           합니다(Base.invokeHookTarget이 E_OperationDisabled로 되돌립니다). 입금·발행·
///           스킴·차입만 막고 **상환·청산·인출·환매는 건드리지 않습니다.** 백서 6.1절의
///           출구 무검사입니다.
///
///      3번과 4번은 `closeMarket`이, 1번과 2번은 `triggerMaturity`가 합니다.
///
///      **왜 청산선을 0까지 내리는가.** 할인은 `maxLiquidationDiscount`(2%)에서 멈추므로
///      사다리의 아래쪽 98%는 할인에 영향이 없습니다. 그래도 0까지 내려야 합니다. 한도를
///      덜 쓴 차입자는 담보가 부채보다 한참 많아서, 청산선이 그 비율 아래로 내려가야
///      비로소 청산 대상이 됩니다. 사다리에는 두 개의 시계가 있습니다.
///
///        청산이 열리는 시점   경과 = (1 - 부채/담보 ÷ 개시LTV) x rampDuration
///        할인이 상한에 닿는 시점  그로부터 약 maxDiscount ÷ 개시LTV x rampDuration
///
///      한도를 꽉 쓴 차입자는 종이 울리는 순간 청산 대상이고, 여유를 남긴 차입자는 그
///      여유가 먼저 소진됩니다. 담보가 많을수록 유예가 길다 — 의도한 성질입니다.
///
///      **통지 창 — GMRA 2011 ¶10.** 전통 repo는 만기 미지급을 자동 부도로 두지 않습니다.
///      ¶10(a)(i)은 비부도 당사자가 Default Notice를 보내야 성립한다고 적고, ¶10(b)는 그
///      통지까지 최대 20일을 줍니다. 대여자가 통지하지 않기로 선택하는 것 — forbearance —
///      이 차입자의 만회 기회입니다. 제3자가 끼어들어 부도를 선언하는 조항은 없습니다.
///
///      그래서 만기 후 `noticeWindow` 동안은 그 계약의 상대방만 부도를 선언합니다. 대리인은
///      EVC operator로 풀었습니다 — 새 레지스트리 없이 대여자 본인이
///      `evc.setAccountOperator`로 위임하며, 서브계정도 함께 통과합니다.
///
///      **창이 지나면 누구나 부릅니다.** 전통금융에 없는 백스톱이고, 필요한 이유는 둘입니다.
///      풀 볼트라 다른 대여자들 현금이 같이 묶이고, 대여자가 사라지면 포지션이 영원히 안
///      풀립니다. 전통금융은 법인과 법원이 뒤를 받치지만 프로토콜은 그렇지 않습니다.
///
///      **거버넌스를 되돌리는 경로를 두지 않았습니다.** 관리자 통로는 온보딩용
///      `configureCollateral` 하나뿐이고, 그것도 시장이 닫히거나 사다리가 시작된 뒤에는
///      막힙니다. `setGovernorAdmin`을 노출하지 않았으므로 **관리자가 LTV를 다시 올려
///      청산을 취소할 수 없습니다.** 이것이 "만기가 지나면 청산된다"를 코드로 성립시키는
///      조건입니다. 대가는 둘입니다 — 복구 경로가 없고, 한 번 닫힌 시장은 다시 열리지
///      않습니다. PoC에서는 그 대가를 받아들였고, 프로덕션에서는 타임락을 거버너로 두어
///      지연된 복구만 허용하는 것이 맞습니다.
contract MaturityController {
    /// @notice 시장을 닫을 때 비활성화하는 연산 집합. 파일 레벨 상수를 그대로 노출합니다.
    function CLOSED_OPS() external pure returns (uint32) {
        return MATURITY_CLOSED_OPS;
    }

    error E_ZeroAddress();
    error E_NotAdmin();
    error E_MarketNotOpen(address market);
    error E_NotYetMatured(uint256 maturity, uint256 nowTs);
    error E_MarketAlreadyClosed();
    error E_MarketClosed();
    error E_RampAlreadyStarted(address collateral);
    error E_CollateralNotConfigured(address collateral);
    error E_ZeroRampDuration();
    error E_NoticeWindowRestricted(address borrower, address counterparty, address caller);
    error E_NotCollateralHolder(address borrower, address collateral);

    event MarketClosed(uint256 at, address zeroRateIrm, uint32 closedOps);
    event MaturityTriggered(
        address indexed collateral, address indexed borrower, address indexed noticedBy, uint16 rampFrom, uint256 at
    );
    event CollateralConfigured(address indexed collateral, uint16 borrowLTV, uint16 liquidationLTV);

    IDebtVaultGovernance public immutable debtVault;
    MaturityRegistry public immutable registry;
    IEVCLike public immutable evc;

    /// @notice 온보딩 통로를 쓸 수 있는 주체. 청산을 되돌릴 수는 없습니다.
    address public immutable admin;

    /// @notice 만기 후 부채를 멈추는 데 쓸 이자율 모델. 0을 반환해야 합니다.
    /// @dev address(0)으로 바꾸면 안 됩니다. EVK의 computeInterestRate는 모델이 0 주소면
    ///      호출을 건너뛰고 `vaultStorage.interestRate`를 그대로 둡니다. 직전 금리가
    ///      박제되어 부채가 계속 자랍니다. 0을 반환하는 모델을 실제로 끼워야 합니다.
    address public immutable zeroRateIrm;

    /// @notice 청산선이 개시 한도에서 0까지 내려가는 데 걸리는 시간.
    uint32 public immutable rampDuration;

    /// @notice 만기 후 상대방만 부도를 선언할 수 있는 기간. GMRA 2011 ¶10(b)의 20일 자리.
    /// @dev 0이면 창이 없고 만기 즉시 누구나 부릅니다 — Wave 1의 동작입니다.
    uint32 public immutable noticeWindow;

    /// @notice 시장이 닫힌 시각. 0이면 아직 열려 있습니다.
    uint256 public marketClosedAt;

    /// @notice 담보별 사다리 시작 시각. 0이면 아직 시작하지 않았습니다.
    mapping(address collateral => uint256 at) public rampStartedAt;

    constructor(
        address debtVault_,
        address registry_,
        address evc_,
        address admin_,
        address zeroRateIrm_,
        uint32 rampDuration_,
        uint32 noticeWindow_
    ) {
        if (
            debtVault_ == address(0) || registry_ == address(0) || evc_ == address(0) || admin_ == address(0)
                || zeroRateIrm_ == address(0)
        ) revert E_ZeroAddress();
        if (rampDuration_ == 0) revert E_ZeroRampDuration();

        debtVault = IDebtVaultGovernance(debtVault_);
        registry = MaturityRegistry(registry_);
        evc = IEVCLike(evc_);
        admin = admin_;
        zeroRateIrm = zeroRateIrm_;
        rampDuration = rampDuration_;
        noticeWindow = noticeWindow_;
    }

    // --- 시장 닫기. 누구나, 만기 즉시 ---

    /// @notice 부채를 멈추고 신규 진입을 막습니다. cure period가 여기서 시작됩니다.
    ///
    /// @dev **권한 검사가 없습니다.** 차입자 본인이 불러도 되고, 그게 정상입니다 — 갚아야
    ///      할 금액을 고정하는 것은 차입자에게 유리한 조치입니다. 대여자도, 제3자도
    ///      부를 수 있습니다.
    ///
    ///      부도 선언이 아닙니다. 담보는 그대로 차입자에게 남아 있고, 청산은 아직
    ///      불가능합니다. 그것을 여는 것은 `triggerMaturity` 입니다.
    function closeMarket() external {
        _requireMatured();
        if (marketClosedAt != 0) revert E_MarketAlreadyClosed();
        _closeMarket();
    }

    // --- 부도 선언. 창 안에는 상대방만 ---

    /// @notice 만기 경과를 청산 가능 상태로 바꿉니다. GMRA의 Default Notice 자리입니다.
    ///
    /// @param collateral 사다리를 시작할 담보 볼트.
    /// @param borrower 그 담보의 차입자. 상대방을 찾는 열쇠입니다.
    ///
    /// @dev 둘을 따로 받고 서로 맞는지 확인합니다 — 차입자가 그 볼트의 지분을 가지고
    ///      있어야 합니다. 이 확인이 없으면 상대방이 기록되지 않은 아무 계정을 넘겨
    ///      남의 담보에 사다리를 걸 수 있습니다.
    ///
    ///      시장이 아직 닫히지 않았으면 함께 닫습니다. 그래서 한 번의 호출로도 끝납니다.
    ///      담보 볼트가 여러개면 각각 한 번씩 부르며, 시장은 첫 호출에서 한 번만 닫힙니다.
    function triggerMaturity(address collateral, address borrower) external {
        uint256 maturity = _requireMatured();
        if (rampStartedAt[collateral] != 0) revert E_RampAlreadyStarted(collateral);

        // 사다리의 출발점은 그 시장이 허용한 차입 한도입니다. 상수로 박지 않습니다.
        uint16 rampFrom = debtVault.LTVBorrow(collateral);
        if (rampFrom == 0) revert E_CollateralNotConfigured(collateral);

        // 차입자와 담보가 서로 맞는지.
        if (IShares(collateral).balanceOf(borrower) == 0) revert E_NotCollateralHolder(borrower, collateral);

        // 통지 창 안에는 그 계약의 상대방만 선언합니다. 상대방이 기록되지 않은 계약은
        // 누구를 기다려야 할지 알 수 없으므로 창을 적용하지 않습니다.
        address counterparty = registry.counterpartyOf(borrower);
        if (counterparty != address(0) && block.timestamp < maturity + noticeWindow) {
            if (!_mayServeNotice(counterparty, msg.sender)) {
                revert E_NoticeWindowRestricted(borrower, counterparty, msg.sender);
            }
        }

        if (marketClosedAt == 0) _closeMarket();
        rampStartedAt[collateral] = block.timestamp;

        // 1. 청산선을 개시 한도까지 즉시. 한도까지 쓴 포지션은 여기서 할인 0으로 청산 대상.
        debtVault.setLTV(collateral, 0, rampFrom, 0);
        // 2. 거기서 0까지 선형으로. 할인이 0에서 선형으로 오릅니다.
        debtVault.setLTV(collateral, 0, 0, rampDuration);

        emit MaturityTriggered(collateral, borrower, msg.sender, rampFrom, block.timestamp);
    }

    /// @dev 상대방 본인, 그 서브계정, 또는 상대방이 지정한 EVC operator.
    function _mayServeNotice(address counterparty, address caller) internal view returns (bool) {
        if (caller == counterparty) return true;
        if (evc.haveCommonOwner(caller, counterparty)) return true;
        return evc.isAccountOperatorAuthorized(counterparty, caller);
    }

    function _requireMatured() internal view returns (uint256 maturity) {
        maturity = registry.marketMaturity(address(debtVault));
        if (maturity == 0) revert E_MarketNotOpen(address(debtVault));
        if (block.timestamp < maturity) revert E_NotYetMatured(maturity, block.timestamp);
    }

    function _closeMarket() internal {
        marketClosedAt = block.timestamp;

        // 3. 부채를 멈춥니다. setInterestRateModel이 먼저 updateVault()로 그 시점까지
        //    이자를 확정하므로 소급 효과가 없습니다.
        debtVault.setInterestRateModel(zeroRateIrm);

        // 4. 신규 진입을 막습니다. 훅 대상이 0 주소면 그 연산이 비활성화됩니다.
        debtVault.setHookConfig(address(0), MATURITY_CLOSED_OPS);

        emit MarketClosed(block.timestamp, zeroRateIrm, MATURITY_CLOSED_OPS);
    }

    // --- 온보딩. 관리자, 시장이 열려 있을 때만 ---

    /// @notice 새 담보 볼트의 LTV를 설정합니다. 온보딩 전용입니다.
    ///
    /// @dev 거버너가 이 컨트랙트이므로 배포 스크립트가 setLTV를 직접 부를 수 없습니다.
    ///      그 한 가지 용도만 통로로 냅니다.
    ///
    ///      시장이 닫힌 뒤에는 거부합니다. 사다리가 시작된 담보도 거부합니다. 둘이
    ///      없으면 관리자가 LTV를 다시 올려 청산을 취소할 수 있고, 그러면 이 컨트랙트가
    ///      보장하는 것이 아무것도 없습니다.
    function configureCollateral(address collateral, uint16 borrowLTV, uint16 liquidationLTV) external {
        if (msg.sender != admin) revert E_NotAdmin();
        if (collateral == address(0)) revert E_ZeroAddress();
        if (marketClosedAt != 0) revert E_MarketClosed();
        if (rampStartedAt[collateral] != 0) revert E_RampAlreadyStarted(collateral);

        debtVault.setLTV(collateral, borrowLTV, liquidationLTV, 0);
        emit CollateralConfigured(collateral, borrowLTV, liquidationLTV);
    }

    // --- 조회 ---

    /// @notice 시장이 닫혔는지.
    function marketClosed() external view returns (bool) {
        return marketClosedAt != 0;
    }

    /// @notice 통지 창이 끝나는 시각. 그 뒤로는 누구나 부도를 선언할 수 있습니다.
    function noticeWindowEndsAt() public view returns (uint256) {
        uint256 maturity = registry.marketMaturity(address(debtVault));
        return maturity == 0 ? 0 : maturity + noticeWindow;
    }

    /// @notice 지금 이 호출자가 이 계약의 부도를 선언할 수 있는지.
    ///
    /// @dev 오프체인 러너가 폴링할 자리입니다. 창 안에서는 상대방에게만 true를 돌려주므로,
    ///      러너는 자기가 대리인으로 등록됐는지까지 이 한 번의 호출로 확인합니다.
    function canTrigger(address collateral, address borrower, address caller) external view returns (bool) {
        uint256 maturity = registry.marketMaturity(address(debtVault));
        if (maturity == 0 || block.timestamp < maturity) return false;
        if (rampStartedAt[collateral] != 0) return false;
        if (debtVault.LTVBorrow(collateral) == 0) return false;
        if (IShares(collateral).balanceOf(borrower) == 0) return false;

        address counterparty = registry.counterpartyOf(borrower);
        if (counterparty != address(0) && block.timestamp < maturity + noticeWindow) {
            return _mayServeNotice(counterparty, caller);
        }
        return true;
    }

    /// @notice 사다리가 0에 닿는 시각. 시작하지 않았으면 0입니다.
    function rampEndsAt(address collateral) external view returns (uint256) {
        uint256 startedAt = rampStartedAt[collateral];
        return startedAt == 0 ? 0 : startedAt + rampDuration;
    }
}
