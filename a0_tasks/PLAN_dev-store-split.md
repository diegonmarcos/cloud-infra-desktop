# PLAN — Dev/User Store Split (Design B)

> Status: **SPEC — awaiting approval** (2026-06-18)
> Owner: diego · Author: pairing session
> Goal: move the ~25 GiB "dev userspace" off the 80 G pool onto p5, **cache-backed**
> (no rebuild-world), behind an **enforced dev/user boundary**.

---

## 1. Motivation (measured, not guessed)

`nix path-info --all -s` on the live store, 2026-06-18:

| Category | own bytes |
|---|---|
| compilers (rust/gcc/clang/llvm) | 5.49 GiB |
| ML / data-science | 1.06 GiB |
| runtimes (go/node/jvm/kotlin) | 2.15 GiB |
| cloud CLIs (tf/k8s/wrangler/…) | 2.16 GiB |
| android SDK + qemu | 11.60 GiB |
| **HEAVY-DEV total (own bytes)** | **22.46 GiB** |
| whole `/nix/store` (own bytes) | 55.05 GiB |

Heavy-dev ≈ **40% of the store**. Moving it (own bytes + dev-only shared deps ≈ **~25 GiB**)
takes pool `/nix` from ~55 G → ~30 G. It also gives a **concrete dev-vs-user separation**,
which is a product requirement, not just a disk win.

## 2. The two spaces

| | **userspace** (pool `/nix`) | **dev userspace** (p5 store) |
|---|---|---|
| Store | `/nix/store` on the LUKS pool | chroot store at `/mnt/shared-lib/dev-store/nix/store` |
| `leaves.json` groups | `shell-core`, `productivity`, `media-graphics`, `browsers`, `ai/*` | `dev-languages`, `build-debug`, `data-science`, `containers-cloud`(dev CLIs), `android-emulator` |
| Entry | default login shell | `dev` command (kernel namespace) |
| PATH | desktop + AI CLIs only; **no compilers** | full toolchain + engines |
| Prompt | normal | `[dev]` marker |

The split is **already data-driven** — it maps onto existing `leaves.json` profile groups.
`dev-space.json` declares which groups are "dev"; nothing is hardcoded.

## 3. Store mechanics — why the cache survives

Use a **chroot store**: logical `storeDir = /nix/store`, physical root on p5
(`--store 'local?root=/mnt/shared-lib/dev-store'`). Because `storeDir` is still `/nix/store`,
every path hash matches `cache.nixos.org` → **substitute, never rebuild**. The price (a ~1 GiB
duplicate of glibc/toolchain foundation, since p5 ext4 can't cross-FS-hardlink with the pool
btrfs) is a *download*, not a compile.

> This is what makes B strictly better than A (alt-`storeDir`): A is PATH-addressable without a
> wrapper but loses the cache (rebuild-world); B keeps the cache and the wrapper *is* the boundary.

## 4. The boundary — the `dev` launcher (bubblewrap)

`dev [cmd]` = generated `bwrap` wrapper:

```
bwrap \
  --bind /mnt/shared-lib/dev-store/nix/store    /nix/store      \  # p5 store masks pool store
  --bind /mnt/shared-lib/dev-store/nix/var/nix  /nix/var/nix    \
  --dev-bind /dev /dev  --proc /proc  --bind /home/diego /home/diego \
  --bind /tmp /tmp  --share-net  --clearenv  \
  --setenv PATH "<dev-profile>/bin:/run/wrappers/bin:..." \
  --setenv PS1 '[dev] \w \$ ' \
  <shell-or-cmd>
```

- Inside: the dev binaries' hardcoded interpreter (`/nix/store/…-glibc/…/ld-linux`) resolves to
  the **p5** glibc (because `/nix/store` *is* the p5 store there). Self-complete; **cache-backed**.
- The pool store is **masked** inside — a compiler can't pull a desktop lib (the wall).
- Outside `dev`: `command -v gcc` → nothing. Lean daily driver.
- **Boot-independent**: the dev store is never on the boot path. p5 unmounted → `dev` errors
  cleanly, userspace untouched. (Unlike moving `/nix`, which is boot-critical.)
- **Caveat (= the feature):** GUI apps don't launch *inside* `dev` (their closure is in the masked
  pool store). Edit in userspace, compile in `dev`; or a TUI editor inside.

## 5. Declarative architecture (engine pattern)

```
~/git/unix/bc_flakes_dev-store/
  build.sh                 # universal engine (build / copy-to-p5 / gcroot / gc / test)
  build.json               # { p5_root, store_uri, profile_name, deploy target }
  src/
    flake.nix              # devProfile = buildEnv of the dev groups (reads dev-space.json)
    dev-space.json         # SoT: which leaves.json groups are "dev"; bwrap binds; launcher cfg
```

`dev-space.json` (single source of truth):

