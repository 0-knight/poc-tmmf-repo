#![no_std]
//! 사다리 한 칸 = 마켓 하나.
//! EVM 판의 부채 볼트, IRM, 진입 훅, RepoOpener, MaturityController 를 합친 것.
//! TODO: 대여 지분 SEP-41 노출(재담보), step-in 후 counterparty 갱신

use common::{
    MaturitiesClient, OracleClient, ParticipantsClient, VaultClient, BPS, INDEX_SCALE,
    PERSISTENT_THRESHOLD, PERSISTENT_TTL, SECONDS_PER_YEAR,
};
use soroban_sdk::{
    contract, contracterror, contractevent, contractimpl, contracttype, panic_with_error, token,
    Address, Env,
};

#[contracterror]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum Error {
    ZeroAmount = 1,
    MarketNotOpen = 2,
    MarketClosed = 3,
    NotYetMatured = 4,
    MarketAlreadyClosed = 5,
    MaturityNotInFuture = 6,
    MaturityNotMarketMaturity = 7,
    VaultMismatch = 8,
    BorrowerNotEligible = 9,
    LenderNotEligible = 10,
    PositionExists = 11,
    NoPosition = 12,
    ExceedsBorrowLtv = 13,
    InsufficientCash = 14,
    CollateralNotConfigured = 15,
    RampAlreadyStarted = 16,
    NoticeWindowRestricted = 17,
    NotCollateralHolder = 18,
    Healthy = 19,
    InsufficientShares = 20,
    RecipientNotEligible = 21,
    InvalidLtv = 22,
}

/// 금리 포함 전부 불변 (백서 3.1). 칸마다 마켓을 따로 배포
#[contracttype]
#[derive(Clone, Debug)]
pub struct Config {
    pub admin: Address,
    pub lend_asset: Address,
    pub collateral_asset: Address,
    pub oracle: Address,
    pub participants: Address,
    pub maturities: Address,
    /// 명목 연이율, bps. 50% = 5000.
    pub rate_bps: u32,
    /// 청산선이 개시 LTV 에서 0 까지 내려가는 시간(초).
    pub ramp_duration: u64,
    /// 만기 후 상대방만 부도 선언 가능한 기간(초). GMRA ¶10(b)
    pub notice_window: u64,
    /// 청산 할인 상한, bps
    pub max_discount_bps: u32,
}

#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Position {
    pub vault: Address,
    /// debt = scaled * index / 1e18 (올림)
    pub scaled_debt: i128,
    /// 0 = 사다리 시작 전
    pub ramp_started_at: u64,
}

#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Health {
    pub collateral_value: i128,
    pub liquidation_ltv_bps: i128,
    pub adjusted_collateral: i128,
    pub debt: i128,
}

#[contracttype]
enum Key {
    Config,
    BorrowLtv,
    LiqLtv,
    Index,
    LastAccrual,
    TotalScaled,
    TotalShares,
    ClosedAt,
    Position(Address),
    Shares(Address),
    Agent(Address, Address),
}

#[contractevent]
pub struct RepoOpened {
    #[topic]
    pub borrower: Address,
    #[topic]
    pub lender: Address,
    pub vault: Address,
    pub collateral_amount: i128,
    pub principal: i128,
    pub maturity: u64,
}

#[contractevent]
pub struct MarketClosed {
    pub at: u64,
}

#[contractevent]
pub struct MaturityTriggered {
    #[topic]
    pub borrower: Address,
    #[topic]
    pub noticed_by: Address,
    pub ramp_from_bps: u32,
    pub at: u64,
}

#[contractevent]
pub struct Liquidated {
    #[topic]
    pub borrower: Address,
    #[topic]
    pub liquidator: Address,
    pub repaid: i128,
    pub seized: i128,
    pub discount_bps: i128,
    pub remaining_debt: i128,
}

#[contract]
pub struct RepoMarket;

fn cfg(env: &Env) -> Config {
    env.storage().instance().get(&Key::Config).unwrap()
}

fn get_i(env: &Env, k: &Key) -> i128 {
    env.storage().instance().get(k).unwrap_or(0)
}

fn get_u(env: &Env, k: &Key) -> u64 {
    env.storage().instance().get(k).unwrap_or(0)
}

