# Android signing — ONE shared constellation key

**Every** Android app in the constellation signs with **one and only one** key.
No exceptions, no per-app keys, no random fallback — ever.

## The one key

| | |
|---|---|
| **Keystore** | `vault/A0_keys/providers/android/release.jks` (PKCS12) |
| **Passwords** | `vault/A0_keys/providers/android/signing.secrets.yaml` (sops/age) — keys: `keystore_password`, `key_password`, `key_alias` |
| **Subject** | `OU=Cloud Constellation, CN=Diego Marcos` |
| **SHA-256** | `C0:F9:4B:17:97:51:AB:6D:09:D5:FE:24:CD:6A:86:56:21:91:F0:0D:31:A0:07:56:AB:FA:8A:06:F9:83:49:9A` |

The raw keystore + passwords live **only in the private `vault` repo**. Public
repos reference the vault *paths* (in each app's `build.json::signing`), never the
material.

## Why one key (do not "fix" this to per-app keys)

The constellation apps talk over a `protectionLevel=signature` IPC permission, and
the in-app fleet updater installs updates across apps. Android refuses to update an
installed app — or grant signature-IPC — across **different** signing keys. So all
of these MUST share the single key above:

- `ea_cloud-comms` — hub **and** its forks (mail/FairEmail, dialer/Fossify, …)
- `ea_cloud-nav`
- `ea_cloud-ide` — hub **and** its forks
- `ea_cloud-superapp`

## How it's wired (declarative)

- `build.json::signing.vault_keystore` / `.vault_secrets` → the vault paths above (identical in all 4 apps).
- `build.sh::_resolve_signing` → resolves the key and exports `ANDROID_KEYSTORE_FILE/PASSWORD` + `ANDROID_KEY_ALIAS/PASSWORD`. It accepts a CI-pre-set keystore env **or** a vault checkout (`VAULT_DIR` + sops). If the key cannot be resolved it **fails loud (`exit 1`)** — it never generates or substitutes another key.
- gradle `signingConfig` reads only those env vars and **throws** if `ANDROID_KEYSTORE_FILE` is absent (no debug-sign, no legacy keystore).
- forks: comms writes `keystore.properties` from the resolved key; ide imports the shared keypair into the fork keystore (same signature). No `keytool -genkeypair`, anywhere.

## CI (builds are GHA-only)

Each `ship-cloud-*.yml` checks out the private vault and decrypts the key:

- secret **`ANDROID_SIGNING_VAULT_TOKEN`** — fine-grained PAT, read access to `diegonmarcos/vault`.
- secret **`SOPS_AGE_KEY`** — age key to decrypt `signing.secrets.yaml`.

No keystore is cached or generated in CI. Missing either secret → the build fails
(by design) rather than signing with a wrong key.

## Re-keying cost

Whenever the canonical key changes, **every** installed app must be uninstalled +
reinstalled once (Android can't cross-key update). After that, all apps share the
one key and update cleanly. This is the *only* situation that requires a device
reinstall — keep the key stable to avoid it.
