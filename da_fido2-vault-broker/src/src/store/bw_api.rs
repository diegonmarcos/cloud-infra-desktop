//! Bitwarden / Vaultwarden REST client — Phase B.5.
//!
//! Implements the subset of the Bitwarden Mobile/CLI auth + sync protocol
//! needed to mirror passkey ciphers into the broker.
//!
//! Flow:
//!   1. `POST /identity/accounts/prelogin` -> KDF parameters.
//!   2. Derive `master_key` (PBKDF2-SHA256 or Argon2id).
//!   3. Derive `master_password_hash` = PBKDF2(master_key, master_password, 1).
//!   4. `POST /identity/connect/token` (password grant) -> bearer token + Key.
//!   5. HKDF-Expand `master_key` -> 64-byte stretched key (enc||mac).
//!   6. Decrypt `Key` (CipherString type 2 / AES-256-CBC + HMAC-SHA256) -> 64-byte user_key.
//!   7. `GET /api/sync` -> walk ciphers, filter logins with `fido2Credentials`.
//!   8. For each cipher: optionally decrypt the per-cipher `key` field
//!      (CipherString type 4 — AES-256-CBC + HMAC, key wrapped with user_key)
//!      then decrypt every passkey field with the resulting per-cipher (or
//!      user) key.
//!
//! NOTE on the per-cipher key step:
//!   In recent Bitwarden data models, ciphers can carry an optional `key`
//!   field which is itself an EncString containing a fresh 64-byte
//!   AES+HMAC key wrapped under the user_key. When present, ALL of that
//!   cipher's other EncStrings (`name`, `notes`, `login.uri`, fido2
//!   credential fields, ...) are encrypted under the unwrapped per-cipher
//!   key, NOT the user_key. When absent, the user_key is used directly.
//!   Bitwarden's official docs are sparse on this — the implementation
//!   here mirrors what `rbw` and the Bitwarden mobile clients do.
//!
//! Master-password sourcing:
//!   - This module only takes `SecretString` from the caller.
//!   - For PoC, `main` reads `FVB_MASTER_PASSWORD` env var.
//!   - Phase B.6 will source it from the TPM-unsealed blob.

#![allow(clippy::too_many_lines)]

use crate::error::{BrokerError, Result};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine as _;
use secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use zeroize::{Zeroize, Zeroizing};

// ─── Constants ─────────────────────────────────────────────────────────

/// HTTP request timeout (seconds).
const HTTP_TIMEOUT_SECS: u64 = 30;

/// Bitwarden CLI client identifier (used in `connect/token`).
const CLIENT_ID: &str = "connector";

/// Device type 14 = "SDK" (closest to a CLI broker).
const DEVICE_TYPE: u8 = 14;

/// HKDF info strings used by Bitwarden to stretch the master key.
const HKDF_INFO_ENC: &[u8] = b"enc";
const HKDF_INFO_MAC: &[u8] = b"mac";

/// AES-256 CBC IV length (bytes).
const AES_IV_LEN: usize = 16;
/// HMAC-SHA256 tag length (bytes).
const HMAC_LEN: usize = 32;
/// Stretched key length: 32 enc + 32 mac.
const STRETCHED_KEY_LEN: usize = 64;
/// Master key length (output of KDF).
const MASTER_KEY_LEN: usize = 32;

// ─── Public types ──────────────────────────────────────────────────────

/// One decrypted passkey credential, ready for the CTAP2 layer to surface.
#[derive(Debug, Clone)]
pub struct PasskeyCipher {
    /// Raw credential ID bytes (typically 16-byte UUID, sometimes longer).
    pub credential_id: Vec<u8>,
    pub rp_id: String,
    pub rp_name: Option<String>,
    pub user_handle: Vec<u8>,
    pub user_name: Option<String>,
    pub user_display_name: Option<String>,
    /// Algorithm string, e.g. `"ECDSA"`.
    pub key_algorithm: String,
    /// Curve string, e.g. `"P-256"`.
    pub key_curve: String,
    /// PKCS#8 DER-encoded private key, zeroized on drop.
    pub private_key_pkcs8: Zeroizing<Vec<u8>>,
    pub counter: u32,
    pub discoverable: bool,
}

/// Bitwarden-API client.
pub struct BwClient {
    endpoint: String,
    email: String,
    http: reqwest::Client,

    // Populated by `login()`.
    access_token: Option<SecretString>,
    refresh_token: Option<SecretString>,
    /// 64-byte user key (32 enc + 32 mac), unwrapped from the response `Key`.
    user_key: Option<SecretBytes>,
}