fn bump_instance(env: &Env) {
    env.storage()
        .instance()
        .extend_ttl(PERSISTENT_THRESHOLD, PERSISTENT_TTL);
}

fn load_position(env: &Env, who: &Address) -> Option<Position> {
    env.storage().persistent().get(&Key::Position(who.clone()))
}

fn save_position(env: &Env, who: &Address, p: &Position) {
    let k = Key::Position(who.clone());
    env.storage().persistent().set(&k, p);
    env.storage()
        .persistent()
        .extend_ttl(&k, PERSISTENT_THRESHOLD, PERSISTENT_TTL);
}

fn shares_of(env: &Env, who: &Address) -> i128 {
    env.storage()
        .persistent()
        .get(&Key::Shares(who.clone()))
        .unwrap_or(0)
}

fn set_shares(env: &Env, who: &Address, v: i128) {
    let k = Key::Shares(who.clone());
    if v == 0 {
        env.storage().persistent().remove(&k);
    } else {
        env.storage().persistent().set(&k, &v);
        env.storage()
            .persistent()
            .extend_ttl(&k, PERSISTENT_THRESHOLD, PERSISTENT_TTL);
    }
}

fn ceil_div(a: i128, b: i128) -> i128 {
    (a + b - 1) / b
}

// 시장이 닫히면 closed_at 에서 이자 정지
fn current_index(env: &Env) -> (i128, u64) {
    let c = cfg(env);
    let mut idx = get_i(env, &Key::Index);
    let last = get_u(env, &Key::LastAccrual);
    let closed = get_u(env, &Key::ClosedAt);
    let end = if closed > 0 {
        closed
    } else {
        env.ledger().timestamp()
    };
    if end > last {
        let dt = (end - last) as i128;
        idx += idx * c.rate_bps as i128 * dt / (BPS * SECONDS_PER_YEAR as i128);
    }
    (idx, end.max(last))
}

fn accrue(env: &Env) -> i128 {
    let (idx, t) = current_index(env);
    env.storage().instance().set(&Key::Index, &idx);
    env.storage().instance().set(&Key::LastAccrual, &t);
    idx
}

fn debt_at(scaled: i128, idx: i128) -> i128 {
    if scaled == 0 {
        0
    } else {
        ceil_div(scaled * idx, INDEX_SCALE)
    }
}

#[contractimpl]
impl RepoMarket {
    pub fn __constructor(env: Env, config: Config, borrow_ltv_bps: u32, liq_ltv_bps: u32) {
        if borrow_ltv_bps > liq_ltv_bps || liq_ltv_bps as i128 > BPS {
            panic_with_error!(&env, Error::InvalidLtv);
        }
        let s = env.storage().instance();
        s.set(&Key::Config, &config);
        s.set(&Key::BorrowLtv, &borrow_ltv_bps);
        s.set(&Key::LiqLtv, &liq_ltv_bps);
        s.set(&Key::Index, &INDEX_SCALE);
        s.set(&Key::LastAccrual, &env.ledger().timestamp());
    }

    pub fn supply(env: Env, lender: Address, amount: i128) -> i128 {
        lender.require_auth();
        bump_instance(&env);
        if amount <= 0 {
            panic_with_error!(&env, Error::ZeroAmount);
        }
        Self::require_open(&env);
        let c = cfg(&env);
        if !ParticipantsClient::new(&env, &c.participants).is_eligible(&lender) {
            panic_with_error!(&env, Error::LenderNotEligible);
        }
        accrue(&env);
        let total_shares = get_i(&env, &Key::TotalShares);
        let total_assets = Self::total_assets(env.clone());
        let minted = if total_shares == 0 || total_assets == 0 {
            amount
        } else {
            amount * total_shares / total_assets
        };
        token::Client::new(&env, &c.lend_asset).transfer(
            &lender,
            &env.current_contract_address(),
            &amount,
        );
        env.storage()
            .instance()
            .set(&Key::TotalShares, &(total_shares + minted));
        set_shares(&env, &lender, shares_of(&env, &lender) + minted);
        minted
    }

