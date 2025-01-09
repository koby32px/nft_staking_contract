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
    call_frames::msg_asset_id,
    string::String,
    storage::storage_string::StorageString,
    contract_id::ContractId,
    hash::Hash,
};

use standards::{
    src20::{SRC20, TotalSupplyEvent},
    src3::SRC3,
    src5::{SRC5, State, AccessError},
};

////////////////////////////////////////
// Constants
////////////////////////////////////////

const SECONDS_PER_DAY: u64 = 86400;
const MAX_REWARD_RATE: u64 = 1000; // 10% max daily rate
const EARLY_UNSTAKE_PENALTY: u64 = 5000; // 50% penalty
const ACTION_REWARD_RATE: b256 = 0x0000000000000000000000000000000000000000000000000000000000000001;
const ACTION_MIN_LOCK: b256 = 0x0000000000000000000000000000000000000000000000000000000000000002;
configurable {
    DECIMALS: u8 = 18u8,
    NAME: str[11] = __to_str_array("StakeReward"),
    SYMBOL: str[4] = __to_str_array("STKR"),
}

////////////////////////////////////////
// Errors
////////////////////////////////////////

enum StakingError {
    ContractPaused: (),
    ReentrancyDetected: (),
    InvalidNFTAmount: (),
    NotStaker: (),
    LockPeriodActive: (),
    WithdrawalTooFrequent: (),
    RewardRateTooHigh: (),
    NotOwner: (),
    EarlyUnstakePenalty: (),
    InvalidNFT: (),
    AlreadyInitialized: (),
    NoRewards: (),
    InvalidChangeType: (),
    AmountMismatch: (),
    InvalidTimeRange: (),
    LockPeriodNotMet: (),
    RewardExceedsMaxRate: (),
    NFTNotFound: ()
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

struct SecurityEvent {
    action: b256,
    timestamp: u64,
    initiator: Identity,
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
    staked_nfts: StorageMap<ContractId, StakingInfo> = StorageMap {},
    staker_nfts: StorageMap<Identity, u64> = StorageMap {},
    rewards: StorageMap<Identity, u64> = StorageMap {},
    total_staked: u64 = 0,
    total_supply: u64 = 0,
    pending_admin_changes: StorageMap<b256, (u64, u64)> = StorageMap {},
    owner: State = State::Uninitialized,
    reward_rate: u64 = 10, // 0.1% daily rate
    paused: bool = false,
    min_lock_period: u64 = SECONDS_PER_DAY * 7, // 1 week minimum lock
    last_withdrawal_time: StorageMap<Identity, u64> = StorageMap {},
    reward_distribution: RewardDistribution = RewardDistribution {
        total_distributed: 0,
        last_distribution_time: 0,
    },
    allow_early_unstake: bool = false, // Whether early unstaking is allowed
    withdrawal_cooldown: u64 = SECONDS_PER_DAY // 24 hour cooldown between withdrawals
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
    fn get_reward_rate() -> u64;
    
    #[storage(read)]
    fn get_total_staked() -> u64;
    
    #[storage(read)]
    fn is_paused() -> bool;

    #[storage(read)]
    fn get_total_distributed_rewards() -> u64;

    #[storage(read)]
    fn get_last_distribution_time() -> u64;

    #[storage(read)]
    fn get_staker_info(staker: Identity) -> (u64, u64);

    // Admin functions
    #[storage(read, write)]
    fn set_reward_rate(new_rate: u64);
    
    #[storage(read, write)]
    fn emergency_pause();
    
    #[storage(read, write)]
    fn emergency_unpause();
    
    #[storage(read, write)]
    fn initialize(owner: Identity);

    #[storage(read, write)]
    fn emergency_withdraw(nft_id: ContractId);

    #[storage(read, write)]
    fn propose_admin_change(action: b256, value: u64);

    #[storage(read, write)]
    fn execute_admin_change(action: b256);
}

abi Ownable {
    #[storage(read, write)]
    fn transfer_ownership(new_owner: Identity);
}

////////////////////////////////////////
// Contract Implementation
////////////////////////////////////////

impl NFTStaking for Contract {
    #[storage(read, write), payable]
    fn stake_nft(nft_id: ContractId) {
        let sender = msg_sender().unwrap();
        
        // Add to staked_nfts
        storage.staked_nfts.insert(nft_id, StakingInfo {
            staker: sender,
            staked_at: timestamp()
        });
        
        // Update staker's NFT count
        let current_count = storage.staker_nfts.get(sender).try_read().unwrap_or(0);
        storage.staker_nfts.insert(sender, current_count + 1);
        
        storage.total_staked.write(storage.total_staked.read() + 1);
        
        // Emit staking event
        emit_staked_event(nft_id, sender);
    }

