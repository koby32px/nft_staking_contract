contract;

pub mod data_structures;
pub mod errors;
pub mod events;
pub mod interface;

use std::{
    auth::msg_sender,
    storage::storage_map::StorageMap,
    constants::DEFAULT_SUB_ID,
    identity::Identity,
    asset::{mint_to, burn, transfer},
    string::String,
    contract_id::ContractId,
    hash::Hash,
    logging::log,
    block::timestamp,
    option::Option,
    address::Address,
    context::msg_amount,
    call_frames::msg_asset_id,
};

use ::data_structures::{StakingInfo, RewardDistribution, State};
use ::errors::StakingError;
use ::events::*;
use ::interface::NFTStaking;

const SECONDS_PER_DAY: u64 = 86400;
const MAX_REWARD_RATE: u64 = 1000; // Maximum reward rate (100%)
const EARLY_UNSTAKE_PENALTY: u64 = 100; // 10% penalty
const REWARD_TOKEN_ID: b256 = 0xf8f8b6283d7fa5b672b530cbb84fcccb4ff8dc40f8176ef4544ddb1f1952ad07;

// Helper function to get reward token AssetId
fn get_reward_token() -> AssetId {
    AssetId::new(ContractId::from(REWARD_TOKEN_ID), DEFAULT_SUB_ID)
}

storage {
    owner: State = State::Uninitialized,
    paused: bool = false,
    reentrancy_guard: bool = false,
    reward_rate: u64 = 0,
    min_lock_period: u64 = 86400, // 1 day in seconds
    withdrawal_cooldown: u64 = 86400, // 1 day in seconds
    allow_early_unstake: bool = false,
    staked_nfts: StorageMap<ContractId, StakingInfo> = StorageMap {},
    staker_nfts: StorageMap<Identity, u64> = StorageMap {},
    rewards: StorageMap<Identity, u64> = StorageMap {},
    last_withdrawal_time: StorageMap<Identity, u64> = StorageMap {},
    total_staked: u64 = 0,
    reward_distribution: RewardDistribution = RewardDistribution {
        total_distributed: 0,
        last_distribution_time: 0,
    },
    reward_token_balance: u64 = 0,
}

////////////////////////////////////////
// Contract Implementation
////////////////////////////////////////

impl NFTStaking for Contract {
    /// Stake a single NFT
    #[storage(read, write), payable]
    fn stake_nft(nft_id: ContractId) {
        reentrancy_guard();

        let sender = msg_sender().unwrap();

        // Store staking info
        storage.staked_nfts.insert(nft_id, StakingInfo {
            staker: sender,
            staked_at: timestamp()
        });

        // Update staker's NFT count
        let current_count = storage.staker_nfts.get(sender).try_read().unwrap_or(0);
        storage.staker_nfts.insert(sender, current_count + 1);

        // Update total staked count
        storage.total_staked.write(storage.total_staked.read() + 1);

        emit_staked_event(nft_id, sender);
        release_reentrancy_guard();
    }