    /// 출구라 자격 검사 없음. 현금 부족하면 실패 (손실이 드러나는 곳)
    pub fn redeem(env: Env, lender: Address, shares: i128) -> i128 {
        lender.require_auth();
        bump_instance(&env);
        if shares <= 0 {
            panic_with_error!(&env, Error::ZeroAmount);
        }
        let held = shares_of(&env, &lender);
        if shares > held {
            panic_with_error!(&env, Error::InsufficientShares);
        }
        accrue(&env);
        let assets = Self::convert_to_assets(env.clone(), shares);
        if assets > Self::cash(env.clone()) {
            panic_with_error!(&env, Error::InsufficientCash);
        }
        let total = get_i(&env, &Key::TotalShares);
        env.storage()
            .instance()
            .set(&Key::TotalShares, &(total - shares));
        set_shares(&env, &lender, held - shares);
        token::Client::new(&env, &cfg(&env).lend_asset).transfer(
            &env.current_contract_address(),
            &lender,
            &assets,
        );
        assets
    }

    /// step-in 용. 수령자 자격 필요
    pub fn transfer_shares(env: Env, from: Address, to: Address, shares: i128) {
        from.require_auth();
        bump_instance(&env);
        let held = shares_of(&env, &from);
        if shares <= 0 || shares > held {
            panic_with_error!(&env, Error::InsufficientShares);
        }
        if !ParticipantsClient::new(&env, &cfg(&env).participants).is_eligible(&to) {
            panic_with_error!(&env, Error::RecipientNotEligible);
        }
        set_shares(&env, &from, held - shares);
        set_shares(&env, &to, shares_of(&env, &to) + shares);
    }

    /// EVC operator 대신. 통지 권한만 위임
    pub fn set_agent(env: Env, lender: Address, agent: Address, enabled: bool) {
        lender.require_auth();
        let k = Key::Agent(lender, agent);
        if enabled {
            env.storage().persistent().set(&k, &true);
            env.storage()
                .persistent()
                .extend_ttl(&k, PERSISTENT_THRESHOLD, PERSISTENT_TTL);
        } else {
            env.storage().persistent().remove(&k);
        }
    }

    /// 유일한 차입 경로. borrow 를 따로 열어두지 않음
    pub fn open(
        env: Env,
        borrower: Address,
        vault: Address,
        collateral_amount: i128,
        principal: i128,
        maturity: u64,
        lender: Address,
    ) {
        borrower.require_auth();
        bump_instance(&env);
        let c = cfg(&env);
        let me = env.current_contract_address();

        if principal <= 0 {
            panic_with_error!(&env, Error::ZeroAmount);
        }
        Self::require_open(&env);
        if maturity <= env.ledger().timestamp() {
            panic_with_error!(&env, Error::MaturityNotInFuture);
        }
        let mats = MaturitiesClient::new(&env, &c.maturities);
        let market = mats.market_maturity(&me);
        if market == 0 {
            panic_with_error!(&env, Error::MarketNotOpen);
        }
        if maturity != market {
            panic_with_error!(&env, Error::MaturityNotMarketMaturity);
        }

        let v = VaultClient::new(&env, &vault);
        if v.asset() != c.collateral_asset || v.owner() != borrower {
            panic_with_error!(&env, Error::VaultMismatch);
        }

        let parts = ParticipantsClient::new(&env, &c.participants);
        if !parts.is_eligible(&borrower) {
            panic_with_error!(&env, Error::BorrowerNotEligible);
        }
        if !parts.is_eligible(&lender) {
            panic_with_error!(&env, Error::LenderNotEligible);
        }
        if load_position(&env, &borrower).is_some() {
            panic_with_error!(&env, Error::PositionExists);
        }

        mats.set_maturity(&me, &borrower, &maturity);
        mats.set_counterparty(&me, &borrower, &lender);

        if collateral_amount > 0 {
            v.deposit(&borrower, &collateral_amount);
        }
        v.pledge(&me);

        let idx = accrue(&env);
        let scaled = ceil_div(principal * INDEX_SCALE, idx);
        save_position(
            &env,
            &borrower,
            &Position {
                vault: vault.clone(),
                scaled_debt: scaled,
                ramp_started_at: 0,
            },
        );
        let ts = get_i(&env, &Key::TotalScaled);
        env.storage()
            .instance()
            .set(&Key::TotalScaled, &(ts + scaled));

        // borrow LTV check
        let borrow_ltv: u32 = env.storage().instance().get(&Key::BorrowLtv).unwrap();
        if borrow_ltv == 0 {
            panic_with_error!(&env, Error::CollateralNotConfigured);
        }
        let value = Self::collateral_value(&env, &c, &vault);
        if principal * BPS > value * borrow_ltv as i128 {
            panic_with_error!(&env, Error::ExceedsBorrowLtv);
        }
        if principal > Self::cash(env.clone()) {
            panic_with_error!(&env, Error::InsufficientCash);
        }
        token::Client::new(&env, &c.lend_asset).transfer(&me, &borrower, &principal);

        RepoOpened {
            borrower,
            lender,
            vault,
            collateral_amount,
            principal,
            maturity,
        }
        .publish(&env);
    }

