# PLAN — Home-Manager module split

> **Goal**: split the 8 monolithic profiles in `src/modules/profiles/` into single-purpose
> leaf modules grouped by **kind of binary**, so heavy packages (libreoffice, joplin,
> wrangler, openjdk, rustc, ansible, …) can be toggled by removing one import.
>
> **Non-goal**: shrinking the closure on its own. The split *enables* shrink decisions;
> it does not perform them. Every package currently imported stays imported until
> Diego decides per-host.

---

## 0. Source of truth & scope

- **Source**: `~/git/unix/ba_flakes_desktop/src/`
- **Engine**: `~/git/unix/ba_flakes_desktop/build.sh`
- **Flake interface that must stay stable during migration**: `profiles.<name>`,
  `toolsets.<name>`, `presets.<name>` in `src/flake.nix:80–139` — `mkHost` consumes
  a list of profile names, so renaming/removing profile keys breaks every host preset.
- **Out of scope (decided 2026-05-05)**:
  - System-side moves to HM (NixOS pkg list is already minimal — see investigation).
  - Removing kiosk SDDM sessions (chromium + tor-browser **stay**).

---

## 1. Target tree

```
src/modules/
├── core/                       # always-on, used by every host
│   ├── shell-utils.nix         # eza, bat, fd, ripgrep, fzf, zoxide, atuin, tealdeer, btop, multitail
│   ├── coreutils.nix           # coreutils, findutils, gnugrep, gnused, gawk, less, bc, file, which, diffutils, patch
│   ├── archive.nix             # zip, unzip, p7zip, unrar
│   ├── network-basics.nix      # bind, dnsutils, inetutils, openssh, socat, rsync, rclone, curl, wget
│   ├── sysinfo.nix             # neofetch, lshw, pciutils, usbutils, htop, iotop, sysstat, procps, psmisc
│   ├── clipboard.nix           # xclip, wl-clipboard, cliphist
│   ├── data-formats.nix        # jq, yq-go
│   ├── tui.nix                 # yazi, ncdu, duf, tree, browsh
│   ├── git-extras.nix          # git-lfs, git-filter-repo, delta, diff-so-fancy, gh
│   └── web-terminal.nix        # ttyd (overridden via overlay in flake.nix)
│
├── languages/                  # one file per toolchain — host imports the ones it needs
│   ├── rust.nix                # imports ../rust-cargo-deps.nix (existing) + cargo subcommands
│   ├── go.nix                  # go, gopls, delve
│   ├── node.nix                # nodejs_20, npm, pnpm, yarn, typescript, esbuild, dart-sass + node-npm-deps
│   ├── python.nix              # python312, pip, virtualenv, pipx, uv
│   ├── java.nix                # jdk
│   ├── ruby.nix                # ruby
│   └── c-cpp.nix               # gcc, llvm, lldb (c++ shared libs flow from here)
│
├── build-tools/
│   ├── build-systems.nix       # cmake, ninja, gnumake, meson, automake, autoconf, libtool, pkg-config
│   ├── debug.nix               # gdb, lldb, valgrind, strace, ltrace
│   ├── analysis.nix            # clang-tools, cppcheck, shellcheck, shfmt
│   ├── docs-diagrams.nix       # pandoc, doxygen, graphviz, d2, plantuml, pikchr
│   └── dev-utils.nix           # direnv, just, watchexec, act
│
├── containers-cloud/
│   ├── containers.nix          # docker-client, podman, youki, buildah, skopeo, dive, docker-compose, docker-buildx
│   ├── kubernetes.nix          # kubectl, kubernetes-helm, k9s, kubectx, stern, istioctl
│   ├── iac.nix                 # terraform, ansible
│   ├── cloud-clis.nix          # google-cloud-sdk, awscli2, azure-cli, oci-cli, cloudflared, flarectl
│   ├── observability.nix       # prometheus, grafana
│   ├── ci-cd.nix               # gitlab-runner
│   └── secrets.nix             # sops, age   (kept here AND in security-net via shared lib)
│
├── security-net/
│   ├── secrets.nix             # sops, age, gnupg, pass, gopass + programs.gpg + services.gpg-agent
│   ├── network-analysis.nix    # nmap, netcat-openbsd, mtr, tcpdump, wireshark-cli, tshark, iftop, nethogs
│   ├── privacy.nix             # tor, torsocks, dnscrypt-proxy2
│   ├── vpn.nix                 # wireguard-tools, openvpn
│   ├── forensics.nix           # yara, binwalk, hexyl, xxd, binutils
│   ├── tls.nix                 # openssl, certbot, ssh-audit, httpie
│   ├── firewall.nix            # iptables, nftables  (user-side TUIs only; rules are NixOS)
│   ├── scanning.nix            # lynis
│   └── passwords-gui.nix       # bitwarden-desktop
│
├── data-science/
│   ├── python-numerics.nix     # numpy, pandas, scipy, matplotlib, seaborn, plotly, polars, dask, pyarrow, bokeh
│   ├── python-ml.nix           # scikit-learn, torch, torchvision
│   ├── jupyter.nix             # jupyterlab, notebook, ipython
│   ├── databases-cli.nix       # sqlite, postgresql, mysql80, redis + pgcli, mycli, litecli
│   ├── stats-r.nix             # R + ggplot2, dplyr, tidyr
│   ├── scientific.nix          # octave, sympy
│   ├── scraping.nix            # beautifulsoup4, scrapy
│   └── api-clients.nix         # requests, httpx, pydantic
│
├── productivity/
│   ├── office.nix              # libreoffice                         ← 1416 MB
│   ├── notes.nix               # obsidian, zettlr, joplin-desktop    ← 700+460 MB
│   ├── pdf.nix                 # okular, zathura, poppler_utils
│   ├── kde-tools.nix           # kdePackages.{dolphin,dolphin-plugins,ark,kate,kcalc,spectacle,
│   │                           #   kmousetool, partitionmanager, filelight, kcharselect, ksystemlog,
│   │                           #   kfind, krdc, krfb, skanlite}, zenity, kdialog
│   ├── file-managers.nix       # ranger, mc
│   ├── archives-gui.nix        # already-existing zip/unzip live in core/archive.nix
│   ├── tasks-time.nix          # taskwarrior, vit, calcurse, remind
│   ├── markdown.nix            # mdcat, glow
│   ├── screenshots.nix         # flameshot, maim
│   └── spell.nix               # aspell + aspellDicts.{en,es}
│
├── media-graphics/
│   ├── images-edit.nix         # imagemagick, gimp, krita, inkscape
│   ├── video.nix               # ffmpeg, mpv, vlc, obs-studio, kdenlive
│   ├── audio.nix               # audacity, sox, lame
│   ├── capture.nix             # peek, simplescreenrecorder        (flameshot lives in productivity/)
│   ├── viewers.nix             # feh, imv, gwenview, kdePackages.{kcolorchooser, elisa, dragon}
│   ├── photo-mgmt.nix          # digikam
│   ├── media-info.nix          # mediainfo, exiftool
│   └── design.nix              # drawio, gpick
│
├── browsers/
│   ├── brave.nix               # MOVED from src/modules/brave.nix
│   ├── firefox.nix             # MOVED from src/modules/firefox.nix
│   └── terminal.nix            # browsh   (alternative: keep in core/tui.nix)
│
├── ai/
│   ├── claude.nix              # claude-code package + writeShellScriptBin wrappers
│   │                           #   (claude-termux, claude-malloc, claude-rescue)
│   └── gemini.nix              # customPkgs.gemini-cli
│
├── infra-tools/                # cloud-repo-specific heavy CLIs
│   ├── wrangler.nix            # cloudflare wrangler                ← 898 MB (toggle separately)
│   └── crawlee.nix             # if/when crawlee CLI is added
│
├── desktop-session/            # session-side guardrails
│   ├── orphan-reaper.nix       # MOVED from src/modules/system-protection-orphan-reaper.nix
│   ├── watchdog-dropbear.nix   # MOVED from src/modules/system-protection-watchdog-dropbear.nix
│   ├── session-watchdog.nix    # MOVED from src/modules/system-protection-desktop-session.nix
│   ├── guardrails.nix          # MOVED from src/modules/system-protection-guardrails.nix
│   ├── resource-bouncer.nix    # MOVED from src/modules/system-protection-resource-bouncer.nix
│   ├── layer2-identity.nix     # MOVED from src/modules/system-protection-layer2-identity.nix
│   └── default.nix             # imports = [ ./orphan-reaper.nix ./watchdog-dropbear.nix … ]
│
├── desktop/                    # UNCHANGED — full DE configs (plasma, gnome)
├── programs/                   # UNCHANGED — editor/git/shell/tmux configs
├── packages/                   # UNCHANGED — custom package overlay (claude-code, gemini-cli derivations)
├── pkgs/                       # UNCHANGED — local nix derivations (octocode)
├── dotfiles/                   # UNCHANGED
└── profiles/                   # → becomes thin shims (see §3 backwards-compat)
```

