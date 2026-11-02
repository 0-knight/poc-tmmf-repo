#![no_std]
//! 1:1 고정 오라클 (PoC 용). TODO: NAV 이탈 감시 어댑터로 교체

use soroban_sdk::{
    contract, contracterror, contractimpl, contracttype, panic_with_error, token, Address, Env,
};

#[contracterror]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum Error {
    PairNotSupported = 1,
    SameAsset = 2,
    DecimalsOutOfRange = 3,
}

#[contracttype]
enum Key {
    A,
    B,
    ScaleA,
    ScaleB,
}

#[contract]
pub struct FixedOneToOneOracle;

#[contractimpl]
impl FixedOneToOneOracle {
    pub fn __constructor(env: Env, asset_a: Address, asset_b: Address) {
        if asset_a == asset_b {
            panic_with_error!(&env, Error::SameAsset);
        }
        let sa = scale_of(&env, &asset_a);
        let sb = scale_of(&env, &asset_b);
        let s = env.storage().instance();
        s.set(&Key::A, &asset_a);
        s.set(&Key::B, &asset_b);
        s.set(&Key::ScaleA, &sa);
        s.set(&Key::ScaleB, &sb);
    }

    /// 내림 (담보 과소평가 쪽)
    pub fn quote(env: Env, amount: i128, base: Address, quote: Address) -> i128 {
        if base == quote {
            return amount;
        }
        let s = env.storage().instance();
        let a: Address = s.get(&Key::A).unwrap();
        let b: Address = s.get(&Key::B).unwrap();
        let sa: i128 = s.get(&Key::ScaleA).unwrap();
        let sb: i128 = s.get(&Key::ScaleB).unwrap();
        if base == a && quote == b {
            amount * sb / sa
        } else if base == b && quote == a {
            amount * sa / sb
        } else {
            panic_with_error!(&env, Error::PairNotSupported)
        }
    }
}

fn scale_of(env: &Env, asset: &Address) -> i128 {
    let d = token::Client::new(env, asset).decimals();
    if d > 18 {
        panic_with_error!(env, Error::DecimalsOutOfRange);
    }
    10i128.pow(d)
}
