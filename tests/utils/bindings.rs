use fuels::prelude::*;

abigen!(Contract(
    name = "NFTStakingContract",
    abi = "out/debug/koby_staking_contract-abi.json"
));

impl<T> NFTStakingContract<T> 
where
    T: Account + Clone,
{
    pub fn with_wallet(self, wallet: T) -> Self {
        Self::new(self.contract_id(), wallet)
    }
} 