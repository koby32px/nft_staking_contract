mod utils;
mod functions;

use utils::*;

#[tokio::test]
async fn test_contract_initialization() {
    let (contract, wallets) = setup_test().await;
    let _deployer = &wallets[0];

    // Test initial state
    let is_paused = contract.clone().methods().is_paused().call().await.unwrap().value;
    assert!(!is_paused, "Contract should not be paused initially");

    let total_staked = contract.clone().methods().get_total_staked().call().await.unwrap().value;
    assert_eq!(total_staked, 0, "Initial staked amount should be 0");

    let reward_rate = contract.methods().get_reward_rate().call().await.unwrap().value;
    assert_eq!(reward_rate, 0, "Initial reward rate should be 0");
}