use fuels::{
    prelude::*,
    types::{AssetId, ContractId, Identity},
};

// Load abi from json
abigen!(Contract(
    name = "NFTStaking",
    abi = "out/debug/koby_staking_contract-abi.json"
));

async fn setup() -> Result<(NFTStaking<WalletUnlocked>, WalletUnlocked, WalletUnlocked, ContractId)> {
    // Create test wallets with single coin type
    let wallets = launch_custom_provider_and_get_wallets(
        WalletsConfig::new(
            Some(2),             // Number of wallets
            Some(1),             // Number of coins per wallet 
            Some(1_000_000_000), // Initial balance per coin
        ),
        None,
        None,
    ).await?;
    
    let admin_wallet = wallets[0].clone();
    let user_wallet = wallets[1].clone();

    // Deploy contract
    let id = Contract::load_from(
        "out/debug/koby_staking_contract.bin",
        LoadConfiguration::default()
    )?
    .deploy(&admin_wallet, TxPolicies::default())
    .await?;

    // Create instance with admin wallet
    let instance = NFTStaking::new(id.clone(), admin_wallet.clone());

    // Initialize contract with admin
    instance.methods()
        .initialize(Identity::Address(admin_wallet.address().into()))
        .call()
        .await?;

    Ok((instance, admin_wallet, user_wallet, id.into()))
}

#[tokio::test]
async fn test_staking_flow() -> Result<()> {
    println!("Starting test: {}", stringify!(test_staking_flow));
    
    let (instance, _admin_wallet, user_wallet, _id) = setup().await?;
    
    // Create test NFT ID
    let test_nft = ContractId::from([1u8; 32]);
    
    // Create instance with user wallet
    let user_instance = NFTStaking::new(instance.contract_id(), user_wallet.clone());
    
    // Stake NFT
    let result = user_instance
        .methods()
        .stake_nft(test_nft)
        .call_params(CallParameters::default().with_amount(1))?
        .call()
        .await;

    assert!(result.is_ok(), "Stake NFT transaction failed: {:?}", result);

    // Verify staking info
    let staking_info = user_instance
        .methods()
        .get_staking_info(test_nft)
        .call()
        .await?;
    
    assert!(staking_info.value.is_some());
    let info = staking_info.value.unwrap();
    assert_eq!(info.staker, Identity::Address(user_wallet.address().into()));
    
    // Check total staked
    let total_staked = user_instance
        .methods()
        .get_total_staked()
        .call()
        .await?;
    
    assert_eq!(total_staked.value, 1);

    Ok(())
}

#[tokio::test]
async fn test_reward_calculation() -> Result<()> {
    println!("Starting test: {}", stringify!(test_reward_calculation));

    let (instance, _admin_wallet, user_wallet, _id) = setup().await?;
    
    // Create test NFT
    let test_nft = ContractId::from([1u8; 32]);

    // Create user instance
    let user_instance = NFTStaking::new(instance.contract_id(), user_wallet.clone());
    
    // Stake NFT
    user_instance
        .methods()
        .stake_nft(test_nft)
        .call_params(CallParameters::default().with_amount(1))?
        .call()
        .await?;

    // Wrap the reward calculation logic in a timeout
    let timeout_result = tokio::time::timeout(
        std::time::Duration::from_secs(30),
        async {
            // Produce blocks and check rewards
            let blocks_to_produce = 100; // Increase from 7 to ensure lock period is over
            user_wallet.provider().unwrap().produce_blocks(blocks_to_produce, None).await?;

            let pre_unstake_rewards = user_instance
                .methods()
                .get_pending_rewards(Identity::Address(user_wallet.address().into()))
                .call()
                .await?;
            assert!(pre_unstake_rewards.value > 0, "No rewards accumulated before unstaking");
    
            // Unstake NFT
            let unstake_result = user_instance
                .methods()
                .unstake_nft(test_nft)
                .call()
                .await;
    
            assert!(unstake_result.is_ok(), "Unstake NFT failed: {:?}", unstake_result);
    
            // Check rewards
            let rewards = user_instance
                .methods()
                .get_pending_rewards(Identity::Address(user_wallet.address().into()))
                .call()
                .await?;
            
            assert!(rewards.value > 0);
    
            Ok::<(), fuels::types::errors::Error>(())
        }
    ).await;

    assert!(timeout_result.is_ok(), "Test timed out after 30 seconds");

    Ok(())
}

#[tokio::test]
async fn test_emergency_functions() -> Result<()> {
    println!("Starting test: {}", stringify!(test_emergency_functions));

    let (instance, _admin_wallet, user_wallet, _id) = setup().await?;
    
    // Verify initial pause state
    let initial_pause_state = instance
        .methods()
        .is_paused()
        .call()
        .await?;
    assert!(!initial_pause_state.value, "Contract should not be paused initially");

    // Test emergency pause as admin
    let pause_result = instance
        .methods()
        .emergency_pause()
        .call()
        .await;
    assert!(pause_result.is_ok(), "Emergency pause failed: {:?}", pause_result);

    // Verify contract is paused
    let is_paused = instance
        .methods()
        .is_paused()
        .call()
        .await?;
    assert!(is_paused.value, "Contract should be paused");

    // Test emergency unpause as admin
    let unpause_result = instance
        .methods()
        .emergency_unpause()
        .call()
        .await;
    assert!(unpause_result.is_ok(), "Emergency unpause failed: {:?}", unpause_result);

    // Verify contract is unpaused
    let is_paused = instance
        .methods()
        .is_paused()
        .call()
        .await?;
    assert!(!is_paused.value, "Contract should be unpaused");

    // Test emergency withdraw
    let test_nft = ContractId::from([1u8; 32]);
    let test_asset_id = AssetId::new(*test_nft);

    // Mint NFT to user first
    let nft_balance = user_wallet.get_asset_balance(&test_asset_id).await?;
    assert_eq!(nft_balance, 0, "User should start with no NFT balance");

    // First stake an NFT as user
    let user_instance = NFTStaking::new(instance.contract_id(), user_wallet.clone());
    let stake_result = user_instance
        .methods()
        .stake_nft(test_nft)
        .call_params(CallParameters::default().with_amount(1))?
        .call()
        .await;
    assert!(stake_result.is_ok(), "Stake NFT failed: {:?}", stake_result);

    // Emergency withdraw as admin
    let withdraw_result = instance
        .methods()
        .emergency_withdraw(test_nft)
        .call()
        .await;
    assert!(withdraw_result.is_ok(), "Emergency withdraw failed: {:?}", withdraw_result);

    // Verify NFT is returned to user
    let user_balance = user_wallet.get_asset_balance(&test_asset_id).await?;
    assert_eq!(user_balance, 1, "User should have received their NFT back");

    // Verify NFT is no longer staked
    let staking_info = instance
        .methods()
        .get_staking_info(test_nft)
        .call()
        .await?;
    assert!(staking_info.value.is_none(), "NFT should no longer be staked");

    Ok(())
}