    #[storage(read, write), payable]
    fn batch_stake(nft_ids: Vec<ContractId>) {
        require(!storage.paused.read(), StakingError::ContractPaused);
        require(msg_amount() == nft_ids.len(), StakingError::AmountMismatch);

        let sender = msg_sender().unwrap();
        let mut i = 0;
        while i < nft_ids.len() {
            let nft_id = nft_ids.get(i).unwrap();
            storage.staked_nfts.insert(nft_id, StakingInfo {
                staker: sender,
                staked_at: timestamp()
            });
            storage.total_staked.write(storage.total_staked.read() + 1);
            i += 1;
        }
    }

    #[storage(read, write)]
    fn unstake_nft(nft_id: ContractId) {
        let sender = msg_sender().unwrap();
        let staking_info = storage.staked_nfts.get(nft_id).read();
        require(staking_info.staker == sender, StakingError::NotStaker);
        
        let is_early = timestamp() < staking_info.staked_at + storage.min_lock_period.read();
        if is_early {
            require(storage.allow_early_unstake.read(), StakingError::LockPeriodActive);
        }
        
        let reward = calculate_rewards(staking_info.staked_at, timestamp());
        let final_reward = reward - (reward * EARLY_UNSTAKE_PENALTY / 10000);
        
        storage.rewards.insert(sender, storage.rewards.get(sender).read() + final_reward);
        
        // Handle the remove() return value
        let removed = storage.staked_nfts.remove(nft_id);
        require(removed, StakingError::NFTNotFound);
        
        // Update staker's NFT count
        let current_count = storage.staker_nfts.get(sender).read();
        storage.staker_nfts.insert(sender, current_count - 1);
        
        storage.total_staked.write(storage.total_staked.read() - 1);
        
        // Emit unstaking event
        emit_unstaked_event(nft_id, sender, final_reward, is_early);
    }

    #[storage(read, write)]
    fn batch_unstake(nft_ids: Vec<ContractId>) {
        require(!storage.paused.read(), StakingError::ContractPaused);
        
        let sender = msg_sender().unwrap();
        let mut i = 0;
        while i < nft_ids.len() {
            let nft_id = nft_ids.get(i).unwrap();
            let staking_info = storage.staked_nfts.get(nft_id).read();
            require(staking_info.staker == sender, StakingError::NotStaker);
            
            let is_early = timestamp() < staking_info.staked_at + storage.min_lock_period.read();
            let penalty = if is_early {
                require(storage.allow_early_unstake.read(), StakingError::LockPeriodActive);
                EARLY_UNSTAKE_PENALTY
            } else {
                0
            };

            let reward = calculate_rewards(staking_info.staked_at, timestamp());
            let final_reward = reward - (reward * penalty / 10000);
            
            storage.rewards.insert(sender, storage.rewards.get(sender).read() + final_reward);
            let _ = storage.staked_nfts.remove(nft_id);
            storage.total_staked.write(storage.total_staked.read() - 1);
            i += 1;
        }
    }

    #[storage(read, write)]
    fn claim_rewards() {
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
    }

    #[storage(read)]
    fn get_pending_rewards(staker: Identity) -> u64 {
        storage.rewards.get(staker).read()
    }

    #[storage(read)]
    fn get_staking_info(nft_id: ContractId) -> Option<StakingInfo> {
        Some(storage.staked_nfts.get(nft_id).read())
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
        require_owner();
        require(new_rate <= MAX_REWARD_RATE, StakingError::RewardRateTooHigh);
        storage.reward_rate.write(new_rate);
    }

