//! /dev/uhid USB-HID emulation — STUB for Phase B.1.
//!
//! The full implementation will:
//!   - Open `/dev/uhid` (group `uhid`).
//!   - Register a virtual device with the FIDO2 HID report descriptor
//!     (vendor 0xF1D0, usage page 0xF1D0, usage 0x01).
//!   - Bridge raw 64-byte HID frames to/from the CTAP2 dispatcher.
//!
//! Why stubbed: requires kernel uhid module + a real HID descriptor
//! constant that we'll lift from `uhid-virt` when Phase B.4 lands.

#![allow(unused)]

use crate::error::Result;
use std::path::Path;

pub async fn run_loop(_uhid_path: &Path) -> Result<()> {
    // Intentional: see module doc.
    Err(crate::BrokerError::UhidNotImplemented)
}
