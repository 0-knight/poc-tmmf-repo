extern crate std;

use super::*;
use collateral_vault::{CollateralVault, CollateralVaultClient};
use fixed_oracle::FixedOneToOneOracle;
use gate::WtgxxGate;
use maturity_registry::{MaturityRegistry, MaturityRegistryClient};
use participant_registry::{ParticipantRegistry, ParticipantRegistryClient};
use soroban_sdk::testutils::{Address as _, IssuerFlags, Ledger};
use soroban_sdk::token::{StellarAssetClient, TokenClient};
use soroban_sdk::{contract, contractimpl};

// 클래식 자산 7 decimals
const ONE: i128 = 10_000_000;
const DAY: u64 = 86_400;
const T0: u64 = 1_760_000_000;
const MATURITY: u64 = T0 + 7 * DAY;
const NOTICE: u64 = 3_600;

struct World {
    env: Env,
    market: RepoMarketClient<'static>,
    market_id: Address,
    vault: CollateralVaultClient<'static>,
    vault_id: Address,
    wtgxx_t: TokenClient<'static>,
    usdc: StellarAssetClient<'static>,
    usdc_t: TokenClient<'static>,
    participants: ParticipantRegistryClient<'static>,
    maturities: MaturityRegistryClient<'static>,
    a: Address,
    b: Address,
    l: Address,
}

fn build(env: Env, oracle: Option<Address>) -> World {
    env.mock_all_auths();
    env.ledger().set_timestamp(T0);

    let issuer = Address::generate(&env);
    let w_sac = env.register_stellar_asset_contract_v2(issuer.clone());
    w_sac.issuer().set_flag(IssuerFlags::RequiredFlag);
    w_sac.issuer().set_flag(IssuerFlags::RevocableFlag);
    let u_sac = env.register_stellar_asset_contract_v2(issuer);

    let admin = Address::generate(&env);
    let gate = env.register(WtgxxGate, (w_sac.address(),));
    let parts_id = env.register(ParticipantRegistry, (admin.clone(), Some(gate)));
    let mats_id = env.register(MaturityRegistry, (admin.clone(),));
    let oracle = oracle
        .unwrap_or_else(|| env.register(FixedOneToOneOracle, (w_sac.address(), u_sac.address())));

    let config = Config {
        admin: admin.clone(),
        lend_asset: u_sac.address(),
        collateral_asset: w_sac.address(),
        oracle,
        participants: parts_id.clone(),
        maturities: mats_id.clone(),
        rate_bps: 5_000,
        ramp_duration: DAY,
        notice_window: NOTICE,
        max_discount_bps: 200,
    };
    // V_B 칸과 같은 값: LTV 92/95, 50%
    let market_id = env.register(RepoMarket, (config, 9_200u32, 9_500u32));

    let maturities = MaturityRegistryClient::new(&env, &mats_id);
    maturities.set_registrar(&market_id, &true);
    maturities.set_market_maturity(&market_id, &MATURITY);

    let a = Address::generate(&env);
    let b = Address::generate(&env);
    let l = Address::generate(&env);
    let vault_id = env.register(
        CollateralVault,
        (a.clone(), w_sac.address(), parts_id.clone()),
    );

    let wtgxx = StellarAssetClient::new(&env, &w_sac.address());
    let usdc = StellarAssetClient::new(&env, &u_sac.address());
    // 볼트 주소도 발행사 승인 필요 (EVM 의 KYC NFT 대신)
    for who in [&a, &b, &l, &vault_id] {
        wtgxx.set_authorized(who, &true);
    }
    wtgxx.mint(&a, &(100 * ONE));
    usdc.mint(&b, &(100 * ONE));
    usdc.mint(&l, &(200 * ONE));

    World {
        market: RepoMarketClient::new(&env, &market_id),
        market_id,
        vault: CollateralVaultClient::new(&env, &vault_id),
        vault_id,
        wtgxx_t: TokenClient::new(&env, &w_sac.address()),
        usdc_t: TokenClient::new(&env, &u_sac.address()),
        usdc,
        participants: ParticipantRegistryClient::new(&env, &parts_id),
        maturities,
        a,
        b,
        l,
        env,
    }
}