    /// 언제든, 누구든 상환 가능. 전액이면 볼트 잠금 해제 + 만기 기록 삭제
    pub fn repay(env: Env, payer: Address, borrower: Address, amount: i128) -> i128 {
        payer.require_auth();
        bump_instance(&env);
        if amount <= 0 {
            panic_with_error!(&env, Error::ZeroAmount);
        }
        let Some(pos) = load_position(&env, &borrower) else {
            panic_with_error!(&env, Error::NoPosition);
        };
        let idx = accrue(&env);
        let debt = debt_at(pos.scaled_debt, idx);
        let paid = amount.min(debt);
        token::Client::new(&env, &cfg(&env).lend_asset).transfer(
            &payer,
            &env.current_contract_address(),
            &paid,
        );
        Self::reduce_debt(&env, &borrower, pos, paid, debt, idx);
        paid
    }

    /// 이자 정지 + 신규 진입 차단. 만기 후 누구나
    pub fn close_market(env: Env) {
        bump_instance(&env);
        Self::require_matured(&env);
        if get_u(&env, &Key::ClosedAt) != 0 {
            panic_with_error!(&env, Error::MarketAlreadyClosed);
        }
        Self::do_close(&env);
    }

    /// 부도 선언. 통지 창 안에서는 상대방/대리인만
    pub fn trigger_maturity(env: Env, caller: Address, borrower: Address) {
        caller.require_auth();
        bump_instance(&env);
        let maturity = Self::require_matured(&env);
        let Some(mut pos) = load_position(&env, &borrower) else {
            panic_with_error!(&env, Error::NoPosition);
        };
        if pos.ramp_started_at != 0 {
            panic_with_error!(&env, Error::RampAlreadyStarted);
        }
        let ramp_from: u32 = env.storage().instance().get(&Key::BorrowLtv).unwrap();
        if ramp_from == 0 {
            panic_with_error!(&env, Error::CollateralNotConfigured);
        }
        if VaultClient::new(&env, &pos.vault).balance() == 0 {
            panic_with_error!(&env, Error::NotCollateralHolder);
        }
        if !Self::may_serve_notice(&env, &borrower, &caller, maturity) {
            panic_with_error!(&env, Error::NoticeWindowRestricted);
        }

        if get_u(&env, &Key::ClosedAt) == 0 {
            Self::do_close(&env);
        }
        let now = env.ledger().timestamp();
        pos.ramp_started_at = now;
        save_position(&env, &borrower, &pos);

        MaturityTriggered {
            borrower,
            noticed_by: caller,
            ramp_from_bps: ramp_from,
            at: now,
        }
        .publish(&env);
    }

