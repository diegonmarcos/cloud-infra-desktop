# PLAN: Plasma broken after login — swap-pin drop-in poisons kwin's PATH

**Status**: root-caused 2026-07-24. Declarative fix APPLIED to
`configuration_system-protection.nix` same day (raw-text `systemd.user.units`
drop-in) — **`build.sh switch` still pending**. An imperative bridge
(Diego-authorized, 2026-07-24) was placed to unblock the GUI immediately:
`~/.config/systemd/user/plasma-{kwin_wayland,plasmashell}.service.d/zz-unpoison-path.conf`
(`Environment=` reset — clears the poisoned PATH; lexically last so it wins).
The bridge is inert once the switch ships, but MUST be deleted (cleanup below).
**Severity**: P0 — desktop GUI unusable (login → black screen → back to SDDM loop).
**Executor**: build agent (sonnet). All edits in `~/git/unix`, main branch, direct push.

## Root cause (verified chain, live evidence 2026-07-24 boot ada268fb)

1. `aa_desk-usr_x86_surface-linux_nixos/src/modules/configuration_system-protection.nix:665-668`
   emits the compositor swap-pin (data: `compositor_no_swap` in
   `src/modules/cloud-data-system-protection.json`) via:
   ```nix
   systemd.user.services = lib.genAttrs sysprot.compositor_no_swap.units (_: {
     overrideStrategy = "asDropin";
     serviceConfig.MemorySwapMax = sysprot.compositor_no_swap.MemorySwapMax;
   });
   ```
2. The NixOS `systemd.user.services` generator injects its DEFAULT service env into
   the generated drop-in — verified content of
   `/etc/systemd/user/plasma-kwin_wayland.service.d/overrides.conf`
   (→ `/nix/store/kc611szk…-user-units/…`):
   `Environment=LOCALE_ARCHIVE=…` + `Environment=PATH=` listing ONLY
   coreutils, findutils, gnugrep, gnused, systemd. **No kwin bin dir.**
3. `kwin_wayland_wrapper` resolves the real compositor by bare name
   `kwin_wayland` via PATH (verified: bare string in the wrapped binary; upstream
   kwin_wrapper spawns by name). With the poisoned PATH the child dies at exec,
   before its first log line.
4. The wrapper keeps running: it already acquired `org.kde.KWinWrapper`
   (unit has `BusName=` and no `Type=` → Type=dbus → unit shows **active**) and it
   holds the `wayland-0` listening socket. systemd never restarts it.
5. Every Qt/GUI session client blocks in the dead socket's accept queue →
   `plasma-plasmashell`, polkit agent, powerdevil, all three xdg portals hit
   Type=dbus start timeouts (40–120 s) → login cascade-fails forever.

**Evidence** (this boot): kwin service cgroup `memory.peak=2.9MB`, `memory.events`
all zero (no OOM, not frozen), unit active since 11:27:20 with 47ms CPU and no
child; `ss -xl` → `/run/user/1000/wayland-0` **Recv-Q 93** (93 clients queued,
nobody accepting); plasmashell dies at 72MB/285ms (blocked, not thrashing);
zero kwin output in journal. Broken since the Jul 22 ~12:45 generation switch
(mass SIGABRT coredumps start Jul 22 12:50). NOT a memory/zram/swappiness issue.

Note: the module comment at lines 657-664 documents the PREVIOUS bug (full unit
replacement → no ExecStart, gen 48). `asDropin` fixed that and introduced this
one: the drop-in is no longer a full replacement, but still carries the
generator's env injection, which overrides the vendor unit's environment.

## Fix design (declarative, data-driven — same JSON stays source of truth)

Replace the `systemd.user.services` block at
`configuration_system-protection.nix:665-668` with a raw-text drop-in via
`systemd.user.units`, which emits EXACTLY the given text (no env injection):

```nix
systemd.user.units = lib.genAttrs
  (map (u: "${u}.service") sysprot.compositor_no_swap.units) (_: {
    overrideStrategy = "asDropin";
    text = ''
      [Service]
      MemorySwapMax=${toString sysprot.compositor_no_swap.MemorySwapMax}
    '';
  });
```

- Check `compositor_no_swap.units` values in the JSON first: if they already
  carry `.service`, drop the `map`.
- Update the 657-664 comment: add the 2026-07-24 incident — drop-ins generated
  via `systemd.user.services` inherit `Environment=PATH=` defaults which
  override the vendor unit env and break `kwin_wayland_wrapper`'s PATH lookup;
  `systemd.user.units` + raw text is mandatory.

## Cleanup (same change-set, after switch verified)

Two imperative shadow layers currently duplicate MemorySwapMax=0 and must go
(they are harmless but shadow the declarative source):
- `~/.config/systemd/user/plasma-{kwin_wayland,plasmashell}.service.d/50-swap-cap.conf`
  — manual bridge from 2026-07-18, self-documented "DELETE THIS FILE once the
  real switch ships".
- `~/.config/systemd/user.control/plasma-{kwin_wayland,plasmashell}.service.d/50-MemorySwapMax.conf`
  — `systemctl set-property` residue.
- `~/.config/systemd/user/plasma-{kwin_wayland,plasmashell}.service.d/zz-unpoison-path.conf`
  — the 2026-07-24 imperative bridge (Environment= reset). Inert after the
  switch, delete anyway.

Do NOT touch `~/.config/systemd/user/*/memory-cap.conf` — those are HM-managed
(`ba_flakes_desktop/src/modules/desktop-session/system-protection-desktop-session.nix`).

## Rollout / recovery

1. Edit module + comment, commit, push (main, no branch).
2. From TTY (GUI is down anyway; ~4.2G free is enough):
   `cd ~/git/unix/aa_desk-usr_x86_surface-linux_nixos && ./build.sh switch`
3. Verify the regenerated drop-in BEFORE reboot:
   `cat /etc/systemd/user/plasma-kwin_wayland.service.d/overrides.conf`
   → must contain ONLY `[Service]` + `MemorySwapMax=0`, no `Environment=` lines.
4. Delete the two shadow layers (step above), reboot, log in.

## Tester (task not done without it)

Extend `ba_flakes_desktop/src/modules/desktop-session/test-system-protection-desktop-session.sh`
(or sibling in aa_desk module dir if system-side) with:
- **Build-time**: for each unit in `compositor_no_swap.units`, the generated
  `/etc/systemd/user/<unit>.service.d/overrides.conf` contains `MemorySwapMax`
  and contains NO `Environment=` line. Fails the switch if the generator ever
  re-injects env.
- **Runtime (post-login)**:
  - `pgrep -x kwin_wayland` exists and RSS > 50MB (compositor really running);
  - `ss -xl` on `/run/user/1000/wayland-0` shows Recv-Q 0;
  - `systemctl --user show plasma-kwin_wayland.service -p SubState` = running;
  - `systemctl --user show plasma-kwin_wayland.service -p MemorySwapMax` = 0
    (pin still effective).

## Out of scope (observed, pre-existing)

- `hm-auto-switch.service` failed this boot: `nix-store` OOM-killed at the 2GB
  `workload.slice/hm-switch-isolated.service` cap (11:33:57). Known issue
  ("HM activation blocked by RAM"), unrelated to the GUI break (kwin died at
  11:27:20, before the switch ran).
- zram (7.6G, prio 100) + `vm.swappiness=150` are healthy and unchanged.
