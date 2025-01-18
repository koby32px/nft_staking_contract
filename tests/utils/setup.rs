use fuels::{
    prelude::*,
    types::Identity,
};
use crate::utils::bindings::NFTStakingContract;

// Default values for testing
pub const REWARD_RATE: u64 = 100; // 10% reward rate
pub const MIN_LOCK_PERIOD: u64 = 86400; // 1 day in seconds
pub const WITHDRAWAL_COOLDOWN: u64 = 86400; // 1 day in seconds

// Helper to setup test wallets and deploy contract
pub async fn setup_test() -> (NFTStakingContract<WalletUnlocked>, Vec<WalletUnlocked>) {
    // Launch a local network and deploy the contract
    let mut wallets = launch_custom_provider_and_get_wallets(
        WalletsConfig::new(
            Some(2),             /* Two wallets */
            Some(1),             /* Single coin (UTXO) */
            Some(1_000_000_000), /* Amount per coin */
        ),
        None,
        None,
    )
    .await
    .unwrap();

    let deployer_wallet = wallets.pop().unwrap();
    let user_wallet = wallets.pop().unwrap();

    // Deploy the contract
    let contract_id = Contract::load_from(
        "./out/debug/koby_staking_contract.bin",
        LoadConfiguration::default()
    )
    .unwrap()
    .deploy(&deployer_wallet, TxPolicies::default())
    .await
    .unwrap();

    let contract_instance = NFTStakingContract::new(contract_id.clone(), deployer_wallet.clone());

    // Initialize the contract
    contract_instance
        .methods()
        .initialize(Identity::Address(deployer_wallet.address().into()))
        .call()
        .await
        .unwrap();

    (contract_instance, vec![deployer_wallet, user_wallet])
}