impl BwClient {
    /// Build a client. Does not perform any network I/O.
    pub fn new(endpoint: &str, email: &str) -> Self {
        let http = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(HTTP_TIMEOUT_SECS))
            .build()
            .expect("reqwest client builder cannot fail with these options");
        Self {
            endpoint: endpoint.trim_end_matches('/').to_string(),
            email: email.to_lowercase(),
            http,
            access_token: None,
            refresh_token: None,
            user_key: None,
        }
    }

    /// Authenticate against the vault and unwrap the user key.
    pub async fn login(&mut self, master_password: SecretString) -> Result<()> {
        let prelogin = self.prelogin().await?;
        let master_key = derive_master_key(
            master_password.expose_secret().as_bytes(),
            self.email.as_bytes(),
            &prelogin,
        )?;
        let master_pw_hash = master_password_hash(
            master_key.as_ref(),
            master_password.expose_secret().as_bytes(),
        )?;

        let token = self.connect_token(&master_pw_hash).await?;

        // Stretch master_key -> 64 bytes (enc+mac), then decrypt the response Key.
        let stretched = hkdf_stretch(master_key.as_ref())?;
        let user_key = decrypt_enc_string(&token.key, &stretched)?;
        if user_key.len() != STRETCHED_KEY_LEN {
            return Err(BrokerError::VaultCrypto(format!(
                "decrypted user_key has unexpected length {} (want {STRETCHED_KEY_LEN})",
                user_key.len()
            )));
        }

        self.access_token = Some(SecretString::new(token.access_token));
        self.refresh_token = Some(SecretString::new(token.refresh_token));
        self.user_key = Some(SecretBytes::new(user_key));
        Ok(())
    }

    /// Refresh the bearer token using the stored refresh token.
    pub async fn refresh_token(&mut self) -> Result<()> {
        let refresh = self
            .refresh_token
            .as_ref()
            .ok_or_else(|| BrokerError::VaultAuth("no refresh token available".into()))?
            .expose_secret()
            .to_string();

        let url = format!("{}/identity/connect/token", self.endpoint);
        let mut form: HashMap<&str, &str> = HashMap::new();
        form.insert("grant_type", "refresh_token");
        form.insert("refresh_token", &refresh);
        form.insert("client_id", CLIENT_ID);

        let resp = self
            .http
            .post(&url)
            .form(&form)
            .send()
            .await
            .map_err(|e| BrokerError::VaultHttp(format!("connect/token (refresh): {e}")))?;
        let status = resp.status();
        let body = resp
            .text()
            .await
            .map_err(|e| BrokerError::VaultHttp(format!("read refresh body: {e}")))?;
        if !status.is_success() {
            return Err(BrokerError::VaultAuth(format!(
                "connect/token refresh failed: HTTP {status}: {body}"
            )));
        }
        let parsed: RefreshResponse = serde_json::from_str(&body)
            .map_err(|e| BrokerError::VaultDecode(format!("refresh response: {e}: {body}")))?;
        self.access_token = Some(SecretString::new(parsed.access_token));
        if let Some(rt) = parsed.refresh_token {
            self.refresh_token = Some(SecretString::new(rt));
        }
        Ok(())
    }

    /// Fetch the vault and return all decrypted passkey ciphers.
    pub async fn sync(&mut self) -> Result<Vec<PasskeyCipher>> {
        let token = self
            .access_token
            .as_ref()
            .ok_or_else(|| BrokerError::VaultAuth("not logged in".into()))?
            .expose_secret()
            .to_string();
        let user_key = self
            .user_key
            .as_ref()
            .ok_or_else(|| BrokerError::VaultAuth("user key missing".into()))?
            .as_slice()
            .to_vec();

        let url = format!("{}/api/sync", self.endpoint);
        let resp = self
            .http
            .get(&url)
            .bearer_auth(&token)
            .send()
            .await
            .map_err(|e| BrokerError::VaultHttp(format!("GET /api/sync: {e}")))?;
        let status = resp.status();
        let body = resp
            .text()
            .await
            .map_err(|e| BrokerError::VaultHttp(format!("read sync body: {e}")))?;
        if !status.is_success() {
            return Err(BrokerError::Vault(format!(
                "sync failed: HTTP {status}: {body}"
            )));
        }
        let sync: SyncResponse = serde_json::from_str(&body)
            .map_err(|e| BrokerError::VaultDecode(format!("sync response: {e}")))?;

        let mut out = Vec::new();
        for cipher in sync.ciphers.unwrap_or_default() {
            if cipher.cipher_type != 1 {
                continue; // Only "login" ciphers can carry passkeys.
            }
            let login = match &cipher.login {
                Some(l) => l,
                None => continue,
            };
            let creds = match &login.fido2_credentials {
                Some(c) if !c.is_empty() => c,
                _ => continue,
            };

            // Per-cipher key: if cipher.key is present, unwrap it with user_key
            // and use it for the rest of this cipher's fields. Otherwise the
            // user_key is used directly.
            let cipher_key_bytes = if let Some(ks) = cipher.key.as_deref() {
                let unwrapped = decrypt_enc_string(ks, &user_key)
                    .map_err(|e| BrokerError::VaultCrypto(format!("unwrap cipher.key: {e}")))?;
                if unwrapped.len() != STRETCHED_KEY_LEN {
                    return Err(BrokerError::VaultCrypto(format!(
                        "per-cipher key has length {} (want {STRETCHED_KEY_LEN})",
                        unwrapped.len()
                    )));
                }
                Some(unwrapped)
            } else {
                None
            };
            let working_key: &[u8] = cipher_key_bytes.as_deref().unwrap_or(&user_key);

            for fc in creds {
                match build_passkey_cipher(fc, working_key) {
                    Ok(p) => out.push(p),
                    Err(e) => {
                        tracing::warn!(error = %e, "skipping passkey credential that failed to decrypt");
                    }
                }
            }
        }
        Ok(out)
    }

    /// Drop in-memory secrets. Subsequent `sync()` will fail until next `login()`.
    pub async fn lock(&mut self) {
        self.access_token = None;
        self.refresh_token = None;
        if let Some(uk) = self.user_key.take() {
            drop(uk); // SecretBytes zeroizes on drop.
        }
    }

    // ─── Private helpers ───────────────────────────────────────────────

    async fn prelogin(&self) -> Result<PreloginResponse> {
        let url = format!("{}/identity/accounts/prelogin", self.endpoint);
        let body = serde_json::json!({ "email": self.email });
        let resp = self
            .http
            .post(&url)
            .json(&body)
            .send()
            .await
            .map_err(|e| BrokerError::VaultHttp(format!("prelogin: {e}")))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| BrokerError::VaultHttp(format!("read prelogin body: {e}")))?;
        if !status.is_success() {
            return Err(BrokerError::VaultAuth(format!(
                "prelogin failed: HTTP {status}: {text}"
            )));
        }
        parse_prelogin(&text)
    }

    async fn connect_token(&self, master_pw_hash: &str) -> Result<TokenResponse> {
        let url = format!("{}/identity/connect/token", self.endpoint);
        let device_id = uuid::Uuid::new_v4().to_string();
        let device_type = DEVICE_TYPE.to_string();

        let mut form: HashMap<&str, &str> = HashMap::new();
        form.insert("grant_type", "password");
        form.insert("username", &self.email);
        form.insert("password", master_pw_hash);
        form.insert("scope", "api offline_access");
        form.insert("client_id", CLIENT_ID);
        form.insert("deviceType", &device_type);
        form.insert("deviceIdentifier", &device_id);
        form.insert("deviceName", "fido2-vault-broker");

        let resp = self
            .http
            .post(&url)
            .form(&form)
            .send()
            .await
            .map_err(|e| BrokerError::VaultHttp(format!("connect/token: {e}")))?;
        let status = resp.status();
        let body = resp
            .text()
            .await
            .map_err(|e| BrokerError::VaultHttp(format!("read token body: {e}")))?;
        if !status.is_success() {
            return Err(BrokerError::VaultAuth(format!(
                "connect/token failed: HTTP {status}: {body}"
            )));
        }
        let parsed: TokenResponse = serde_json::from_str(&body)
            .map_err(|e| BrokerError::VaultDecode(format!("token response: {e}")))?;
        Ok(parsed)
    }
}

