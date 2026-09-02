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

    uint16 internal constant INITIAL_LTV = 0.9e4; // 90%
    uint16 internal constant MAX_LIQUIDATION_DISCOUNT = 0.2e4; // 20%
    uint256 internal constant NOMINAL_APR = 0.5e18; // 연 50% 명목

    struct Deployment {
        address evc;
        address factory;
        address evaultImpl;
        address collateralVaultImpl;
        address router;
        address priceAdapter;
        address irm;
        address maturityRegistry;
        address gate;
        address collateralVaultFactory;
        address debtVault;
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
        d.priceAdapter = address(new FixedOneToOneOracle(d.wtgxx, 18, d.usdc, 6));
        router.govSetConfig(d.wtgxx, d.usdc, d.priceAdapter);

        // --- Radius 컨트랙트 ---
        d.irm = address(new FixedRateIRM(deployer, NOMINAL_APR));
        d.maturityRegistry = address(new MaturityRegistry(deployer));
        d.gate = address(new WTGXXGate(d.wtgxx));
        d.collateralVaultFactory = address(new CollateralVaultFactory(d.collateralVaultImpl, d.router, d.usdc));

        // --- 부채 볼트. EVK 표준 팩토리 ---
        IEVault debtVault = IEVault(factory.createProxy(address(0), true, abi.encodePacked(d.usdc, d.router, d.usdc)));
        d.debtVault = address(debtVault);

        debtVault.setHookConfig(address(0), 0);
        debtVault.setInterestRateModel(d.irm);
        debtVault.setMaxLiquidationDiscount(MAX_LIQUIDATION_DISCOUNT);
        debtVault.setConfigFlags(CFG_DONT_SOCIALIZE_DEBT); // 백서 4.5절
        debtVault.setFeeReceiver(deployer);
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

        hook = address(new CollateralVaultHook(d.evc, borrower));
        IEVault(vault).setHookConfig(hook, HOOKED_OPS);

        EulerRouter(d.router).govSetResolvedVault(vault, true);
        IEVault(d.debtVault).setLTV(vault, INITIAL_LTV, INITIAL_LTV, 0);

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
        console.log("WTGXXGate              ", d.gate);
        console.log("CollateralVaultFactory ", d.collateralVaultFactory);
        console.log("DebtVault              ", d.debtVault);
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

        require(EulerRouter(d.router).getConfiguredOracle(d.wtgxx, d.usdc) == d.priceAdapter, "router adapter");
        require(FixedOneToOneOracle(d.priceAdapter).getQuote(1e18, d.wtgxx, d.usdc) == 1e6, "oracle scaling");
        require(FixedRateIRM(d.irm).ratePerSecond() > 0, "irm rate");
        require(CollateralVaultFactory(d.collateralVaultFactory).oracle() == d.router, "factory oracle");
    }
}
