#![no_std]
//! 시장/계정 만기와 상대방 기록. 강제는 repo-market 에서 함

use common::{PERSISTENT_THRESHOLD, PERSISTENT_TTL};
use soroban_sdk::{
    contract, contracterror, contractevent, contractimpl, contracttype, panic_with_error, Address,
    Env,
};

#[contracterror]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum Error {
    NotAuthorized = 1,
    AlreadySet = 2,
    MaturityInPast = 3,
    NotSet = 4,
    CounterpartyAlreadySet = 5,
}

#[contracttype]
enum Key {
    Admin,
    Registrar(Address),
    MarketMaturity(Address),
    Maturity(Address),
    Counterparty(Address),
}

#[contractevent]
pub struct MaturitySet {
    #[topic]
    pub account: Address,
    pub maturity: u64,
    pub set_by: Address,
}

#[contractevent]
pub struct MaturityCleared {
    #[topic]
    pub account: Address,
    pub cleared_by: Address,
}

#[contractevent]
pub struct CounterpartySet {
    #[topic]
    pub account: Address,
    pub counterparty: Address,
}

#[contractevent]
pub struct MarketMaturitySet {
    #[topic]
    pub market: Address,
    pub previous: u64,
    pub current: u64,
}

#[contract]
pub struct MaturityRegistry;

fn bump(env: &Env, key: &Key) {
    env.storage()
        .persistent()
        .extend_ttl(key, PERSISTENT_THRESHOLD, PERSISTENT_TTL);
}

#[contractimpl]
impl MaturityRegistry {
    pub fn __constructor(env: Env, admin: Address) {
        env.storage().instance().set(&Key::Admin, &admin);
    }

    pub fn admin(env: Env) -> Address {
        env.storage().instance().get(&Key::Admin).unwrap()
    }

    /// 칸마다 마켓이 하나씩이라 registrar 는 여러 개
    pub fn set_registrar(env: Env, who: Address, enabled: bool) {
        Self::admin(env.clone()).require_auth();
        let key = Key::Registrar(who);
        if enabled {
            env.storage().persistent().set(&key, &true);
            bump(&env, &key);
        } else {
            env.storage().persistent().remove(&key);
        }
    }

    pub fn is_registrar(env: Env, who: Address) -> bool {
        env.storage()
            .persistent()
            .get(&Key::Registrar(who))
            .unwrap_or(false)
    }

    pub fn set_market_maturity(env: Env, market: Address, maturity: u64) {
        Self::admin(env.clone()).require_auth();
        let now = env.ledger().timestamp();
        if maturity <= now {
            panic_with_error!(&env, Error::MaturityInPast);
        }
        let key = Key::MarketMaturity(market.clone());
        let previous: u64 = env.storage().persistent().get(&key).unwrap_or(0);
        env.storage().persistent().set(&key, &maturity);
        bump(&env, &key);
        MarketMaturitySet {
            market,
            previous,
            current: maturity,
        }
        .publish(&env);
    }

    pub fn market_maturity(env: Env, market: Address) -> u64 {
        env.storage()
            .persistent()
            .get(&Key::MarketMaturity(market))
            .unwrap_or(0)
    }

    pub fn is_market_matured(env: Env, market: Address) -> bool {
        let m = Self::market_maturity(env.clone(), market);
        m != 0 && env.ledger().timestamp() >= m
    }

    pub fn set_maturity(env: Env, caller: Address, account: Address, maturity: u64) {
        Self::require_account_or_registrar(&env, &caller, &account);
        let key = Key::Maturity(account.clone());
        if env.storage().persistent().has(&key) {
            panic_with_error!(&env, Error::AlreadySet);
        }
        if maturity <= env.ledger().timestamp() {
            panic_with_error!(&env, Error::MaturityInPast);
        }
        env.storage().persistent().set(&key, &maturity);
        bump(&env, &key);
        MaturitySet {
            account,
            maturity,
            set_by: caller,
        }
        .publish(&env);
    }

    pub fn set_counterparty(env: Env, caller: Address, account: Address, counterparty: Address) {
        Self::require_account_or_registrar(&env, &caller, &account);
        if !env
            .storage()
            .persistent()
            .has(&Key::Maturity(account.clone()))
        {
            panic_with_error!(&env, Error::NotSet);
        }
        let key = Key::Counterparty(account.clone());
        if env.storage().persistent().has(&key) {
            panic_with_error!(&env, Error::CounterpartyAlreadySet);
        }
        env.storage().persistent().set(&key, &counterparty);
        bump(&env, &key);
        CounterpartySet {
            account,
            counterparty,
        }
        .publish(&env);
    }

