//! fido2-vault-broker entrypoint.
//! Phase B.1 + B.2 only: subcommands run/seal/unseal/version.
//! `run` is what systemd will invoke once Phase B.3+ ships; today it just
//! logs and exits 0.

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

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    init_tracing();
    let cli = Cli::parse();
    match cli.command {
        Cmd::Run => {
            tracing::info!(
                "fido2-vault-broker: Phase B.1 ready; CTAP2 + uhid + BW API not yet implemented"
            );
            Ok(())
        }
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
