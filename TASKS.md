# Active task list (2026-07-31) — survives context compaction

1. [DONE] Nix Switch Progress "Failed" notification missing an "Open Log" button.
   Fixed: ba_flakes_desktop/src/modules/programs/nix-switch-progress.nix —
   notify-send now uses `-A "open=Open Log"`, log copied to
   $STATE_DIR/last-failure.log (persists past script exit), action opens it
   in `konsole -e less -R`. UNCOMMITTED — needs push.

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

4. [TODO] "nixOS systray" (nix-daemon control/management applet) missing,
   must be PERSISTENT / non-closeable — used to bring nix-daemon back up
   when it's down.
   Context found: configuration_workflow-systray.nix has an explicit
   comment: tray apps are deliberately NOT autostarted — "fought the
   freeze-guard watchdog and ate RAM" (past incident). References to
   "nixos-systray"/"cloud-systray" exist in nixos-cp.json,
   configuration_cloud-cp.nix, configuration_nixos-switch-gui.nix — need to
   read these to find the existing nixos-systray control-panel definition
   before building persistence for it. Must reconcile "must never
   autostart, ate RAM" precedent vs user's "must be persistent, can't be
   closed" requirement — likely needs a lightweight/low-RAM persistence
   design (systemd user service with Restart=always, NOT a heavy Electron
   tray) rather than just removing the old guard.

5. [TODO] "watchdog systray" (freeze-guard/OOM/system-protection control)
   same persistence requirement as #4 — must reflect full system-protection
   data (OOM triggers etc.), always present, restart if closed.

6. [TODO] Add a "docker systray" — manage docker daemon + containers
   (start/stop/restart containers, daemon status) — same tray family as
   #4/#5.

7. [TODO] KDE Notification Center — all nix command notifications
   (notify-send calls from nix-switch-progress-wrap and any other nix/
   nixos-rebuild catcher paths) must post into KDE's persistent
   notification history, not just transient popups. Check current
   notify-send calls for flags that might exclude them from history
   (e.g. transient hints) — likely already fine by default, needs
   verification once catcher is actually deployed (see #3).

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
