//! Bitwarden / Vaultwarden REST client — STUB for Phase B.1.
//!
//! The full implementation will:
//!   - Authenticate via `prelogin` + `connect/token` (PBKDF2/Argon2 KDF).
//!   - Sync `/api/sync` periodically.
//!   - Decrypt the cipher vault using the master-key-derived stretched key.
//!   - Surface passkey ciphers (`type == 5` in the BW data model) to the
//!     CTAP2 layer.
//!
//! Why stubbed: requires a long protocol implementation that's irrelevant
//! to proving TPM seal/unseal. Will likely lift from `rbw` internals.

#![allow(unused)]

use crate::error::Result;

pub struct BwClient;

impl BwClient {
    pub async fn login(_endpoint: &str, _email: &str, _master_pw: &[u8]) -> Result<Self> {
        Err(crate::BrokerError::Vault("not yet implemented".into()))
    }

    pub async fn sync(&self) -> Result<()> {
        Err(crate::BrokerError::Vault("not yet implemented".into()))
    }
}
