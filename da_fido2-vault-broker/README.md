# fido2-vault-broker

A Linux user-session daemon that mirrors a Bitwarden-API-compatible vault
(Vaultwarden, upstream Bitwarden) into a TPM2-sealed local cache and
exposes the cached passkeys as a virtual FIDO2/CTAP2 USB-HID device via
`/dev/uhid`. Per-machine, browser-agnostic; once running, **any** browser
on the host can use the host's passkeys without a per-browser extension.

## Status

- **Phase B.1 + B.2 — complete in this repo.**
  - Workspace compiles, clippy is clean, `cargo test` passes.
  - TPM seal/unseal proof-of-concept works on **any** Linux box thanks
    to the default mock backend (AES-256-GCM with a key derived from
    `/etc/machine-id` via HKDF-SHA256).
  - Public seal/unseal API and on-disk format are nailed down — the real
    `tss-esapi` backend (PCR-bound to 0+7+8) plugs into the same shape.
- **Phases B.3 - B.7 — stubbed.** CTAP2 dispatch, `/dev/uhid` virtual
  device, and Bitwarden REST client all return `Ctap2NotImplemented` /
  `UhidNotImplemented` / `Vault("not yet implemented")` for now.

Multi-week phase plan: `~/.claude/plans/da_browser-fido2-rbw-stack.md`.

## Build

Everything goes through `build.sh`, which is driven by `build.json` —
no path or name is hardcoded in the script.

```sh
./build.sh build      # cargo build --release in nix dev shell -> dist/
./build.sh test       # cargo test
./build.sh check      # fmt --check + clippy -D warnings + cargo check
./build.sh fmt        # cargo fmt
./build.sh clean      # rm dist/ + target/
./build.sh nix        # nix build (reproducible flake-based build)
./build.sh install    # install binary + user systemd unit
./build.sh enable     # systemctl --user enable --now
```

## Demo (works on any Linux box, no TPM required)

```sh
echo "secret-$(date +%s)" > /tmp/p
./dist/fido2-vault-broker seal --in /tmp/p --out /tmp/s
./dist/fido2-vault-broker unseal --in /tmp/s | diff - /tmp/p   # must be empty
./dist/fido2-vault-broker version
```

## TPM-real demo (host with TPM2 chip)

```sh
cargo build --release --features tpm
```

This is **expected to fail at runtime** (and the seal/unseal calls are
literally `todo!()`) until the `tss-esapi` PCR-bound Create/Load/Unseal
flow lands in Phase B.2-hw. The feature gate exists today so that the
hardware path can be filled in without disturbing the mock build.

## Architecture

```
 ┌────────────────────────┐
 │  Vaultwarden / Bitwarden│      (HTTPS, master-key login,
 │       (upstream API)    │       /api/sync, passkey ciphers)
 └───────────┬────────────┘
             │  Phase B.5 — bw_api.rs
             ▼
 ┌────────────────────────┐
 │  fido2-vault-broker     │
 │  (user systemd service) │
 │                         │
 │  ┌───────────────────┐  │      Phase B.2 — tpm_seal.rs
 │  │ TPM-sealed cache  │◀─┼──── seal (PCR 0,7,8) at rest;
 │  │  ~/.local/share/  │  │      unsealed into RAM at start.
 │  │  …/sealed.bin     │  │
 │  └───────────────────┘  │
 │           │             │
 │           ▼             │      Phase B.3 — ctap2.rs
 │   CTAP2 dispatcher      │      authenticatorMakeCredential,
 │   (CBOR over HID frames)│      authenticatorGetAssertion, …
 │           │             │
 └───────────┼─────────────┘
             │  Phase B.4 — uhid_dev.rs
             ▼
 ┌────────────────────────┐
 │      /dev/uhid          │      virtual USB-HID FIDO device
 │    (group: uhid)        │      vendor 0xF1D0, usage 0xF1D0
 └───────────┬────────────┘
             ▼
 ┌────────────────────────┐
 │  any browser on the host │     Chromium/Firefox/Brave see a real
 │  (no extension needed)   │     FIDO2 authenticator on the bus.
 └────────────────────────┘
```

## Configure

The operator sets the vault endpoint and account identifier in a
**user-local** TOML file. **No defaults are committed in this repo** —
`build.json`'s `vault.default_endpoint` is intentionally empty.

```toml
# ~/.config/fido2-vault-broker/config.toml
vault_endpoint = "https://vault.example.invalid"
vault_email    = "you@example.invalid"
# sealed_path  = "~/.local/share/fido2-vault-broker/sealed.bin"  # default
# uhid_path    = "/dev/uhid"                                     # default
```

## Repository layout

```
da_fido2-vault-broker/
├── build.json           # source of truth — names, paths, deps
├── build.sh             # node-driven engine
├── README.md
└── src/
    ├── Cargo.toml
    ├── Cargo.lock
    ├── flake.nix        # nixpkgs-unstable dev shell + buildRustPackage
    ├── systemd/
    │   └── fido2-vault-broker.service
    └── src/
        ├── main.rs      # clap CLI: run | seal | unseal | version
        ├── lib.rs
        ├── error.rs     # BrokerError enum
        ├── config.rs    # XDG TOML loader (no defaults committed)
        ├── ctap2.rs     # Phase B.3 stub
        ├── uhid_dev.rs  # Phase B.4 stub
        └── store/
            ├── mod.rs
            ├── tpm_seal.rs   # Phase B.2 — mock + tpm-feature backend
            └── bw_api.rs     # Phase B.5 stub
```

## On-disk sealed-blob format (v1, little-endian)

```
u32 version           = 1
u32 pcr_bitmask       (mock: 0; real: bit i set => PCR i is bound)
u32 public_blob_len ; [public_blob bytes]
u32 private_blob_len; [private_blob bytes]
```

The mock backend stores the AES-GCM nonce in `public_blob` and the
ciphertext+tag in `private_blob`. The real TPM2 backend stores the
TPM2B_PUBLIC and TPM2B_PRIVATE wire blobs respectively. Both backends
share `seal_to_path` / `unseal_from_path`.

## License

MIT.
