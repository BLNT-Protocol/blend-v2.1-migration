use soroban_sdk::{
    contract, contractclient, contractimpl, contracttype,
    testutils::{Address as _, Ledger},
    token::{StellarAssetClient, TokenClient},
    Address, Env,
};

mod receiver {
    soroban_sdk::contractimport!(
        file = "../blend-v2.1-receiver/target/wasm32v1-none/optimized/blend_v2_1_receiver.wasm"
    );
}

mod legacy_emitter {
    soroban_sdk::contractimport!(file = "../blend-contracts/blend-contract-sdk/wasm/emitter.wasm");
}

const SCALAR_7: i128 = 10_000_000;
const SWAP_QUEUE_SECONDS: u64 = 31 * 24 * 60 * 60;
const INCUMBENT_LEGACY_LP: i128 = 100 * SCALAR_7;
const RECEIVER_LEGACY_LP: i128 = 101 * SCALAR_7;
const V2_1_BACKSTOP_LP: i128 = 200 * SCALAR_7;
const RECEIVER_V2_1_LP: i128 = 3 * SCALAR_7;

#[derive(Clone, Debug, Eq, PartialEq)]
#[contracttype]
struct QueuedSwap {
    new_backstop: Address,
    new_backstop_token: Address,
    unlock_time: u64,
}

#[contractclient(name = "LegacyEmitterClient")]
#[allow(dead_code)]
trait LegacyEmitter {
    fn initialize(env: Env, blnd_token: Address, backstop: Address, backstop_token: Address);
    fn get_backstop(env: Env) -> Address;
    fn get_queued_swap(env: Env) -> Option<QueuedSwap>;
    fn queue_swap_backstop(env: Env, new_backstop: Address, new_backstop_token: Address);
    fn swap_backstop(env: Env);
}

#[contract]
struct BackstopMarker;

#[contractimpl]
impl BackstopMarker {}

struct Fixture {
    env: Env,
    emitter: Address,
    incumbent: Address,
    receiver: Address,
    v2_1_backstop: Address,
    legacy_lp: Address,
    v2_1_lp: Address,
    blnd: Address,
    ysc: Address,
}

impl Fixture {
    fn create(receiver_legacy_lp: i128, v2_1_backstop_lp: i128, receiver_v2_1_lp: i128) -> Self {
        let env = Env::default();
        env.mock_all_auths();
        env.ledger().set_timestamp(1_000_000);

        let token_admin = Address::generate(&env);
        let incumbent = env.register(BackstopMarker, ());
        let v2_1_backstop = env.register(BackstopMarker, ());
        let emitter = env.register(legacy_emitter::WASM, ());
        let blnd = env
            .register_stellar_asset_contract_v2(token_admin.clone())
            .address();
        let legacy_lp = env
            .register_stellar_asset_contract_v2(token_admin.clone())
            .address();
        let v2_1_lp = env
            .register_stellar_asset_contract_v2(token_admin.clone())
            .address();
        let ysc = Address::generate(&env);

        StellarAssetClient::new(&env, &blnd).set_admin(&emitter);
        LegacyEmitterClient::new(&env, &emitter).initialize(&blnd, &incumbent, &legacy_lp);

        let receiver = env.register(
            receiver::WASM,
            (&emitter, &legacy_lp, &v2_1_backstop, &v2_1_lp, &blnd, &ysc),
        );

        let legacy_admin = StellarAssetClient::new(&env, &legacy_lp);
        legacy_admin.mint(&incumbent, &INCUMBENT_LEGACY_LP);
        legacy_admin.mint(&ysc, &receiver_legacy_lp);
        TokenClient::new(&env, &legacy_lp).transfer(&ysc, &receiver, &receiver_legacy_lp);

        let v2_1_admin = StellarAssetClient::new(&env, &v2_1_lp);
        v2_1_admin.mint(&v2_1_backstop, &v2_1_backstop_lp);
        v2_1_admin.mint(&receiver, &receiver_v2_1_lp);

        Self {
            env,
            emitter,
            incumbent,
            receiver,
            v2_1_backstop,
            legacy_lp,
            v2_1_lp,
            blnd,
            ysc,
        }
    }

    fn emitter(&self) -> LegacyEmitterClient<'_> {
        LegacyEmitterClient::new(&self.env, &self.emitter)
    }

    fn receiver(&self) -> receiver::Client<'_> {
        receiver::Client::new(&self.env, &self.receiver)
    }

    fn balance(&self, token: &Address, holder: &Address) -> i128 {
        TokenClient::new(&self.env, token).balance(holder)
    }
}

