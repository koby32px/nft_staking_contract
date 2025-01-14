contract;

use std::{
    auth::msg_sender,
    storage::storage_map::*,
    constants::DEFAULT_SUB_ID,
    identity::Identity,
    logging::log,
    block::timestamp,
    context::msg_amount,
    asset::{burn, mint_to, transfer},
    string::String,
    contract_id::ContractId,
    hash::Hash,
};
use sway_libs::reentrancy::reentrancy_guard;

use standards::{
    src20::{SRC20},
    src3::SRC3,
    src5::{SRC5, State},
};

////////////////////////////////////////
// Constants
////////////////////////////////////////
const SECONDS_PER_DAY: u64 = 86400;
const MAX_REWARD_RATE: u64 = 1000; // 10% max daily reward rate
const EARLY_UNSTAKE_PENALTY: u64 = 1000; // 10% penalty
configurable {
    NAME: str[7] = __to_str_array("MyAsset"),
    SYMBOL: str[5] = __to_str_array("MYTKN"),
    DECIMALS: u8 = 18u8,
}

trait Ownable {
    #[storage(read, write)]
    fn transfer_ownership(new_owner: Identity);
    
    #[storage(read)]
    fn owner() -> State;
}

////////////////////////////////////////
// Errors
////////////////////////////////////////

enum StakingError {
    NotOwner: (),
    NotStaker: (),
    ContractPaused: (),
    AmountMismatch: (),
    InvalidTimeRange: (),
    LockPeriodNotMet: (),
    RewardExceedsMaxRate: (),
    ReentrancyDetected: (),
    NoRewards: (),
    WithdrawalTooFrequent: (),
    InvalidStaker: (),
    RewardRateTooHigh: (),
    AlreadyInitialized: (),
    LockPeriodActive: (),
    NFTNotFound: (),
    NotInitialized: (),
}

////////////////////////////////////////
// Events
////////////////////////////////////////

struct Staked {
    nft_id: ContractId,
    staker: Identity,
    timestamp: u64
}
struct OwnershipTransferred {
    previous_owner: Identity,
    new_owner: Identity,
}

struct Unstaked {
    nft_id: ContractId,
    staker: Identity,
    timestamp: u64,
    reward_earned: u64,
    penalty_applied: bool,
}

struct RewardClaimed {
    staker: Identity,
    amount: u64,
}

struct RewardDistribution {
    total_distributed: u64,
    last_distribution_time: u64,
}

struct StakingInfo {
    staker: Identity,
    staked_at: u64
}

// Event emission functions
fn emit_staked_event(nft_id: ContractId, staker: Identity) {
    log(Staked {
        nft_id,
        staker,
        timestamp: timestamp()
    });
}

fn emit_unstaked_event(nft_id: ContractId, staker: Identity, reward: u64, penalty: bool) {
    log(Unstaked {
        nft_id,
        staker,
        timestamp: timestamp(),
        reward_earned: reward,
        penalty_applied: penalty
    });
}

////////////////////////////////////////
// Storage
////////////////////////////////////////

storage {
    owner: State = State::Uninitialized,
    allow_early_unstake: bool = false,
    withdrawal_cooldown: u64 = 0,
    reentrancy_guard: bool = false,
    paused: bool = false,
    reward_rate: u64 = 0,
    min_lock_period: u64 = 0,
    total_staked: u64 = 0,
    staked_nfts: StorageMap<ContractId, StakingInfo> = StorageMap {},
    staker_nfts: StorageMap<Identity, u64> = StorageMap {},
    rewards: StorageMap<Identity, u64> = StorageMap {},
    last_withdrawal_time: StorageMap<Identity, u64> = StorageMap {},
    reward_distribution: RewardDistribution = RewardDistribution {
        total_distributed: 0,
        last_distribution_time: 0
    },
}

