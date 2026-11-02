extern crate std;

use super::*;
use soroban_sdk::testutils::{Address as _, IssuerFlags};
use soroban_sdk::token::StellarAssetClient;

struct Setup {
    env: Env,
    gate: WtgxxGateClient<'static>,
    sac: soroban_sdk::testutils::StellarAssetContract,
}

fn setup() -> Setup {
    let env = Env::default();
    env.mock_all_auths();
    let issuer = Address::generate(&env);
    let sac = env.register_stellar_asset_contract_v2(issuer);
    sac.issuer().set_flag(IssuerFlags::RequiredFlag);
    sac.issuer().set_flag(IssuerFlags::RevocableFlag);
    let id = env.register(WtgxxGate, (sac.address(),));
    let gate = WtgxxGateClient::new(&env, &id);
    Setup { env, gate, sac }
}

#[test]
fn authorized_holder_is_allowed() {
    let s = setup();
    let who = Address::generate(&s.env);
    assert_eq!(s.gate.check_entry(&who), Reason::NotAuthorized);

    StellarAssetClient::new(&s.env, &s.sac.address()).set_authorized(&who, &true);
    assert_eq!(s.gate.check_entry(&who), Reason::Allowed);
    assert!(s.gate.can_enter(&who));
}

#[test]
fn revoked_holder_is_blocked() {
    let s = setup();
    let who = Address::generate(&s.env);
    let sac = StellarAssetClient::new(&s.env, &s.sac.address());
    sac.set_authorized(&who, &true);
    sac.set_authorized(&who, &false);
    assert_eq!(s.gate.check_entry(&who), Reason::NotAuthorized);
}

/// AUTH_REQUIRED 가 꺼지면 토큰은 통과, 게이트는 차단
#[test]
fn clearing_auth_required_trips_the_canary() {
    let s = setup();
    let who = Address::generate(&s.env);
    StellarAssetClient::new(&s.env, &s.sac.address()).set_authorized(&who, &true);
    assert!(s.gate.can_enter(&who));

    s.sac.issuer().clear_flag(IssuerFlags::RequiredFlag);
    assert_eq!(s.gate.check_entry(&who), Reason::ComplianceRemoved);
}

#[test]
fn non_token_address_does_not_panic() {
    let env = Env::default();
    let not_a_token = Address::generate(&env);
    let id = env.register(WtgxxGate, (not_a_token,));
    let gate = WtgxxGateClient::new(&env, &id);
    assert_eq!(
        gate.check_entry(&Address::generate(&env)),
        Reason::CallFailed
    );
}

#[test]
fn exit_check_reports_recipient() {
    let s = setup();
    let vault = Address::generate(&s.env);
    let to = Address::generate(&s.env);
    let sac = StellarAssetClient::new(&s.env, &s.sac.address());
    sac.set_authorized(&vault, &true);
    assert_eq!(
        s.gate.check_exit(&vault, &to),
        Blocker::RecipientNotAuthorized
    );
    sac.set_authorized(&to, &true);
    assert_eq!(s.gate.check_exit(&vault, &to), Blocker::None);
}
