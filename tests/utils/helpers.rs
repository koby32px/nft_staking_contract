use fuels::types::Bits256;
use fuels::types::ContractId;
use fuels::types::bech32::Bech32ContractId;

pub const SECONDS_PER_DAY: u64 = 86400;

pub fn create_test_nft_id(id: u64) -> ContractId {
    let bits = Bits256::from_hex_str(&format!("{:064x}", id)).unwrap();
    ContractId::from(bits.0)
}

pub fn contract_id_to_bech32(contract_id: ContractId) -> Bech32ContractId {
    Bech32ContractId::from(contract_id)
} 