    /// Unstake a single NFT
    #[storage(read, write)]
    fn unstake_nft(nft_id: ContractId) {
        reentrancy_guard();
        require(!storage.paused.read(), StakingError::ContractPaused);

        let sender = msg_sender().unwrap();

        // Retrieve staking info
        let staking_info_option = storage.staked_nfts.get(nft_id).try_read();
        require(staking_info_option.is_some(), StakingError::NFTNotFound);
        let staking_info = staking_info_option.unwrap();

        // Verify staker
        require(staking_info.staker == sender, StakingError::NotStaker);

        // Calculate rewards
        let current_time = timestamp();
        let mut reward_amount = calculate_rewards(staking_info.staked_at, current_time);
        let mut penalty_applied = false;

        // Apply early unstake penalty if applicable
        if !storage.allow_early_unstake.read() &&
           current_time < staking_info.staked_at + storage.min_lock_period.read() {
            reward_amount = saturating_sub(reward_amount, reward_amount / 1000 * EARLY_UNSTAKE_PENALTY);
            penalty_applied = true;
        }

        // Transfer NFT back to staker
        match sender {
            Identity::Address(_) => {
                let sub_id = nft_id.into();
                mint_to(sender, sub_id, 1);
            },
            _ => require(false, StakingError::InvalidStaker),
        }

        // Transfer rewards to staker
        if reward_amount > 0 {
            require(
                storage.reward_token_balance.read() >= reward_amount,
                StakingError::NoRewards
            );
            
            match sender {
                Identity::Address(_) => {
                    transfer(sender, get_reward_token(), reward_amount);
                    storage.reward_token_balance.write(
                        storage.reward_token_balance.read() - reward_amount
                    );
                },
                _ => require(false, StakingError::InvalidStaker),
            }
            storage.rewards.insert(sender, storage.rewards.get(sender).read() + reward_amount);
            storage.reward_distribution.write(RewardDistribution {
                total_distributed: storage.reward_distribution.read().total_distributed + reward_amount,
                last_distribution_time: current_time,
            });
            emit_reward_claimed_event(sender, reward_amount);
        }

        // Remove staking info
        let _ = storage.staked_nfts.remove(nft_id);

        // Update staker's NFT count
        storage.staker_nfts.insert(sender, storage.staker_nfts.get(sender).read() - 1);

        // Update total staked count
        storage.total_staked.write(storage.total_staked.read() - 1);

        emit_unstaked_event(nft_id, sender, reward_amount, penalty_applied);
        release_reentrancy_guard();
    }

    #[storage(read, write)]
    fn claim_rewards() {
        reentrancy_guard();
        require(!storage.paused.read(), StakingError::ContractPaused);

        let sender = msg_sender().unwrap();
        let reward_amount = storage.rewards.get(sender).read();
        require(reward_amount > 0, StakingError::NoRewards);

        let last_withdrawal = storage.last_withdrawal_time.get(sender).read();
        require(
            timestamp() >= last_withdrawal + storage.withdrawal_cooldown.read(),
            StakingError::WithdrawalTooFrequent
        );

        require(
            storage.reward_token_balance.read() >= reward_amount,
            StakingError::NoRewards
        );
        
        match sender {
            Identity::Address(_) => {
                transfer(sender, get_reward_token(), reward_amount);
                storage.reward_token_balance.write(
                    storage.reward_token_balance.read() - reward_amount
                );
            },
            _ => require(false, StakingError::InvalidStaker),
        }
        storage.rewards.insert(sender, 0); // Reset rewards after claiming
        storage.last_withdrawal_time.insert(sender, timestamp());
        storage.reward_distribution.write(RewardDistribution {
            total_distributed: storage.reward_distribution.read().total_distributed + reward_amount,
            last_distribution_time: timestamp(),
        });

        emit_reward_claimed_event(sender, reward_amount);
        release_reentrancy_guard();
    }

    /// Stake multiple NFTs in a batch
    #[storage(read, write), payable]
    fn batch_stake(nft_ids: Vec<ContractId>) {
        reentrancy_guard();
        let sender = msg_sender().unwrap();
        require(!storage.paused.read(), StakingError::ContractPaused);

        let mut i = 0;
        while i < nft_ids.len() {
            let nft_id = nft_ids.get(i).unwrap();
            storage.staked_nfts.insert(nft_id, StakingInfo {
                staker: sender,
                staked_at: timestamp()
            });
            let current_count = storage.staker_nfts.get(sender).try_read().unwrap_or(0);
            storage.staker_nfts.insert(sender, current_count + 1);
            storage.total_staked.write(storage.total_staked.read() + 1);
            emit_staked_event(nft_id, sender);
            i += 1;
        }
        release_reentrancy_guard();
    }

    /// Unstake multiple NFTs in a batch
    #[storage(read, write)]
    fn batch_unstake(nft_ids: Vec<ContractId>) {
        reentrancy_guard();
        require(!storage.paused.read(), StakingError::ContractPaused);

        let sender = msg_sender().unwrap();
        let mut i = 0;
        while i < nft_ids.len() {
            let nft_id = nft_ids.get(i).unwrap();

            let staking_info = storage.staked_nfts.get(nft_id).read();
            require(staking_info.staker == sender, StakingError::NotStaker);
            i += 1;
        }
        release_reentrancy_guard();
    }