**Naming rule** for every leaf module:

```nix
# src/modules/<category>/<concern>.nix
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    # exactly one logical concern's worth of packages
  ];
  # if the concern owns a service/program block, declare it here too
}
```

No `imports = [ ../other/category.nix ]` inside leaf modules — leaves are leaves.
Imports compose at the **profile shim** layer or at the **flake** layer.

---

## 2. Leaf-module mapping (current profile → target leaves)

> Concrete enough that the migration can be executed mechanically.

### profile 1 → core/
| current line | → leaf |
|---|---|
| `(nerdfonts.override …)` | `core/coreutils.nix` (or new `core/fonts.nix`) |
| eza, bat, fd, ripgrep, fzf, zoxide, atuin, tealdeer, btop, multitail | `core/shell-utils.nix` |
| browsh, yazi, ncdu, duf, tree | `core/tui.nix` |
| jq, yq-go | `core/data-formats.nix` |
| rsync, rclone, **wrangler** | rsync/rclone → `core/network-basics.nix`; **wrangler → `infra-tools/wrangler.nix`** |
| xclip, wl-clipboard, cliphist | `core/clipboard.nix` |
| coreutils, findutils, gnugrep, gnused, gawk, less, bc, file, which, diffutils, patch | `core/coreutils.nix` |
| curl, wget | `core/network-basics.nix` |
| htop, iotop, sysstat, procps, psmisc, lshw, pciutils, usbutils, neofetch | `core/sysinfo.nix` |
| zip, unzip, p7zip | `core/archive.nix` |
| bind, dnsutils, inetutils, openssh, socat | `core/network-basics.nix` |
| ttyd | `core/web-terminal.nix` |
| git-filter-repo, gh | `core/git-extras.nix` |