    /// 사다리 전에는 liq LTV, 시작 후엔 borrow LTV -> 0 선형
    pub fn liquidate(
        env: Env,
        liquidator: Address,
        borrower: Address,
        max_repay: i128,
    ) -> (i128, i128) {
        liquidator.require_auth();
        bump_instance(&env);
        if max_repay <= 0 {
            panic_with_error!(&env, Error::ZeroAmount);
        }
        let c = cfg(&env);
        let Some(pos) = load_position(&env, &borrower) else {
            panic_with_error!(&env, Error::NoPosition);
        };
        let idx = accrue(&env);
        let debt = debt_at(pos.scaled_debt, idx);
        let vault = VaultClient::new(&env, &pos.vault);
        let coll_bal = vault.balance();
        let value = Self::collateral_value(&env, &c, &pos.vault);
        let ltv = Self::ltv_now(&env, &pos);
        let adjusted = value * ltv / BPS;
        if adjusted >= debt {
            panic_with_error!(&env, Error::Healthy);
        }

        let discount = ((debt - adjusted) * BPS / debt).min(c.max_discount_bps as i128);
        let mut repay = max_repay.min(debt);
        let oracle = OracleClient::new(&env, &c.oracle);
        let seize_value = repay * BPS / (BPS - discount);
        let mut seize = oracle.quote(&seize_value, &c.lend_asset, &c.collateral_asset);
        if seize >= coll_bal {
            // 담보 부족: 전량 압류, 상환액을 맞춤
            seize = coll_bal;
            repay = (value * (BPS - discount) / BPS).min(debt);
        }

        token::Client::new(&env, &c.lend_asset).transfer(
            &liquidator,
            &env.current_contract_address(),
            &repay,
        );
        // seize 가 release 보다 먼저여야 함
        if seize > 0 {
            vault.seize(&liquidator, &seize);
        }
        let remaining = Self::reduce_debt(&env, &borrower, pos, repay, debt, idx);

        Liquidated {
            borrower,
            liquidator,
            repaid: repay,
            seized: seize,
            discount_bps: discount,
            remaining_debt: remaining,
        }
        .publish(&env);
        (repay, seize)
    }

    /// 닫힌 뒤엔 불가 (청산 취소 경로 차단)
    pub fn configure_collateral(env: Env, borrow_ltv_bps: u32, liq_ltv_bps: u32) {
        cfg(&env).admin.require_auth();
        if get_u(&env, &Key::ClosedAt) != 0 {
            panic_with_error!(&env, Error::MarketClosed);
        }
        if borrow_ltv_bps > liq_ltv_bps || liq_ltv_bps as i128 > BPS {
            panic_with_error!(&env, Error::InvalidLtv);
        }
        env.storage()
            .instance()
            .set(&Key::BorrowLtv, &borrow_ltv_bps);
        env.storage().instance().set(&Key::LiqLtv, &liq_ltv_bps);
    }

    pub fn config(env: Env) -> Config {
        cfg(&env)
    }

    pub fn position(env: Env, borrower: Address) -> Option<Position> {
        load_position(&env, &borrower)
    }

    pub fn debt_of(env: Env, borrower: Address) -> i128 {
        match load_position(&env, &borrower) {
            None => 0,
            Some(p) => debt_at(p.scaled_debt, current_index(&env).0),
        }
    }

    pub fn health(env: Env, borrower: Address) -> Health {
        let c = cfg(&env);
        let Some(p) = load_position(&env, &borrower) else {
            panic_with_error!(&env, Error::NoPosition);
        };
        let value = Self::collateral_value(&env, &c, &p.vault);
        let ltv = Self::ltv_now(&env, &p);
        Health {
            collateral_value: value,
            liquidation_ltv_bps: ltv,
            adjusted_collateral: value * ltv / BPS,
            debt: debt_at(p.scaled_debt, current_index(&env).0),
        }
    }

    pub fn cash(env: Env) -> i128 {
        token::Client::new(&env, &cfg(&env).lend_asset).balance(&env.current_contract_address())
    }

    pub fn total_borrows(env: Env) -> i128 {
        debt_at(get_i(&env, &Key::TotalScaled), current_index(&env).0)
    }

    /// cash + borrows. bad debt 도 borrows 에 남음 (비사회화)
    pub fn total_assets(env: Env) -> i128 {
        Self::cash(env.clone()) + Self::total_borrows(env)
    }

    pub fn total_shares(env: Env) -> i128 {
        get_i(&env, &Key::TotalShares)
    }

    pub fn shares_of(env: Env, who: Address) -> i128 {
        shares_of(&env, &who)
    }

    pub fn convert_to_assets(env: Env, shares: i128) -> i128 {
        let total = get_i(&env, &Key::TotalShares);
        if total == 0 {
            shares
        } else {
            shares * Self::total_assets(env) / total
        }
    }

    pub fn closed_at(env: Env) -> u64 {
        get_u(&env, &Key::ClosedAt)
    }

    pub fn notice_window_ends_at(env: Env) -> u64 {
        let m = MaturitiesClient::new(&env, &cfg(&env).maturities)
            .market_maturity(&env.current_contract_address());
        if m == 0 {
            0
        } else {
            m + cfg(&env).notice_window
        }
    }

