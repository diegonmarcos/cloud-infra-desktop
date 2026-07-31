# Active task list (2026-07-31) — survives context compaction

1. [DONE] Nix Switch Progress "Failed" notification missing an "Open Log" button.
   Fixed: ba_flakes_desktop/src/modules/programs/nix-switch-progress.nix —
   notify-send now uses `-A "open=Open Log"`, log copied to
   $STATE_DIR/last-failure.log (persists past script exit), action opens it
   in `konsole -e less -R`. Committed + pushed (56bf3433).

2. [DONE] mattermost compose.nix `ollama-hai` eval error (attribute missing).
   Root cause: ollama-hai decommissioned/archived
   (a_solutions/z_archive/user-ai_ollama-hai); live replacement key is
   ollama-arm. Fixed + committed in ~/git/cloud (f73d2fba5). NOTE: cloud
   repo has a large pre-existing unrelated dirty tree (mass dist
   regeneration, deleted ollama-arm/ollama/ollama-hai build.json sources
   under 2_configs/src/builds/) — NOT touched, NOT mine, flagged only.

3. [DONE - explained] Why switch didn't trigger terminal-log+dashboard again.
   Root cause found: configuration_nix-command-catcher.nix (the global PATH
   shim catcher) IS committed + pushed (HEAD==origin/main, commit
   74beaa37e). But the RUNNING system generation (gen 54, built
   2026-07-30 15:48) predates that commit (2026-07-31 13:19) — the catcher
   was simply never deployed yet. Needs CI build + pull/switch (never local
   switch — 8GB freeze risk). Not a bug in the design.

4. [DONE] "nixOS systray" persistence + nix-daemon control.
   configuration_nixos-switch-gui.nix: Restart on-failure → always (RestartSec 3)
   — a clean quit (exit 0) now respawns, so the tray can't be closed away.
   da_nixos-systray/src/data/nixos-cp.json: new "Nix Daemon" section (status +
   RESET via systemctl restart nix-daemon.service), pure JSON type:"shell"
   entries, no new code.

5. [DONE] "watchdog systray" — new "Watchdog / Freeze-Guard" section in
   nixos-cp.json: status, live journal tail, /proc/pressure (cpu/memory/io)
   PSI dump, restart freeze-guard.service. Persistence covered by the same
   Restart=always tray-process fix as #4 (same tray process/menu).

6. [DONE] "docker systray" — new "Docker" section in nixos-cp.json: daemon
   status, `docker ps -a` list, RESET (systemctl restart docker.service).

7. [DONE] KDE Notification Center — verified all notify-send calls added/
   existing (nix-switch-progress.nix, nixos-cp.json shell entries) use plain
   notify-send with no --expire-time/--hint transient flags, so they land in
   Plasma's persistent notification history by default. No change needed.

8. [DONE] This file — keeps the list durable across /compact.

## Standing constraints (do not violate)
- Desktop is 8GB Surface: NEVER local `nix build`/`nix eval`/`home-manager
  switch` toplevel — freezes the box. Deploy via CI (ci-build) + pull only.
- Fully declarative + data-driven; fix the engine, no workarounds.
- Work on main, direct commit+push, no branches/PRs, no `git add -f`.
- Never suggest sudo (passwordless already configured).
- unix repo has known wg-key pollution files that must NEVER be committed:
  configuration_network.nix, nat64.json, wireguard-endpoints.json,
  wireguard-public-endpoints.json (derive pre-commit hook re-bakes live wg
  keys — commit with --no-verify, staging ONLY intended files).