fn world() -> World {
    build(Env::default(), None)
}

// B supplies 100, A borrows 80 against 100 WTGXX
fn opened() -> World {
    let w = world();
    w.market.supply(&w.b, &(100 * ONE));
    w.market.open(
        &w.a,
        &w.vault_id,
        &(100 * ONE),
        &(80 * ONE),
        &MATURITY,
        &w.b,
    );
    w
}

fn err<T: core::fmt::Debug, E: core::fmt::Debug>(
    r: Result<T, Result<E, soroban_sdk::InvokeError>>,
) -> E {
    r.err()
        .expect("expected failure")
        .ok()
        .expect("expected contract error")
}

fn at(w: &World, t: u64) {
    w.env.ledger().set_timestamp(t);
}

#[test]
fn open_and_repay_round_trip() {
    let w = opened();
    assert_eq!(w.usdc_t.balance(&w.a), 80 * ONE);
    assert_eq!(w.vault.balance(), 100 * ONE);
    assert_eq!(w.vault.pledged_to(), Some(w.market_id.clone()));
    assert_eq!(w.maturities.maturity_of(&w.a), MATURITY);
    assert_eq!(w.maturities.counterparty_of(&w.a), Some(w.b.clone()));

    at(&w, MATURITY - 1);
    let debt = w.market.debt_of(&w.a);
    // 80 x 50% x 7/365.2425 ≈ 0.7666 이자
    assert!(
        debt > 80 * ONE + 7_600_000 && debt < 80 * ONE + 7_700_000,
        "debt {debt}"
    );
    w.usdc.mint(&w.a, &ONE);
    assert_eq!(w.market.repay(&w.a, &w.a, &(1_000 * ONE)), debt);

    assert_eq!(w.market.position(&w.a), None);
    assert_eq!(w.vault.pledged_to(), None);
    assert_eq!(w.maturities.maturity_of(&w.a), 0);

    w.vault.withdraw(&w.a, &(100 * ONE));
    assert_eq!(w.wtgxx_t.balance(&w.a), 100 * ONE);

    let shares = w.market.shares_of(&w.b);
    let got = w.market.redeem(&w.b, &shares);
    assert_eq!(got, 100 * ONE + (debt - 80 * ONE));
}

#[test]
fn open_rejects_wrong_maturity() {
    let w = world();
    w.market.supply(&w.b, &(100 * ONE));
    let e = err(w.market.try_open(
        &w.a,
        &w.vault_id,
        &(100 * ONE),
        &(80 * ONE),
        &(MATURITY + 1),
        &w.b,
    ));
    assert_eq!(e, Error::MaturityNotMarketMaturity.into());
}

#[test]
fn open_rejects_ineligible_lender() {
    let w = world();
    w.market.supply(&w.b, &(100 * ONE));
    let stranger = Address::generate(&w.env);
    let e = err(w.market.try_open(
        &w.a,
        &w.vault_id,
        &(100 * ONE),
        &(80 * ONE),
        &MATURITY,
        &stranger,
    ));
    assert_eq!(e, Error::LenderNotEligible.into());
}

#[test]
fn open_rejects_someone_elses_vault() {
    let w = world();
    w.market.supply(&w.b, &(100 * ONE));
    let e = err(w
        .market
        .try_open(&w.b, &w.vault_id, &0, &(10 * ONE), &MATURITY, &w.b));
    assert_eq!(e, Error::VaultMismatch.into());
}

#[test]
fn open_rejects_over_ltv() {
    let w = world();
    w.market.supply(&w.b, &(100 * ONE));
    let e = err(w.market.try_open(
        &w.a,
        &w.vault_id,
        &(100 * ONE),
        &(93 * ONE),
        &MATURITY,
        &w.b,
    ));
    assert_eq!(e, Error::ExceedsBorrowLtv.into());
}

#[test]
fn supply_requires_eligibility() {
    let w = world();
    let stranger = Address::generate(&w.env);
    w.usdc.mint(&stranger, &ONE);
    assert_eq!(
        err(w.market.try_supply(&stranger, &ONE)),
        Error::LenderNotEligible.into()
    );
}

