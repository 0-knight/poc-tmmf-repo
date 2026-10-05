// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {GenericFactory} from "euler-vault-kit/src/GenericFactory/GenericFactory.sol";
import {EVault} from "evk/EVault/EVault.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {Dispatch} from "evk/EVault/Dispatch.sol";
import {Base} from "evk/EVault/shared/Base.sol";
import {Initialize} from "evk/EVault/modules/Initialize.sol";
import {Token} from "evk/EVault/modules/Token.sol";
import {Vault} from "evk/EVault/modules/Vault.sol";
import {Borrowing} from "evk/EVault/modules/Borrowing.sol";
import {Liquidation} from "evk/EVault/modules/Liquidation.sol";
import {RiskManager} from "evk/EVault/modules/RiskManager.sol";
import {BalanceForwarder} from "evk/EVault/modules/BalanceForwarder.sol";
import {Governance} from "evk/EVault/modules/Governance.sol";
import {ProtocolConfig} from "euler-vault-kit/src/ProtocolConfig/ProtocolConfig.sol";
import {SequenceRegistry} from "euler-vault-kit/src/SequenceRegistry/SequenceRegistry.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";

import {WTGXXCollateralVault} from "../src/vault/WTGXXCollateralVault.sol";
import {CollateralVaultFactory} from "../src/vault/CollateralVaultFactory.sol";
import {CollateralVaultHook} from "../src/vault/CollateralVaultHook.sol";
import {FixedRateIRM} from "../src/irm/FixedRateIRM.sol";
import {FixedOneToOneOracle} from "../src/oracle/FixedOneToOneOracle.sol";
import {MaturityRegistry} from "../src/registry/MaturityRegistry.sol";
import {WTGXXGate} from "../src/gate/WTGXXGate.sol";
import {RepoOpener} from "../src/repo/RepoOpener.sol";
import {MaturityController, MATURITY_CLOSED_OPS} from "../src/repo/MaturityController.sol";
import {ParticipantRegistry} from "../src/registry/ParticipantRegistry.sol";
import {DebtVaultAccessHook} from "../src/vault/DebtVaultAccessHook.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockWTGXX} from "../src/mocks/MockWTGXX.sol";
import {MockKycNFT} from "../src/mocks/MockKycNFT.sol";
import {MockComplianceOracle} from "../src/mocks/MockComplianceOracle.sol";

