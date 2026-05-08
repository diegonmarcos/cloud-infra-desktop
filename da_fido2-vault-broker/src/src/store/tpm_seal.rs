//! Phase B.2 — TPM2 seal/unseal proof of concept.
//!
//! Default build = mock backend. AES-256-GCM with key derived from
//! `/etc/machine-id` via HKDF-SHA256. **NOT FOR PRODUCTION** — provides a
//! reproducible roundtrip on any Linux box (incl. CI) so the on-disk
//! format and the public API can be exercised without TPM hardware.
//!
//! `--features tpm` build = real `tss-esapi` backend, PCR-bound to 0+7+8.
//! That hardware path is currently `todo!()` and will be fleshed out in
//! Phase B.2-hw on a host with a real TPM2 chip. Today the mock proves
//! the format and the API; the feature-gated stub guarantees the module
//! compiles when the feature is OFF (default).
//!
//! On-disk format (binary, all little-endian):
//!   u32 version=1
//!   u32 pcr_bitmask           (mock backend uses 0)
//!   u32 public_blob_len; [public_blob bytes]
//!   u32 private_blob_len; [private_blob bytes]
//!
//! Public API:
//!   pub fn seal_to_path(plain: &[u8], path: &Path) -> Result<()>
//!   pub fn unseal_from_path(path: &Path) -> Result<Zeroizing<Vec<u8>>>

use crate::error::{BrokerError, Result};
use std::io::{Read, Write};
use std::path::Path;
use zeroize::Zeroizing;

/// Wire format version. Bumped on any incompatible layout change.
const FORMAT_VERSION: u32 = 1;

/// Maximum size for a sealed blob field (1 MiB) — guards against
/// pathological / corrupt headers triggering huge allocations.
const MAX_BLOB_FIELD: u32 = 1024 * 1024;

// ─── Public API ────────────────────────────────────────────────────────

/// Seal `plain` and write the framed blob to `path`.
pub fn seal_to_path(plain: &[u8], path: &Path) -> Result<()> {
    #[cfg(not(feature = "tpm"))]
    let (pcr_bitmask, public_blob, private_blob) = mock::seal(plain)?;
    #[cfg(feature = "tpm")]
    let (pcr_bitmask, public_blob, private_blob) = tpm::seal(plain)?;

    write_framed(path, pcr_bitmask, &public_blob, &private_blob)
}

/// Read the framed blob at `path` and unseal it.
pub fn unseal_from_path(path: &Path) -> Result<Zeroizing<Vec<u8>>> {
    let (pcr_bitmask, public_blob, private_blob) = read_framed(path)?;

    #[cfg(not(feature = "tpm"))]
    {
        mock::unseal(pcr_bitmask, &public_blob, &private_blob)
    }
    #[cfg(feature = "tpm")]
    {
        tpm::unseal(pcr_bitmask, &public_blob, &private_blob)
    }
}

// ─── Frame I/O (shared by both backends) ───────────────────────────────

fn write_framed(
    path: &Path,
    pcr_bitmask: u32,
    public_blob: &[u8],
    private_blob: &[u8],
) -> Result<()> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)?;
        }
    }
    let mut f = std::fs::File::create(path)?;
    f.write_all(&FORMAT_VERSION.to_le_bytes())?;
    f.write_all(&pcr_bitmask.to_le_bytes())?;
    f.write_all(&(public_blob.len() as u32).to_le_bytes())?;
    f.write_all(public_blob)?;
    f.write_all(&(private_blob.len() as u32).to_le_bytes())?;
    f.write_all(private_blob)?;
    f.sync_all()?;
    Ok(())
}

fn read_framed(path: &Path) -> Result<(u32, Vec<u8>, Vec<u8>)> {
    let mut f = std::fs::File::open(path)?;
    let version = read_u32(&mut f)
        .map_err(|_| BrokerError::SealFormat("file truncated before version field".into()))?;
    if version != FORMAT_VERSION {
        return Err(BrokerError::SealFormat(format!(
            "unsupported format version {version} (expected {FORMAT_VERSION})"
        )));
    }
    let pcr_bitmask = read_u32(&mut f)
        .map_err(|_| BrokerError::SealFormat("file truncated before pcr_bitmask".into()))?;
    let public_blob = read_len_prefixed(&mut f, "public_blob")?;
    let private_blob = read_len_prefixed(&mut f, "private_blob")?;
    Ok((pcr_bitmask, public_blob, private_blob))
}

fn read_u32(f: &mut std::fs::File) -> std::io::Result<u32> {
    let mut buf = [0u8; 4];
    f.read_exact(&mut buf)?;
    Ok(u32::from_le_bytes(buf))
}

