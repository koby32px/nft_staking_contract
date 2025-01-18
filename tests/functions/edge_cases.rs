use crate::utils::*;

#[tokio::test]
async fn test_invalid_reward_rate() {
    let (contract, wallets) = setup_test().await;
    let deployer = &wallets[0];
    
    // Try to set reward rate above maximum
    let result = contract
        .with_wallet(deployer.clone())
        .methods()
        .set_reward_rate(1001) // Above MAX_REWARD_RATE
        .call()
        .await;
        
    assert!(result.is_err(), "Should not allow reward rate above maximum");
}

#[tokio::test]
async fn test_withdrawal_cooldown() {
    let (contract, wallets) = setup_test().await;
    let user = &wallets[1];
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

    // Try to unstake immediately
    let result = contract
        .clone()
        .with_wallet(user.clone())
        .methods()
        .unstake_nft(nft_id)
        .call()
        .await;

    assert!(result.is_err(), "Should not allow immediate unstaking");
}

#[tokio::test]
async fn test_invalid_token_deposit() {
    let (contract, wallets) = setup_test().await;
    let user = &wallets[1];
    
    // Try to stake an invalid NFT ID
    let invalid_nft_id = create_test_nft_id(999);
    
    let result = contract
        .clone()
        .with_wallet(user.clone())
        .methods()
        .stake_nft(invalid_nft_id)
        .call()
        .await;
        
    assert!(result.is_err(), "Should not allow staking invalid NFT");
}
