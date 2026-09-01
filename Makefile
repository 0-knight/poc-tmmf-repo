.PHONY: build test test-fork deploy-local anvil clean

build:
	forge build

test:
	forge test

test-fork:
	forge test --match-path "test/fork/*" -vv

anvil:
	anvil

deploy-local:
	forge script script/DeployLocal.s.sol:DeployLocal \
	  --rpc-url http://127.0.0.1:8545 --broadcast \
	  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

clean:
	forge clean
