library;

use ::data_structures::StakingInfo;

abi NFTStaking {
    // Core staking functions
    #[storage(read, write), payable]
    fn stake_nft(nft_id: ContractId);

    #[storage(read, write)]
    fn unstake_nft(nft_id: ContractId);

    #[storage(read, write)]
    fn claim_rewards();

    // Batch functions
    #[storage(read, write), payable]
    fn batch_stake(nft_ids: Vec<ContractId>);

    #[storage(read, write)]
    fn batch_unstake(nft_ids: Vec<ContractId>);

    // View functions
    #[storage(read)]
    fn get_pending_rewards(staker: Identity) -> u64;

    #[storage(read)]
    fn get_staking_info(nft_id: ContractId) -> Option<StakingInfo>;

    #[storage(read)]
    fn get_total_staked() -> u64;

    #[storage(read)]
    fn get_reward_rate() -> u64;

    #[storage(read)]
    fn is_paused() -> bool;

    #[storage(read)]
    fn get_total_distributed_rewards() -> u64;

    #[storage(read)]
    fn get_last_distribution_time() -> u64;

    #[storage(read)]
    fn get_staker_info(staker: Identity) -> Option<StakingInfo>;

    // Admin functions
    #[storage(read, write)]
    fn emergency_pause();

    #[storage(read, write)]
    fn emergency_unpause();

    #[storage(read, write)]
    fn initialize(owner: Identity);

    #[storage(read, write)]
    fn emergency_withdraw(nft_id: ContractId);

    #[storage(read, write)]
    fn transfer_ownership(new_owner: Identity);

    #[storage(read, write)]
    fn set_reward_rate(new_rate: u64);

    #[storage(read, write)]
    fn initialize_mint_capabilities();

    #[storage(read, write), payable]
    fn deposit_rewards();
}