#[test]
fn locked_vault_cannot_withdraw() {
    let w = opened();
    let e = err(w.vault.try_withdraw(&w.a, &ONE));
    assert_eq!(e, collateral_vault::Error::Locked.into());
}

#[test]
fn close_market_freezes_debt_and_blocks_entry() {
    let w = opened();
    assert_eq!(
        err(w.market.try_close_market()),
        Error::NotYetMatured.into()
    );

    at(&w, MATURITY);
    w.market.close_market();
    let frozen = w.market.debt_of(&w.a);

    at(&w, MATURITY + 30 * DAY);
    assert_eq!(w.market.debt_of(&w.a), frozen, "연체 이자 없음");

    assert_eq!(
        err(w.market.try_supply(&w.b, &ONE)),
        Error::MarketClosed.into()
    );
    assert_eq!(
        err(w.market.try_configure_collateral(&9_900, &9_900)),
        Error::MarketClosed.into()
    );

    // 상환은 닫힌 뒤에도 가능
    w.usdc.mint(&w.a, &ONE);
    w.market.repay(&w.a, &w.a, &frozen);
    assert_eq!(w.market.position(&w.a), None);
}

#[test]
fn notice_window_only_counterparty() {
    let w = opened();
    at(&w, MATURITY + 10);
    let stranger = Address::generate(&w.env);
    assert!(!w.market.can_trigger(&w.a, &stranger));
    assert_eq!(
        err(w.market.try_trigger_maturity(&stranger, &w.a)),
        Error::NoticeWindowRestricted.into()
    );
    assert!(w.market.can_trigger(&w.a, &w.b));
    w.market.trigger_maturity(&w.b, &w.a);
    assert!(w.market.closed_at() != 0, "부도 선언은 시장도 닫는다");
    assert_eq!(
        err(w.market.try_trigger_maturity(&w.b, &w.a)),
        Error::RampAlreadyStarted.into()
    );
}

#[test]
fn notice_window_agent() {
    let w = opened();
    let agent = Address::generate(&w.env);
    w.market.set_agent(&w.b, &agent, &true);
    at(&w, MATURITY + 10);
    w.market.trigger_maturity(&agent, &w.a);
}

#[test]
fn notice_window_expires_to_anyone() {
    let w = opened();
    at(&w, MATURITY + NOTICE);
    let anyone = Address::generate(&w.env);
    w.market.trigger_maturity(&anyone, &w.a);
}

#[test]
fn ramp_opens_liquidation_over_time() {
    let w = opened();
    at(&w, MATURITY);
    w.market.trigger_maturity(&w.b, &w.a);
    let debt = w.market.debt_of(&w.a);

    // 92 > 80.77, 아직 건전
    let h = w.market.health(&w.a);
    assert_eq!(h.liquidation_ltv_bps, 9_200);
    assert_eq!(
        err(w.market.try_liquidate(&w.l, &w.a, &debt)),
        Error::Healthy.into()
    );

    // 원본 README 기준 약 12% 지점에서 열림
    let opens_at = ((BPS - debt * BPS * BPS / (100 * ONE * 9_200)) as u64) * DAY / BPS as u64;
    at(&w, MATURITY + opens_at - 60);
    assert!(w.market.try_liquidate(&w.l, &w.a, &debt).is_err());
    at(&w, MATURITY + opens_at + 600);
    let (repaid, seized) = w.market.liquidate(&w.l, &w.a, &debt);

    assert_eq!(repaid, debt);
    // 열리고 10분 뒤 -> 할인 2% 상한 미만
    let discount_bps = (seized - repaid) * BPS / seized;
    assert!(
        discount_bps > 0 && discount_bps < 200,
        "discount {discount_bps}"
    );
    assert_eq!(w.wtgxx_t.balance(&w.l), seized);
    assert_eq!(w.market.position(&w.a), None);
    assert_eq!(w.vault.pledged_to(), None);
    w.vault.withdraw(&w.a, &(100 * ONE - seized));
}

#[test]
fn discount_is_capped() {
    let w = opened();
    at(&w, MATURITY);
    w.market.trigger_maturity(&w.b, &w.a);
    at(&w, MATURITY + DAY); // 사다리 끝. 청산선 0.
    let debt = w.market.debt_of(&w.a);
    let (repaid, seized) = w.market.liquidate(&w.l, &w.a, &debt);
    assert_eq!(seized, repaid * BPS / (BPS - 200));
}

