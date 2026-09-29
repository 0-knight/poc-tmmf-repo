.PHONY: install build test test-fork test-vault deploy-local deploy-gate scenario scenario-liquidate anvil clean

# git apply 는 서브모듈을 인덱스에 등록하지 못합니다. forge install 로 명시적으로 받습니다.
install:
	@test -f lib/euler-vault-kit/src/EVault/EVault.sol \
	  || forge install euler-xyz/euler-vault-kit
	@test -f lib/euler-price-oracle/src/EulerRouter.sol \
	  || forge install euler-xyz/euler-price-oracle
	cd lib/euler-vault-kit && git submodule update --init --recursive --depth 1
	cd lib/euler-price-oracle && git submodule update --init --recursive --depth 1

build:
	forge build

test:
	forge test

test-fork:
	forge test --match-path "test/fork/*" -vv

test-vault:
	forge test --match-path "test/unit/WTGXXCollateralVault.t.sol" -vv

anvil:
	anvil

# M1 컨트랙트만. 게이트를 손으로 눌러볼 때 씁니다.
deploy-gate:
	forge script script/DeployLocal.s.sol:DeployLocal \
	  --rpc-url http://127.0.0.1:8545 --broadcast \
	  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# 스택 전체. EVC, 볼트, 라우터, IRM, 팩토리까지.
deploy-local:
	forge script script/DeployStack.s.sol:DeployStack \
	  --rpc-url http://127.0.0.1:8545 --broadcast \
	  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

ANVIL_RPC := http://127.0.0.1:8545
DEPLOYER_PK := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
SCENARIO := forge script script/Scenario.s.sol:Scenario --rpc-url $(ANVIL_RPC) --broadcast

# 정상 종료. anvil 이 떠 있어야 합니다.
scenario:
	@PRIVATE_KEY=$(DEPLOYER_PK) $(SCENARIO) --sig "step1_deploy()"
	@PRIVATE_KEY=$(DEPLOYER_PK) $(SCENARIO) --sig "step2_open()"
	@PRIVATE_KEY=$(DEPLOYER_PK) forge script script/Scenario.s.sol:Scenario \
	  --rpc-url $(ANVIL_RPC) --sig "step2b_probeLock()"
	@cast rpc evm_increaseTime 604800 --rpc-url $(ANVIL_RPC) > /dev/null
	@cast rpc evm_mine --rpc-url $(ANVIL_RPC) > /dev/null
	@PRIVATE_KEY=$(DEPLOYER_PK) $(SCENARIO) --sig "step3_close()"

# 디폴트 청산. anvil 을 새로 띄운 상태에서 돌리세요.
scenario-liquidate:
	@PRIVATE_KEY=$(DEPLOYER_PK) $(SCENARIO) --sig "step1_deploy()"
	@PRIVATE_KEY=$(DEPLOYER_PK) $(SCENARIO) --sig "step2_open()"
	@cast rpc evm_increaseTime 691200 --rpc-url $(ANVIL_RPC) > /dev/null
	@cast rpc evm_mine --rpc-url $(ANVIL_RPC) > /dev/null
	@PRIVATE_KEY=$(DEPLOYER_PK) $(SCENARIO) --sig "step4_liquidate()"

clean:
	forge clean
