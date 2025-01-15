library;

use std::{
    contract_id::ContractId,
    identity::Identity,
    logging::log,
    block::timestamp,
};

pub struct Staked {
    pub nft_id: ContractId,
    pub staker: Identity,
    pub timestamp: u64
}

pub struct OwnershipTransferred {
    pub previous_owner: Identity,
    pub new_owner: Identity,
}

pub struct Unstaked {
    pub nft_id: ContractId,
    pub staker: Identity,
    pub timestamp: u64,
    pub reward_earned: u64,
    pub penalty_applied: bool,
}

pub struct RewardClaimed {
    pub staker: Identity,
    pub amount: u64,
}

pub struct RewardDistribution {
    pub total_distributed: u64,
    pub last_distribution_time: u64,
}

pub struct StakingInfo {
    pub staker: Identity,
    pub staked_at: u64
}

// Event emission functions
pub fn emit_staked_event(nft_id: ContractId, staker: Identity) {
    log(Staked {
        nft_id,
        staker,
        timestamp: timestamp()
    });
}

pub fn emit_unstaked_event(nft_id: ContractId, staker: Identity, reward: u64, penalty: bool) {
    log(Unstaked {
        nft_id,
        staker,
        timestamp: timestamp(),
        reward_earned: reward,
        penalty_applied: penalty
    });
}

pub fn emit_reward_claimed_event(staker: Identity, amount: u64) {
    log(RewardClaimed { staker, amount });
}

pub fn emit_paused_event(is_paused: bool) {
    log(is_paused);
}

pub fn emit_reward_rate_updated_event(new_rate: u64) {
    log(new_rate);
}

pub fn emit_ownership_transferred_event(previous_owner: Identity, new_owner: Identity) {
    log(OwnershipTransferred { previous_owner, new_owner });
}