    pub fn clear_maturity(env: Env, caller: Address, account: Address) {
        Self::require_account_or_registrar(&env, &caller, &account);
        let key = Key::Maturity(account.clone());
        if !env.storage().persistent().has(&key) {
            panic_with_error!(&env, Error::NotSet);
        }
        env.storage().persistent().remove(&key);
        env.storage()
            .persistent()
            .remove(&Key::Counterparty(account.clone()));
        MaturityCleared {
            account,
            cleared_by: caller,
        }
        .publish(&env);
    }

    pub fn maturity_of(env: Env, account: Address) -> u64 {
        env.storage()
            .persistent()
            .get(&Key::Maturity(account))
            .unwrap_or(0)
    }

    pub fn counterparty_of(env: Env, account: Address) -> Option<Address> {
        env.storage().persistent().get(&Key::Counterparty(account))
    }

    pub fn is_defaulted(env: Env, account: Address) -> bool {
        let m = Self::maturity_of(env.clone(), account);
        m != 0 && env.ledger().timestamp() > m
    }

    pub fn time_to_maturity(env: Env, account: Address) -> u64 {
        let m = Self::maturity_of(env.clone(), account);
        let now = env.ledger().timestamp();
        if m == 0 || now >= m {
            0
        } else {
            m - now
        }
    }
}

impl MaturityRegistry {
    fn require_account_or_registrar(env: &Env, caller: &Address, account: &Address) {
        caller.require_auth();
        if caller != account && !Self::is_registrar(env.clone(), caller.clone()) {
            panic_with_error!(env, Error::NotAuthorized);
        }
    }
}

#[cfg(test)]
mod test {
    extern crate std;
    use super::*;
    use soroban_sdk::testutils::{Address as _, Ledger};

    fn setup() -> (Env, MaturityRegistryClient<'static>) {
        let env = Env::default();
        env.mock_all_auths();
        env.ledger().set_timestamp(1_000);
        let id = env.register(MaturityRegistry, (Address::generate(&env),));
        (env.clone(), MaturityRegistryClient::new(&env, &id))
    }

    #[test]
    fn registrar_records_and_clears() {
        let (env, reg) = setup();
        let market = Address::generate(&env);
        let a = Address::generate(&env);
        let b = Address::generate(&env);
        reg.set_registrar(&market, &true);
        reg.set_maturity(&market, &a, &2_000);
        reg.set_counterparty(&market, &a, &b);
        assert_eq!(reg.maturity_of(&a), 2_000);
        assert_eq!(reg.counterparty_of(&a), Some(b));
        assert_eq!(reg.time_to_maturity(&a), 1_000);

        env.ledger().set_timestamp(2_001);
        assert!(reg.is_defaulted(&a));

        reg.clear_maturity(&market, &a);
        assert_eq!(reg.maturity_of(&a), 0);
        assert_eq!(reg.counterparty_of(&a), None);
    }

    #[test]
    fn stranger_cannot_record() {
        let (env, reg) = setup();
        let stranger = Address::generate(&env);
        let a = Address::generate(&env);
        let r = reg.try_set_maturity(&stranger, &a, &2_000);
        assert_eq!(r.err().unwrap().ok().unwrap(), Error::NotAuthorized.into());
    }

    #[test]
    fn no_overwrite() {
        let (env, reg) = setup();
        let a = Address::generate(&env);
        reg.set_maturity(&a, &a, &2_000);
        let r = reg.try_set_maturity(&a, &a, &3_000);
        assert_eq!(r.err().unwrap().ok().unwrap(), Error::AlreadySet.into());
    }

    #[test]
    fn market_maturity_must_be_future() {
        let (env, reg) = setup();
        let m = Address::generate(&env);
        assert!(reg.try_set_market_maturity(&m, &999).is_err());
        reg.set_market_maturity(&m, &5_000);
        assert!(!reg.is_market_matured(&m));
        env.ledger().set_timestamp(5_000);
        assert!(reg.is_market_matured(&m));
    }
}
