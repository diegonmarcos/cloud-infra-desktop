//! CTAP2 protocol handler — STUB for Phase B.1.
//!
//! The full implementation will:
//!   - Parse CTAP2 CBOR commands (authenticatorMakeCredential,
//!     authenticatorGetAssertion, authenticatorGetInfo, authenticatorReset).
//!   - Hold a stable AAGUID derived from `machine-id ⊕ vault account identifier`.
//!   - Forward signing operations to the local sealed key store.
//!
//! Why stubbed: the whole point of Phase B.1+B.2 is to prove TPM
//! seal/unseal works first. CTAP2 + uhid wiring is Phase B.3 + B.4.

#![allow(unused)]

use crate::error::Result;

/// Placeholder — will become `pub fn handle_command(req: Ctap2Request) -> Ctap2Response`.
pub fn dispatch(_cbor: &[u8]) -> Result<Vec<u8>> {
    // Intentional: see module doc.
    Err(crate::BrokerError::Ctap2NotImplemented)
}