    #[storage(read, write)]
    fn emergency_withdraw(nft_id: ContractId) {
        require_owner();
        
        // Get staking info
        let staking_info = storage.staked_nfts.get(nft_id).try_read();
        require(staking_info.is_some(), StakingError::NFTNotFound);
        
        let info = staking_info.unwrap();
        require(info.staker != Identity::Address(Address::from(0x0000000000000000000000000000000000000000000000000000000000000000)), StakingError::InvalidNFTAmount);
        
        // Create AssetId using ContractId and DEFAULT_SUB_ID
        let asset_id = AssetId::new(nft_id, DEFAULT_SUB_ID); // Added DEFAULT_SUB_ID parameter
        
        // Transfer NFT back to staker
        transfer(info.staker, asset_id, 1); // Assuming 1 NFT is being transferred
        
        // Remove from storage and check success
        let removed = storage.staked_nfts.remove(nft_id);
        require(removed, StakingError::NFTNotFound);
        
        storage.total_staked.write(storage.total_staked.read() - 1);
        
        log(SecurityEvent {
            action: ACTION_REWARD_RATE,
            timestamp: timestamp(),
            initiator: msg_sender().unwrap(),
        });
    }

    #[storage(read, write)]
    fn emergency_pause() {
        require_owner();
        storage.paused.write(true);
    }

    #[storage(read, write)]
    fn emergency_unpause() {
        require_owner();
        storage.paused.write(false);
    }

    #[storage(read, write)]
    fn initialize(owner: Identity) {
        require(storage.owner.read() == State::Uninitialized, StakingError::AlreadyInitialized);
        storage.owner.write(State::Initialized(owner));
    }

    #[storage(read)]
    fn get_staker_info(staker: Identity) -> (u64, u64) {
        let total_rewards = storage.rewards.get(staker).try_read().unwrap_or(0);
        let total_staked = storage.staker_nfts.get(staker).try_read().unwrap_or(0);
        (total_staked, total_rewards)
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
    fn propose_admin_change(change_type: b256, new_value: u64) {
        require_owner();
        storage.pending_admin_changes.insert(
            change_type,
            (timestamp(), new_value)
        );
    }

    #[storage(read, write)]
    fn execute_admin_change(change_type: b256) {
        let change_data = storage.pending_admin_changes
            .get(change_type)
            .try_read()
            .expect("No pending change found");

        match change_type {
            ACTION_REWARD_RATE => {
                storage.reward_rate.write(change_data.1);
            },
            ACTION_MIN_LOCK => {
                storage.min_lock_period.write(change_data.1);
            },
            _ => revert(0),
        }

        let _ = storage.pending_admin_changes.remove(change_type);
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
        require(sub_id.is_some() && sub_id.unwrap() == DEFAULT_SUB_ID, "incorrect-sub-id");
        require_owner();

        let new_supply = storage.total_supply.read() + amount;
        storage.total_supply.write(new_supply);
        mint_to(recipient, DEFAULT_SUB_ID, amount);
    }

    #[storage(read, write)]
    #[payable]
    fn burn(sub_id: SubId, amount: u64) {
        require(sub_id == DEFAULT_SUB_ID, "incorrect-sub-id");
        require_owner();

        let new_supply = storage.total_supply.read() - amount;
        storage.total_supply.write(new_supply);
        burn(DEFAULT_SUB_ID, amount);
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
    let owner = match storage.owner.read() {
        State::Initialized(owner) => owner,
        _ => revert(0),
    };
    require(msg_sender().unwrap() == owner, "not owner");
}

// Implementation for ownership transfer
impl Ownable for Contract {
    #[storage(read, write)]
    fn transfer_ownership(new_owner: Identity) {
        require_owner();
        storage.owner.write(State::Initialized(new_owner));
        
        log(OwnershipTransferred {
            previous_owner: msg_sender().unwrap(),
            new_owner,
        });
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
    
    // Safe math for days calculation
    let days_staked = duration / SECONDS_PER_DAY;
    
    // Withdrawal cooldown check
    let last_withdrawal = storage.last_withdrawal_time
        .get(msg_sender().unwrap())
        .try_read()
        .unwrap_or(0);
    require(
        current_time >= last_withdrawal + SECONDS_PER_DAY,
        StakingError::WithdrawalTooFrequent
    );
    
    // Safe reward calculation
    let base_reward = days_staked * storage.reward_rate.read();
    require(
        base_reward <= MAX_REWARD_RATE * days_staked,
        StakingError::RewardExceedsMaxRate
    );
    
    base_reward
}

impl b256 {
    fn from_u64(value: u64) -> b256 {
        // Create a b256 with the u64 value in the last 8 bytes
        asm(r1: value) {
            r1: b256
        }
    }
}