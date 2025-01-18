use fuels::types::Identity;
use crate::utils::*;

#[tokio::test]
async fn test_emergency_pause() {
    let (contract, wallets) = setup_test().await;
    let deployer = &wallets[0];
    let user = &wallets[1];

    // Pause contract
    contract
        .clone()
        .with_wallet(deployer.clone())
        .methods()
        .emergency_pause()
        .call()
        .await
        .unwrap();

    let is_paused = contract.methods().is_paused().call().await.unwrap().value;
    assert!(is_paused, "Contract should be paused");

    // Try to stake while paused (should fail)
    let nft_id = create_test_nft_id(1);
    let result = contract
        .clone()
        .with_wallet(user.clone())
        .methods()
        .stake_nft(nft_id)
        .call()
        .await;

    assert!(result.is_err(), "Should not be able to stake while paused");
}

#[tokio::test]
async fn test_ownership_transfer() {
    let (contract, wallets) = setup_test().await;
    let deployer = &wallets[0];
    let new_owner = &wallets[1];

    // Transfer ownership
    contract
        .clone()
        .with_wallet(deployer.clone())
        .methods()
        .transfer_ownership(Identity::Address(new_owner.address().into()))
        .call()
        .await
        .unwrap();

    // Try to call admin function with old owner (should fail)
    let result = contract
        .clone()
        .with_wallet(deployer.clone())
        .methods()
        .emergency_pause()
        .call()
        .await;

    assert!(result.is_err(), "Old owner should not have access");
} 