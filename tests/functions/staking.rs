use fuels::types::Identity;
use crate::utils::*;

#[tokio::test]
async fn test_stake_nft() {
    let (contract, wallets) = setup_test().await;
    let user = &wallets[1];
    let nft_id = create_test_nft_id(1);

    // Stake NFT
    let result = contract
        .clone()
        .with_wallet(user.clone())
        .methods()
        .stake_nft(contract_id_to_bech32(nft_id))
        .call()
        .await
        .unwrap();
    println!("Staking result: {:?}", result);

    // Verify staking info
    let info = contract
        .methods()
        .get_staking_info(contract_id_to_bech32(nft_id))
        .call()
        .await
        .unwrap()
        .value
        .unwrap();

    assert_eq!(
        info.staker,
        Identity::Address(user.address().into()),
        "Incorrect staker"
    );

    // Verify total staked count
    let total_staked = contract.methods().get_total_staked().call().await.unwrap().value;
    assert_eq!(total_staked, 1, "Total staked should be 1");
}

#[tokio::test]
async fn test_unstake_nft() {
    let (contract, wallets) = setup_test().await;
    let user = &wallets[1];
    let nft_id = create_test_nft_id(1);

    // First stake the NFT
    contract
        .clone()
        .with_wallet(user.clone())
        .methods()
        .stake_nft(nft_id)
        .call()
        .await
        .unwrap();

    // Wait for minimum lock period and withdrawal cooldown
    std::thread::sleep(std::time::Duration::from_secs(MIN_LOCK_PERIOD + WITHDRAWAL_COOLDOWN));

    // Unstake NFT
    let result = contract
        .clone()
        .with_wallet(user.clone())
        .methods()
        .unstake_nft(nft_id)
        .call()
        .await
        .unwrap();
    println!("Unstake result: {:?}", result);

    // Verify NFT is unstaked
    let info = contract
        .methods()
        .get_staking_info(nft_id)
        .call()
        .await
        .unwrap()
        .value;

    assert!(info.is_none(), "NFT should be unstaked");
} 