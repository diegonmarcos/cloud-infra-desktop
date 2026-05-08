//! Crate-wide error type. Thin `thiserror` enum; everything else uses `anyhow`
//! at the binary boundary.

use thiserror::Error;

#[derive(Debug, Error)]
pub enum BrokerError {
    #[error("TPM2 device unavailable or inaccessible: {0}")]
    TpmUnavailable(String),

    #[error("sealed blob format invalid: {0}")]
    SealFormat(String),

    #[error("config error: {0}")]
    Config(String),

    #[error("vault API error: {0}")]
    Vault(String),

    #[error("ctap2 not yet implemented (Phase B.3)")]
    Ctap2NotImplemented,

    #[error("uhid not yet implemented (Phase B.4)")]
    UhidNotImplemented,

    #[error("io: {0}")]
    Io(#[from] std::io::Error),

    #[error("other: {0}")]
    Other(String),
}

pub type Result<T> = std::result::Result<T, BrokerError>;