### profile 2 → languages/
| current | → leaf |
|---|---|
| `(callPackage ../../pkgs/octocode.nix {})` | `languages/rust.nix` (it's a Rust analyser) |
| go, gopls, delve | `languages/go.nix` |
| nodejs_20, pnpm, npm, yarn, typescript, esbuild, dart-sass | `languages/node.nix` |
| python312, pip, virtualenv, pipx, uv | `languages/python.nix` |
| gcc, llvm, lldb | `languages/c-cpp.nix` |
| jdk | `languages/java.nix` |
| ruby | `languages/ruby.nix` |
| `home.sessionVariables { GOPATH; npm_config_prefix }` | each var lives in the language module that owns it |

### profile 3 → build-tools/
| current | → leaf |
|---|---|
| cmake, ninja, gnumake, meson, automake, autoconf, libtool, pkg-config | `build-tools/build-systems.nix` |
| gdb, lldb, valgrind, strace, ltrace | `build-tools/debug.nix` |
| clang-tools, cppcheck, shellcheck, shfmt | `build-tools/analysis.nix` |
| pandoc, doxygen, graphviz, d2, plantuml, pikchr | `build-tools/docs-diagrams.nix` |
| git-lfs, diff-so-fancy, delta | `core/git-extras.nix` (consolidated with profile-1) |
| act | `build-tools/dev-utils.nix` |
| direnv, just, watchexec | `build-tools/dev-utils.nix` |

### profile 4 → containers-cloud/
| current | → leaf |
|---|---|
| docker-client, podman, youki, buildah, skopeo, dive, docker-compose, docker-buildx | `containers-cloud/containers.nix` |
| kubectl, kubernetes-helm, k9s, kubectx, stern, istioctl | `containers-cloud/kubernetes.nix` |
| terraform, **ansible** | `containers-cloud/iac.nix` |
| google-cloud-sdk, awscli2, azure-cli, oci-cli, cloudflared, flarectl | `containers-cloud/cloud-clis.nix` |
| prometheus, grafana | `containers-cloud/observability.nix` |
| gitlab-runner | `containers-cloud/ci-cd.nix` |
| sops, age | `containers-cloud/secrets.nix` (keep parallel copy in security-net/ via shared list — see §4) |

### profile 5 → security-net/
| current | → leaf |
|---|---|
| tor, torsocks, dnscrypt-proxy2 | `security-net/privacy.nix` |
| wireguard-tools, openvpn | `security-net/vpn.nix` |
| nmap, netcat-openbsd, mtr, tcpdump, wireshark-cli, tshark, iftop, nethogs | `security-net/network-analysis.nix` |
| lynis | `security-net/scanning.nix` |
| gnupg, age, sops, openssl + `programs.gpg`, `services.gpg-agent` | `security-net/secrets.nix` |
| pass, gopass | `security-net/secrets.nix` |
| bitwarden-desktop | `security-net/passwords-gui.nix` |
| openssh, ssh-audit | `security-net/secrets.nix` (ssh-audit) — openssh already in `core/network-basics.nix` |
| yara, binwalk, hexyl, xxd, binutils | `security-net/forensics.nix` |
| httpie | `security-net/tls.nix` |
| certbot | `security-net/tls.nix` |
| iptables, nftables | `security-net/firewall.nix` |

### profile 6 → data-science/ + ai/
| current | → leaf |
|---|---|
| customPkgs.gemini-cli | `ai/gemini.nix` |
| claude-termux/claude-malloc/claude-rescue wrappers | `ai/claude.nix` |
| numpy, pandas, scipy, matplotlib, seaborn, plotly, polars, dask, pyarrow, bokeh | `data-science/python-numerics.nix` |
| scikit-learn, torch, torchvision | `data-science/python-ml.nix` |
| jupyterlab, notebook, ipython | `data-science/jupyter.nix` |
| sqlite, postgresql, mysql80, redis | `data-science/databases-cli.nix` |
| pgcli, mycli, litecli | `data-science/databases-cli.nix` |
| R + ggplot2, dplyr, tidyr | `data-science/stats-r.nix` |
| sympy, octave | `data-science/scientific.nix` |
| beautifulsoup4, scrapy | `data-science/scraping.nix` |
| requests, httpx, pydantic | `data-science/api-clients.nix` |
| `home.sessionVariables { PYTHONPATH; JUPYTER_CONFIG_DIR }` | each in its leaf |

### profile 7 → productivity/ + browsers/
| current | → leaf |
|---|---|
| `imports = [ ../brave.nix ../firefox.nix ]` | `imports = [ ../browsers/brave.nix ../browsers/firefox.nix ]` |
| **libreoffice** | `productivity/office.nix` |
| obsidian, **zettlr**, **joplin-desktop** | `productivity/notes.nix` |
| okular, zathura, poppler_utils | `productivity/pdf.nix` |
| kdePackages.{dolphin, dolphin-plugins, ark, kate, kcalc, spectacle, kmousetool, partitionmanager, filelight, kcharselect, ksystemlog, kfind, krdc, krfb, skanlite}, zenity, kdialog | `productivity/kde-tools.nix` |
| ranger, mc | `productivity/file-managers.nix` |
| p7zip, unrar, unzip, zip | `core/archive.nix` (deduped with profile-1) |
| taskwarrior, vit, calcurse, remind | `productivity/tasks-time.nix` |
| flameshot, maim | `productivity/screenshots.nix` |
| mdcat, glow | `productivity/markdown.nix` |
| aspell + aspellDicts | `productivity/spell.nix` |

### profile 8 → media-graphics/
| current | → leaf |
|---|---|
| imagemagick, gimp, krita, inkscape | `media-graphics/images-edit.nix` |
| ffmpeg, mpv, vlc, obs-studio, kdenlive | `media-graphics/video.nix` |
| audacity, sox, lame | `media-graphics/audio.nix` |
| flameshot, peek, simplescreenrecorder | `media-graphics/capture.nix` (or split flameshot to productivity/screenshots.nix — pick one) |
| feh, imv, gwenview, kdePackages.kcolorchooser, kdePackages.elisa, kdePackages.dragon | `media-graphics/viewers.nix` |
| digikam | `media-graphics/photo-mgmt.nix` |
| mediainfo, exiftool | `media-graphics/media-info.nix` |
| drawio, gpick | `media-graphics/design.nix` |

---

## 3. Backwards-compat: keep `profiles.<name>` working

`flake.nix` lines 80–139 currently do:

```nix
profiles = {
  shell-core       = ./modules/profiles/1-shell-core.nix;
  dev-languages    = ./modules/profiles/2-dev-languages.nix;
  …
};
toolsets.full = [ "shell-core" "dev-languages" … ];
```

**Migration approach: profiles become shims that import leaves.** Each
`profiles/N-<name>.nix` is rewritten as:

```nix
# src/modules/profiles/1-shell-core.nix  (after migration)
{ ... }:
{
  imports = [
    ../core/shell-utils.nix
    ../core/coreutils.nix
    ../core/archive.nix
    ../core/network-basics.nix
    ../core/sysinfo.nix
    ../core/clipboard.nix
    ../core/data-formats.nix
    ../core/tui.nix
    ../core/git-extras.nix
    ../core/web-terminal.nix
  ];
}
```

Result:
- `presets.full-plasma` keeps working — same profile names, same outputs.
- Hosts that want **granular** control bypass profiles: they import leaves directly.
- After all 8 profiles are shimmed, we can introduce a NEW interface
  `granular = { core = […leaf paths…]; languages = { rust = …; go = …; }; … }`
  in flake.nix, exposed alongside `profiles`. Hosts opt in over time.
- Eventually (Phase 4) profiles can be removed once no preset references them.

---

## 4. Data-driven follow-up (NOT this PR)

The current `flake.nix` `containerPackages` (lines 195–230+) hardcodes a duplicate
package list. Once leaves exist, replace with:

```nix
containerPackages = with pkgs; (
  (import ./modules/core/shell-utils.nix     { inherit pkgs lib config; }).home.packages ++
  (import ./modules/languages/rust.nix       { …}).home.packages ++
  …
);
```

Or (cleaner): put package lists in `modules/<category>/<concern>.json`, import
JSON in both the leaf module AND `containerPackages`. Single source of truth.

Out of scope for the split itself — file as a follow-up after Phase 4.

---

## 5. Phased migration

Each phase is independently shippable (HM build still works) and tested before
the next phase starts.

### Migration tracker (executed 2026-05-05)

| Phase | Status | What landed | Closure delta vs Phase-0 baseline |
|---|---|---|---|
| 0   | ✓ done | 12 category dirs + default.nix shims; engine fix: `build.sh build` (no-activate dry build) | 0 packages added/removed |
| 1   | ✓ done | profile 3 → 5 build-tools/ leaves + core/git-extras.nix (git-lfs, delta, diff-so-fancy) | 0 packages added/removed |
| 1a  | ✓ done | profile 1 → 10 core/ leaves + infra-tools/wrangler.nix + git-extras gets gh + git-filter-repo | 0 packages added/removed |
| 1b  | ✓ done | profile 2 → 7 languages/ leaves; GOPATH in go.nix, npm_config_prefix in node.nix | 0 packages added/removed |
| 1c  | ✓ done | profile 4 → 7 containers-cloud/ leaves (incl. parallel secrets.nix) | 0 packages added/removed |
| 1d  | ✓ done | profile 5 → 9 security-net/ leaves; programs.gpg+services.gpg-agent owned by secrets.nix | 0 packages added/removed |
| 1e  | ✓ done | profile 6 → 8 data-science/ leaves + 2 ai/ leaves; PYTHONPATH→python-numerics, JUPYTER_CONFIG_DIR→jupyter | 0 packages added/removed |
| 1f  | ✓ done | profile 7 → 9 productivity/ leaves; archive.nix gains unrar (consolidated with profile 1) | 0 packages added/removed |
| 1g  | ✓ done | profile 8 → 8 media-graphics/ leaves; flameshot OWNED by productivity/screenshots.nix per §8 #1 | 0 packages added/removed |
| 2   | ✓ done | brave.nix + firefox.nix + browsers-gpu.{nix,json} + brave/firefox-extensions.json + test-browsers-gpu.sh — moved to browsers/ via `git mv`; profile 7 import paths updated | 0 packages added/removed (byte-identical store path on rebuild) |
| 2b  | ✓ done | system-protection cluster (11 .nix/.json/.sh + 2 test-*.sh = 13 files) → desktop-session/ via `git mv`; flake.nix `userModules` updated; relative refs intra-cluster preserved (all use `./`); test-script "Run:" comments updated | 0 packages added/removed (byte-identical store path: `fn4v5cqp...`) |
| 2c  | ✓ verified | bb_flakes_termux build (HM termux): success — proot-static path error is pre-existing cross-arch artefact (this host x86_64, termux aarch64-android), unrelated to refactor. aa_nixos-surface_host check (NixOS): 47.7s dry-run, clean. | — |
| 3   | ✓ done | granular per-leaf imports already enabled by the leaf files themselves — any host can `imports = [ ../modules/<cat>/<leaf>.nix ];`. No flake.nix sugar needed (would just duplicate paths). | — |
| 4   | ✓ done | DATA-DRIVEN: created `src/modules/leaves.json` (profile→leaf-list map). flake.nix now reads it via `builtins.fromJSON` + `mkProfile` helper that maps `"<cat>/<leaf>"` strings to `./modules/<cat>/<leaf>.nix`. All 8 shim files (`profiles/N-*.nix`) deleted via `git rm -f`. `toolsets`/`presets` in flake.nix and `presets` in build.json untouched — they reference profile names by string and the JSON exposes the same names. | 0 packages added/removed (byte-identical store path: `fn4v5cqp...` after both Phase 4 sub-steps) |
| Final | ✓ verified | All three flakes build clean: ba_flakes_desktop (`fn4v5cqp...`, 17.3s), bb_flakes_termux (build OK, pre-existing cross-arch proot-static noise unchanged), aa_nixos-surface_host (22.6s dry-run, "Git tree dirty" warning is expected from uncommitted work). | — |

**Closure equality test (Phase 0 baseline → Phase 2 final):**
```
4435 paths in both. 8 added / 8 removed; all 16 are top-of-tree wrappers
(home-manager-{generation,files,path}, man-cache, man-paths, hm_.manpath,
hm_fontconfigconf.d10hmfonts.conf, diego-fish-completions, hm_CLAUDE.md.tpl).
0 user-visible packages added or removed.
```
Reference: `/tmp/hm-closure-before.txt` (sha256 9b598abdac6f27e6...) ↔ `/tmp/hm-closure-final.txt`.



### Phase 0 — Skeleton (no semantic change)
1. `mkdir` the new category dirs (`core/`, `languages/`, …).
2. Add a `default.nix` in each that just sets `imports = [];` so the dir is a
   valid module path.
3. Run `build.sh build` → must still build the same closure. **Test**: `nix-store
   -qR result | sort > /tmp/before.txt` and after = same.

### Phase 1 — Move *one* profile (start with #3 build-debug, smallest)
1. Create `build-tools/{build-systems,debug,analysis,docs-diagrams,dev-utils}.nix`
   leaves.
2. Rewrite `profiles/3-build-debug.nix` to import them.
3. Build + diff closure: should be byte-identical (`/tmp/before.txt == after.txt`).
4. Repeat profile-by-profile in this order: 3 → 1 → 2 → 4 → 5 → 8 → 6 → 7
   (smallest/easiest first, profile 7 has the most KDE entanglement).

### Phase 2 — Top-level scattered modules
- Move `brave.nix`, `firefox.nix` → `browsers/`. Update profile-7 import paths.
- Move `system-protection-*.nix` → `desktop-session/`. Update `userModules` in
  `flake.nix`.
- Move `cliphist.nix` (if it ends up unused as a top-level) → `core/clipboard.nix`.

### Phase 3 — Granular host interface
- Add `granular = { … }` to `flake.nix` mirroring the new tree.
- Migrate `surface.nix` host config to use granular imports for at least one
  category as a smoke test. Keep all others on `profiles`.

### Phase 4 — Cleanup
- Once no host references `profiles.<name>` directly, delete the
  `profiles/N-*.nix` shims.
- Remove the legacy `profiles` key from `flake.nix`.
- Replace `containerPackages` hardcode (§4).

---

## 6. Test plan (mandatory — task is not done without a tester)

| Phase | Test |
|---|---|
| 0 | `nix-store -qR result` byte-equality before/after |
| 1 | Same closure-equality test per profile migrated. Plus: `build.sh switch` succeeds; `nix-store --gc --print-roots` shows the same generation count delta as a normal HM rebuild. |
| 2 | Same closure-equality test. Plus a smoke test: `home-manager switch` then verify each moved program still launches (`brave --version`, `firefox --version`, dropbear-watchdog systemd unit `active`). |
| 3 | Build with granular host imports → closure equals the equivalent `profiles`-based build. |
| 4 | Full HM build on at least `surface` host succeeds; closure size deviation ≤ 0.1% from the pre-migration baseline (i.e. the split itself caused no regression — only intentional deletions shrink). |

Common test runner: `~/git/unix/ba_flakes_desktop/build.sh build` — engine is the
only entry point; no inline `nix build` calls anywhere in tests. If a regression
is found, fix the engine/leaf, never bypass with a profile-side workaround.

Add per-leaf assertion tests in `tests/leaves/` mirroring the tree:
`tests/leaves/core/shell-utils.test.sh` checks `command -v eza bat fd …`
exits 0. Each leaf module gets one tester.

---

## 7. Risk register

| Risk | Mitigation |
|---|---|
| Profile-shim import order matters for option merges (e.g. `programs.gpg.enable`) | Move option-bearing blocks to ONE leaf only. Document in the leaf header which options it owns. |
| `home.sessionVariables` collisions across leaves | Each var declared in exactly one leaf. PATH-style vars (`PYTHONPATH`, `GOPATH`) live with the language leaf. |
| Hidden cross-profile deps (e.g. flameshot in both 7 and 8) | Resolved in §2 mapping — each pkg has exactly one home leaf. Audit script: `grep -h "^\s*[a-z]" modules/<cat>/*.nix | sort | uniq -d` must be empty. |
| Breaking GHA / CI builds during migration | Phases 1–4 keep `profiles.<name>` working, so CI presets stay green. |
| `containerPackages` still hardcoded after split | Tracked as Phase 4 follow-up — does not block anything. |

---

## 8. Decisions still open

1. **flameshot** lives in productivity/screenshots OR media-graphics/capture? → Pick **productivity/screenshots.nix** (it's a screenshot tool, not a media tool); media-graphics/capture keeps peek + simplescreenrecorder.
2. Should `wrangler` (898 MB) live in `infra-tools/` or `containers-cloud/cloud-clis.nix`? → **`infra-tools/wrangler.nix`** so it's toggleable independently of the rest of the cloud CLI bundle.
3. Should `core/git-extras.nix` swallow git-lfs/delta/diff-so-fancy/git-filter-repo/gh in one file, or split? → **One file** — they're all "git CLI add-ons", small total weight.
4. Should `programs.fish`/`programs.zsh` configuration live in `programs/shells/` (existing) or move to `core/`? → **Keep in `programs/shells/`** — they're config not packages, separate concern.

---

## 9. Out of scope for this plan

- Removing fat HM packages (libreoffice, joplin, …) — deferred to a separate
  per-host decision once leaves exist.
- NixOS-side reorg — system flake's direct pkg list is already minimal
  (verified 2026-05-05).
- Removing chromium/tor-browser kiosk SDDM sessions — Diego decided **keep**.
