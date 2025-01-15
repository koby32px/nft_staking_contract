library;

pub struct StakingInfo {
    pub staker: Identity,
    pub staked_at: u64,
}

pub struct RewardDistribution {
    pub total_distributed: u64,
    pub last_distribution_time: u64,
}

pub enum State {
    Uninitialized: (),
    Initialized: Identity,
} 