fn read_len_prefixed(f: &mut std::fs::File, name: &str) -> Result<Vec<u8>> {
    let len = read_u32(f)
        .map_err(|_| BrokerError::SealFormat(format!("file truncated before {name} length")))?;
    if len > MAX_BLOB_FIELD {
        return Err(BrokerError::SealFormat(format!(
            "{name} length {len} exceeds maximum {MAX_BLOB_FIELD}"
        )));
    }
    let mut buf = vec![0u8; len as usize];
    f.read_exact(&mut buf)
        .map_err(|_| BrokerError::SealFormat(format!("file truncated inside {name}")))?;
    Ok(buf)
}

// ─── Mock backend (default build) ──────────────────────────────────────

#[cfg(not(feature = "tpm"))]
mod mock {
    use super::*;
    use aes_gcm::aead::{Aead, KeyInit};
    use aes_gcm::{Aes256Gcm, Key, Nonce};
    use hkdf::Hkdf;
    use rand::RngCore;
    use sha2::Sha256;
    use std::path::PathBuf;

    /// HKDF salt — namespaces the derived key to this crate + format version.
    const HKDF_SALT: &[u8] = b"fido2-vault-broker-mock-v1";
    /// HKDF info — domain-separates the seal key.
    const HKDF_INFO: &[u8] = b"seal-key";
    /// AES-256-GCM nonce length.
    const NONCE_LEN: usize = 12;
    /// AES-256 key length.
    const KEY_LEN: usize = 32;

    fn machine_id_path() -> PathBuf {
        PathBuf::from("/etc/machine-id")
    }

    /// Derive the AES-256 key from `/etc/machine-id` (or `path` for tests).
    pub(super) fn derive_key(path: &Path) -> Zeroizing<[u8; KEY_LEN]> {
        let ikm = match std::fs::read(path) {
            Ok(b) => Zeroizing::new(b),
            Err(_) => {
                // PoC fallback for non-Linux test envs only.
                tracing::warn!(
                    "mock seal: {} unreadable; using ZERO key (PoC fallback, NOT secure)",
                    path.display()
                );
                Zeroizing::new(vec![0u8; 32])
            }
        };
        let hk = Hkdf::<Sha256>::new(Some(HKDF_SALT), &ikm);
        let mut out = Zeroizing::new([0u8; KEY_LEN]);
        hk.expand(HKDF_INFO, out.as_mut())
            .expect("HKDF expand of 32 bytes never fails");
        out
    }

    pub(super) fn seal(plain: &[u8]) -> Result<(u32, Vec<u8>, Vec<u8>)> {
        seal_with_key(plain, &derive_key(&machine_id_path()))
    }

    pub(super) fn unseal(
        _pcr_bitmask: u32,
        public_blob: &[u8],
        private_blob: &[u8],
    ) -> Result<Zeroizing<Vec<u8>>> {
        unseal_with_key(public_blob, private_blob, &derive_key(&machine_id_path()))
    }

    pub(super) fn seal_with_key(
        plain: &[u8],
        key: &Zeroizing<[u8; KEY_LEN]>,
    ) -> Result<(u32, Vec<u8>, Vec<u8>)> {
        let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key.as_ref()));
        let mut nonce_bytes = [0u8; NONCE_LEN];
        rand::thread_rng().fill_bytes(&mut nonce_bytes);
        let nonce = Nonce::from_slice(&nonce_bytes);
        let ciphertext = cipher
            .encrypt(nonce, plain)
            .map_err(|e| BrokerError::Other(format!("AES-GCM seal failed: {e}")))?;
        // public_blob = nonce, private_blob = ciphertext+tag, pcr_bitmask = 0 (mock)
        Ok((0u32, nonce_bytes.to_vec(), ciphertext))
    }

    pub(super) fn unseal_with_key(
        public_blob: &[u8],
        private_blob: &[u8],
        key: &Zeroizing<[u8; KEY_LEN]>,
    ) -> Result<Zeroizing<Vec<u8>>> {
        if public_blob.len() != NONCE_LEN {
            return Err(BrokerError::SealFormat(format!(
                "mock backend expected {NONCE_LEN}-byte nonce in public_blob, got {}",
                public_blob.len()
            )));
        }
        let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key.as_ref()));
        let nonce = Nonce::from_slice(public_blob);
        let plain = cipher
            .decrypt(nonce, private_blob)
            .map_err(|e| BrokerError::SealFormat(format!("AES-GCM unseal failed: {e}")))?;
        Ok(Zeroizing::new(plain))
    }
}

// ─── Test-only helper: deterministic, parallel-safe roundtrips ─────────

