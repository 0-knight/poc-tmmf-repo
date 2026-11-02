#![no_std]
//! 컨트랙트 간 호출 인터페이스와 공용 상수

use soroban_sdk::{contractclient, Address, Env};

pub const BPS: i128 = 10_000;

// 365.2425 days, EVK 와 동일
pub const SECONDS_PER_YEAR: u64 = 31_556_952;

pub const INDEX_SCALE: i128 = 1_000_000_000_000_000_000;

// TTL ~30d, 7d 남으면 연장. TODO: 만기 긴 마켓은 별도 연장 러너 필요
pub const PERSISTENT_TTL: u32 = 518_400;
pub const PERSISTENT_THRESHOLD: u32 = 120_960;

/// 구현체는 panic 하면 안 됨
#[contractclient(name = "GateClient")]
pub trait ComplianceGate {
    fn can_enter(env: Env, who: Address) -> bool;
}

#[contractclient(name = "ParticipantsClient")]
pub trait Participants {
    fn is_eligible(env: Env, who: Address) -> bool;
}

#[contractclient(name = "MaturitiesClient")]
pub trait Maturities {
    fn market_maturity(env: Env, market: Address) -> u64;
    fn maturity_of(env: Env, account: Address) -> u64;
    fn counterparty_of(env: Env, account: Address) -> Option<Address>;
    fn set_maturity(env: Env, caller: Address, account: Address, maturity: u64);
    fn set_counterparty(env: Env, caller: Address, account: Address, counterparty: Address);
    fn clear_maturity(env: Env, caller: Address, account: Address);
}

#[contractclient(name = "VaultClient")]
pub trait CollateralVault {
    fn owner(env: Env) -> Address;
    fn asset(env: Env) -> Address;
    fn balance(env: Env) -> i128;
    fn pledged_to(env: Env) -> Option<Address>;
    fn deposit(env: Env, from: Address, amount: i128);
    fn pledge(env: Env, market: Address);
    fn release(env: Env);
    fn seize(env: Env, to: Address, amount: i128);
}

#[contractclient(name = "OracleClient")]
pub trait PriceOracle {
    fn quote(env: Env, amount: i128, base: Address, quote: Address) -> i128;
}
