// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {IEVault} from "evk/EVault/IEVault.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";

import {RepoOpener} from "../src/repo/RepoOpener.sol";
import {MaturityRegistry} from "../src/registry/MaturityRegistry.sol";
import {MaturityController} from "../src/repo/MaturityController.sol";
import {WTGXXGate} from "../src/gate/WTGXXGate.sol";

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IEVCLike {
    function setAccountOperator(address account, address operator, bool authorized) external payable;
    function enableController(address account, address vault) external payable;
    function enableCollateral(address account, address vault) external payable;
    function batch(IEVC.BatchItem[] calldata items) external payable;
}

interface ILiquidationCall {
    function liquidate(address violator, address collateral, uint256 repayAssets, uint256 minYieldBalance) external;
    function repay(uint256 amount, address receiver) external returns (uint256);
}

/// @title RepoChain
/// @notice 사다리 세 칸을 단계별로 눌러 보여주는 시연 스크립트.
///
/// @dev **단계마다 보내는 사람이 다릅니다.** forge script 는 한 번에 한 발신자만 쓰므로
///      단계를 함수로 쪼개고 `--sender` 를 바꿔 가며 부릅니다. 스크립트 안에 개인키가
///      없습니다 — keystore 가 서명하고 `vm.startBroadcast()` 가 그 발신자를 씁니다.
///
///      주소는 `runChain()` 이 써 둔 `broadcast/chain-state.json` 에서 읽습니다. 참여자
///      주소만 환경 변수로 받습니다.
///
///          ADDR_A  담보를 거는 차입자. WTGXX 보유, 화이트리스트 필요
///          ADDR_B  V_B 대여자. A 의 상대방. 화이트리스트 필요
///          ADDR_C  V_C 대여자. B 의 상대방. 화이트리스트 필요
///          ADDR_D  V_D 대여자. C 의 상대방. 화이트리스트 필요
///          ADDR_L  청산 에이전트. WTGXX 를 받으므로 화이트리스트 필요
///
///      **넷 다 화이트리스트가 필요합니다.** `RepoOpener.open` 이 개시 때 차입자와
///      대여자 양쪽에 `gate.canEnter` 를 겁니다. C·D 는 WTGXX 에 닿지 않지만 오프너가
///      참여자 자격으로 검사합니다.
///
///      순서가 강제됩니다. 위 칸이 먼저 현금을 대야 아래 칸이 빌릴 수 있습니다.
///
///          supplyD → supplyC → openC → supplyB → openB → openA
///          → (만기 대기) → notice → liquidate
///
///      시연 직전에 `rollMaturity` 로 만기를 당깁니다. **사다리를 세우기 전에** 불러야
///      합니다 — 레지스트리는 이미 열린 계약의 만기를 건드리지 않습니다.
contract RepoChain is Script {
    string internal constant STATE_FILE = "./broadcast/chain-state.json";

    /// @dev 배포 스크립트의 비율과 같은 값. 상태 파일에 금액이 없는 옛 배포에만 씁니다.
    uint16 internal constant DRAW_RUNG1 = 0.80e4;
    uint16 internal constant DRAW_RUNG2 = 0.80e4;
    uint16 internal constant DRAW_RUNG3 = 0.70e4;

    struct S {
        address evc;
        address usdc;
        address wtgxx;
        address gate;
        address maturityRegistry;
        address borrower;
        address vaultA;
        address vaultB;
        address vaultC;
        address vaultD;
        address openerB;
        address openerC;
        address openerD;
        address controllerB;
        uint256 scaleUnit;
        uint256 collateralAmount;
        uint256 supplyAmount;
        uint256 drawA;
        uint256 drawB;
        uint256 drawC;
    }

    struct Party {
        address a;
        address b;
        address c;
        address d;
        address l;
    }

    // --- 공급. 위 칸부터 ---

    /// @notice D 가 V_D 에 현금을 댑니다. 사다리의 꼭대기이고 여기서 시작합니다.
    function supplyD() external {
        _doSupply(_read().vaultD, "D");
    }

    /// @notice C 가 V_C 에 현금을 댑니다.
    function supplyC() external {
        _doSupply(_read().vaultC, "C");
    }

    /// @notice B 가 V_B 에 현금을 댑니다.
    function supplyB() external {
        _doSupply(_read().vaultB, "B");
    }

    // --- 개시. 위 칸부터 ---

    /// @notice C 가 eV_C 를 걸고 D 에게서 빌립니다.
    function openC() external {
        S memory s = _read();
        _open(s, s.vaultC, s.openerD, s.vaultD, _parties().d, 0, _draw(s, 3), "C -> D");
    }

    /// @notice B 가 eV_B 를 걸고 C 에게서 빌립니다.
    function openB() external {
        S memory s = _read();
        _open(s, s.vaultB, s.openerC, s.vaultC, _parties().c, 0, _draw(s, 2), "B -> C");
    }

    /// @notice A 가 WTGXX 를 걸고 B 에게서 빌립니다. 사다리가 여기서 닫힙니다.
    /// @dev 유일하게 담보를 실제로 예치하는 단계입니다. WTGXX approve 가 먼저 붙습니다.
    function openA() external {
        S memory s = _read();
        _open(s, s.vaultA, s.openerB, s.vaultB, _parties().b, _collateral(s), _draw(s, 1), "A -> B");
    }

    // --- 만기 ---

    /// @notice 세 시장의 만기를 지금 + MARKET_TERM 으로 당깁니다. 배포자만 부릅니다.
    /// @dev **사다리를 세우기 전에** 부르세요. 이미 열린 계약의 만기는 안 바뀝니다.
    function rollMaturity() external {
        S memory s = _read();
        uint256 when = block.timestamp + _rollTerm();

        vm.startBroadcast();
        MaturityRegistry(s.maturityRegistry).setMarketMaturity(s.vaultB, when);
        MaturityRegistry(s.maturityRegistry).setMarketMaturity(s.vaultC, when);
        MaturityRegistry(s.maturityRegistry).setMarketMaturity(s.vaultD, when);
        vm.stopBroadcast();

        console.log("");
        console.log("=== maturity rolled ===");
        console.log("now                    ", block.timestamp);
        console.log("maturity               ", when);
        console.log("seconds to maturity    ", when - block.timestamp);
    }

    /// @notice B 가 A 의 부도를 선언합니다. 통지 창 안에는 상대방만 부를 수 있습니다.
    function notice() external {
        S memory s = _read();
        MaturityController controller = MaturityController(s.controllerB);
        Party memory p = _parties();

        console.log("");
        console.log("=== notice ===");
        console.log("caller                 ", msg.sender);
        console.log("counterparty of A      ", MaturityRegistry(s.maturityRegistry).counterpartyOf(p.a));
        console.log("notice window ends at  ", controller.noticeWindowEndsAt());
        console.log("now                    ", block.timestamp);
        console.log("can trigger            ", controller.canTrigger(s.vaultA, p.a, msg.sender));

        vm.startBroadcast();
        controller.triggerMaturity(s.vaultA, p.a);
        vm.stopBroadcast();

        console.log("market closed          ", controller.marketClosed());
        console.log("borrow LTV after       ", IEVault(s.vaultB).LTVBorrow(s.vaultA));
        console.log("liq LTV now (ramping)  ", IEVault(s.vaultB).LTVLiquidation(s.vaultA));
        console.log("ramp ends at           ", controller.rampEndsAt(s.vaultA));
    }

    /// @notice L 이 A 를 청산합니다. 담보를 넘겨받고 부채를 떠안은 뒤 곧바로 갚습니다.
    /// @dev 청산과 상환을 한 배치로 묶습니다. 떼어 놓으면 중간 상태에서 L 자신이
    ///      건전성 검사에 걸립니다.
    function liquidate() external {
        S memory s = _read();
        Party memory p = _parties();

        (uint256 maxRepay,) = IEVault(s.vaultB).checkLiquidation(msg.sender, p.a, s.vaultA);

        console.log("");
        console.log("=== liquidate ===");
        console.log("liquidator             ", msg.sender);
        console.log("A debt before          ", IEVault(s.vaultB).debtOf(p.a));
        console.log("max repay now          ", maxRepay);
        require(maxRepay > 0, "ramp has not opened liquidation yet - wait and re-run");

        vm.startBroadcast();
        IERC20Like(s.usdc).approve(s.vaultB, type(uint256).max);
        IEVCLike(s.evc).enableController(msg.sender, s.vaultB);
        IEVCLike(s.evc).enableCollateral(msg.sender, s.vaultA);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: s.vaultB,
            onBehalfOfAccount: msg.sender,
            value: 0,
            data: abi.encodeCall(ILiquidationCall.liquidate, (p.a, s.vaultA, maxRepay, 0))
        });
        items[1] = IEVC.BatchItem({
            targetContract: s.vaultB,
            onBehalfOfAccount: msg.sender,
            value: 0,
            data: abi.encodeCall(ILiquidationCall.repay, (type(uint256).max, msg.sender))
        });
        IEVCLike(s.evc).batch(items);
        vm.stopBroadcast();

        console.log("A debt after           ", IEVault(s.vaultB).debtOf(p.a));
        console.log("L shares of V_A        ", IEVault(s.vaultA).balanceOf(msg.sender));
        console.log("A residual shares      ", IEVault(s.vaultA).balanceOf(p.a));
    }

    /// @notice L 이 압류한 지분을 WTGXX 로 바꿉니다. 여기서 담보가 처음 볼트를 떠납니다.
    function withdrawSeized() external {
        S memory s = _read();
        uint256 shares = IEVault(s.vaultA).balanceOf(msg.sender);
        require(shares > 0, "nothing seized");

        console.log("");
        console.log("=== withdraw seized ===");
        console.log("L WTGXX before         ", IERC20Like(s.wtgxx).balanceOf(msg.sender));

        vm.startBroadcast();
        IEVault(s.vaultA).withdraw(shares, msg.sender, msg.sender);
        vm.stopBroadcast();

        console.log("L WTGXX after          ", IERC20Like(s.wtgxx).balanceOf(msg.sender));
    }

    // --- 읽기 전용 ---

    /// @notice 사다리의 현재 상태. 시연에서 이 한 화면을 보여줍니다.
    function status() external view {
        S memory s = _read();
        Party memory p = _parties();

        console.log("");
        console.log("=== where is the collateral ===");
        console.log("WTGXX in V_A           ", IERC20Like(s.wtgxx).balanceOf(s.vaultA));
        console.log("WTGXX in V_B           ", IERC20Like(s.wtgxx).balanceOf(s.vaultB));
        console.log("WTGXX in V_C           ", IERC20Like(s.wtgxx).balanceOf(s.vaultC));
        console.log("WTGXX in V_D           ", IERC20Like(s.wtgxx).balanceOf(s.vaultD));

        console.log("");
        console.log("=== cash in each vault ===");
        console.log("V_B                    ", IEVault(s.vaultB).cash());
        console.log("V_C                    ", IEVault(s.vaultC).cash());
        console.log("V_D                    ", IEVault(s.vaultD).cash());

        console.log("");
        console.log("=== debt ===");
        console.log("A owes V_B             ", IEVault(s.vaultB).debtOf(p.a));
        console.log("B owes V_C             ", IEVault(s.vaultC).debtOf(p.b));
        console.log("C owes V_D             ", IEVault(s.vaultD).debtOf(p.c));

        console.log("");
        console.log("=== shares pledged ===");
        console.log("A holds eV_A           ", IEVault(s.vaultA).balanceOf(p.a));
        console.log("B holds eV_B           ", IEVault(s.vaultB).balanceOf(p.b));
        console.log("C holds eV_C           ", IEVault(s.vaultC).balanceOf(p.c));
        console.log("D holds eV_D           ", IEVault(s.vaultD).balanceOf(p.d));

        console.log("");
        console.log("=== share price stays put ===");
        console.log("V_B totalAssets        ", IEVault(s.vaultB).totalAssets());
        console.log("V_B totalSupply        ", IEVault(s.vaultB).totalSupply());
        console.log("B would redeem         ", IEVault(s.vaultB).convertToAssets(IEVault(s.vaultB).balanceOf(p.b)));

        console.log("");
        console.log("=== wallets ===");
        console.log("A USDC                 ", IERC20Like(s.usdc).balanceOf(p.a));
        console.log("B USDC                 ", IERC20Like(s.usdc).balanceOf(p.b));
        console.log("C USDC                 ", IERC20Like(s.usdc).balanceOf(p.c));
        console.log("D USDC                 ", IERC20Like(s.usdc).balanceOf(p.d));
        console.log("A WTGXX                ", IERC20Like(s.wtgxx).balanceOf(p.a));
        console.log("L WTGXX                ", IERC20Like(s.wtgxx).balanceOf(p.l));

        console.log("");
        console.log("=== scale recorded at deploy ===");
        console.log("SCALE_UNIT             ", s.scaleUnit);
        console.log("collateral for A       ", s.collateralAmount);
        console.log("supply per lender      ", s.supplyAmount);
        console.log("draws A / B / C        ", s.drawA);
        console.log("                       ", s.drawB);
        console.log("                       ", s.drawC);

        console.log("");
        console.log("=== clock ===");
        console.log("now                    ", block.timestamp);
        console.log("market maturity        ", MaturityRegistry(s.maturityRegistry).marketMaturity(s.vaultB));
    }

    /// @notice 개시 전에 다섯 주소가 게이트를 통과하는지 봅니다. 한 번에 확인합니다.
    function checkParties() external view {
        S memory s = _read();
        Party memory p = _parties();
        WTGXXGate gate = WTGXXGate(s.gate);

        console.log("");
        console.log("=== gate verdicts. 0 = Allowed ===");
        console.log("A                      ", uint256(gate.checkEntry(p.a)));
        console.log("B                      ", uint256(gate.checkEntry(p.b)));
        console.log("C                      ", uint256(gate.checkEntry(p.c)));
        console.log("D                      ", uint256(gate.checkEntry(p.d)));
        console.log("L                      ", uint256(gate.checkEntry(p.l)));
        console.log("V_A collateral vault   ", uint256(gate.checkEntry(s.vaultA)));
    }

    // --- 내부 ---

    function _doSupply(address vault, string memory who) internal {
        S memory s = _read();
        uint256 amount = _supply(s);

        vm.startBroadcast();
        IERC20Like(s.usdc).approve(vault, type(uint256).max);
        IEVault(vault).deposit(amount, msg.sender);
        vm.stopBroadcast();

        console.log("");
        console.log("=== supply ===");
        console.log("who                    ", who);
        console.log("vault                  ", vault);
        console.log("deposited              ", amount);
        console.log("shares held            ", IEVault(vault).balanceOf(msg.sender));
        console.log("vault cash             ", IEVault(vault).cash());
    }

    /// @dev `RepoOpener.open` 은 `msg.sender` 를 차입자로 씁니다. 그래서 각 참여자가
    ///      자기 트랜잭션으로 불러야 하고, 서브계정으로는 못 엽니다.
    function _open(
        S memory s,
        address collateralVault,
        address opener,
        address debtVault,
        address lender,
        uint256 collateralAmount,
        uint256 principal,
        string memory label
    ) internal {
        uint256 maturity = MaturityRegistry(s.maturityRegistry).marketMaturity(debtVault);
        require(maturity > block.timestamp, "market matured - roll maturity before opening");

        vm.startBroadcast();
        if (collateralAmount > 0) IERC20Like(s.wtgxx).approve(collateralVault, type(uint256).max);
        IEVCLike(s.evc).setAccountOperator(msg.sender, opener, true);
        RepoOpener(opener).open(collateralVault, collateralAmount, principal, maturity, lender);
        vm.stopBroadcast();

        console.log("");
        console.log("=== open ===");
        console.log("leg                    ", label);
        console.log("borrower               ", msg.sender);
        console.log("lender                 ", lender);
        console.log("collateral vault       ", collateralVault);
        console.log("collateral deposited   ", collateralAmount);
        console.log("principal drawn        ", principal);
        console.log("debt now               ", IEVault(debtVault).debtOf(msg.sender));
        console.log("maturity               ", maturity);
    }

    /// @notice 사다리 단위. **배포가 적어 둔 값을 먼저 봅니다.**
    ///
    /// @dev 예전에는 호출할 때마다 `SCALE_UNIT` 을 다시 읽었는데, 그게 비어 있으면
    ///      기본값 100으로 **조용히** 돌아가 한 칸에 100 USDC 를 넣으려 했습니다.
    ///      10/04 리허설에서 여섯 단계가 그렇게 죽었습니다.
    ///
    ///      이제 금액은 배포에 묶입니다. 상태 파일에 값이 없는 옛 배포만 환경 변수로
    ///      넘어가고, 그마저 비어 있으면 기본값으로 가지 않고 **멈춥니다.**
    function _unit(S memory s) internal view returns (uint256 unit) {
        if (s.scaleUnit > 0) return s.scaleUnit;
        unit = vm.envOr("SCALE_UNIT", uint256(0));
        require(unit > 0, "no scale in chain-state.json and SCALE_UNIT unset - redeploy or export SCALE_UNIT");
    }

    function _supply(S memory s) internal view returns (uint256) {
        return s.supplyAmount > 0 ? s.supplyAmount : _unit(s) * 1e6;
    }

    function _collateral(S memory s) internal view returns (uint256) {
        return s.collateralAmount > 0 ? s.collateralAmount : _unit(s) * 1e18;
    }

    function _draw(S memory s, uint256 rung) internal view returns (uint256) {
        if (rung == 1) return s.drawA > 0 ? s.drawA : (_supply(s) * DRAW_RUNG1) / 1e4;
        if (rung == 2) return s.drawB > 0 ? s.drawB : (_supply(s) * DRAW_RUNG2) / 1e4;
        return s.drawC > 0 ? s.drawC : (_supply(s) * DRAW_RUNG3) / 1e4;
    }

    /// @dev 만기만 환경 변수입니다. 배포 때 쓴 기간이 아니라 **지금 굴릴 기간**이므로
    ///      상태 파일에서 읽으면 안 됩니다. 기본값으로 빠지지 않게 명시를 요구합니다.
    function _rollTerm() internal view returns (uint256 term) {
        term = vm.envOr("MARKET_TERM", uint256(0));
        require(term > 0, "MARKET_TERM must be set for rollMaturity - e.g. MARKET_TERM=1800");
    }

    function _parties() internal view returns (Party memory p) {
        p.a = vm.envAddress("ADDR_A");
        p.b = vm.envAddress("ADDR_B");
        p.c = vm.envAddress("ADDR_C");
        p.d = vm.envAddress("ADDR_D");
        p.l = vm.envAddress("ADDR_L");
    }

    function _read() internal view returns (S memory s) {
        string memory json = vm.readFile(STATE_FILE);
        s.evc = vm.parseJsonAddress(json, ".evc");
        s.usdc = vm.parseJsonAddress(json, ".usdc");
        s.wtgxx = vm.parseJsonAddress(json, ".wtgxx");
        s.gate = vm.parseJsonAddress(json, ".gate");
        s.maturityRegistry = vm.parseJsonAddress(json, ".maturityRegistry");
        s.borrower = vm.parseJsonAddress(json, ".borrower");
        s.vaultA = vm.parseJsonAddress(json, ".vaultA");
        s.vaultB = vm.parseJsonAddress(json, ".vaultB");
        s.vaultC = vm.parseJsonAddress(json, ".vaultC");
        s.vaultD = vm.parseJsonAddress(json, ".vaultD");
        s.openerB = vm.parseJsonAddress(json, ".openerB");
        s.openerC = vm.parseJsonAddress(json, ".openerC");
        s.openerD = vm.parseJsonAddress(json, ".openerD");
        s.controllerB = vm.parseJsonAddress(json, ".controllerB");

        // 금액은 이 패치 이후 배포에만 있습니다. 없으면 0으로 두고 호출부가
        // 환경 변수로 넘어갑니다 — 그마저 없으면 멈춥니다. `_unit` 참조.
        if (vm.keyExistsJson(json, ".scaleUnit")) s.scaleUnit = vm.parseJsonUint(json, ".scaleUnit");
        if (vm.keyExistsJson(json, ".collateralAmount")) {
            s.collateralAmount = vm.parseJsonUint(json, ".collateralAmount");
        }
        if (vm.keyExistsJson(json, ".supplyAmount")) s.supplyAmount = vm.parseJsonUint(json, ".supplyAmount");
        if (vm.keyExistsJson(json, ".drawA")) s.drawA = vm.parseJsonUint(json, ".drawA");
        if (vm.keyExistsJson(json, ".drawB")) s.drawB = vm.parseJsonUint(json, ".drawB");
        if (vm.keyExistsJson(json, ".drawC")) s.drawC = vm.parseJsonUint(json, ".drawC");
    }
}