// ─── Wire types ────────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize, Serialize)]
pub(crate) struct PreloginResponse {
    /// 0 = PBKDF2-SHA256, 1 = Argon2id.
    #[serde(rename = "kdf", alias = "Kdf")]
    pub kdf: u32,
    #[serde(rename = "kdfIterations", alias = "KdfIterations")]
    pub kdf_iterations: u32,
    #[serde(default, rename = "kdfMemory", alias = "KdfMemory")]
    pub kdf_memory: Option<u32>,
    #[serde(default, rename = "kdfParallelism", alias = "KdfParallelism")]
    pub kdf_parallelism: Option<u32>,
}

fn parse_prelogin(text: &str) -> Result<PreloginResponse> {
    serde_json::from_str(text)
        .map_err(|e| BrokerError::VaultDecode(format!("prelogin response: {e}: {text}")))
}

#[derive(Debug, Deserialize)]
struct TokenResponse {
    access_token: String,
    refresh_token: String,
    #[serde(rename = "Key", alias = "key")]
    key: String,
    #[allow(dead_code)]
    #[serde(default, rename = "PrivateKey", alias = "privateKey")]
    private_key: Option<String>,
    #[allow(dead_code)]
    #[serde(default)]
    expires_in: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct RefreshResponse {
    access_token: String,
    #[serde(default)]
    refresh_token: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SyncResponse {
    #[serde(rename = "ciphers", alias = "Ciphers", default)]
    ciphers: Option<Vec<Cipher>>,
}

#[derive(Debug, Deserialize)]
struct Cipher {
    #[serde(rename = "type", alias = "Type")]
    cipher_type: u32,
    #[serde(default, rename = "key", alias = "Key")]
    key: Option<String>,
    #[serde(default, rename = "login", alias = "Login")]
    login: Option<CipherLogin>,
}

#[derive(Debug, Deserialize)]
struct CipherLogin {
    #[serde(default, rename = "fido2Credentials", alias = "Fido2Credentials")]
    fido2_credentials: Option<Vec<Fido2Credential>>,
}

#[derive(Debug, Deserialize)]
struct Fido2Credential {
    #[serde(default, rename = "credentialId", alias = "CredentialId")]
    credential_id: Option<String>,
    #[serde(default, rename = "keyType", alias = "KeyType")]
    #[allow(dead_code)]
    key_type: Option<String>,
    #[serde(default, rename = "keyAlgorithm", alias = "KeyAlgorithm")]
    key_algorithm: Option<String>,
    #[serde(default, rename = "keyCurve", alias = "KeyCurve")]
    key_curve: Option<String>,
    #[serde(default, rename = "keyValue", alias = "KeyValue")]
    key_value: Option<String>,
    #[serde(default, rename = "rpId", alias = "RpId")]
    rp_id: Option<String>,
    #[serde(default, rename = "userHandle", alias = "UserHandle")]
    user_handle: Option<String>,
    #[serde(default, rename = "userName", alias = "UserName")]
    user_name: Option<String>,
    #[serde(default, rename = "counter", alias = "Counter")]
    counter: Option<String>,
    #[serde(default, rename = "rpName", alias = "RpName")]
    rp_name: Option<String>,
    #[serde(default, rename = "userDisplayName", alias = "UserDisplayName")]
    user_display_name: Option<String>,
    #[serde(default, rename = "discoverable", alias = "Discoverable")]
    discoverable: Option<String>,
}

// ─── Crypto primitives ─────────────────────────────────────────────────

/// PBKDF2-SHA256 of `master_key` over `password`, 1 iteration -> base64.
/// (Bitwarden's "master_password_hash" used as the password-grant password.)
fn master_password_hash(master_key: &[u8], password: &[u8]) -> Result<String> {
    let mut out = [0u8; 32];
    pbkdf2::pbkdf2_hmac::<sha2::Sha256>(master_key, password, 1, &mut out);
    Ok(B64.encode(out))
}

/// Derive the 32-byte master key from prelogin parameters.
pub(crate) fn derive_master_key(
    password: &[u8],
    email: &[u8],
    p: &PreloginResponse,
) -> Result<Zeroizing<[u8; MASTER_KEY_LEN]>> {
    let mut out = Zeroizing::new([0u8; MASTER_KEY_LEN]);
    match p.kdf {
        0 => {
            if p.kdf_iterations < 5_000 {
                return Err(BrokerError::VaultCrypto(format!(
                    "PBKDF2 iterations {} below floor 5000",
                    p.kdf_iterations
                )));
            }
            pbkdf2::pbkdf2_hmac::<sha2::Sha256>(password, email, p.kdf_iterations, out.as_mut());
        }
        1 => {
            // Argon2id parameters per Bitwarden:
            //   time_cost     = kdfIterations
            //   memory_cost   = kdfMemory * 1024  (KiB)
            //   parallelism   = kdfParallelism
            //   salt          = SHA-256(email)
            //   output length = 32
            let memory_mib = p
                .kdf_memory
                .ok_or_else(|| BrokerError::VaultCrypto("argon2: missing kdfMemory".into()))?;
            let parallelism = p
                .kdf_parallelism
                .ok_or_else(|| BrokerError::VaultCrypto("argon2: missing kdfParallelism".into()))?;

            // SHA-256(email) is the required salt for Argon2id in BW.
            use sha2::Digest;
            let salt = sha2::Sha256::digest(email);

            let params = argon2::Params::new(
                memory_mib.saturating_mul(1024),
                p.kdf_iterations,
                parallelism,
                Some(MASTER_KEY_LEN),
            )
            .map_err(|e| BrokerError::VaultCrypto(format!("argon2 params: {e}")))?;
            let argon =
                argon2::Argon2::new(argon2::Algorithm::Argon2id, argon2::Version::V0x13, params);
            argon
                .hash_password_into(password, salt.as_slice(), out.as_mut())
                .map_err(|e| BrokerError::VaultCrypto(format!("argon2 hash: {e}")))?;
        }
        other => {
            return Err(BrokerError::VaultCrypto(format!(
                "unsupported KDF type {other}"
            )));
        }
    }
    Ok(out)
}

/// HKDF-Expand the 32-byte master_key to 64 bytes (enc||mac).
fn hkdf_stretch(master_key: &[u8]) -> Result<Vec<u8>> {
    use hkdf::Hkdf;
    let prk = Hkdf::<sha2::Sha256>::from_prk(master_key)
        .map_err(|e| BrokerError::VaultCrypto(format!("hkdf from_prk: {e}")))?;
    let mut enc = [0u8; 32];
    let mut mac = [0u8; 32];
    prk.expand(HKDF_INFO_ENC, &mut enc)
        .map_err(|e| BrokerError::VaultCrypto(format!("hkdf expand enc: {e}")))?;
    prk.expand(HKDF_INFO_MAC, &mut mac)
        .map_err(|e| BrokerError::VaultCrypto(format!("hkdf expand mac: {e}")))?;
    let mut out = Vec::with_capacity(64);
    out.extend_from_slice(&enc);
    out.extend_from_slice(&mac);
    enc.zeroize();
    mac.zeroize();
    Ok(out)
}

/// Parsed Bitwarden CipherString (`"<type>.<iv_b64>|<ct_b64>|<mac_b64>"`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CipherString {
    pub enc_type: u8,
    pub iv: Vec<u8>,
    pub ct: Vec<u8>,
    pub mac: Vec<u8>,
}

pub(crate) fn parse_cipher_string(s: &str) -> Result<CipherString> {
    let (enc_type_str, rest) = s
        .split_once('.')
        .ok_or_else(|| BrokerError::VaultDecode("cipher string missing '.' separator".into()))?;
    let enc_type: u8 = enc_type_str
        .parse()
        .map_err(|_| BrokerError::VaultDecode(format!("bad enc type '{enc_type_str}'")))?;

    let parts: Vec<&str> = rest.split('|').collect();
    let (iv_b64, ct_b64, mac_b64) = match parts.as_slice() {
        [iv, ct, mac] => (*iv, *ct, *mac),
        _ => {
            return Err(BrokerError::VaultDecode(format!(
                "cipher string has {} parts, expected 3",
                parts.len()
            )));
        }
    };
    let iv = B64
        .decode(iv_b64)
        .map_err(|e| BrokerError::VaultDecode(format!("cipher iv b64: {e}")))?;
    let ct = B64
        .decode(ct_b64)
        .map_err(|e| BrokerError::VaultDecode(format!("cipher ct b64: {e}")))?;
    let mac = B64
        .decode(mac_b64)
        .map_err(|e| BrokerError::VaultDecode(format!("cipher mac b64: {e}")))?;
    Ok(CipherString {
        enc_type,
        iv,
        ct,
        mac,
    })
}

/// Decrypt a Bitwarden CipherString (`enc_type` 2 = AES-256-CBC + HMAC-SHA256)
/// with a 64-byte stretched key (32 enc + 32 mac).
pub(crate) fn decrypt_enc_string(s: &str, key64: &[u8]) -> Result<Vec<u8>> {
    if key64.len() != STRETCHED_KEY_LEN {
        return Err(BrokerError::VaultCrypto(format!(
            "stretched key length {} (want {STRETCHED_KEY_LEN})",
            key64.len()
        )));
    }
    let cs = parse_cipher_string(s)?;
    // Types 2 (user-key) and 4 (per-cipher rsa-wrapped) both use AES-CBC+HMAC
    // when the wrapping key is symmetric. We accept 2 for direct use here.
    if cs.enc_type != 2 {
        return Err(BrokerError::VaultCrypto(format!(
            "unsupported EncString type {} (only 2 = AesCbc256_HmacSha256_B64 supported)",
            cs.enc_type
        )));
    }
    if cs.iv.len() != AES_IV_LEN {
        return Err(BrokerError::VaultCrypto(format!(
            "iv length {} (want {AES_IV_LEN})",
            cs.iv.len()
        )));
    }
    if cs.mac.len() != HMAC_LEN {
        return Err(BrokerError::VaultCrypto(format!(
            "mac length {} (want {HMAC_LEN})",
            cs.mac.len()
        )));
    }
    let (enc_key, mac_key) = key64.split_at(32);

    // Verify HMAC over iv||ct first.
    use hmac::{Hmac, Mac};
    let mut hm = <Hmac<sha2::Sha256> as Mac>::new_from_slice(mac_key)
        .map_err(|e| BrokerError::VaultCrypto(format!("hmac init: {e}")))?;
    hm.update(&cs.iv);
    hm.update(&cs.ct);
    hm.verify_slice(&cs.mac)
        .map_err(|_| BrokerError::VaultCrypto("HMAC verification failed".into()))?;

    // Then AES-256-CBC decrypt.
    use cbc::cipher::block_padding::Pkcs7;
    use cbc::cipher::{BlockDecryptMut, KeyIvInit};
    type Aes256CbcDec = cbc::Decryptor<aes::Aes256>;
    let dec = Aes256CbcDec::new_from_slices(enc_key, &cs.iv)
        .map_err(|e| BrokerError::VaultCrypto(format!("aes init: {e}")))?;
    let plain = dec
        .decrypt_padded_vec_mut::<Pkcs7>(&cs.ct)
        .map_err(|e| BrokerError::VaultCrypto(format!("aes decrypt: {e}")))?;
    Ok(plain)
}

fn decrypt_to_string(s: &str, key64: &[u8]) -> Result<String> {
    let raw = decrypt_enc_string(s, key64)?;
    String::from_utf8(raw).map_err(|e| BrokerError::VaultDecode(format!("non-utf8 plaintext: {e}")))
}

fn decrypt_optional_string(opt: Option<&str>, key64: &[u8]) -> Result<Option<String>> {
    match opt {
        Some(s) if !s.is_empty() => Ok(Some(decrypt_to_string(s, key64)?)),
        _ => Ok(None),
    }
}

fn build_passkey_cipher(fc: &Fido2Credential, key64: &[u8]) -> Result<PasskeyCipher> {
    let credential_id_str = fc
        .credential_id
        .as_deref()
        .ok_or_else(|| BrokerError::VaultDecode("passkey: credentialId missing".into()))?;
    let credential_id_plain = decrypt_to_string(credential_id_str, key64)?;
    // Bitwarden serialises credentialId as a base64url string (no padding).
    let credential_id = decode_b64url_loose(&credential_id_plain)
        .or_else(|_| B64.decode(&credential_id_plain))
        .map_err(|e| BrokerError::VaultDecode(format!("credentialId b64: {e}")))?;

    let rp_id = fc
        .rp_id
        .as_deref()
        .ok_or_else(|| BrokerError::VaultDecode("passkey: rpId missing".into()))?;
    let rp_id = decrypt_to_string(rp_id, key64)?;

    let user_handle_str = fc
        .user_handle
        .as_deref()
        .ok_or_else(|| BrokerError::VaultDecode("passkey: userHandle missing".into()))?;
    let user_handle_plain = decrypt_to_string(user_handle_str, key64)?;
    let user_handle = decode_b64url_loose(&user_handle_plain)
        .or_else(|_| B64.decode(&user_handle_plain))
        .map_err(|e| BrokerError::VaultDecode(format!("userHandle b64: {e}")))?;

    let key_value_str = fc
        .key_value
        .as_deref()
        .ok_or_else(|| BrokerError::VaultDecode("passkey: keyValue missing".into()))?;
    let key_value_plain = decrypt_to_string(key_value_str, key64)?;
    // Bitwarden stores the PKCS#8 DER private key as base64.
    let pkcs8 = decode_b64url_loose(&key_value_plain)
        .or_else(|_| B64.decode(&key_value_plain))
        .map_err(|e| BrokerError::VaultDecode(format!("keyValue b64: {e}")))?;

    let key_algorithm = decrypt_optional_string(fc.key_algorithm.as_deref(), key64)?
        .unwrap_or_else(|| "ECDSA".to_string());
    let key_curve = decrypt_optional_string(fc.key_curve.as_deref(), key64)?
        .unwrap_or_else(|| "P-256".to_string());

    let counter = match decrypt_optional_string(fc.counter.as_deref(), key64)? {
        Some(s) => s.parse::<u32>().unwrap_or(0),
        None => 0,
    };
    let discoverable = match decrypt_optional_string(fc.discoverable.as_deref(), key64)? {
        Some(s) => matches!(s.as_str(), "true" | "True" | "1"),
        None => false,
    };

    let user_name = decrypt_optional_string(fc.user_name.as_deref(), key64)?;
    let user_display_name = decrypt_optional_string(fc.user_display_name.as_deref(), key64)?;
    let rp_name = decrypt_optional_string(fc.rp_name.as_deref(), key64)?;

    Ok(PasskeyCipher {
        credential_id,
        rp_id,
        rp_name,
        user_handle,
        user_name,
        user_display_name,
        key_algorithm,
        key_curve,
        private_key_pkcs8: Zeroizing::new(pkcs8),
        counter,
        discoverable,
    })
}

/// Decode either base64url (with optional `=` padding) — Bitwarden uses both
/// flavours in different fields and across versions.
fn decode_b64url_loose(s: &str) -> std::result::Result<Vec<u8>, base64::DecodeError> {
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    URL_SAFE_NO_PAD.decode(s.trim_end_matches('='))
}

// ─── In-memory secret container with mlock + zeroize ───────────────────

/// Owned byte buffer that mlocks itself on construction (best-effort),
/// zeroes on drop. Used for the unwrapped 64-byte user key.
struct SecretBytes {
    inner: Zeroizing<Vec<u8>>,
    locked: bool,
}

impl SecretBytes {
    fn new(bytes: Vec<u8>) -> Self {
        let inner = Zeroizing::new(bytes);
        let locked = unsafe {
            // SAFETY: ptr+len are valid for the lifetime of `inner` while we
            // hold it; mlock is documented safe to call on any mapped region.
            libc::mlock(inner.as_ptr().cast(), inner.len()) == 0
        };
        if !locked {
            tracing::debug!(
                "mlock failed (errno={}); secret will not be page-locked",
                std::io::Error::last_os_error()
            );
        }
        Self { inner, locked }
    }