#[test]
fn exact_wasm_executes_two_hop_migration_and_burns_receiver_emissions() {
    let fixture = Fixture::create(RECEIVER_LEGACY_LP, V2_1_BACKSTOP_LP, RECEIVER_V2_1_LP);
    let emitter = fixture.emitter();
    let receiver = fixture.receiver();
    let first_queue_time = fixture.env.ledger().timestamp();

    receiver.queue_receiver();
    let first = emitter.get_queued_swap().unwrap();
    assert_eq!(first.new_backstop, fixture.receiver);
    assert_eq!(first.new_backstop_token, fixture.v2_1_lp);
    assert_eq!(first.unlock_time, first_queue_time + SWAP_QUEUE_SECONDS);

    fixture.env.ledger().set_timestamp(first.unlock_time);
    assert_eq!(receiver.advance_to_v2_1(), RECEIVER_LEGACY_LP);
    assert_eq!(emitter.get_backstop(), fixture.receiver);
    assert_eq!(fixture.balance(&fixture.legacy_lp, &fixture.receiver), 0);
    assert_eq!(
        fixture.balance(&fixture.legacy_lp, &fixture.ysc),
        RECEIVER_LEGACY_LP
    );
    assert_eq!(fixture.balance(&fixture.v2_1_lp, &fixture.receiver), 0);
    assert_eq!(
        fixture.balance(&fixture.v2_1_lp, &fixture.ysc),
        RECEIVER_V2_1_LP
    );

    let second = emitter.get_queued_swap().unwrap();
    assert_eq!(second.new_backstop, fixture.v2_1_backstop);
    assert_eq!(second.new_backstop_token, fixture.v2_1_lp);
    assert_eq!(second.unlock_time, first.unlock_time + SWAP_QUEUE_SECONDS);

    fixture.env.ledger().set_timestamp(second.unlock_time);
    let receiver_period_emissions = i128::from(SWAP_QUEUE_SECONDS) * SCALAR_7;
    assert_eq!(receiver.finalize_v2_1(), receiver_period_emissions);
    assert_eq!(emitter.get_backstop(), fixture.v2_1_backstop);
    assert!(emitter.get_queued_swap().is_none());
    assert_eq!(fixture.balance(&fixture.blnd, &fixture.receiver), 0);
    assert_eq!(fixture.balance(&fixture.blnd, &fixture.ysc), 0);
    assert_eq!(fixture.balance(&fixture.blnd, &fixture.v2_1_backstop), 0);
    assert_eq!(
        fixture.balance(&fixture.blnd, &fixture.incumbent),
        receiver_period_emissions
    );
}

#[test]
fn exact_emitter_rejects_an_equal_legacy_lp_balance() {
    let fixture = Fixture::create(INCUMBENT_LEGACY_LP, V2_1_BACKSTOP_LP, 0);

    assert!(fixture.receiver().try_queue_receiver().is_err());
    assert_eq!(fixture.emitter().get_backstop(), fixture.incumbent);
    assert!(fixture.emitter().get_queued_swap().is_none());
}

#[test]
fn failed_second_queue_rolls_back_first_swap_and_asset_movements() {
    let fixture = Fixture::create(RECEIVER_LEGACY_LP, 0, RECEIVER_V2_1_LP);
    let emitter = fixture.emitter();
    let receiver = fixture.receiver();

    receiver.queue_receiver();
    let first = emitter.get_queued_swap().unwrap();
    fixture.env.ledger().set_timestamp(first.unlock_time);

    assert!(receiver.try_advance_to_v2_1().is_err());
    assert_eq!(emitter.get_backstop(), fixture.incumbent);
    assert_eq!(emitter.get_queued_swap().unwrap(), first);
    assert_eq!(
        fixture.balance(&fixture.legacy_lp, &fixture.receiver),
        RECEIVER_LEGACY_LP
    );
    assert_eq!(
        fixture.balance(&fixture.v2_1_lp, &fixture.receiver),
        RECEIVER_V2_1_LP
    );
    assert_eq!(fixture.balance(&fixture.legacy_lp, &fixture.ysc), 0);
    assert_eq!(fixture.balance(&fixture.v2_1_lp, &fixture.ysc), 0);
    assert_eq!(fixture.balance(&fixture.blnd, &fixture.incumbent), 0);
}

#[test]
fn fallback_methods_recover_after_direct_emitter_swaps() {
    let fixture = Fixture::create(RECEIVER_LEGACY_LP, V2_1_BACKSTOP_LP, 0);
    let emitter = fixture.emitter();
    let receiver = fixture.receiver();

    receiver.queue_receiver();
    let first = emitter.get_queued_swap().unwrap();
    fixture.env.ledger().set_timestamp(first.unlock_time);
    emitter.swap_backstop();
    assert_eq!(emitter.get_backstop(), fixture.receiver);

    assert_eq!(receiver.return_legacy(), RECEIVER_LEGACY_LP);
    assert_eq!(receiver.advance_to_v2_1(), 0);
    let second = emitter.get_queued_swap().unwrap();
    fixture.env.ledger().set_timestamp(second.unlock_time);
    emitter.swap_backstop();
    assert_eq!(emitter.get_backstop(), fixture.v2_1_backstop);

    let receiver_period_emissions = i128::from(SWAP_QUEUE_SECONDS) * SCALAR_7;
    assert_eq!(
        fixture.balance(&fixture.blnd, &fixture.receiver),
        receiver_period_emissions
    );
    assert_eq!(receiver.burn_received_blnd(), receiver_period_emissions);
    assert_eq!(receiver.finalize_v2_1(), 0);
    assert_eq!(fixture.balance(&fixture.blnd, &fixture.receiver), 0);
    assert_eq!(fixture.balance(&fixture.legacy_lp, &fixture.receiver), 0);
    assert_eq!(fixture.balance(&fixture.v2_1_lp, &fixture.receiver), 0);
}
