#![no_std]
//! 참여 자격 = 게이트 OR 운영 승인 목록

use common::{GateClient, PERSISTENT_THRESHOLD, PERSISTENT_TTL};
use soroban_sdk::{contract, contractevent, contractimpl, contracttype, Address, Env};

#[contracttype]
enum Key {
    Admin,
    Gate,
    Approved(Address),
}

#[contractevent]
pub struct ApprovalSet {
    #[topic]
    pub who: Address,
    pub approved: bool,
}

#[contract]
pub struct ParticipantRegistry;

#[contractimpl]
impl ParticipantRegistry {
    /// gate 없으면 승인 목록만 사용
    pub fn __constructor(env: Env, admin: Address, gate: Option<Address>) {
        env.storage().instance().set(&Key::Admin, &admin);
        if let Some(g) = gate {
            env.storage().instance().set(&Key::Gate, &g);
        }
    }

    pub fn admin(env: Env) -> Address {
        env.storage().instance().get(&Key::Admin).unwrap()
    }

    pub fn gate(env: Env) -> Option<Address> {
        env.storage().instance().get(&Key::Gate)
    }

    pub fn set_approved(env: Env, who: Address, value: bool) {
        Self::admin(env.clone()).require_auth();
        let key = Key::Approved(who.clone());
        if value {
            env.storage().persistent().set(&key, &true);
            env.storage()
                .persistent()
                .extend_ttl(&key, PERSISTENT_THRESHOLD, PERSISTENT_TTL);
        } else {
            env.storage().persistent().remove(&key);
        }
        ApprovalSet {
            who,
            approved: value,
        }
        .publish(&env);
    }

    pub fn approved(env: Env, who: Address) -> bool {
        env.storage()
            .persistent()
            .get(&Key::Approved(who))
            .unwrap_or(false)
    }

    pub fn is_eligible(env: Env, who: Address) -> bool {
        if Self::approved(env.clone(), who.clone()) {
            return true;
        }
        let (answered, allowed) = Self::gate_says(env, who);
        answered && allowed
    }

    /// (answered, allowed). answered == false 면 게이트 고장
    pub fn gate_says(env: Env, who: Address) -> (bool, bool) {
        let Some(gate) = Self::gate(env.clone()) else {
            return (false, false);
        };
        match GateClient::new(&env, &gate).try_can_enter(&who) {
            Ok(Ok(v)) => (true, v),
            _ => (false, false),
        }
    }

    /// 모니터링용
    pub fn is_eligible_only_by_approval(env: Env, who: Address) -> bool {
        if !Self::approved(env.clone(), who.clone()) {
            return false;
        }
        let (answered, allowed) = Self::gate_says(env, who);
        !(answered && allowed)
    }
}

#[cfg(test)]
mod test {
    extern crate std;
    use super::*;
    use soroban_sdk::testutils::{Address as _, IssuerFlags};
    use soroban_sdk::token::StellarAssetClient;

    #[test]
    fn gate_or_approval() {
        let env = Env::default();
        env.mock_all_auths();
        let sac = env.register_stellar_asset_contract_v2(Address::generate(&env));
        sac.issuer().set_flag(IssuerFlags::RequiredFlag);
        let gate = env.register(gate::WtgxxGate, (sac.address(),));
        let admin = Address::generate(&env);
        let id = env.register(ParticipantRegistry, (admin, Some(gate)));
        let reg = ParticipantRegistryClient::new(&env, &id);

        let kyc = Address::generate(&env);
        let ops = Address::generate(&env);
        let nobody = Address::generate(&env);
        StellarAssetClient::new(&env, &sac.address()).set_authorized(&kyc, &true);
        reg.set_approved(&ops, &true);

        assert!(reg.is_eligible(&kyc));
        assert!(reg.is_eligible(&ops));
        assert!(!reg.is_eligible(&nobody));
        assert!(reg.is_eligible_only_by_approval(&ops));
        assert!(!reg.is_eligible_only_by_approval(&kyc));
    }

    // 백서 6.2
    #[test]
    fn approval_survives_compliance_removal() {
        let env = Env::default();
        env.mock_all_auths();
        let sac = env.register_stellar_asset_contract_v2(Address::generate(&env));
        sac.issuer().set_flag(IssuerFlags::RequiredFlag);
        let gate = env.register(gate::WtgxxGate, (sac.address(),));
        let id = env.register(ParticipantRegistry, (Address::generate(&env), Some(gate)));
        let reg = ParticipantRegistryClient::new(&env, &id);

        let liquidator = Address::generate(&env);
        StellarAssetClient::new(&env, &sac.address()).set_authorized(&liquidator, &true);
        reg.set_approved(&liquidator, &true);

        sac.issuer().clear_flag(IssuerFlags::RequiredFlag);
        assert_eq!(reg.gate_says(&liquidator), (true, false));
        assert!(reg.is_eligible(&liquidator));
    }

    #[test]
    fn no_gate_means_list_only() {
        let env = Env::default();
        env.mock_all_auths();
        let id = env.register(
            ParticipantRegistry,
            (Address::generate(&env), None::<Address>),
        );
        let reg = ParticipantRegistryClient::new(&env, &id);
        let who = Address::generate(&env);
        assert_eq!(reg.gate_says(&who), (false, false));
        assert!(!reg.is_eligible(&who));
        reg.set_approved(&who, &true);
        assert!(reg.is_eligible(&who));
    }
}
