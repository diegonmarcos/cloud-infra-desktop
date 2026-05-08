//! fido2-vault-broker entrypoint.
//!
//! Subcommands:
//!   * `run`     — start the daemon: BW login + sync, register a virtual
//!                 FIDO2 device on /dev/uhid, dispatch CTAP2 commands.
//!   * `seal`    — wrap input bytes via TPM2 (or mock), write framed blob.
//!   * `unseal`  — unwrap framed blob to stdout.
//!   * `version` — print crate version.
//!
//! ## Daemon (`run`) requirements
//!
//! 1. `~/.config/fido2-vault-broker/config.toml` declares `vault.endpoint`
//!    and `vault.email` (no defaults committed — operator must set).
//! 2. Master vault password is read from `FVB_MASTER_PASSWORD` env var.
//!    PoC only — Phase B.7+ will swap this for a TPM2-sealed blob unsealed
//!    at daemon start, so the password never lives in process env.
//! 3. /dev/uhid must be present. systemd unit gates on it.
//!
//! ## Known caveats (today)
//!
//! * Newly-registered passkeys (via `authenticatorMakeCredential`) live in
//!   memory only — they are NOT synced back to Vaultwarden yet. Restarting
//!   the daemon loses them. Sign-only (already-registered) passkeys work.
//! * `--features fido2` is required to build the daemon path; without it,
//!   `run` exits 0 immediately with a "not built with fido2 feature" log.
//! * End-to-end browser test loop has not been validated in CI; manual
//!   verification on a real Surface + webauthn.io is the acceptance gate.

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use fido2_vault_broker::store::tpm_seal;
use std::io::Write;
use std::path::PathBuf;
use tracing_subscriber::{fmt, EnvFilter};

#[derive(Parser, Debug)]
#[command(
    name = "fido2-vault-broker",
    version,
    about = "Virtual FIDO2/CTAP2 authenticator backed by a Bitwarden-API vault (Phase B.1+B.2 PoC)."
)]
struct Cli {
    #[command(subcommand)]
    command: Cmd,
}

#[derive(Subcommand, Debug)]
enum Cmd {
    /// Run the daemon. Phase B.1 stub — logs readiness and exits 0.
    Run,
    /// Seal a file: read `--in`, write framed sealed blob to `--out`.
    Seal {
        #[arg(long = "in")]
        input: PathBuf,
        #[arg(long = "out")]
        output: PathBuf,
    },
    /// Unseal a framed blob from `--in` and write the plaintext to stdout.
    Unseal {
        #[arg(long = "in")]
        input: PathBuf,
    },
    /// Print the crate version and exit.
    Version,
}

fn init_tracing() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    fmt().with_env_filter(filter).with_target(false).init();
}

