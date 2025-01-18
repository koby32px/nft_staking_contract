use fuels::types::Identity;
use crate::utils::*;

#[tokio::test]
async fn test_full_staking_cycle() {
    let (contract, wallets) = setup_test().await;
    let deployer = &wallets[0];
    let user = &wallets[1];
    
    // 1. Set reward rate
    contract
        .clone()
        .with_wallet(deployer.clone())
        .methods()
        .set_reward_rate(100)
        .call()
        .await
        .unwrap();
        
    // 2. Stake NFT
    let nft_id = create_test_nft_id(1);
    contract
        .clone()
        .with_wallet(user.clone())
        .methods()
        .stake_nft(nft_id)
        .call()
        .await
        .unwrap();
        
    // 3. Wait for rewards
    std::thread::sleep(std::time::Duration::from_secs(SECONDS_PER_DAY));
    
    // 4. Check and claim rewards
    let rewards = contract
        .methods()
        .get_pending_rewards(Identity::Address(user.address().into()))
        .call()
        .await
        .unwrap()
        .value;
        
    assert!(rewards > 0, "Should have accumulated rewards");
    
    // 5. Unstake
    contract
        .clone()
        .with_wallet(user.clone())
        .methods()
        .unstake_nft(nft_id)
        .call()
        .await
        .unwrap();
} 