#[cfg(all(test, not(feature = "tpm")))]
pub(crate) fn seal_to_path_with_machine_id_path(
    plain: &[u8],
    sealed_path: &Path,
    machine_id_path: &Path,
) -> Result<()> {
    let key = mock::derive_key(machine_id_path);
    let (pcr_bitmask, public_blob, private_blob) = mock::seal_with_key(plain, &key)?;
    write_framed(sealed_path, pcr_bitmask, &public_blob, &private_blob)
}

#[cfg(all(test, not(feature = "tpm")))]
pub(crate) fn unseal_from_path_with_machine_id_path(
    sealed_path: &Path,
    machine_id_path: &Path,
) -> Result<Zeroizing<Vec<u8>>> {
    let key = mock::derive_key(machine_id_path);
    let (_pcr, public_blob, private_blob) = read_framed(sealed_path)?;
    mock::unseal_with_key(&public_blob, &private_blob, &key)
}

// ─── Real TPM backend (feature-gated; hardware path not yet wired) ─────

#[cfg(feature = "tpm")]
mod tpm {
    use super::*;

    pub(super) fn seal(_plain: &[u8]) -> Result<(u32, Vec<u8>, Vec<u8>)> {
        // PCR-bound (0+7+8) Create -> Load -> Unseal flow lives here.
        // Phase B.2-hw on a host with a real TPM2 chip.
        // See ~/.claude/plans/da_browser-fido2-rbw-stack.md.
        todo!("tss-esapi seal: bind to PCRs 0,7,8 and emit framed blob")
    }

    pub(super) fn unseal(
        _pcr_bitmask: u32,
        _public_blob: &[u8],
        _private_blob: &[u8],
    ) -> Result<Zeroizing<Vec<u8>>> {
        todo!("tss-esapi unseal: load + Unseal against current PCR state")
    }
}

// ─── Tests ─────────────────────────────────────────────────────────────

#[cfg(all(test, not(feature = "tpm")))]
mod tests {
    use super::*;
    use std::io::{Seek, SeekFrom};

    /// Materialise a unique fake `machine-id` per test so parallel runs
    /// don't race on `/etc/machine-id` and roundtrips stay deterministic.
    fn fake_machine_id() -> tempfile::NamedTempFile {
        let mut f = tempfile::NamedTempFile::new().expect("temp machine-id");
        // Real machine-ids are 32 hex chars + newline; any stable bytes work.
        f.write_all(b"0123456789abcdef0123456789abcdef\n")
            .expect("write fake machine-id");
        f.flush().expect("flush fake machine-id");
        f
    }

    #[test]
    fn seal_unseal_roundtrip() {
        let plain = b"hello-fido2-vault-broker-roundtrip-test-2026";
        let mid = fake_machine_id();
        let sealed = tempfile::NamedTempFile::new().unwrap();
        seal_to_path_with_machine_id_path(plain, sealed.path(), mid.path()).unwrap();
        let got = unseal_from_path_with_machine_id_path(sealed.path(), mid.path()).unwrap();
        assert_eq!(plain, got.as_slice());
    }

    #[test]
    fn unseal_rejects_corrupt_blob() {
        let mid = fake_machine_id();
        let sealed = tempfile::NamedTempFile::new().unwrap();
        seal_to_path_with_machine_id_path(b"data", sealed.path(), mid.path()).unwrap();

        // Flip a byte well inside the private_blob (ciphertext+tag).
        // Header is 16 bytes (version+pcr+pub_len+priv_len) + 12-byte nonce
        // = 28 bytes. Anything past that is ciphertext/tag.
        let raw = std::fs::read(sealed.path()).unwrap();
        assert!(
            raw.len() > 30,
            "sealed file unexpectedly small: {}",
            raw.len()
        );
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .open(sealed.path())
            .unwrap();
        let target = raw.len() - 1; // flip the last byte (inside the GCM tag)
        f.seek(SeekFrom::Start(target as u64)).unwrap();
        f.write_all(&[raw[target] ^ 0xFF]).unwrap();
        f.sync_all().unwrap();
        drop(f);

        let res = unseal_from_path_with_machine_id_path(sealed.path(), mid.path());
        assert!(res.is_err(), "corrupt blob must not unseal");
    }

    #[test]
    fn unseal_rejects_truncated() {
        let sealed = tempfile::NamedTempFile::new().unwrap();
        // Only the version field, nothing else.
        std::fs::write(sealed.path(), FORMAT_VERSION.to_le_bytes()).unwrap();
        let mid = fake_machine_id();
        let err = unseal_from_path_with_machine_id_path(sealed.path(), mid.path())
            .expect_err("truncated file must error");
        assert!(
            matches!(err, BrokerError::SealFormat(_)),
            "expected SealFormat, got {err:?}"
        );
    }
}
