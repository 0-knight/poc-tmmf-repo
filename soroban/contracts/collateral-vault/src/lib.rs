#![no_std]
//! 차입자 1인 전용 담보 볼트. share 없이 잔고만 들고, 압류 시 WTGXX 를 바로 옮김

use common::ParticipantsClient;
use soroban_sdk::{
    contract, contracterror, contractevent, contractimpl, contracttype, panic_with_error, token,
    Address, Env,
};

#[contracterror]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum Error {
    DepositorNotOwner = 1,
    AlreadyPledged = 2,
    NotPledged = 3,
    Locked = 4,
    SeizureRecipientNotEligible = 5,
    NonPositiveAmount = 6,
}

#[contracttype]
enum Key {
    Owner,
    Asset,
    Participants,
    PledgedTo,
}

#[contractevent]
pub struct Pledged {
    #[topic]
    pub market: Address,
}

#[contractevent]
pub struct Released {
    #[topic]
    pub market: Address,
}

#[contractevent]
pub struct Seized {
    #[topic]
    pub market: Address,
    #[topic]
    pub to: Address,
    pub amount: i128,
}

#[contract]
pub struct CollateralVault;

#[contractimpl]
impl CollateralVault {
    pub fn __constructor(env: Env, owner: Address, asset: Address, participants: Address) {
        let s = env.storage().instance();
        s.set(&Key::Owner, &owner);
        s.set(&Key::Asset, &asset);
        s.set(&Key::Participants, &participants);
    }

    pub fn owner(env: Env) -> Address {
        env.storage().instance().get(&Key::Owner).unwrap()
    }

    pub fn asset(env: Env) -> Address {
        env.storage().instance().get(&Key::Asset).unwrap()
    }

    pub fn balance(env: Env) -> i128 {
        token::Client::new(&env, &Self::asset(env.clone())).balance(&env.current_contract_address())
    }

    pub fn pledged_to(env: Env) -> Option<Address> {
        env.storage().instance().get(&Key::PledgedTo)
    }

    pub fn deposit(env: Env, from: Address, amount: i128) {
        from.require_auth();
        if amount <= 0 {
            panic_with_error!(&env, Error::NonPositiveAmount);
        }
        if from != Self::owner(env.clone()) {
            panic_with_error!(&env, Error::DepositorNotOwner);
        }
        token::Client::new(&env, &Self::asset(env.clone())).transfer(
            &from,
            &env.current_contract_address(),
            &amount,
        );
    }

    /// market.open 안에서 차입자 서명으로 함께 호출됨
    pub fn pledge(env: Env, market: Address) {
        Self::owner(env.clone()).require_auth();
        if Self::pledged_to(env.clone()).is_some() {
            panic_with_error!(&env, Error::AlreadyPledged);
        }
        env.storage().instance().set(&Key::PledgedTo, &market);
        Pledged { market }.publish(&env);
    }

    pub fn release(env: Env) {
        let market = Self::require_pledged_market(&env);
        env.storage().instance().remove(&Key::PledgedTo);
        Released { market }.publish(&env);
    }

    /// 출구는 자격 검사 안 함 (백서 6.1)
    pub fn withdraw(env: Env, to: Address, amount: i128) {
        Self::owner(env.clone()).require_auth();
        if Self::pledged_to(env.clone()).is_some() {
            panic_with_error!(&env, Error::Locked);
        }
        token::Client::new(&env, &Self::asset(env.clone())).transfer(
            &env.current_contract_address(),
            &to,
            &amount,
        );
    }

    pub fn seize(env: Env, to: Address, amount: i128) {
        let market = Self::require_pledged_market(&env);
        if amount <= 0 {
            panic_with_error!(&env, Error::NonPositiveAmount);
        }
        let participants: Address = env.storage().instance().get(&Key::Participants).unwrap();
        if !ParticipantsClient::new(&env, &participants).is_eligible(&to) {
            panic_with_error!(&env, Error::SeizureRecipientNotEligible);
        }
        // 수령자가 발행사 미승인이면 SAC transfer 가 실패 -> 청산 전체 revert
        token::Client::new(&env, &Self::asset(env.clone())).transfer(
            &env.current_contract_address(),
            &to,
            &amount,
        );
        Seized { market, to, amount }.publish(&env);
    }
}

impl CollateralVault {
    fn require_pledged_market(env: &Env) -> Address {
        let Some(market) = Self::pledged_to(env.clone()) else {
            panic_with_error!(env, Error::NotPledged);
        };
        market.require_auth();
        market
    }
}