    fn as_slice(&self) -> &[u8] {
        &self.inner
    }
}

impl Drop for SecretBytes {
    fn drop(&mut self) {
        if self.locked {
            unsafe {
                libc::munlock(self.inner.as_ptr().cast(), self.inner.len());
            }
        }
        // Zeroizing<Vec<u8>> handles the wipe.
    }
}

// ─── Tests ─────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prelogin_response_parses() {
        let json = r#"{"kdf":0,"kdfIterations":600000,"kdfMemory":null,"kdfParallelism":null}"#;
        let p = parse_prelogin(json).unwrap();
        assert_eq!(p.kdf, 0);
        assert_eq!(p.kdf_iterations, 600_000);
        assert!(p.kdf_memory.is_none());

        let json2 = r#"{"Kdf":1,"KdfIterations":3,"KdfMemory":64,"KdfParallelism":4}"#;
        let p2 = parse_prelogin(json2).unwrap();
        assert_eq!(p2.kdf, 1);
        assert_eq!(p2.kdf_iterations, 3);
        assert_eq!(p2.kdf_memory, Some(64));
        assert_eq!(p2.kdf_parallelism, Some(4));
    }

    #[test]
    fn pbkdf2_master_key_is_deterministic() {
        // Same email + password + KDF params -> same master key (asserts
        // PBKDF2 wiring is stable; no published BW vector required).
        let p = PreloginResponse {
            kdf: 0,
            kdf_iterations: 100_000,
            kdf_memory: None,
            kdf_parallelism: None,
        };
        let pw = b"correct horse battery staple";
        let email = b"user@example.com";
        let a = derive_master_key(pw, email, &p).unwrap();
        let b = derive_master_key(pw, email, &p).unwrap();
        assert_eq!(a.as_slice(), b.as_slice());
        assert_eq!(a.len(), 32);

        // Different password -> different key.
        let c = derive_master_key(b"different", email, &p).unwrap();
        assert_ne!(a.as_slice(), c.as_slice());

        // Master password hash also deterministic.
        let h1 = master_password_hash(a.as_ref(), pw).unwrap();
        let h2 = master_password_hash(a.as_ref(), pw).unwrap();
        assert_eq!(h1, h2);
    }

    #[test]
    fn pbkdf2_floor_rejects_low_iterations() {
        let p = PreloginResponse {
            kdf: 0,
            kdf_iterations: 1_000,
            kdf_memory: None,
            kdf_parallelism: None,
        };
        let err = derive_master_key(b"pw", b"e@x", &p).unwrap_err();
        assert!(
            matches!(err, BrokerError::VaultCrypto(_)),
            "expected VaultCrypto, got {err:?}"
        );
    }

    #[test]
    fn cipher_string_parses_three_fields() {
        let iv = [0xAAu8; 16];
        let ct = [0xBBu8; 32];
        let mac = [0xCCu8; 32];
        let s = format!(
            "2.{}|{}|{}",
            B64.encode(iv),
            B64.encode(ct),
            B64.encode(mac)
        );
        let cs = parse_cipher_string(&s).unwrap();
        assert_eq!(cs.enc_type, 2);
        assert_eq!(cs.iv, iv);
        assert_eq!(cs.ct, ct);
        assert_eq!(cs.mac, mac);
    }

    #[test]
    fn cipher_string_rejects_wrong_part_count() {
        let bad = "2.aGVsbG8=|d29ybGQ=";
        assert!(parse_cipher_string(bad).is_err());
    }

    /// Round-trip test: encrypt a known plaintext with a known 64-byte
    /// stretched key, format as a CipherString, decrypt, assert match.
    #[test]
    fn decrypt_known_test_vector() {
        use aes::cipher::{block_padding::Pkcs7, BlockEncryptMut, KeyIvInit};
        use hmac::{Hmac, Mac};
        type Aes256CbcEnc = cbc::Encryptor<aes::Aes256>;

        // Deterministic 64-byte key (32 enc + 32 mac).
        let mut key64 = [0u8; 64];
        for (i, b) in key64.iter_mut().enumerate() {
            *b = i as u8;
        }
        let (enc_key, mac_key) = key64.split_at(32);
        let iv = [7u8; 16];
        let plain = b"fido2-vault-broker-test-vector\x00\x00\x00";

        let ct = Aes256CbcEnc::new_from_slices(enc_key, &iv)
            .unwrap()
            .encrypt_padded_vec_mut::<Pkcs7>(plain);

        let mut hm = <Hmac<sha2::Sha256> as Mac>::new_from_slice(mac_key).unwrap();
        hm.update(&iv);
        hm.update(&ct);
        let mac = hm.finalize().into_bytes();

        let cs = format!(
            "2.{}|{}|{}",
            B64.encode(iv),
            B64.encode(&ct),
            B64.encode(mac)
        );
        let got = decrypt_enc_string(&cs, &key64).unwrap();
        assert_eq!(got.as_slice(), plain);
    }

    #[test]
    fn decrypt_rejects_bad_mac() {
        use aes::cipher::{block_padding::Pkcs7, BlockEncryptMut, KeyIvInit};
        type Aes256CbcEnc = cbc::Encryptor<aes::Aes256>;

        let key64 = [9u8; 64];
        let (enc_key, _) = key64.split_at(32);
        let iv = [3u8; 16];
        let ct = Aes256CbcEnc::new_from_slices(enc_key, &iv)
            .unwrap()
            .encrypt_padded_vec_mut::<Pkcs7>(b"hello");
        let bad_mac = [0u8; 32];
        let cs = format!(
            "2.{}|{}|{}",
            B64.encode(iv),
            B64.encode(&ct),
            B64.encode(bad_mac)
        );
        let err = decrypt_enc_string(&cs, &key64).unwrap_err();
        assert!(
            matches!(err, BrokerError::VaultCrypto(_)),
            "expected VaultCrypto, got {err:?}"
        );
    }

    #[test]
    fn decrypt_rejects_unsupported_type() {
        let cs = "1.AAAA|BBBB|CCCC";
        let key64 = [0u8; 64];
        let err = decrypt_enc_string(cs, &key64).unwrap_err();
        assert!(matches!(err, BrokerError::VaultCrypto(_)));
    }

    #[test]
    fn bw_client_new_normalises_email_and_endpoint() {
        let c = BwClient::new("https://vault.example.com/", "USER@Example.COM");
        assert_eq!(c.endpoint, "https://vault.example.com");
        assert_eq!(c.email, "user@example.com");
        assert!(c.access_token.is_none());
        assert!(c.user_key.is_none());
    }

    /// Manual integration test against a real Vaultwarden — opt-in only.
    /// Requires `FVB_VAULT_ENDPOINT`, `FVB_VAULT_EMAIL`, `FVB_MASTER_PASSWORD`.
    /// Run with: `cargo test --ignored login_real_server -- --nocapture`.
    #[tokio::test]
    #[ignore]
    async fn login_real_server() {
        let endpoint = std::env::var("FVB_VAULT_ENDPOINT")
            .expect("set FVB_VAULT_ENDPOINT for ignored real-server test");
        let email = std::env::var("FVB_VAULT_EMAIL")
            .expect("set FVB_VAULT_EMAIL for ignored real-server test");
        let pw = std::env::var("FVB_MASTER_PASSWORD")
            .expect("set FVB_MASTER_PASSWORD for ignored real-server test");
        let mut c = BwClient::new(&endpoint, &email);
        c.login(SecretString::new(pw)).await.unwrap();
        let creds = c.sync().await.unwrap();
        eprintln!("synced {} passkey credentials", creds.len());
        c.lock().await;
    }
}