#[test]
fn seizure_rejects_ineligible_liquidator() {
    let w = opened();
    at(&w, MATURITY + DAY + NOTICE);
    w.market.trigger_maturity(&w.b, &w.a);
    at(&w, MATURITY + 2 * DAY + NOTICE);
    let x = Address::generate(&w.env);
    w.usdc.mint(&x, &(100 * ONE));
    let debt = w.market.debt_of(&w.a);
    let e = err(w.market.try_liquidate(&x, &w.a, &debt));
    assert_eq!(
        e,
        collateral_vault::Error::SeizureRecipientNotEligible.into()
    );
    assert_eq!(w.usdc_t.balance(&x), 100 * ONE);
}

// EVM 판과 다른 점: 레지스트리 승인만 있고 발행사 미승인이면 청산 자체가 revert
#[test]
fn seizure_to_issuer_unauthorized_reverts_atomically() {
    let w = opened();
    at(&w, MATURITY);
    w.market.trigger_maturity(&w.b, &w.a);
    at(&w, MATURITY + DAY);

    let ops = Address::generate(&w.env);
    w.participants.set_approved(&ops, &true); // Radius 는 승인, 발행사는 미승인
    w.usdc.mint(&ops, &(100 * ONE));
    let debt = w.market.debt_of(&w.a);

    assert!(w.market.try_liquidate(&ops, &w.a, &debt).is_err());
    assert_eq!(w.usdc_t.balance(&ops), 100 * ONE, "상환도 되돌아감");
    assert_eq!(w.market.debt_of(&w.a), debt, "부채 그대로");
    assert_eq!(w.vault.balance(), 100 * ONE, "담보 그대로");
}

#[contract]
pub struct MockOracle;

#[contractimpl]
impl MockOracle {
    pub fn set_price_bps(env: Env, p: i128) {
        env.storage().instance().set(&0u32, &p);
    }
    pub fn quote(env: Env, amount: i128, base: Address, quote: Address) -> i128 {
        let p: i128 = env.storage().instance().get(&0u32).unwrap_or(BPS);
        let usdc: Address = env.storage().instance().get(&1u32).unwrap();
        if base == quote {
            amount
        } else if quote == usdc {
            amount * p / BPS
        } else {
            amount * BPS / p
        }
    }
    pub fn set_usdc(env: Env, a: Address) {
        env.storage().instance().set(&1u32, &a);
    }
}

// WTGXX 0.70 -> 담보 소진 후에도 bad debt 는 차입자에게 남고 total_assets 불변
#[test]
fn bad_debt_is_not_socialized() {
    let env = Env::default();
    let oracle = env.register(MockOracle, ());
    let w = build(env, Some(oracle));
    let mock = MockOracleClient::new(&w.env, &w.market.config().oracle);
    mock.set_usdc(&w.usdc_t.address);

    w.market.supply(&w.b, &(100 * ONE));
    w.market.open(
        &w.a,
        &w.vault_id,
        &(100 * ONE),
        &(80 * ONE),
        &MATURITY,
        &w.b,
    );
    at(&w, MATURITY);
    w.market.trigger_maturity(&w.b, &w.a);
    mock.set_price_bps(&7_000);
    at(&w, MATURITY + DAY);

    let before = w.market.total_assets();
    let debt = w.market.debt_of(&w.a);
    let (repaid, seized) = w.market.liquidate(&w.l, &w.a, &debt);
    assert_eq!(seized, 100 * ONE, "담보 전부");
    let left = w.market.debt_of(&w.a);
    assert!(left > 0 && left == debt - repaid);
    assert_eq!(
        w.market.total_assets(),
        before,
        "지분 가격은 움직이지 않는다"
    );

    // B 청구권 - 현금 = A bad debt
    let claim = w.market.convert_to_assets(&w.market.shares_of(&w.b));
    assert_eq!(claim - w.market.cash(), left);
    assert!(w
        .market
        .try_redeem(&w.b, &w.market.shares_of(&w.b))
        .is_err());
}
