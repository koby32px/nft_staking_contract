use fuels::types::Identity;
use crate::utils::*;

#[tokio::test]
async fn test_reward_calculation() {
    let (contract, wallets) = setup_test().await;
    let deployer = &wallets[0];
    let user = &wallets[1];

    // Set reward rate
    contract
        .clone()
        .with_wallet(deployer.clone())
        .methods()
        .set_reward_rate(100) // 10% reward rate
        .call()
        .await
        .unwrap();

    let nft_id = create_test_nft_id(1);

    // Stake NFT
    contract
        .clone()
        .with_wallet(user.clone())
        .methods()
        .stake_nft(nft_id)
        .call()
        .await
        .unwrap();

    // Wait for some time
    std::thread::sleep(std::time::Duration::from_secs(SECONDS_PER_DAY * 2));

    // Check pending rewards
    let pending_rewards = contract
        .methods()
        .get_pending_rewards(Identity::Address(user.address().into()))
        .call()
        .await
        .unwrap()
        .value;

    assert!(pending_rewards > 0, "Should have accumulated rewards");
}

#[tokio::test]
async fn test_claim_rewards() {
    let (contract, wallets) = setup_test().await;
    let deployer = &wallets[0];
    let user = &wallets[1];

    // Setup reward rate and deposit rewards
    contract
        .clone()
        .with_wallet(deployer.clone())
        .methods()
        .set_reward_rate(100)
        .call()
        .await
        .unwrap();

    // Deposit rewards
    contract
        .clone()
        .with_wallet(deployer.clone())
        .methods()
        .deposit_rewards()
        .call()
        .await
        .unwrap();

    // Stake and wait
    let nft_id = create_test_nft_id(1);
    contract
        .clone()
        .with_wallet(user.clone())
        .methods()
        .stake_nft(nft_id)
        .call()
        .await
        .unwrap();

    std::thread::sleep(std::time::Duration::from_secs(SECONDS_PER_DAY * 2));

    // Claim rewards
    contract
        .clone()
        .with_wallet(user.clone())
        .methods()
        .claim_rewards()
        .call()
        .await
        .unwrap();

    // Verify rewards were claimed
    let pending_rewards = contract
        .clone()
        .methods()
        .get_pending_rewards(Identity::Address(user.address().into()))
        .call()
        .await
        .unwrap()
        .value;

    assert_eq!(pending_rewards, 0, "Rewards should be claimed");
}

#[tokio::test]
async fn test_reward_calculation_precise() {
    let (contract, wallets) = setup_test().await;
    let deployer = &wallets[0];
    let user = &wallets[1];

    // Set reward rate (10%)
    contract
        .clone()
        .with_wallet(deployer.clone())
        .methods()
        .set_reward_rate(100)
        .call()
        .await
        .unwrap();

    let nft_id = create_test_nft_id(1);

    // Record initial timestamp
    let initial_time = std::time::SystemTime::now();
    println!("Starting reward test at: {:?}", initial_time);

    // Stake NFT
    contract
        .clone()
        .with_wallet(user.clone())
        .methods()
        .stake_nft(nft_id)
        .call()
        .await
        .unwrap();

    // Simulate time passage (7 days)
    let time_passed = SECONDS_PER_DAY * 7;
    // Note: Add blockchain time manipulation here based on your test framework

    // Calculate expected rewards
    let expected_rewards = (time_passed * 100) / (365 * SECONDS_PER_DAY); // 10% annual rate

    // Check pending rewards
    let pending_rewards = contract
        .clone()
        .methods()
        .get_pending_rewards(Identity::Address(user.address().into()))
        .call()
        .await
        .unwrap()
        .value;

    assert_eq!(pending_rewards, expected_rewards, "Rewards calculation mismatch");
} 