/// @title DeployStack
/// @notice 스택 전체를 배포하고 거버넌스를 설정합니다.
///
/// @dev 목업과 실물을 환경 변수로 전환합니다. 시나리오 코드를 한 벌만 유지하기 위해서이며,
///      M8에서 Sepolia 실물로 넘어갈 때 이 스크립트를 그대로 씁니다.
///
///          WTGXX_ADDRESS   비우면 MockWTGXX 를 배포합니다.
///          USDC_ADDRESS    비우면 MockUSDC 를 배포합니다.
///
///      담보 볼트와 부채 볼트를 다르게 만듭니다. 담보 볼트는 CollateralVaultFactory로
///      CREATE2 배포해 주소를 예측 가능하게 하고(백서 2.2절), 부채 볼트는 EVK의
///      GenericFactory를 그대로 씁니다. 부채 볼트는 명부 등록도 KYC NFT도 없어서 주소를
///      사전 검증할 이유가 없습니다.
contract DeployStack is Script {
    /// @dev EVK Constants.sol: 청산 시 부실채권 사회화를 끕니다. 백서 4.5절.
    uint32 internal constant CFG_DONT_SOCIALIZE_DEBT = 1 << 0;

    /// @dev 담보 볼트에 훅으로 걸 연산. 출금은 걸지 않습니다. 백서 6.1절.
    uint32 internal constant HOOKED_OPS = (1 << 0) | (1 << 1) | (1 << 4) | (1 << 5);

    /// @dev 두 LTV를 벌립니다. 전까지는 둘이 같아서 "빌릴 수 있는 한도"와 "청산되는 선"이
    ///      한 점에 붙어 있었고, 한도까지 빌린 계정은 다음 블록에 바로 청산 대상이었습니다.
    ///
    ///      헤어컷으로 읽습니다 — 개시 8%, 청산 5%. 암호자산 관행이 아니라 전통 repo의
    ///      헤어컷에서 왔습니다. 백서 4.2절은 "볼 것은 가격이 아니라 회수 시간"이라고
    ///      적고, WTGXX는 $1 고정에 환매가 T+1이므로 덮어야 하는 것은 가격 변동이 아니라
    ///      하루의 지연입니다.
    ///
    ///      전통금융의 정부채 MMF 헤어컷은 1~3%입니다. 우리가 더 넓게 잡은 이유는 둘
    ///      입니다. 일일 마크와 마진콜이 아직 없어서 하루를 한 번에 덮어야 하고, 재담보
    ///      체인에서는 사다리 칸마다 헤어컷이 쌓여 아래 칸의 여유가 위 칸의 완충이
    ///      됩니다. 마진콜이 붙으면 이 숫자는 좁혀야 합니다.
    uint16 internal constant BORROW_LTV = 0.92e4; // 92%. 개시 한도
    uint16 internal constant LIQUIDATION_LTV = 0.95e4; // 95%. 청산선

    /// @dev 청산 할인 한도. EVK는 담보가 부채에 얼마나 모자라는지에 비례해 할인율을
    ///      계산하고(Liquidation.calculateMaxLiquidation), 이 값이 그 하한입니다.
    ///      전까지 20%였는데, 정부채 MMF 담보에 20% 할인은 청산인에게 과한 보상입니다.
    ///      백서 4.4절이 "할인은 0에서 시작해 선형으로 오른다"고 한 것과도 어긋납니다.
    uint16 internal constant MAX_LIQUIDATION_DISCOUNT = 0.02e4; // 2%

    /// @dev 청산 쿨오프. EVK 기본값은 0이지만 명시해 둡니다. 0이 아니면 만기 직후
    ///      청산이 한 블록 밀리고, 그 사이 차입자가 담보를 빼는 경로가 생깁니다.
    uint16 internal constant LIQUIDATION_COOL_OFF = 0;

    /// @dev 시장의 기간. 백서 3.1절 — 시장 하나가 만기 하나입니다. 차입자가 각자
    ///      만기를 고르는 것이 아니라 배포 시점에 시장이 만기를 정하고 공표합니다.
    uint256 internal constant DEFAULT_MARKET_TERM = 7 days;

    uint256 internal constant NOMINAL_APR = 0.5e18; // 연 50% 명목

    /// @dev 청산선이 개시 한도에서 0까지 내려가는 데 걸리는 시간. 백서 4.4절의 "창".
    ///
    ///      WTGXX 환매가 T+1이므로 하루로 잡았습니다. 다만 사다리에는 두 시계가 있습니다 —
    ///      청산이 열리는 시점은 차입자가 한도를 얼마나 썼는지에 달리고, 할인이 2% 상한에
    ///      닿는 데는 그로부터 사다리의 2% 남짓만 걸립니다. MaturityController 주석 참조.
    uint32 internal constant DEFAULT_MATURITY_RAMP_DURATION = 1 days;

    /// @dev 만기 후 그 계약의 상대방만 부도를 선언할 수 있는 기간. GMRA 2011 ¶10(b)가
    ///      비부도 당사자에게 Default Notice까지 최대 20일을 주는 자리입니다.
    ///
    ///      20일이 아니라 하루로 잡은 이유는 담보가 WTGXX이기 때문입니다. 환매가 T+1이라
    ///      대여자가 하루 안에 판단할 수 있고, 그 사이 다른 대여자들 현금이 묶여 있습니다.
    ///      창이 지나면 누구나 선언할 수 있습니다 — 대여자가 사라져도 포지션이 풀립니다.
    uint32 internal constant DEFAULT_MATURITY_NOTICE_WINDOW = 1 days;

    /// @notice 기간 셋을 환경 변수로 읽습니다. 비우면 위 기본값입니다.
    ///
    /// @dev **Sepolia 데모 때문에 뺐습니다.** 기본값대로면 만기 7일 + 통지 창 1일 +
    ///      사다리 1일이라 만기에서 청산까지 전 과정을 보려면 9일을 기다려야 합니다.
    ///      로컬에서는 치트코드로 시간을 옮기지만 실물 체인에서는 진짜로 기다려야 합니다.
    ///
    ///      숫자를 줄여도 논리는 그대로입니다. 사다리의 두 시계가 절대 시간이 아니라
    ///      비율로 돌기 때문입니다 — 청산이 열리는 시점은 `(1 − 부채/담보 ÷ 개시LTV)`,
    ///      할인이 상한에 닿는 데 걸리는 몫은 `maxDiscount ÷ 개시LTV` 입니다.
    ///
    ///      `forge test` 는 건드리지 마세요. 테스트가 7일과 1일을 박아 두고 있어서
    ///      환경 변수를 세우면 그쪽이 깨집니다. 배포와 시나리오 스크립트 전용입니다.
    function marketTerm() public view returns (uint256 value) {
        value = vm.envOr("MARKET_TERM", DEFAULT_MARKET_TERM);
        require(value > 0, "MARKET_TERM must be positive");
    }

    function rampDuration() public view returns (uint32 value) {
        value = uint32(vm.envOr("MATURITY_RAMP_DURATION", uint256(DEFAULT_MATURITY_RAMP_DURATION)));
        // 0이면 MaturityController 생성자가 E_ZeroRampDuration 으로 되돌립니다.
        require(value > 0, "MATURITY_RAMP_DURATION must be positive");
    }

    /// @dev 0도 허용합니다. 창이 없으면 만기 즉시 누구나 선언할 수 있고, 그것이
    ///      Wave 1의 동작입니다. 데모에서 통지 단계를 건너뛰고 싶을 때 씁니다.
    function noticeWindow() public view returns (uint32) {
        return uint32(vm.envOr("MATURITY_NOTICE_WINDOW", uint256(DEFAULT_MATURITY_NOTICE_WINDOW)));
    }

    /// @dev 재담보 사다리 두 번째 칸의 LTV. 담보가 eV_B — V_B 지분 — 입니다.
    ///
    ///      아래 칸보다 좁습니다. 백서 4.2절이 "볼 것은 가격이 아니라 회수 시간"이라고
    ///      적는데, eV_B를 현금으로 바꾸려면 V_B에서 환매해야 하고 그 환매는 A가 갚거나
    ///      청산되어야 가능합니다. 한 단계가 더 걸리므로 헤어컷이 커집니다.
    uint16 internal constant RUNG2_BORROW_LTV = 0.85e4; // 85%
    uint16 internal constant RUNG2_LIQUIDATION_LTV = 0.90e4; // 90%

    /// @dev 세 번째 칸. 담보가 eV_C이고, 현금까지 두 단계가 더 걸립니다. 더 좁습니다.
    uint16 internal constant RUNG3_BORROW_LTV = 0.78e4; // 78%
    uint16 internal constant RUNG3_LIQUIDATION_LTV = 0.85e4; // 85%

    /// @dev 칸마다 금리가 내려갑니다. **사다리가 서려면 스프레드가 있어야 합니다.**
    ///
    ///      Wave 3까지 모든 칸이 같은 모델(`d.irm`, 연 50%)을 썼고, 그 상태에서는 중간
    ///      참여자가 손해를 봅니다. EVK는 볼트마다 이자의 10%를 수수료로 떼므로
    ///      (`Initialize.DEFAULT_INTEREST_FEE`) 같은 금리로 받아서 같은 금리로 내면
    ///      수수료만큼 모자랍니다. 칸이 늘수록 누적됩니다.
    ///
    ///      그래서 아래 칸에서 받는 금리가 위 칸에 내는 금리보다 높아야 합니다. 전통
    ///      repo의 매치북이 그렇게 돕니다 — 중간은 자기 돈을 거의 안 내고 스프레드를
    ///      먹습니다. 수수료 10%를 덮고 남을 폭으로 10%p씩 두었습니다.
    uint256 internal constant RUNG2_APR = 0.40e18; // 연 40%
    uint256 internal constant RUNG3_APR = 0.30e18; // 연 30%

    /// @notice 사다리 한 칸의 기본 단위. 담보 WTGXX와 대여자 USDC가 둘 다 이 수량입니다.
    ///
    /// @dev **기간 상수와 같은 이유로 뺐습니다.** 기본값 100은 테스트가 쓰는 값이고, 샌드박스
    ///      잔고는 그만큼 없습니다. 시연 중에 숫자를 줄이려고 코드를 고쳐 다시 배포하는 일을
    ///      없애기 위해 환경 변수로 받습니다.
    ///
    ///      단위는 **개수**입니다. wei가 아닙니다. `SCALE_UNIT=20` 이면 담보 20 WTGXX,
    ///      칸마다 예치 20 USDC 입니다. decimals 보정은 아래 두 함수가 합니다.
    uint256 internal constant DEFAULT_SCALE_UNIT = 100;

    /// @dev 칸마다 끌어쓰는 비율. 그 칸의 **개시 LTV보다 낮아야** 합니다.
    ///      숫자를 손으로 적지 않고 비율에서 끌어내는 이유가 이것입니다 — `SCALE_UNIT` 을
    ///      바꿔도 LTV 여유가 그대로 유지됩니다.
    uint16 internal constant DRAW_RUNG1 = 0.80e4; // A가 WTGXX 담보로. 개시 LTV 92%
    uint16 internal constant DRAW_RUNG2 = 0.80e4; // B가 eV_B 담보로. 개시 LTV 85%
    uint16 internal constant DRAW_RUNG3 = 0.70e4; // C가 eV_C 담보로. 개시 LTV 78%

    function scaleUnit() public view returns (uint256 value) {
        value = vm.envOr("SCALE_UNIT", DEFAULT_SCALE_UNIT);
        require(value > 0, "SCALE_UNIT must be positive");
    }

    /// @notice A가 거는 WTGXX 수량. WTGXX는 18 decimals 입니다.
    function collateralAmount() public view returns (uint256) {
        return scaleUnit() * 1e18;
    }

    /// @notice 대여자 한 명이 자기 볼트에 넣는 USDC. USDC는 6 decimals 입니다.
    function supplyAmount() public view returns (uint256) {
        return scaleUnit() * 1e6;
    }

    /// @notice 비율에서 차입액을 끌어냅니다. 담보 가치가 1:1이라 예치액을 기준으로 씁니다.
    function drawAmount(uint16 ratio) public view returns (uint256) {
        return (supplyAmount() * ratio) / 1e4;
    }

    struct Deployment {
        address evc;
        address factory;
        address evaultImpl;
        address collateralVaultImpl;
        address router;
        address priceAdapter;
        address irm;
        address zeroRateIrm;
        address maturityRegistry;
        address maturityController;
        address participantRegistry;
        address debtVaultHook;
        address gate;
        address collateralVaultFactory;
        address debtVault;
        address repoOpener;
        address wtgxx;
        address usdc;
        address kycNft;
        address complianceOracle;
    }

    function run() external returns (Deployment memory d) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = pk == 0 ? msg.sender : vm.addr(pk);

        if (pk == 0) vm.startBroadcast(deployer);
        else vm.startBroadcast(pk);

        d = _deploy(deployer);

        vm.stopBroadcast();

        _log(d, deployer);
        _verify(d);
    }

    struct ChainDeployment {
        Deployment d;
        Rung rungC;
        Rung rungD;
        address vaultA;
        address hookA;
        address borrower;
    }

    string internal constant CHAIN_STATE_FILE = "./broadcast/chain-state.json";

    /// @notice 사다리 세 칸을 한 번에 올립니다. 시연 배포의 진입점입니다.
    ///
    /// @dev `run()` 은 기반 스택 + 부채 볼트 하나(V_B)까지입니다. 둘째·셋째 칸은
    ///      `deployRung` 으로 따로 올려야 하는데 지금까지 그걸 부르는 건 테스트뿐이었습니다.
    ///
    ///      **이 함수가 최상위 진입점이어야 합니다.** keystore 로 배포하면 `PRIVATE_KEY` 가
    ///      없고 배포자는 `msg.sender` 인데, forge 는 `--sender` 로 받은 주소를 **최상위
    ///      함수의** `msg.sender` 로만 세웁니다. 다른 스크립트가 `new DeployStack()` 뒤
    ///      외부 호출하면 그 스크립트 주소가 배포자가 되어 거버너와 레지스트리 소유권이
    ///      통째로 아무도 키를 모르는 주소로 갑니다. 되돌릴 수 없습니다.
    ///
    ///          forge script script/DeployStack.s.sol:DeployStack --sig "runChain()" \
    ///            --rpc-url $RPC --account radius-deployer --sender 0x8CBF70... --broadcast
    ///
    ///      `--sender` 를 빼면 로그의 `deployer` 가 `0x1804c8AB...`(Foundry 기본 발신자)로
    ///      찍힙니다. 배포 전에 `--broadcast` 없이 돌려 그 줄을 먼저 확인하세요.
    function runChain() external returns (ChainDeployment memory c) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = pk == 0 ? msg.sender : vm.addr(pk);

        if (pk == 0) vm.startBroadcast(deployer);
        else vm.startBroadcast(pk);
        c.d = _deploy(deployer);
        vm.stopBroadcast();

        _verify(c.d);

        c.borrower = vm.envOr("BORROWER_ADDRESS", deployer);
        (c.vaultA, c.hookA) = deployCollateralVault(c.d, c.borrower);

        c.rungC = deployRung(c.d, c.d.debtVault, RUNG2_BORROW_LTV, RUNG2_LIQUIDATION_LTV, RUNG2_APR);
        c.rungD = deployRung(c.d, c.rungC.debtVault, RUNG3_BORROW_LTV, RUNG3_LIQUIDATION_LTV, RUNG3_APR);

        _logChain(c, deployer);
        _writeChainState(c, deployer);
    }

    function _logChain(ChainDeployment memory c, address deployer) internal view {
        _log(c.d, deployer);

        console.log("");
        console.log("=== rung ladder ===");
        console.log("borrower A             ", c.borrower);
        console.log("V_A collateral vault   ", c.vaultA);
        console.log("V_A hook               ", c.hookA);
        console.log("V_B debt vault         ", c.d.debtVault);
        console.log("V_C debt vault         ", c.rungC.debtVault);
        console.log("V_D debt vault         ", c.rungD.debtVault);
        console.log("opener  B              ", c.d.repoOpener);
        console.log("opener  C              ", c.rungC.opener);
        console.log("opener  D              ", c.rungD.opener);
        console.log("controller B           ", c.d.maturityController);
        console.log("controller C           ", c.rungC.controller);
        console.log("controller D           ", c.rungD.controller);

        console.log("");
        console.log("=== demo amounts ===");
        console.log("SCALE_UNIT             ", scaleUnit());
        console.log("A collateral WTGXX     ", collateralAmount());
        console.log("each lender supplies   ", supplyAmount());
        console.log("A draws                ", drawAmount(DRAW_RUNG1));
        console.log("B draws                ", drawAmount(DRAW_RUNG2));
        console.log("C draws                ", drawAmount(DRAW_RUNG3));
        console.log("market term seconds    ", marketTerm());
        console.log("notice window seconds  ", uint256(noticeWindow()));
        console.log("ramp duration seconds  ", uint256(rampDuration()));
    }

    /// @dev 다음 단계 스크립트가 주소를 읽어갑니다. 사람이 손으로 옮겨 적지 않게 합니다.
    function _writeChainState(ChainDeployment memory c, address deployer) internal {
        string memory json = "chain";
        vm.serializeAddress(json, "evc", c.d.evc);
        vm.serializeAddress(json, "router", c.d.router);
        vm.serializeAddress(json, "maturityRegistry", c.d.maturityRegistry);
        vm.serializeAddress(json, "gate", c.d.gate);
        vm.serializeAddress(json, "wtgxx", c.d.wtgxx);
        vm.serializeAddress(json, "usdc", c.d.usdc);
        vm.serializeAddress(json, "kycNft", c.d.kycNft);
        vm.serializeAddress(json, "deployer", deployer);
        vm.serializeAddress(json, "borrower", c.borrower);
        vm.serializeAddress(json, "vaultA", c.vaultA);
        vm.serializeAddress(json, "vaultB", c.d.debtVault);
        vm.serializeAddress(json, "vaultC", c.rungC.debtVault);
        vm.serializeAddress(json, "vaultD", c.rungD.debtVault);
        vm.serializeAddress(json, "openerB", c.d.repoOpener);
        vm.serializeAddress(json, "openerC", c.rungC.opener);
        vm.serializeAddress(json, "openerD", c.rungD.opener);
        vm.serializeAddress(json, "controllerB", c.d.maturityController);
        vm.serializeAddress(json, "controllerC", c.rungC.controller);
        vm.serializeAddress(json, "controllerD", c.rungD.controller);

        // 금액도 함께 적습니다. **배포 시점의 값이 어디에도 안 남으면 다음 단계
        // 스크립트가 호출 시점 환경 변수를 다시 읽고, 그게 비어 있으면 기본값 100으로
        // 조용히 돌아갑니다.** 10/04 리허설에서 여섯 단계가 그렇게 죽었습니다.
        vm.serializeUint(json, "scaleUnit", scaleUnit());
        vm.serializeUint(json, "collateralAmount", collateralAmount());
        vm.serializeUint(json, "supplyAmount", supplyAmount());
        vm.serializeUint(json, "drawA", drawAmount(DRAW_RUNG1));
        vm.serializeUint(json, "drawB", drawAmount(DRAW_RUNG2));
        string memory out = vm.serializeUint(json, "drawC", drawAmount(DRAW_RUNG3));
        vm.writeJson(out, CHAIN_STATE_FILE);
    }

    function _deploy(address deployer) internal returns (Deployment memory d) {
        // --- 대상 자산. 목업이거나 실물이거나 ---
        d.wtgxx = vm.envOr("WTGXX_ADDRESS", address(0));
        d.usdc = vm.envOr("USDC_ADDRESS", address(0));

        if (d.usdc == address(0)) {
            d.usdc = address(new MockUSDC());
        }

        if (d.wtgxx == address(0)) {
            MockKycNFT kyc = new MockKycNFT(deployer);
            MockComplianceOracle compliance = new MockComplianceOracle(deployer, address(kyc));
            d.kycNft = address(kyc);
            d.complianceOracle = address(compliance);
            d.wtgxx = address(new MockWTGXX(deployer, address(compliance), address(0xDEAD)));
        }

        // --- EVK 기반 ---
        EthereumVaultConnector evc = new EthereumVaultConnector();
        d.evc = address(evc);

        GenericFactory factory = new GenericFactory(deployer);
        d.factory = address(factory);

        ProtocolConfig protocolConfig = new ProtocolConfig(deployer, deployer);
        address sequenceRegistry = address(new SequenceRegistry());

        Base.Integrations memory integrations =
            Base.Integrations(d.evc, address(protocolConfig), sequenceRegistry, address(0), address(0));

        Dispatch.DeployedModules memory modules = Dispatch.DeployedModules({
            initialize: address(new Initialize(integrations)),
            token: address(new Token(integrations)),
            vault: address(new Vault(integrations)),
            borrowing: address(new Borrowing(integrations)),
            liquidation: address(new Liquidation(integrations)),
            riskManager: address(new RiskManager(integrations)),
            balanceForwarder: address(new BalanceForwarder(integrations)),
            governance: address(new Governance(integrations))
        });

        d.evaultImpl = address(new EVault(integrations, modules));
        d.collateralVaultImpl = address(new WTGXXCollateralVault(integrations, modules));

        factory.setImplementation(d.evaultImpl);

        // --- 가격: 라우터 뒤에 어댑터 ---
        EulerRouter router = new EulerRouter(d.evc, deployer);
        d.router = address(router);
        d.priceAdapter = address(new FixedOneToOneOracle(d.wtgxx, d.usdc));
        router.govSetConfig(d.wtgxx, d.usdc, d.priceAdapter);

        // --- Radius 컨트랙트 ---
        d.irm = address(new FixedRateIRM(deployer, NOMINAL_APR));
        // 만기 후 부채를 멈추는 데 쓸 모델. address(0)으로는 안 됩니다 — EVK가 직전
        // 금리를 그대로 두기 때문입니다. MaturityController.zeroRateIrm 주석 참조.
        d.zeroRateIrm = address(new FixedRateIRM(deployer, 0));
        d.maturityRegistry = address(new MaturityRegistry(deployer));
        d.gate = address(new WTGXXGate(d.wtgxx));
        // 자격 판정의 단일 출처. 게이트 + 대비 승인 목록.
        d.participantRegistry = address(new ParticipantRegistry(d.gate, deployer));
        d.collateralVaultFactory = address(new CollateralVaultFactory(d.collateralVaultImpl, d.router, d.usdc));

        // --- 부채 볼트. EVK 표준 팩토리 ---
        IEVault debtVault = IEVault(factory.createProxy(address(0), true, abi.encodePacked(d.usdc, d.router, d.usdc)));
        d.debtVault = address(debtVault);

        // 부채 볼트의 입구에 자격 검사를 붙입니다. 출구에는 붙이지 않습니다. 백서 6.1절.
        // 걸는 연산 집합은 MATURITY_CLOSED_OPS 와 같아야 합니다 — 만기에
        // 같은 연산들이 비활성화로 바뀌며, 어긋나면 그 순간 입구가 다시 열립니다.
        d.debtVaultHook = address(new DebtVaultAccessHook(d.participantRegistry, d.maturityRegistry, d.debtVault));
        debtVault.setHookConfig(d.debtVaultHook, MATURITY_CLOSED_OPS);
        debtVault.setInterestRateModel(d.irm);
        debtVault.setMaxLiquidationDiscount(MAX_LIQUIDATION_DISCOUNT);
        debtVault.setLiquidationCoolOffTime(LIQUIDATION_COOL_OFF);
        debtVault.setConfigFlags(CFG_DONT_SOCIALIZE_DEBT); // 백서 4.5절
        debtVault.setFeeReceiver(deployer);

        // 개시 컨트랙트. 게이트 통과와 만기 기록을 강제하는 유일한 경로입니다.
        // 레지스트리와 순환 의존이라 배포 후 registrar로 지정합니다.
        d.repoOpener = address(new RepoOpener(d.evc, d.gate, d.maturityRegistry, d.debtVault, d.wtgxx));
        MaturityRegistry(d.maturityRegistry).setRegistrar(d.repoOpener);

        // 시장의 만기를 공표합니다. 백서 3.1절. 이 한 줄이 없으면 RepoOpener가
        // 개시를 거부합니다 — 만기 없는 시장에서는 repo를 열 수 없습니다.
        MaturityRegistry(d.maturityRegistry).setMarketMaturity(d.debtVault, block.timestamp + marketTerm());

        // 만기 컨트랙트. 백서 4.4절을 EVK 동작으로 옮깁니다.
        //
        // 관리자 자리에 `deployer`가 아니라 지금의 볼트 거버너를 넣습니다. 둘이 다를 수
        // 있습니다 — 볼트 거버너는 `factory.createProxy`를 부른 주체이고, broadcast 없이
        // 돌면 그것이 이 스크립트 컨트랙트, broadcast 로 돌면 EOA입니다. 온보딩에서
        // configureCollateral 을 부르는 것도 같은 주체이므로 여기서 읽어 맞춥니다.
        d.maturityController = address(
            new MaturityController(
                d.debtVault,
                d.maturityRegistry,
                d.evc,
                debtVault.governorAdmin(),
                d.zeroRateIrm,
                rampDuration(),
                noticeWindow()
            )
        );

        // **거버넌스를 넘깁니다. 부채 볼트 거버넌스 호출은 이 줄보다 위에 있어야 합니다.**
        // 넘긴 뒤에는 배포자가 setLTV를 직접 부를 수 없고, 온보딩은
        // MaturityController.configureCollateral 을 거칩니다. 되돌릴 경로는 없습니다.
        debtVault.setGovernorAdmin(d.maturityController);
    }

    /// @notice 재담보 사다리의 한 칸. 부채 볼트 하나 + 그에 딸린 넷.
    struct Rung {
        address debtVault;
        address hook;
        address controller;
        address opener;
        address irm;
    }

    /// @notice 사다리를 한 칸 올립니다. 아래 칸의 볼트 지분을 담보로 받는 새 시장입니다.
    ///
    /// @param d 배포 결과.
    /// @param collateralVault 담보로 쓸 아래 칸의 볼트. V_B를 넣으면 eV_B가 담보가 됩니다.
    /// @param borrowLTV 개시 한도.
    /// @param liquidationLTV 청산선.
    /// @param apr 이 칸의 명목 금리. 아래 칸보다 낮아야 중간 참여자에게 스프레드가 남습니다.
    ///
    /// @dev **새 컨트랙트가 필요 없습니다.** 재담보가 EVK 위에 자연스럽게 얹히는 이유가
    ///      여기 있습니다 — 대여자의 채권이 이미 ERC-4626 지분이므로, 그것을 그대로 다음
    ///      칸의 담보로 걸면 됩니다. 매니저 원장도, 포장 토큰도 없습니다.
    ///
    ///      가격도 한 줄입니다. `EulerRouter.govSetResolvedVault` 를 부르면 라우터가
    ///      `convertToAssets` 로 지분을 자산으로 풀고, 그 자산이 unitOfAccount와 같으면
    ///      그대로 통과시킵니다(EulerRouter.getQuote: `if (base == quote) return inAmount`).
    ///      어댑터를 새로 쓸 일이 없습니다.
    ///
    ///      칸마다 자기 시장입니다 — 자기 부채 볼트, 자기 만기, 자기 만기 컨트랙트, 자기
    ///      개시 컨트랙트. 백서 3.1절의 "시장 하나에 만기 하나"가 칸마다 성립합니다.
    ///
    ///      **LTV를 여기서 직접 세우는 이유.** 아래 칸의 담보는 이 시장이 만들어지는
    ///      시점에 이미 정해져 있습니다. 거버넌스를 넘기기 전에 세우고 넘깁니다. 반면
    ///      맨 아래 칸의 담보 볼트는 참여자마다 나중에 생기므로
    ///      `MaturityController.configureCollateral` 통로를 거칩니다.
    function deployRung(
        Deployment memory d,
        address collateralVault,
        uint16 borrowLTV,
        uint16 liquidationLTV,
        uint256 apr
    ) public returns (Rung memory r) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = pk == 0 ? msg.sender : vm.addr(pk);
        if (pk == 0) vm.startBroadcast(deployer);
        else vm.startBroadcast(pk);

        IEVault vault = IEVault(GenericFactory(d.factory).createProxy(address(0), true, abi.encodePacked(d.usdc, d.router, d.usdc)));
        r.debtVault = address(vault);

        // 이 칸만의 금리. 아래 칸과 같은 모델을 쓰면 중간 참여자가 수수료만큼 손해입니다.
        r.irm = address(new FixedRateIRM(deployer, apr));
        vault.setInterestRateModel(r.irm);
        vault.setMaxLiquidationDiscount(MAX_LIQUIDATION_DISCOUNT);
        vault.setLiquidationCoolOffTime(LIQUIDATION_COOL_OFF);
        vault.setConfigFlags(CFG_DONT_SOCIALIZE_DEBT);
        vault.setFeeReceiver(deployer);

        r.hook = address(new DebtVaultAccessHook(d.participantRegistry, d.maturityRegistry, r.debtVault));
        vault.setHookConfig(r.hook, MATURITY_CLOSED_OPS);

        // 아래 칸의 지분을 가격으로 풀어 줍니다. 이 한 줄이 재담보의 가격 문제 전부입니다.
        EulerRouter(d.router).govSetResolvedVault(collateralVault, true);
        vault.setLTV(collateralVault, borrowLTV, liquidationLTV, 0);

        // 이 칸의 시장 만기. 아래 칸과 같은 날짜로 둡니다 — 사다리가 한 번에 끝나야
        // 중간 참여자가 아래에서 받기 전에 위에 갚아야 하는 일이 생기지 않습니다.
        MaturityRegistry(d.maturityRegistry).setMarketMaturity(
            r.debtVault, MaturityRegistry(d.maturityRegistry).marketMaturity(d.debtVault)
        );

        r.opener = address(new RepoOpener(d.evc, d.gate, d.maturityRegistry, r.debtVault, IEVault(collateralVault).asset()));
        MaturityRegistry(d.maturityRegistry).setRegistrarEnabled(r.opener, true);

        r.controller = address(
            new MaturityController(
                r.debtVault,
                d.maturityRegistry,
                d.evc,
                vault.governorAdmin(),
                d.zeroRateIrm,
                rampDuration(),
                noticeWindow()
            )
        );
        vault.setGovernorAdmin(r.controller);

        vm.stopBroadcast();

        _verifyRung(d, r, collateralVault, borrowLTV, liquidationLTV, apr);
    }

    function _verifyRung(
        Deployment memory d,
        Rung memory r,
        address collateralVault,
        uint16 borrowLTV,
        uint16 liquidationLTV,
        uint256 apr
    ) internal view {
        IEVault vault = IEVault(r.debtVault);

        require(vault.interestRateModel() == r.irm, "rung irm wiring");
        require(FixedRateIRM(r.irm).ratePerSecond() == (apr * 1e9) / (365.2425 days), "rung rate");

        // 아래 칸보다 금리가 낮아야 중간 참여자에게 스프레드가 남습니다. EVK가 볼트마다
        // 이자의 10%를 떼므로 같은 금리로는 중간이 손해입니다.
        address irmUnder = IEVault(collateralVault).interestRateModel();
        require(irmUnder != address(0), "rung must sit on a debt vault");
        require(
            FixedRateIRM(r.irm).ratePerSecond() < FixedRateIRM(irmUnder).ratePerSecond(),
            "rung rate not below the rung under it"
        );

        require(vault.asset() == d.usdc, "rung asset");
        require(vault.oracle() == d.router, "rung oracle");
        require(vault.unitOfAccount() == d.usdc, "rung unit");
        require(vault.configFlags() == CFG_DONT_SOCIALIZE_DEBT, "rung socialization");
        require(vault.LTVBorrow(collateralVault) == borrowLTV, "rung borrow ltv");
        require(vault.LTVLiquidation(collateralVault) == liquidationLTV, "rung liquidation ltv");
        require(vault.governorAdmin() == r.controller, "rung governor");

        (address hookTarget, uint32 hookedOps) = vault.hookConfig();
        require(hookTarget == r.hook, "rung hook");
        require(hookedOps == MATURITY_CLOSED_OPS, "rung hooked ops");

        require(MaturityRegistry(d.maturityRegistry).isRegistrar(r.opener), "rung registrar");
        require(RepoOpener(r.opener).debtVault() == r.debtVault, "rung opener vault");
        require(
            MaturityRegistry(d.maturityRegistry).marketMaturity(r.debtVault)
                == MaturityRegistry(d.maturityRegistry).marketMaturity(d.debtVault),
            "rung maturity"
        );

        // 아래 칸의 지분이 가격으로 풀리는지. 1:1 자산이므로 환산이 항등에 가깝습니다.
        uint256 quoted = EulerRouter(d.router).getQuote(1e18, collateralVault, d.usdc);
        require(quoted > 0, "rung collateral not priced");
    }

    /// @notice 차입자별 담보 볼트를 배포하고 설정합니다.
    /// @dev 온보딩 시점에 참여자마다 한 번 호출됩니다. 주소는 배포 전에
    ///      collateralVaultFactory.computeAddress 로 알 수 있습니다.
    function deployCollateralVault(Deployment memory d, address borrower) public returns (address vault, address hook) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) vm.startBroadcast(msg.sender);
        else vm.startBroadcast(pk);

        CollateralVaultFactory f = CollateralVaultFactory(d.collateralVaultFactory);
        vault = f.deploy(borrower, d.wtgxx);

        hook = address(new CollateralVaultHook(d.evc, borrower, d.participantRegistry));
        IEVault(vault).setHookConfig(hook, HOOKED_OPS);

        EulerRouter(d.router).govSetResolvedVault(vault, true);
        // 거버너는 MaturityController 입니다. 온보딩 통로를 거칩니다.
        MaturityController(d.maturityController).configureCollateral(vault, BORROW_LTV, LIQUIDATION_LTV);

        vm.stopBroadcast();
    }

    function _log(Deployment memory d, address deployer) internal pure {
        console.log("deployer               ", deployer);
        console.log("EVC                    ", d.evc);
        console.log("GenericFactory         ", d.factory);
        console.log("EVault impl            ", d.evaultImpl);
        console.log("CollateralVault impl   ", d.collateralVaultImpl);
        console.log("EulerRouter            ", d.router);
        console.log("FixedOneToOneOracle    ", d.priceAdapter);
        console.log("FixedRateIRM           ", d.irm);
        console.log("MaturityRegistry       ", d.maturityRegistry);
        console.log("MaturityController     ", d.maturityController);
        console.log("ZeroRateIRM            ", d.zeroRateIrm);
        console.log("WTGXXGate              ", d.gate);
        console.log("ParticipantRegistry    ", d.participantRegistry);
        console.log("DebtVaultAccessHook    ", d.debtVaultHook);
        console.log("CollateralVaultFactory ", d.collateralVaultFactory);
        console.log("DebtVault              ", d.debtVault);
        console.log("RepoOpener             ", d.repoOpener);
        console.log("WTGXX                  ", d.wtgxx);
        console.log("USDC                   ", d.usdc);
    }

    /// @dev 배포 직후 상태를 검증합니다. 하나라도 어긋나면 배포가 실패합니다.
    function _verify(Deployment memory d) internal view {
        IEVault debtVault = IEVault(d.debtVault);

        require(debtVault.asset() == d.usdc, "debt vault asset");
        require(debtVault.oracle() == d.router, "debt vault oracle");
        require(debtVault.unitOfAccount() == d.usdc, "debt vault unit");
        require(debtVault.interestRateModel() == d.irm, "irm wiring");
        require(debtVault.configFlags() == CFG_DONT_SOCIALIZE_DEBT, "socialization not disabled");
        require(debtVault.maxLiquidationDiscount() == MAX_LIQUIDATION_DISCOUNT, "max liquidation discount");
        require(debtVault.liquidationCoolOffTime() == LIQUIDATION_COOL_OFF, "liquidation cool off");

        require(EulerRouter(d.router).getConfiguredOracle(d.wtgxx, d.usdc) == d.priceAdapter, "router adapter");
        require(FixedOneToOneOracle(d.priceAdapter).getQuote(1e18, d.wtgxx, d.usdc) == 1e6, "oracle scaling");
        require(FixedRateIRM(d.irm).ratePerSecond() > 0, "irm rate");
        require(CollateralVaultFactory(d.collateralVaultFactory).oracle() == d.router, "factory oracle");
        require(MaturityRegistry(d.maturityRegistry).registrar() == d.repoOpener, "registrar wiring");
        require(RepoOpener(d.repoOpener).debtVault() == d.debtVault, "opener debt vault");
        require(
            MaturityRegistry(d.maturityRegistry).marketMaturity(d.debtVault) == block.timestamp + marketTerm(),
            "market maturity"
        );

        MaturityController controller = MaturityController(d.maturityController);
        require(debtVault.governorAdmin() == d.maturityController, "governor not handed over");
        require(address(controller.debtVault()) == d.debtVault, "controller debt vault");
        require(address(controller.registry()) == d.maturityRegistry, "controller registry");
        require(controller.zeroRateIrm() == d.zeroRateIrm, "controller zero irm");
        require(controller.rampDuration() == rampDuration(), "controller ramp");
        require(controller.noticeWindow() == noticeWindow(), "controller notice window");
        require(address(controller.evc()) == d.evc, "controller evc");
        require(!controller.marketClosed(), "market already closed");
        require(FixedRateIRM(d.zeroRateIrm).ratePerSecond() == 0, "zero irm not zero");

        (address hookTarget, uint32 hookedOps) = debtVault.hookConfig();
        require(hookTarget == d.debtVaultHook, "debt vault hook");
        require(hookedOps == MATURITY_CLOSED_OPS, "debt vault hooked ops mismatch");
        require(
            address(DebtVaultAccessHook(d.debtVaultHook).registry()) == d.participantRegistry,
            "debt hook registry"
        );
        require(
            address(DebtVaultAccessHook(d.debtVaultHook).maturities()) == d.maturityRegistry,
            "debt hook maturities"
        );
        require(DebtVaultAccessHook(d.debtVaultHook).debtVault() == d.debtVault, "debt hook vault");
        require(
            address(ParticipantRegistry(d.participantRegistry).gate()) == d.gate, "participant registry gate"
        );
    }
}
