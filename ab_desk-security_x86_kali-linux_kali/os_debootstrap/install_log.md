# Kali Surface — Manual Install Log

## 2026-05-15

### apt repos added
- `github-cli` — https://cli.github.com/packages (keyring: githubcli-archive-keyring.gpg)
- `brave-browser` — https://brave-browser-apt-release.s3.brave.com/ (keyring: brave-browser-archive-keyring.gpg)

### packages installed
- `gh` 2.92.0 — GitHub CLI, authenticated via device flow as diegonmarcos
- `brave-browser` 148.1.90.122 — Chromium-based browser; replaces Firefox for passkey/caBLE (cross-device BT auth)
- `gocryptfs` 2.6.1 — FUSE encrypted filesystem backend for Plasma Vault

### services enabled
- `bluetooth` — was disabled; enabled + started (hardware was unblocked). S21+ de DIEGO (64:03:7F:8D:46:87) already paired/bonded.

### nix
- Installed: Determinate Nix 3.20.0 (wraps Nix 2.34.6), multi-user daemon mode
- `nix-daemon.service` active + enabled
- Uninstall: `/nix/nix-installer uninstall`