/// Convert a B.3 `PasskeyCipher` (the on-vault representation) into the
/// B.4 `PasskeyCredential` (the in-memory CTAP2 representation). Discards
/// fields the CTAP2 layer doesn't consume (rp_name, key_algorithm,
/// key_curve, discoverable). The PKCS#8 buffer is moved out of the
/// `Zeroizing` wrapper — the new owner (`PasskeyCredential`) zeroes on Drop.
#[cfg(feature = "fido2")]
fn cipher_to_credential(
    p: fido2_vault_broker::store::bw_api::PasskeyCipher,
) -> fido2_vault_broker::ctap2::PasskeyCredential {
    fido2_vault_broker::ctap2::PasskeyCredential {
        credential_id: p.credential_id,
        rp_id: p.rp_id,
        user_handle: p.user_handle,
        user_name: p.user_name.unwrap_or_default(),
        user_display_name: p.user_display_name.unwrap_or_default(),
        key_pkcs8: (*p.private_key_pkcs8).clone(),
        counter: p.counter,
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    init_tracing();
    let cli = Cli::parse();
    match cli.command {
        Cmd::Run => run_daemon().await,
        Cmd::Seal { input, output } => {
            let plain =
                std::fs::read(&input).with_context(|| format!("read input {}", input.display()))?;
            tpm_seal::seal_to_path(&plain, &output)
                .with_context(|| format!("seal -> {}", output.display()))?;
            tracing::info!(?output, bytes = plain.len(), "sealed");
            Ok(())
        }
        Cmd::Unseal { input } => {
            let plain = tpm_seal::unseal_from_path(&input)
                .with_context(|| format!("unseal {}", input.display()))?;
            std::io::stdout()
                .write_all(plain.as_slice())
                .context("write plaintext to stdout")?;
            Ok(())
        }
        Cmd::Version => {
            println!("{}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Daemon path (Phase B.7 — wire up B.3 + B.4 + B.5/B.6 + TPM2/mock from B.1).
//
// Default builds (no `fido2` feature) ship a stub that logs and exits 0
// so `cargo build` works on systems without libudev/libclang. The real
// path is gated behind `--features fido2`.
// ─────────────────────────────────────────────────────────────────────

#[cfg(not(feature = "fido2"))]
async fn run_daemon() -> Result<()> {
    tracing::info!(
        "fido2-vault-broker daemon path requires `--features fido2`; \
         today's build only exposes seal/unseal/version. \
         Rebuild with: cargo build --release --features fido2"
    );
    Ok(())
}

#[cfg(feature = "fido2")]
async fn run_daemon() -> Result<()> {
    use fido2_vault_broker::config::Config;
    use fido2_vault_broker::ctap2::{derive_aaguid, Authenticator, InMemoryKeyStore, KeyStore};
    use fido2_vault_broker::store::bw_api::BwClient;
    use fido2_vault_broker::uhid_dev::UhidServer;
    use fido2_vault_broker::up_prompt::DesktopUpProvider;
    use secrecy::SecretString;
    use std::sync::Arc;
    use std::time::Duration;
    use tokio::sync::Mutex;

    // ── 1. Load operator-side config (vault endpoint + account identifier) ──
    let cfg = Config::load().context("load config (~/.config/fido2-vault-broker/config.toml)")?;
    if cfg.vault_endpoint.trim().is_empty() {
        anyhow::bail!(
            "vault.endpoint is empty — set it in ~/.config/fido2-vault-broker/config.toml"
        );
    }
    if cfg.vault_email.trim().is_empty() {
        anyhow::bail!(
            "vault.email is empty — set it in ~/.config/fido2-vault-broker/config.toml"
        );
    }
    tracing::info!(endpoint = %cfg.vault_endpoint, "config loaded");

    // ── 2. Master password from env (PoC; Phase B.7+ replaces with TPM-unseal) ──
    let master = std::env::var("FVB_MASTER_PASSWORD")
        .context("FVB_MASTER_PASSWORD env var not set — required for daemon login (PoC path)")?;
    if master.is_empty() {
        anyhow::bail!("FVB_MASTER_PASSWORD is empty");
    }

    // ── 3. Login + sync vault ──
    let mut bw = BwClient::new(&cfg.vault_endpoint, &cfg.vault_email);
    bw.login(SecretString::new(master))
        .await
        .context("vault login")?;
    let ciphers = bw.sync().await.context("vault sync")?;
    tracing::info!(count = ciphers.len(), "synced passkey ciphers");

    // ── 4. Build in-memory keystore from synced ciphers ──
    let mut keystore = InMemoryKeyStore::new();
    for c in ciphers {
        let cred = cipher_to_credential(c);
        if let Err(e) = keystore.store_new_credential(cred) {
            tracing::warn!(error = ?e, "failed to load credential into keystore — skipping");
        }
    }

    // ── 5. AAGUID = SHA-256(machine_id || vault_email) → 16 bytes (UUID-v4 shape) ──
    let machine_id = std::fs::read_to_string("/etc/machine-id")
        .context("read /etc/machine-id (required for stable AAGUID)")?;
    let aaguid = derive_aaguid(machine_id.trim().as_bytes(), &cfg.vault_email);

    // ── 6. Wire authenticator + UP prompt ──
    let up = Box::new(DesktopUpProvider::new(Duration::from_secs(30)));
    let auth = Arc::new(Mutex::new(Authenticator::new(aaguid, Box::new(keystore), up)));

    // ── 7. Run uhid HID server with a callback that delegates CTAP2
    //       commands to the authenticator. The callback is sync; we bridge
    //       to async via Handle::block_on under block_in_place (multi-thread
    //       runtime — see #[tokio::main] above). ──
    let auth_for_cb = auth.clone();
    let on_cbor = move |cmd: u8, payload: &[u8]| -> Vec<u8> {
        let auth = auth_for_cb.clone();
        let payload = payload.to_vec();
        tokio::task::block_in_place(|| {
            tokio::runtime::Handle::current().block_on(async move {
                let mut a = auth.lock().await;
                a.handle_command(cmd, &payload).await
            })
        })
    };

    let mut uhid = UhidServer::new(aaguid);
    tracing::info!("starting /dev/uhid server — register with browser via webauthn.io to test");
    uhid.run(on_cbor).await.context("uhid server")?;

    Ok(())
}