    pub fn ramp_ends_at(env: Env, borrower: Address) -> u64 {
        match load_position(&env, &borrower) {
            Some(p) if p.ramp_started_at != 0 => p.ramp_started_at + cfg(&env).ramp_duration,
            _ => 0,
        }
    }

    /// 오프체인 러너 폴링용
    pub fn can_trigger(env: Env, borrower: Address, caller: Address) -> bool {
        let m = MaturitiesClient::new(&env, &cfg(&env).maturities)
            .market_maturity(&env.current_contract_address());
        if m == 0 || env.ledger().timestamp() < m {
            return false;
        }
        match load_position(&env, &borrower) {
            Some(p) if p.ramp_started_at == 0 => {}
            _ => return false,
        }
        Self::may_serve_notice(&env, &borrower, &caller, m)
    }
}

impl RepoMarket {
    fn require_open(env: &Env) {
        if get_u(env, &Key::ClosedAt) != 0 {
            panic_with_error!(env, Error::MarketClosed);
        }
    }

    fn require_matured(env: &Env) -> u64 {
        let m = MaturitiesClient::new(env, &cfg(env).maturities)
            .market_maturity(&env.current_contract_address());
        if m == 0 {
            panic_with_error!(env, Error::MarketNotOpen);
        }
        if env.ledger().timestamp() < m {
            panic_with_error!(env, Error::NotYetMatured);
        }
        m
    }

    fn do_close(env: &Env) {
        accrue(env);
        let now = env.ledger().timestamp();
        env.storage().instance().set(&Key::ClosedAt, &now);
        MarketClosed { at: now }.publish(env);
    }

    fn may_serve_notice(env: &Env, borrower: &Address, caller: &Address, maturity: u64) -> bool {
        let c = cfg(env);
        let cp = MaturitiesClient::new(env, &c.maturities).counterparty_of(borrower);
        let Some(cp) = cp else { return true };
        if env.ledger().timestamp() >= maturity + c.notice_window {
            return true;
        }
        if caller == &cp {
            return true;
        }
        env.storage()
            .persistent()
            .get(&Key::Agent(cp, caller.clone()))
            .unwrap_or(false)
    }

    fn ltv_now(env: &Env, p: &Position) -> i128 {
        if p.ramp_started_at == 0 {
            let l: u32 = env.storage().instance().get(&Key::LiqLtv).unwrap();
            return l as i128;
        }
        let from: u32 = env.storage().instance().get(&Key::BorrowLtv).unwrap();
        let ramp = cfg(env).ramp_duration as i128;
        let elapsed = (env.ledger().timestamp() - p.ramp_started_at) as i128;
        if elapsed >= ramp {
            0
        } else {
            from as i128 * (ramp - elapsed) / ramp
        }
    }

    fn collateral_value(env: &Env, c: &Config, vault: &Address) -> i128 {
        let bal = VaultClient::new(env, vault).balance();
        OracleClient::new(env, &c.oracle).quote(&bal, &c.collateral_asset, &c.lend_asset)
    }

    /// 남은 부채 반환
    fn reduce_debt(
        env: &Env,
        borrower: &Address,
        mut pos: Position,
        paid: i128,
        debt: i128,
        idx: i128,
    ) -> i128 {
        let total = get_i(env, &Key::TotalScaled);
        if paid >= debt {
            env.storage()
                .instance()
                .set(&Key::TotalScaled, &(total - pos.scaled_debt));
            env.storage()
                .persistent()
                .remove(&Key::Position(borrower.clone()));
            let me = env.current_contract_address();
            VaultClient::new(env, &pos.vault).release();
            MaturitiesClient::new(env, &cfg(env).maturities).clear_maturity(&me, borrower);
            return 0;
        }
        let cut = (paid * INDEX_SCALE / idx).min(pos.scaled_debt);
        pos.scaled_debt -= cut;
        env.storage()
            .instance()
            .set(&Key::TotalScaled, &(total - cut));
        let remaining = debt_at(pos.scaled_debt, idx);
        save_position(env, borrower, &pos);
        remaining
    }
}

#[cfg(test)]
mod test;
