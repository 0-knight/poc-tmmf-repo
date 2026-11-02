#![no_std]
//! 볼트 결정적 배포.
//! 주소에 코드 해시가 안 들어감 -> 검증할 때 wasm_hash 도 같이 볼 것

use soroban_sdk::{
    contract, contracterror, contractevent, contractimpl, contracttype, panic_with_error,
    xdr::ToXdr, Address, Bytes, BytesN, ContractExecutable, Env,
};

#[contracterror]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum Error {
    AlreadyDeployed = 1,
}

#[contracttype]
enum Key {
    WasmHash,
    Participants,
    VaultOf(Address, Address),
}

#[contractevent]
pub struct VaultDeployed {
    #[topic]
    pub borrower: Address,
    #[topic]
    pub asset: Address,
    pub vault: Address,
}

#[contract]
pub struct VaultFactory;

#[contractimpl]
impl VaultFactory {
    pub fn __constructor(env: Env, vault_wasm_hash: BytesN<32>, participants: Address) {
        env.storage()
            .instance()
            .set(&Key::WasmHash, &vault_wasm_hash);
        env.storage()
            .instance()
            .set(&Key::Participants, &participants);
    }

    pub fn wasm_hash(env: Env) -> BytesN<32> {
        env.storage().instance().get(&Key::WasmHash).unwrap()
    }

    /// sha256(borrower xdr || asset xdr)
    pub fn salt_for(env: Env, borrower: Address, asset: Address) -> BytesN<32> {
        let mut b = Bytes::new(&env);
        b.append(&borrower.to_xdr(&env));
        b.append(&asset.to_xdr(&env));
        env.crypto().sha256(&b).into()
    }

    pub fn compute_address(env: Env, borrower: Address, asset: Address) -> Address {
        let salt = Self::salt_for(env.clone(), borrower, asset);
        env.deployer()
            .with_current_contract(salt)
            .deployed_address()
    }

    pub fn vault_of(env: Env, borrower: Address, asset: Address) -> Option<Address> {
        env.storage()
            .persistent()
            .get(&Key::VaultOf(borrower, asset))
    }

    /// 누구나 호출 가능. 주소는 (borrower, asset) 으로 고정
    pub fn deploy(env: Env, borrower: Address, asset: Address) -> Address {
        let key = Key::VaultOf(borrower.clone(), asset.clone());
        if env.storage().persistent().has(&key) {
            panic_with_error!(&env, Error::AlreadyDeployed);
        }
        let salt = Self::salt_for(env.clone(), borrower.clone(), asset.clone());
        let participants: Address = env.storage().instance().get(&Key::Participants).unwrap();
        let vault = env.deployer().with_current_contract(salt).deploy_contract(
            ContractExecutable::Wasm(Self::wasm_hash(env.clone())),
            (borrower.clone(), asset.clone(), participants),
        );
        env.storage().persistent().set(&key, &vault);
        VaultDeployed {
            borrower,
            asset,
            vault: vault.clone(),
        }
        .publish(&env);
        vault
    }
}

#[cfg(test)]
mod test {
    extern crate std;
    use super::*;
    use soroban_sdk::testutils::Address as _;

    #[test]
    fn address_is_known_before_deploy_and_depends_on_pair() {
        let env = Env::default();
        let hash = BytesN::from_array(&env, &[7u8; 32]);
        let id = env.register(VaultFactory, (hash, Address::generate(&env)));
        let f = VaultFactoryClient::new(&env, &id);
        let a = Address::generate(&env);
        let b = Address::generate(&env);
        let wtgxx = Address::generate(&env);
        let x = f.compute_address(&a, &wtgxx);
        assert_eq!(x, f.compute_address(&a, &wtgxx));
        assert_ne!(x, f.compute_address(&b, &wtgxx));
    }

    // TODO: wasm 빌드 후 contractimport! 로 붙이기
    #[test]
    #[ignore]
    fn deploy_lands_on_computed_address() {
        // let wasm = env.deployer().upload_contract_wasm(collateral_vault::WASM);
    }
}