```json
{
  "p5_root": "/mnt/shared-lib/dev-store",
  "store_uri": "local?root=/mnt/shared-lib/dev-store",
  "profile": "/mnt/shared-lib/dev-store/profile",
  "dev_groups": ["dev-languages", "build-debug", "data-science",
                 "containers-cloud", "android-emulator"],
  "launcher": { "name": "dev", "prompt": "[dev] ", "share_net": true,
                "binds": ["/home/diego", "/tmp", "/etc/resolv.conf"] },
  "gc": { "keep_generations": 3 },
  "watch_mount": "/mnt/shared-lib"
}
```

### Wiring
- **`bc_flakes_dev-store/src/flake.nix`** — `devProfile = pkgs.buildEnv { paths = <leaves of dev_groups>; }`.
  Reuses the SAME leaf modules as `ba_flakes_desktop` (import the leaf list from the shared
  `leaves.json` so there is ONE definition of each tool — no divergence).
- **`build.sh build`** → `nix build .#devProfile` (substitutes from cache).
- **`build.sh ship`** → `nix copy --to "$store_uri" ./result` + register a profile/gcroot in the
  p5 store + write `<p5>/profile` symlink (what `dev` puts on PATH).
- **HM (`ba_flakes_desktop`)** — generates the `dev` launcher from `dev-space.json`; **removes the
  `dev_groups` from the pool profile** (the `leaves.json` routing). `bubblewrap` added to userspace.
- **p5 dir** provisioned by the existing NixOS-host tmpfiles rule (already added for android):
  extend it to `/mnt/shared-lib/dev-store` (diego-owned).

## 6. GC + disk-protection

- The p5 dev store has its **own** gcroots → `nix store gc --store "$store_uri"` (keep last N
  generations from `dev-space.json`). Wire into the weekly `disk-housekeeping` service as a second
  store.
- `cloud-data-disk-protection.json`: `/mnt/shared-lib` already implicitly relevant; add an explicit
  watch + a `dev_store_gc` reclaim action. The 95 % emergency tier already protects the box.

## 7. Android fold-in (cleans up the in-flight hack)

The android SDK (11.6 G, incl. system images) is just a member of the dev profile now:
- **Revert commit `a6d7065`** (the standalone p5 image-move) and the un-switched `escapeShellArg`
  fix — both become unnecessary.
- `android-emulator.nix` returns to `includeSystemImages = true` (nix-pure, cache-backed) and moves
  into the **dev profile** → its 11.6 G lands in the p5 dev store automatically. No `sdkmanager`, no
  symlink farm, no semicolon bug. The emulator is launched from within `dev` (or a thin host shim
  that enters the namespace).

## 8. Rollout phases (each independently revertable)

0. **Approve this spec.**
1. Scaffold `bc_flakes_dev-store` (engine + flake + `dev-space.json`); `build.sh build` (cache pull,
   no system change). Verify `result` closure ≈ 25 G.
2. `build.sh ship` → populate the p5 chroot store; verify `nix store ping --store "$store_uri"`.
3. HM: add `bubblewrap` + the `dev` launcher; **do not yet remove** pool groups. Verify `dev` enters,
   `dev -- rustc --version` works from p5.
4. HM: remove `dev_groups` from `leaves.json` → pool profile shrinks; `nix-collect-garbage -d` →
   measure pool `/nix` drop (~25 G).
5. Android fold-in + revert `a6d7065`.
6. GC + watchdog wiring.

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| bwrap masks pool store → no GUI in `dev` | by design; edit in userspace, compile in `dev` |
| p5 unmounts | `dev` fails closed; userspace + boot unaffected |
| Two stores diverge (tool defined twice) | flake imports the SAME `leaves.json` leaves — one definition |
| p5 ext4 perf vs nvme pool | p5 *is* on nvme0n1p5 (same disk, different partition) — negligible |
| First `ship` needs network (cache pull ~25 G) | one-time; documented; fails safe |
| Dev-store GC orphaned | own gcroots + weekly housekeeping + watchdog |

## 10. Testers (Rule 5)

- `command -v gcc` in userspace → empty; `dev -- command -v gcc` → path **physically under**
  `/mnt/shared-lib/dev-store`.
- `find /nix/store -maxdepth 1 -name '*rustc*' -o -name '*android-sdk-system-image*' | wc -l` → `0`.
- `nix store ping --store "$store_uri"` → ok.
- pool `/nix` own-bytes drops ≥ 20 GiB vs the 55 G baseline.
- `dev -- nix store gc --store "$store_uri" --dry-run` → succeeds (own GC works).

## 11. Open decisions (need your call)

1. **Engines (servers/builders) → Design C (nspawn) or stay in B?** B is fine for interactive;
   C gives long-running engines a real container. Recommend: **B for everything now**, lift heavy
   *daemons* to C later if needed.
2. **`containers-cloud` group**: it mixes dev CLIs (kubectl/terraform — dev) with waydroid +
   android-emulator (also dev) — all → dev space. Confirm nothing in it is needed at *login*.
3. **Keep `ai/*` (Claude/Gemini) in userspace** (recommended — daily driver) — confirm.