////////////////////////////////////////
// ABI Definition
////////////////////////////////////////

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

    /// Stake multiple NFTs in a batch
    #[storage(read, write), payable]
    fn batch_stake(nft_ids: Vec<ContractId>) {
        reentrancy_guard();
        require(!storage.paused.read(), StakingError::ContractPaused);
        require(msg_amount() == nft_ids.len(), StakingError::AmountMismatch);

        let sender = msg_sender().unwrap();
        let mut i = 0;
        while i < nft_ids.len() {
            let nft_id = nft_ids.get(i).unwrap();
            
            // Store staking info for each NFT
            storage.staked_nfts.insert(nft_id, StakingInfo {
                staker: sender,
                staked_at: timestamp(),
            });
            i += 1;
        }
        
        // Update total staked count
        let current_total = storage.total_staked.read();
        let nft_count = nft_ids.len();
        storage.total_staked.write(current_total + nft_count);
        
        release_reentrancy_guard();
    }

    /// Unstake a single NFT
    #[storage(read, write)]
    fn unstake_nft(nft_id: ContractId) {
        reentrancy_guard();
        
        let sender = msg_sender().unwrap();
        let staking_info = storage.staked_nfts.get(nft_id).read();
        require(staking_info.staker == sender, StakingError::NotStaker);
        
        // Check if unstaking early
        let is_early = timestamp() < staking_info.staked_at + storage.min_lock_period.read();
        if is_early {
            require(storage.allow_early_unstake.read(), StakingError::LockPeriodActive);
        }
        
        // Calculate and apply penalty if early
        let reward = calculate_rewards(staking_info.staked_at, timestamp());
        let final_reward = reward - (reward * EARLY_UNSTAKE_PENALTY / 10000);
        
        // Update rewards and remove NFT from staking
        storage.rewards.insert(sender, storage.rewards.get(sender).read() + final_reward);
        require(storage.staked_nfts.remove(nft_id), StakingError::NFTNotFound);
        
        // Update staker's NFT count and total staked
        let current_count = storage.staker_nfts.get(sender).read();
        storage.staker_nfts.insert(sender, current_count - 1);
        storage.total_staked.write(storage.total_staked.read() - 1);
        
        emit_unstaked_event(nft_id, sender, final_reward, is_early);
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

        storage.rewards.insert(sender, 0);
        storage.last_withdrawal_time.insert(sender, timestamp());

        mint_to(sender, DEFAULT_SUB_ID, reward_amount);
        log(RewardClaimed {
            staker: sender,
            amount: reward_amount,
        });
        release_reentrancy_guard();
    }

    #[storage(read)]
    fn get_pending_rewards(staker: Identity) -> u64 {
        storage.rewards.get(staker).read()
    }

    #[storage(read)]
    fn get_staking_info(nft_id: ContractId) -> Option<StakingInfo> {
        storage.staked_nfts.get(nft_id).try_read()
    }

    #[storage(read)]
    fn get_staker_info(staker: Identity) -> Option<StakingInfo> {
        match staker {
            Identity::ContractId(id) => storage.staked_nfts.get(id).try_read(),
            _ => None,
        }
    }

    #[storage(read)]
    fn get_reward_rate() -> u64 {
        storage.reward_rate.read()
    }

    #[storage(read)]
    fn get_total_staked() -> u64 {
        storage.total_staked.read()
    }

    #[storage(read)]
    fn is_paused() -> bool {
        storage.paused.read()
    }

    #[storage(read, write)]
    fn set_reward_rate(new_rate: u64) {
        reentrancy_guard();
        require_owner();
        require(new_rate <= MAX_REWARD_RATE, StakingError::RewardRateTooHigh);
        storage.reward_rate.write(new_rate);
        release_reentrancy_guard();
    }

    #[storage(read, write)]
    fn emergency_withdraw(nft_id: ContractId) {
        reentrancy_guard();
        require_owner();

        let staking_info = storage.staked_nfts.get(nft_id).read();
        
        // Create AssetId from ContractId using AssetId::new
        let asset_id = AssetId::new(nft_id, DEFAULT_SUB_ID);
        
        // Transfer the NFT back to the staker
        transfer(staking_info.staker, asset_id, 1);
        
        // Remove from storage
        require(storage.staked_nfts.remove(nft_id), StakingError::NFTNotFound);
        storage.total_staked.write(storage.total_staked.read() - 1);
        
        release_reentrancy_guard();
    }

    #[storage(read, write)]
    fn emergency_pause() {
        reentrancy_guard();
        require_owner();
        storage.paused.write(true);
        release_reentrancy_guard();
    }

    #[storage(read, write)]
    fn emergency_unpause() {
        reentrancy_guard();
        require_owner();
        storage.paused.write(false);
        release_reentrancy_guard();
    }

    #[storage(read, write)]
    fn initialize(owner: Identity) {
        reentrancy_guard();
        require(storage.owner.read() == State::Uninitialized, StakingError::AlreadyInitialized);
        storage.owner.write(State::Initialized(owner));
        release_reentrancy_guard();
    }

    #[storage(read)]
    fn get_total_distributed_rewards() -> u64 {
        storage.reward_distribution.read().total_distributed
    }

    #[storage(read)]
    fn get_last_distribution_time() -> u64 {
        storage.reward_distribution.read().last_distribution_time
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
        release_reentrancy_guard();
    }

    #[storage(read, write)]
    fn initialize_mint_capabilities() {
        require_owner();
        // Initialize any necessary mint-related storage
        // This will depend on your specific requirements
    }
}

