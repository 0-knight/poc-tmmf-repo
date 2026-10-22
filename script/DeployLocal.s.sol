// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockWTGXX} from "../src/mocks/MockWTGXX.sol";
import {MockKycNFT} from "../src/mocks/MockKycNFT.sol";
import {MockComplianceOracle} from "../src/mocks/MockComplianceOracle.sol";
import {FixedOneToOneOracle} from "../src/oracle/FixedOneToOneOracle.sol";
import {MaturityRegistry} from "../src/registry/MaturityRegistry.sol";
import {WTGXXGate} from "../src/gate/WTGXXGate.sol";

/// @title DeployLocal
/// @notice anvil에 M1 스택 전체를 올립니다.
///
/// @dev 목업 WTGXX를 씁니다. M8에서 실물로 전환할 때는 DeploySepolia를 따로 둡니다.
///      배포 순서에 의존성이 있습니다. KYC NFT -> 컴플라이언스 오라클 -> 토큰 -> 게이트.
contract DeployLocal is Script {
    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = pk == 0 ? msg.sender : vm.addr(pk);

        if (pk == 0) {
            vm.startBroadcast();
        } else {
            vm.startBroadcast(pk);
        }

        // 발행 권한과 관리 권한을 배포자가 갖습니다. PoC 한정입니다.
        MockKycNFT kyc = new MockKycNFT(deployer);
        MockComplianceOracle oracle = new MockComplianceOracle(deployer, address(kyc));
        MockWTGXX wtgxx = new MockWTGXX(deployer, address(oracle), address(0xDEAD));
        MockUSDC usdc = new MockUSDC();

        FixedOneToOneOracle priceOracle = new FixedOneToOneOracle(address(wtgxx), address(usdc));
        MaturityRegistry registry = new MaturityRegistry(deployer);
        WTGXXGate gate = new WTGXXGate(address(wtgxx));

        vm.stopBroadcast();

        console.log("deployer          ", deployer);
        console.log("MockKycNFT        ", address(kyc));
        console.log("ComplianceOracle  ", address(oracle));
        console.log("MockWTGXX         ", address(wtgxx));
        console.log("MockUSDC          ", address(usdc));
        console.log("FixedOneToOne     ", address(priceOracle));
        console.log("MaturityRegistry  ", address(registry));
        console.log("WTGXXGate         ", address(gate));

        // 배포 직후 상태 확인. 하나라도 어긋나면 즉시 드러납니다.
        require(wtgxx.decimals() == 18, "wtgxx decimals");
        require(usdc.decimals() == 6, "usdc decimals");
        require(wtgxx.getCompliance() == address(oracle), "compliance wiring");
        require(priceOracle.getQuote(1e18, address(wtgxx), address(usdc)) == 1e6, "oracle scaling");
        require(!gate.canEnter(deployer), "deployer should not be whitelisted yet");
    }
}
