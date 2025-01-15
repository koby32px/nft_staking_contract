library;

pub enum StakingError {
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
    InvalidToken: (),
}
