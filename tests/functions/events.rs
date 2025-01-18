use fuels::types::{ContractId, Identity};
use fuels::macros::{Tokenizable, Parameterize};
use crate::utils::{setup_test, REWARD_RATE};

fn create_test_nft_id(id: u64) -> ContractId {
    ContractId::from([id as u8; 32])
}

#[derive(Debug, PartialEq, Clone, Parameterize, Tokenizable)]
pub struct StakeEvent {
    pub nft_id: ContractId,
    pub staker: Identity,
}

#[derive(Debug, PartialEq, Clone, Parameterize, Tokenizable)]
pub struct RewardClaimed {
    pub staker: Identity,
    pub amount: u64,
}

#[tokio::test]
async fn test_stake_event_emission() {
    let (contract, wallets) = setup_test().await;
    let admin = &wallets[0];
    let user = &wallets[1];
    let nft_id = create_test_nft_id(1);
    
    // First, initialize the NFT contract as admin with reward rate
    contract
        .clone()
        .with_wallet(admin.clone())
        .methods()
        .initialize(Identity::ContractId(nft_id))
        .call()
        .await
        .unwrap();
        
    // Set reward rate
    contract
        .clone()
        .with_wallet(admin.clone())
        .methods()
        .set_reward_rate(REWARD_RATE)
        .call()
        .await
        .unwrap();
        
    let result = contract
        .with_wallet(user.clone())
        .methods()
        .stake_nft(nft_id)
        .call()
        .await
        .unwrap();
        
    let logs = result.decode_logs_with_type::<StakeEvent>().unwrap();
    assert!(!logs.is_empty(), "No stake event emitted");
    let event = &logs[0];
    assert_eq!(event.nft_id, nft_id);
    assert_eq!(event.staker, Identity::Address(user.address().into()));
}

#[tokio::test]
async fn test_reward_claim_event() {
    let (contract, wallets) = setup_test().await;
    let admin = &wallets[0];
    let user = &wallets[1];
    let nft_id = create_test_nft_id(1);
    
    // Setup: Initialize with reward rate and stake NFT
    contract
        .clone()
        .with_wallet(admin.clone())
        .methods()
        .initialize(Identity::ContractId(nft_id))
        .call()
        .await
        .unwrap();
        
    contract
        .clone()
        .with_wallet(admin.clone())
        .methods()
        .set_reward_rate(REWARD_RATE)
        .call()
        .await
        .unwrap();
        
    // Stake NFT
    contract
        .clone()
        .with_wallet(user.clone())
        .methods()
        .stake_nft(nft_id)
        .call()
        .await
        .unwrap();
    
    // Wait for rewards to accumulate
    tokio::time::sleep(std::time::Duration::from_secs(5)).await;
    
    let result = contract
        .with_wallet(user.clone())
        .methods()
        .claim_rewards()
        .call()
        .await
        .unwrap();
        
    let logs = result.decode_logs_with_type::<RewardClaimed>().unwrap();
    assert!(!logs.is_empty(), "No reward claim event emitted");
    let event = &logs[0];
    assert_eq!(event.staker, Identity::Address(user.address().into()));
    assert!(event.amount > 0, "Reward amount should be greater than 0");
} 