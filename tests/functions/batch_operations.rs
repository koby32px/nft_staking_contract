use crate::utils::*;
use fuels::types::ContractId;
use fuels::types::bech32::Bech32ContractId;
#[tokio::test]
async fn test_batch_stake() {
    let (contract, wallets) = setup_test().await;
    let user = &wallets[1];

    // Create multiple NFT IDs
    let nft_ids: Vec<ContractId> = (1..=3)
        .map(create_test_nft_id)
        .collect();

    let bech32_ids: Vec<Bech32ContractId> = nft_ids.iter()
        .map(|&id| contract_id_to_bech32(id))
        .collect();

    contract
        .clone()
        .with_wallet(user.clone())
        .methods()
        .batch_stake(bech32_ids.iter().map(|id| ContractId::from(id)).collect())
        .call()
        .await
        .unwrap();

    // Verify all NFTs are staked
    let total_staked = contract.clone().methods().get_total_staked().call().await.unwrap().value;
    assert_eq!(total_staked, 3, "All NFTs should be staked");

    // Verify individual NFT staking info
    for nft_id in nft_ids {
        let info = contract
            .clone()
            .methods()
            .get_staking_info(nft_id)
            .call()
            .await
            .unwrap()
            .value;
        assert!(info.is_some(), "NFT should be staked");
    }
}

#[tokio::test]
async fn test_batch_stake_limits() {
    let (contract, wallets) = setup_test().await;
    let user = &wallets[1];

    // Create a large batch of NFT IDs
    let nft_ids: Vec<ContractId> = (1..=101)
        .map(create_test_nft_id)
        .collect();

    // Try to stake more than allowed
    let result = contract
        .clone()
        .with_wallet(user.clone())
        .methods()
        .batch_stake(nft_ids.iter().map(|&id| id).collect())
        .call()
        .await;

    assert!(result.is_err(), "Should not allow batch size > 100");
}

#[tokio::test]
async fn test_batch_stake_partial_failure() {
    let (contract, wallets) = setup_test().await;
    let user = &wallets[1];

    // Create mix of valid and invalid NFT IDs
    let nft_ids: Vec<ContractId> = vec![1, 999, 2]
        .into_iter()
        .map(create_test_nft_id)
        .collect();

    // Attempt batch stake
    let result = contract
        .clone()
        .with_wallet(user.clone())
        .methods()
        .batch_stake(nft_ids.iter().map(|&id| id).collect())
        .call()
        .await;

    assert!(result.is_err(), "Should fail on invalid NFT in batch");
} 