#![no_std]
//! WTGXX 진입 게이트. SAC authorized() 로 판정, AUTH_REQUIRED 해제는 카나리아로 감지

use soroban_sdk::{
    contract, contractimpl, contracttype, vec, Address, Env, IntoVal, InvokeError, Symbol,
};

#[contracttype]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum Reason {
    Allowed = 0,
    /// AUTH_REQUIRED 꺼짐 (EVM: compliance == 0)
    ComplianceRemoved = 2,
    /// 미승인 또는 승인 철회 (EVM: frozen / not whitelisted)
    NotAuthorized = 5,
    /// 트러스트라인 없음 or 호출 실패
    CallFailed = 6,
}

/// 압류 전 진단용. Stellar 에서는 SAC 가 어차피 막아서 UI 표시 용도
#[contracttype]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum Blocker {
    None = 0,
    VaultNotAuthorized = 2,
    RecipientNotAuthorized = 4,
    ComplianceRemoved = 5,
    CallFailed = 6,
}

#[contracttype]
enum Key {
    Token,
}

#[contract]
pub struct WtgxxGate;

#[contractimpl]
impl WtgxxGate {
    pub fn __constructor(env: Env, token: Address) {
        env.storage().instance().set(&Key::Token, &token);
    }

    pub fn token(env: Env) -> Address {
        env.storage().instance().get(&Key::Token).unwrap()
    }

    /// panic 하지 않음
    pub fn can_enter(env: Env, who: Address) -> bool {
        Self::check_entry(env, who) == Reason::Allowed
    }

    pub fn check_entry(env: Env, who: Address) -> Reason {
        match Self::compliance_removed(&env) {
            None => return Reason::CallFailed,
            Some(true) => return Reason::ComplianceRemoved,
            Some(false) => {}
        }
        match authorized(&env, &who) {
            None => Reason::CallFailed,
            Some(true) => Reason::Allowed,
            Some(false) => Reason::NotAuthorized,
        }
    }

    pub fn check_exit(env: Env, vault: Address, recipient: Address) -> Blocker {
        let removed = match Self::compliance_removed(&env) {
            None => return Blocker::CallFailed,
            Some(r) => r,
        };
        match authorized(&env, &vault) {
            None => return Blocker::CallFailed,
            Some(false) => return Blocker::VaultNotAuthorized,
            Some(true) => {}
        }
        match authorized(&env, &recipient) {
            None => return Blocker::CallFailed,
            Some(false) => return Blocker::RecipientNotAuthorized,
            Some(true) => {}
        }
        if removed {
            Blocker::ComplianceRemoved
        } else {
            Blocker::None
        }
    }
}

impl WtgxxGate {
    /// 카나리아: 게이트 주소는 승인된 적 없음. authorized == true 면 AUTH_REQUIRED 가 꺼진 것
    fn compliance_removed(env: &Env) -> Option<bool> {
        authorized(env, &env.current_contract_address())
    }
}

fn authorized(env: &Env, who: &Address) -> Option<bool> {
    let token: Address = env.storage().instance().get(&Key::Token).unwrap();
    let func: Symbol = Symbol::new(env, "authorized");
    let args = vec![env, who.into_val(env)];
    let res: Result<Result<bool, _>, Result<soroban_sdk::Error, InvokeError>> =
        env.try_invoke_contract::<bool, soroban_sdk::Error>(&token, &func, args);
    match res {
        Ok(Ok(v)) => Some(v),
        _ => None,
    }
}

#[cfg(test)]
mod test;