    /// Returns the pending rewards for a staker
    #[storage(read)]
    fn get_pending_rewards(staker: Identity) -> u64 {
        calculate_rewards_for_staker(staker)
    }

    /// Returns the staking info for a given NFT ID
    #[storage(read)]
    fn get_staking_info(nft_id: ContractId) -> Option<StakingInfo> {
        storage.staked_nfts.get(nft_id).try_read()
    }

    /// Returns the total number of NFTs staked
    #[storage(read)]
    fn get_total_staked() -> u64 {
        storage.total_staked.read()
    }

    /// Returns the current reward rate
    #[storage(read)]
    fn get_reward_rate() -> u64 {
        storage.reward_rate.read()
    }

    /// Returns the current paused state of the contract
    #[storage(read)]
    fn is_paused() -> bool {
        storage.paused.read()
    }

    /// Returns the total distributed rewards
    #[storage(read)]
    fn get_total_distributed_rewards() -> u64 {
        storage.reward_distribution.read().total_distributed
    }

    /// Returns the last reward distribution time
    #[storage(read)]
    fn get_last_distribution_time() -> u64 {
        storage.reward_distribution.read().last_distribution_time
    }

    /// Returns staking information for a given staker
    #[storage(read)]
    fn get_staker_info(staker: Identity) -> Option<StakingInfo> {
        let nft_count = storage.staker_nfts.get(staker).try_read().unwrap_or(0);
        if nft_count > 0 {
            Some(StakingInfo {
                staker,
                staked_at: storage.last_withdrawal_time.get(staker).try_read().unwrap_or(0)
            })
        } else {
            None
        }
    }

    /// Pauses the contract, preventing staking and unstaking
    #[storage(read, write)]
    fn emergency_pause() {
        require_owner();
        storage.paused.write(true);
        emit_paused_event(true);
    }

    /// Unpauses the contract, allowing staking and unstaking
    #[storage(read, write)]
    fn emergency_unpause() {
        require_owner();
        storage.paused.write(false);
        emit_paused_event(false);
    }

    /// Initializes the contract with the owner
    #[storage(read, write)]
    fn initialize(owner: Identity) {
        match storage.owner.read() {
            State::Uninitialized => {
                storage.owner.write(State::Initialized(owner));
                emit_ownership_transferred_event(Identity::Address(Address::zero()), owner);
            },
            _ => require(false, StakingError::AlreadyInitialized),
        }
    }

    /// Allows the owner to withdraw a stuck NFT
    #[storage(read, write)]
    fn emergency_withdraw(nft_id: ContractId) {
        require_owner();
        
        // Check if NFT exists in contract
        let staking_info = storage.staked_nfts.get(nft_id).try_read();
        require(staking_info.is_some(), StakingError::NFTNotFound);
        
        // Get the staking info
        let info = staking_info.unwrap();
        
        // Remove staking info
        let _ = storage.staked_nfts.remove(nft_id);
        
        // Update staker's NFT count
        let current_count = storage.staker_nfts.get(info.staker).try_read().unwrap_or(0);
        if current_count > 0 {
            storage.staker_nfts.insert(info.staker, current_count - 1);
        }
        
        // Update total staked count
        storage.total_staked.write(storage.total_staked.read() - 1);
        
        // Transfer NFT back to owner
        let sub_id = nft_id.into();
        mint_to(msg_sender().unwrap(), sub_id, 1);
    }

    /// Transfers ownership of the contract
    #[storage(read, write)]
    fn transfer_ownership(new_owner: Identity) {
        reentrancy_guard();
        require_owner();
        storage.owner.write(State::Initialized(new_owner));
        log(OwnershipTransferred {
            previous_owner: msg_sender().unwrap(),
            new_owner,
        });
    }

    /// Sets the reward rate
    #[storage(read, write)]
    fn set_reward_rate(new_rate: u64) {
        require_owner();
        require(new_rate <= MAX_REWARD_RATE, StakingError::RewardRateTooHigh);
        storage.reward_rate.write(new_rate);
        emit_reward_rate_updated_event(new_rate);
    }