////////////////////////////////////////
// Native Asset Standard Implementation
////////////////////////////////////////

impl SRC20 for Contract {
    #[storage(read)]
    fn total_assets() -> u64 {
        1
    }

    #[storage(read)]
    fn total_supply(asset: AssetId) -> Option<u64> {
        if asset == AssetId::default() {
            Some(storage.total_staked.read())
        } else {
            None
        }
    }

    #[storage(read)]
    fn name(asset: AssetId) -> Option<String> {
        if asset == AssetId::default() {
            Some(String::from_ascii_str(from_str_array(NAME)))
        } else {
            None
        }
    }

    #[storage(read)]
    fn symbol(asset: AssetId) -> Option<String> {
        if asset == AssetId::default() {
            Some(String::from_ascii_str(from_str_array(SYMBOL)))
        } else {
            None
        }
    }

    #[storage(read)]
    fn decimals(asset: AssetId) -> Option<u8> {
        if asset == AssetId::default() {
            Some(DECIMALS)
        } else {
            None
        }
    }
}

impl SRC3 for Contract {
    #[storage(read, write)]
    fn mint(recipient: Identity, sub_id: Option<SubId>, amount: u64) {
        require_owner();
        let sub_id = sub_id.unwrap_or(DEFAULT_SUB_ID);
        
        // Add any necessary checks before minting
        require(!storage.paused.read(), StakingError::ContractPaused);
        
        // Perform the mint operation
        mint_to(recipient, sub_id, amount);
    }

    #[storage(read, write), payable]
    fn burn(sub_id: SubId, amount: u64) {
        require_owner();
        burn(sub_id, amount);
    }
}

impl SRC5 for Contract {
    #[storage(read)]
    fn owner() -> State {
        storage.owner.read()
    }
}

#[storage(read)]
fn require_owner() {
    let sender = msg_sender().unwrap();
    require(
        storage.owner.read() == State::Initialized(sender),
        StakingError::NotOwner,
    );
}

// Implementation for ownership transfer
impl Ownable for Contract {
    #[storage(read, write)]
    fn transfer_ownership(new_owner: Identity) {
        reentrancy_guard();
        require_owner();
        storage.owner.write(State::Initialized(new_owner));
        log(OwnershipTransferred {
            previous_owner: msg_sender().unwrap(),
            new_owner,
        });
        release_reentrancy_guard();
    }

    #[storage(read)]
    fn owner() -> State {
        storage.owner.read()
    }
}

////////////////////////////////////////
// Helper Functions
////////////////////////////////////////

#[storage(read)]
fn calculate_rewards(staked_at: u64, current_time: u64) -> u64 {
    require(current_time > staked_at, StakingError::InvalidTimeRange);
    let duration = current_time - staked_at;
    require(duration >= storage.min_lock_period.read(), StakingError::LockPeriodNotMet);

    let days_staked = duration / SECONDS_PER_DAY;
    let base_reward = days_staked * storage.reward_rate.read();
    
    require(
        base_reward <= MAX_REWARD_RATE * days_staked,
        StakingError::RewardExceedsMaxRate
    );
    
    base_reward
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