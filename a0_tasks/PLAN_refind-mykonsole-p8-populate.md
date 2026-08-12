# PLAN: rEFInd "my-konsole Rescue" not booting — p8 never populated

**Status**: root-caused 2026-07-24. Fix = run the already-declared populate
pipeline + add a generic dangling-stanza preflight to the bootloader engine.
**Severity**: P2 — rescue entry dead, main boot unaffected.
**Executor**: build agent (sonnet). Repos: `~/git/unix`, main branch, direct push.

## Root cause (verified)

rEFInd error "invalid loader file / bootx64.efi not found" is a dangling stanza:

- Stanza (source `aa_bootloader/src/boot.json`, deployed via
  `aa_bootloader/dist/boot/efi/EFI/refind/refind.conf` → ESP):
  `volume "5f765784-767d-42ab-85a1-40d4d44519e4"` + `loader /EFI/boot/bootx64.efi`.
- `5f765784-…` is the PARTUUID of `/dev/nvme0n1p8` — correct target.
- p8 verified (ro mount 2026-07-24): **empty except `lost+found`**. Label is
  still `mykonsole-resc` (the install pipeline relabels to `MY_KONSOLE` — proof
  the populate step never ran).
- `ext4_x64.efi` driver IS present in `/boot/efi/EFI/refind/drivers_x64/` —
  rEFInd finds the volume, then fails on the missing loader file. Config and
  drivers are fine; only the payload is missing.

Same failure class as the BlissOS dangling entry
(`project_blissos-boot-missing-install`).

## Fix design

### Part A — populate p8 via the declared pipeline (no new machinery)

`ca_ventoy_fallback_usb/my-konsole/install.json` already declares the whole
flow: CI workflow `ship-my-konsole-iso.yml` builds the rescue ISO artifact
(`my-konsole-iso`, repo diegonmarcos/unix); `build.sh install-partition` in
`ca_ventoy_fallback_usb/my-konsole/` rsyncs the live filesystem onto the
partition (stable UUID `27ffc22b-f89e-492d-aeda-2341e8eba898`), installs
`/EFI/boot/bootx64.efi`, and relabels to `MY_KONSOLE`.

Agent steps:
1. `gh run list -w ship-my-konsole-iso.yml` — confirm a green run on current
   main; trigger it if stale/red (fix CI first if red — no bypass).
2. Run the engine verb: `cd ~/git/unix/ca_ventoy_fallback_usb/my-konsole &&
   ./build.sh install-partition` (it consumes the CI artifact per install.json —
   read install.json first and follow exactly what it declares; do NOT hand-roll
   mount/rsync commands outside the engine).
3. Verify: p8 mounted ro contains `/EFI/boot/bootx64.efi`, kernel+squashfs per
   install.json manifest; `blkid /dev/nvme0n1p8` label = `MY_KONSOLE`.
   NOTE: if GRUB/rEFInd stanzas reference the label, confirm boot.json matches
   the post-install label before shipping.

### Part B — engine hardening: dangling-stanza preflight (root-cause class fix)

Add a data-driven preflight to the aa_bootloader engine (where `build.sh`
renders/deploys refind.conf from `src/boot.json`):

- For EVERY refind/grub entry in boot.json that declares `volume` + `loader`:
  resolve the volume (blkid by PARTUUID/UUID/LABEL), mount ro, assert the
  loader path exists; unmount.
- Run it in the deploy/burn verb; on failure, list every dangling entry and
  abort. No hardcoded entry list — iterate boot.json (FIRE rule 4).
- This preflight will immediately flag the BlissOS entry too — report it,
  don't silently drop it (separate decision:
  `project_blissos-boot-missing-install`).

## Tester (task not done without it)

- Part B IS the automated tester: `build.sh <deploy-verb>` fails on any stanza
  whose loader is missing; green run = no dangling entries.
- Acceptance for Part A: preflight green for the my-konsole entry, then a real
  reboot → rEFInd → "my-konsole Rescue" boots to the Alacritty TTY
  (manual, one-time; record result in this file).

## Security flag (report to Diego, do not fix here)

`ca_ventoy_fallback_usb/my-konsole/install.json` carries a plaintext rescue
password and enables sshd, in a public repo. Belongs to the P0 secrets
remediation effort (`project_secrets_remediation`) — the rescue credential
should come from the sops pipeline or be disabled for ssh.