    /// Initializes minting capabilities
    #[storage(read, write)]
    fn initialize_mint_capabilities() {
        require_owner();
        require(!storage.paused.read(), StakingError::ContractPaused);
        
        // Set up initial minting state
        storage.reward_rate.write(0);
        storage.total_staked.write(0);
        storage.reward_distribution.write(RewardDistribution {
            total_distributed: 0,
            last_distribution_time: timestamp(),
        });
    }

    /// Deposits rewards
    #[storage(read, write), payable]
    fn deposit_rewards() {
        require_owner();
        let amount = msg_amount();
        let asset_id = msg_asset_id();
        require(amount > 0, StakingError::AmountMismatch);
        require(asset_id == get_reward_token(), StakingError::InvalidToken);
        
        // Update reward token balance
        storage.reward_token_balance.write(
            storage.reward_token_balance.read() + amount
        );
    }
}

trait Ownable {
    #[storage(read)]
    fn owner() -> State;
    #[storage(read, write)]
    fn transfer_ownership(new_owner: Identity);
}

impl Ownable for Contract {
    #[storage(read)]
    fn owner() -> State {
        storage.owner.read()
    }

    #[storage(read, write)]
    fn transfer_ownership(new_owner: Identity) {
        reentrancy_guard();
        require_owner();
        storage.owner.write(State::Initialized(new_owner));
        log(OwnershipTransferred {
            previous_owner: msg_sender().unwrap(),
            new_owner,
        });
    }
}

#[storage(read)]
fn calculate_rewards(staked_at: u64, current_time: u64) -> u64 {
    require(current_time > staked_at, StakingError::InvalidTimeRange);
    let duration = current_time - staked_at;
    require(duration >= storage.min_lock_period.read(), StakingError::LockPeriodNotMet);

    let days_staked = duration / SECONDS_PER_DAY;
    let base_reward = days_staked * storage.reward_rate.read();
    base_reward
}

#[storage(read)]
fn calculate_rewards_for_staker(staker: Identity) -> u64 {
    let mut total_rewards = 0;
    let nfts = storage.staker_nfts.get(staker).try_read().unwrap_or(0);
    let current_time = timestamp();
    
    let mut i = 0;
    while i < nfts {
        let staked_at = current_time - SECONDS_PER_DAY; // Example: staked one day ago
        total_rewards += calculate_rewards(staked_at, current_time);
        i += 1;
    }
    total_rewards
}

#[storage(read)]
fn require_owner() {
    let sender = msg_sender().unwrap();
    match storage.owner.read() {
        State::Initialized(owner) => require(owner == sender, StakingError::NotOwner),
        _ => require(false, StakingError::NotInitialized),
    }
}

#[storage(read, write)]
fn reentrancy_guard() {
    require(!storage.reentrancy_guard.read(), StakingError::ReentrancyDetected);
    storage.reentrancy_guard.write(true);
}

#[storage(read, write)]
fn release_reentrancy_guard() {
    storage.reentrancy_guard.write(false);
}

fn emit_staked_event(nft_id: ContractId, staker: Identity) {
    events::emit_staked_event(nft_id, staker);
}

fn emit_unstaked_event(nft_id: ContractId, staker: Identity, reward: u64, penalty: bool) {
    events::emit_unstaked_event(nft_id, staker, reward, penalty);
}

fn emit_reward_claimed_event(staker: Identity, amount: u64) {
    events::emit_reward_claimed_event(staker, amount);
}

fn emit_paused_event(is_paused: bool) {
    events::emit_paused_event(is_paused);
}

fn emit_reward_rate_updated_event(new_rate: u64) {
    events::emit_reward_rate_updated_event(new_rate);
}

fn emit_ownership_transferred_event(previous_owner: Identity, new_owner: Identity) {
    events::emit_ownership_transferred_event(previous_owner, new_owner);
}

fn saturating_sub(a: u64, b: u64) -> u64 {
    if b > a {
        0
    } else {
        a - b
    }
}