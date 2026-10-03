// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {IEVault} from "evk/EVault/IEVault.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";

import {DeployStack} from "./DeployStack.s.sol";
import {RepoOpener} from "../src/repo/RepoOpener.sol";
import {LiquidationPrecheck} from "../src/repo/LiquidationPrecheck.sol";
import {MaturityRegistry} from "../src/registry/MaturityRegistry.sol";
import {WTGXXGate} from "../src/gate/WTGXXGate.sol";
import {MockWTGXX} from "../src/mocks/MockWTGXX.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockKycNFT} from "../src/mocks/MockKycNFT.sol";

interface IEVCLike {
    function setAccountOperator(address account, address operator, bool authorized) external payable;
    function enableController(address account, address vault) external payable;
    function enableCollateral(address account, address vault) external payable;
    function disableController(address vault) external payable;
    function batch(IEVC.BatchItem[] calldata items) external payable;
}

interface ILiquidationCall {
    function liquidate(address violator, address collateral, uint256 repayAssets, uint256 minYieldBalance) external;
    function repay(uint256 amount, address receiver) external returns (uint256);
}

/// @title Scenario
/// @notice 실제 트랜잭션으로 전체 시나리오를 돌립니다.
///
/// @dev 단위 테스트와 다른 점이 둘입니다.
///
///      **vm.prank 이 없습니다.** 각 역할이 자기 개인키로 서명합니다. 테스트에서는
///      msg.sender 를 마음대로 바꿨지만 실제로는 operator 등록이 차입자 본인 트랜잭션이어야
///      하고, 청산은 대여자 본인 트랜잭션이어야 합니다.
///
///      **vm.warp 이 없습니다.** anvil 에서는 evm_increaseTime RPC 로 시간을 옮기고,
///      Sepolia 에서는 실제로 기다려야 합니다. 그래서 시나리오를 단계로 나눠 각각 따로
///      실행할 수 있게 했습니다.
///
///      실행 (anvil 기준. 별도 터미널에서 anvil 을 띄워둡니다):
///
///          forge script script/Scenario.s.sol:Scenario --sig "step1_deploy()" \
///            --rpc-url http://127.0.0.1:8545 --broadcast
///
///          forge script script/Scenario.s.sol:Scenario --sig "step2_open()" \
///            --rpc-url http://127.0.0.1:8545 --broadcast
///
///          cast rpc evm_increaseTime 604800 --rpc-url http://127.0.0.1:8545
///          cast rpc evm_mine --rpc-url http://127.0.0.1:8545
///
///          forge script script/Scenario.s.sol:Scenario --sig "step3_close()" \
///            --rpc-url http://127.0.0.1:8545 --broadcast
///
///      또는 make scenario 로 한 번에 돌립니다.
///
///      각 단계가 주소를 파일에 저장하고 다음 단계가 읽습니다. Sepolia 로 옮길 때는
///      RPC 만 바꾸면 됩니다.
contract Scenario is Script {
    /// @dev anvil 기본 계정. 역할별로 나눕니다.
    uint256 internal constant PK_DEPLOYER = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant PK_BORROWER = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant PK_LENDER = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;

    uint256 internal constant COLLATERAL = 100e18;
    uint256 internal constant PRINCIPAL = 80e6;

    string internal constant STATE_FILE = "./broadcast/scenario-state.json";

    function _pk(string memory name, uint256 fallbackPk) internal view returns (uint256) {
        return vm.envOr(name, fallbackPk);
    }

    // --- 1단계. 배포와 온보딩 ---

    function step1_deploy() external {
        uint256 deployerPk = _pk("PRIVATE_KEY", PK_DEPLOYER);
        address borrower = vm.addr(_pk("BORROWER_PK", PK_BORROWER));
        address lender = vm.addr(_pk("LENDER_PK", PK_LENDER));

        DeployStack deployScript = new DeployStack();
        DeployStack.Deployment memory d = deployScript.run();
        (address vault,) = deployScript.deployCollateralVault(d, borrower);

        RepoOpener opener = RepoOpener(d.repoOpener);
        LiquidationPrecheck precheck;

        vm.startBroadcast(deployerPk);
        precheck = new LiquidationPrecheck(d.wtgxx);

        // 온보딩. 실물에서는 WisdomTree 가 발행하는 부분입니다.
        if (d.kycNft != address(0)) {
            MockKycNFT(d.kycNft).safeMint(vault);
            MockKycNFT(d.kycNft).safeMint(borrower);
            MockKycNFT(d.kycNft).safeMint(lender);
            MockWTGXX(d.wtgxx).mint(borrower, COLLATERAL);
            // 대여 자금 1000 + 청산 시 부채 상환용 여유분.
            // 청산인은 부채를 인수하고 곧바로 갚아야 하므로 예치액 외에 현금이 필요합니다.
            MockUSDC(d.usdc).mint(lender, 2_000e6);
        }
        vm.stopBroadcast();

        _writeState(d, vault, address(precheck), borrower, lender);

        console.log("");
        console.log("=== step1. deploy and onboard ===");
        console.log("borrower               ", borrower);
        console.log("lender                 ", lender);
        console.log("collateral vault       ", vault);
        console.log("debt vault             ", d.debtVault);
        console.log("repo opener            ", d.repoOpener);
        console.log("liquidation precheck   ", address(precheck));
        console.log("");
        console.log("gate.canEnter(borrower)", WTGXXGate(d.gate).canEnter(borrower));
        console.log("gate.canEnter(lender)  ", WTGXXGate(d.gate).canEnter(lender));
        console.log("");
        console.log("market maturity        ", MaturityRegistry(d.maturityRegistry).marketMaturity(d.debtVault));
        console.log("now                    ", block.timestamp);
        console.log("borrow LTV             ", IEVault(d.debtVault).LTVBorrow(vault));
        console.log("liquidation LTV        ", IEVault(d.debtVault).LTVLiquidation(vault));
        console.log("max liq discount       ", IEVault(d.debtVault).maxLiquidationDiscount());
        console.log("");
        console.log("vault address was predictable:", vault == opener.debtVault() ? false : true);
    }

    // --- 2단계. 개시 ---

    function step2_open() external {
        State memory s = _readState();

        // 대여자가 자금을 공급합니다. 대여자 본인 트랜잭션입니다.
        vm.startBroadcast(_pk("LENDER_PK", PK_LENDER));
        MockUSDC(s.usdc).approve(s.debtVault, type(uint256).max);
        IEVault(s.debtVault).deposit(1_000e6, s.lender);
        vm.stopBroadcast();

        // 차입자가 operator 를 등록하고 대출을 엽니다. 차입자 본인 트랜잭션입니다.
        // 테스트에서는 vm.prank 로 넘어갔던 부분이며, 실제로는 두 트랜잭션입니다.
        //
        // 만기는 시장에서 읽습니다. 백서 3.1절. 전까지 여기서 block.timestamp + 7 days 로
        // 계산했는데, step1 과 step2 가 다른 블록이라 차입자마다 만기가 달라졌습니다.
        uint256 maturity = MaturityRegistry(s.maturityRegistry).marketMaturity(s.debtVault);
        require(maturity != 0, "market not open");

        vm.startBroadcast(_pk("BORROWER_PK", PK_BORROWER));
        MockWTGXX(s.wtgxx).approve(s.vault, type(uint256).max);
        IEVCLike(s.evc).setAccountOperator(s.borrower, s.repoOpener, true);
        RepoOpener(s.repoOpener).open(s.vault, COLLATERAL, PRINCIPAL, maturity, s.lender);
        vm.stopBroadcast();

        console.log("");
        console.log("=== step2. open ===");
        console.log("borrower USDC          ", MockUSDC(s.usdc).balanceOf(s.borrower));
        console.log("borrower vault shares  ", IEVault(s.vault).balanceOf(s.borrower));
        console.log("borrower debt          ", IEVault(s.debtVault).debtOf(s.borrower));
        console.log("maturity recorded      ", MaturityRegistry(s.maturityRegistry).maturityOf(s.borrower));
        console.log("is defaulted           ", MaturityRegistry(s.maturityRegistry).isDefaulted(s.borrower));
    }

    /// @notice 담보가 잠겼는지 확인합니다. 이 호출은 실패해야 정상입니다.
    /// @dev broadcast 하지 않습니다. 실패를 관찰만 합니다. 실제 실패 트랜잭션 해시가
    ///      필요하면 cast send 로 직접 보내세요 — README 참조.
    function step2b_probeLock() external {
        State memory s = _readState();

        vm.prank(s.borrower);
        (bool ok,) =
            s.vault.call(abi.encodeWithSignature("withdraw(uint256,address,address)", 30e18, s.borrower, s.borrower));

        console.log("");
        console.log("=== step2b. collateral lock probe ===");
        console.log("withdraw succeeded     ", ok);
        console.log("expected               ", false);
        require(!ok, "collateral was NOT locked");
    }

    // --- 3단계. 정상 종료 ---

    function step3_close() external {
        State memory s = _readState();

        uint256 debt = IEVault(s.debtVault).debtOf(s.borrower);

        // 이자만큼 채워줍니다. 실물에서는 차입자가 스스로 마련합니다.
        vm.startBroadcast(_pk("PRIVATE_KEY", PK_DEPLOYER));
        MockUSDC(s.usdc).mint(s.borrower, debt);
        vm.stopBroadcast();

        vm.startBroadcast(_pk("BORROWER_PK", PK_BORROWER));
        MockUSDC(s.usdc).approve(s.debtVault, type(uint256).max);
        IEVault(s.debtVault).repay(type(uint256).max, s.borrower);
        IEVCLike(s.evc).disableController(s.debtVault);
        IEVault(s.vault).withdraw(COLLATERAL, s.borrower, s.borrower);
        vm.stopBroadcast();

        console.log("");
        console.log("=== step3. close ===");
        console.log("debt at close          ", debt);
        console.log("interest paid          ", debt - PRINCIPAL);
        console.log("borrower WTGXX         ", MockWTGXX(s.wtgxx).balanceOf(s.borrower));
        console.log("borrower debt          ", IEVault(s.debtVault).debtOf(s.borrower));
        console.log("collateral returned    ", MockWTGXX(s.wtgxx).balanceOf(s.borrower) == COLLATERAL);
    }

    // --- 4단계. 디폴트 청산 ---

    /// @notice 만기가 지난 상태에서 청산합니다. step2 후 시간을 넘기고 step3 대신 부릅니다.
    function step4_liquidate() external {
        State memory s = _readState();

        console.log("");
        console.log("=== step4. default liquidation ===");
        console.log("is defaulted           ", MaturityRegistry(s.maturityRegistry).isDefaulted(s.borrower));

        // 청산 전 사전검사. 통과할 때만 진행합니다.
        bool canSettle = LiquidationPrecheck(s.precheck).canSettle(s.vault, s.lender);
        console.log("precheck before        ", canSettle);
        require(canSettle, "precheck failed before liquidation");

        // 만기 경과를 EVK 언어로 번역합니다. 거버넌스 트랜잭션입니다.
        vm.startBroadcast(_pk("PRIVATE_KEY", PK_DEPLOYER));
        IEVault(s.debtVault).setLTV(s.vault, 0.7e4, 0.7e4, 0);
        vm.stopBroadcast();

        (uint256 maxRepay,) = IEVault(s.debtVault).checkLiquidation(s.lender, s.borrower, s.vault);
        console.log("max repay after setLTV ", maxRepay);
        require(maxRepay > 0, "liquidation still not possible");

        // 청산과 상환을 배치로 묶습니다. 대여자 본인 트랜잭션입니다.
        vm.startBroadcast(_pk("LENDER_PK", PK_LENDER));
        MockUSDC(s.usdc).approve(s.debtVault, type(uint256).max);
        IEVCLike(s.evc).enableController(s.lender, s.debtVault);
        IEVCLike(s.evc).enableCollateral(s.lender, s.vault);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: s.debtVault,
            onBehalfOfAccount: s.lender,
            value: 0,
            data: abi.encodeCall(ILiquidationCall.liquidate, (s.borrower, s.vault, maxRepay, 0))
        });
        items[1] = IEVC.BatchItem({
            targetContract: s.debtVault,
            onBehalfOfAccount: s.lender,
            value: 0,
            data: abi.encodeCall(ILiquidationCall.repay, (type(uint256).max, s.lender))
        });
        IEVCLike(s.evc).batch(items);
        vm.stopBroadcast();

        uint256 shares = IEVault(s.vault).balanceOf(s.lender);
        console.log("lender vault shares    ", shares);
        console.log("lender WTGXX (yet)     ", MockWTGXX(s.wtgxx).balanceOf(s.lender));

        // 인출 직전 재확인. 청산과 인출 사이에 상태가 바뀔 수 있습니다.
        require(LiquidationPrecheck(s.precheck).canSettle(s.vault, s.lender), "precheck failed before withdraw");

        vm.startBroadcast(_pk("LENDER_PK", PK_LENDER));
        IEVault(s.vault).withdraw(shares, s.lender, s.lender);
        vm.stopBroadcast();

        console.log("lender WTGXX (now)     ", MockWTGXX(s.wtgxx).balanceOf(s.lender));
        console.log("borrower residual      ", IEVault(s.vault).balanceOf(s.borrower));
    }

    // --- 상태 저장 ---

    struct State {
        address evc;
        address vault;
        address debtVault;
        address repoOpener;
        address maturityRegistry;
        address gate;
        address precheck;
        address wtgxx;
        address usdc;
        address kycNft;
        address borrower;
        address lender;
    }

    function _writeState(
        DeployStack.Deployment memory d,
        address vault,
        address precheck,
        address borrower,
        address lender
    ) internal {
        string memory json = "state";
        vm.serializeAddress(json, "evc", d.evc);
        vm.serializeAddress(json, "vault", vault);
        vm.serializeAddress(json, "debtVault", d.debtVault);
        vm.serializeAddress(json, "repoOpener", d.repoOpener);
        vm.serializeAddress(json, "maturityRegistry", d.maturityRegistry);
        vm.serializeAddress(json, "gate", d.gate);
        vm.serializeAddress(json, "precheck", precheck);
        vm.serializeAddress(json, "wtgxx", d.wtgxx);
        vm.serializeAddress(json, "usdc", d.usdc);
        vm.serializeAddress(json, "kycNft", d.kycNft);
        vm.serializeAddress(json, "borrower", borrower);
        string memory out = vm.serializeAddress(json, "lender", lender);
        vm.writeJson(out, STATE_FILE);
    }

    function _readState() internal view returns (State memory s) {
        string memory json = vm.readFile(STATE_FILE);
        s.evc = vm.parseJsonAddress(json, ".evc");
        s.vault = vm.parseJsonAddress(json, ".vault");
        s.debtVault = vm.parseJsonAddress(json, ".debtVault");
        s.repoOpener = vm.parseJsonAddress(json, ".repoOpener");
        s.maturityRegistry = vm.parseJsonAddress(json, ".maturityRegistry");
        s.gate = vm.parseJsonAddress(json, ".gate");
        s.precheck = vm.parseJsonAddress(json, ".precheck");
        s.wtgxx = vm.parseJsonAddress(json, ".wtgxx");
        s.usdc = vm.parseJsonAddress(json, ".usdc");
        s.kycNft = vm.parseJsonAddress(json, ".kycNft");
        s.borrower = vm.parseJsonAddress(json, ".borrower");
        s.lender = vm.parseJsonAddress(json, ".lender");
    }
}
