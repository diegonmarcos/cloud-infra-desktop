# da_browser-qute

A *config layer* (not a fork) over upstream qutebrowser that ships as a
home-manager module. Reads four JSON files in `src/2_configs/` and projects
them into qutebrowser's declarative settings/search/keybindings/quickmarks
surface. Edit JSON, switch home-manager, browser config rewrites itself.

## Why

The Bitwarden browser extension provides two things:
1. **Password autofill** — replaced by `~/git/unix/da_autofill-rbw-rofi/`
   (system-wide hotkey → rofi/wofi picker → keystroke synth).
2. **Passkey / WebAuthn signing** — replaced by
   `~/git/unix/da_fido2-vault-broker/` (virtual FIDO2 device on /dev/uhid).

With both daemons running, the browser doesn't need an extension for either.
This project picks **qutebrowser** as the daily-driver because:
- ~50k Python LoC — small relative to Brave/Firefox
- Vim-style keybindings; tiny UI chrome
- QtWebEngine (Chromium) → FIDO2 over /dev/hidraw works natively
- Already in nixpkgs → ship via home-manager, no fork
- `programs.qutebrowser` home-manager surface lets us declare every
  setting/keybind/search-engine/quickmark as data

We don't fork. We just own the config.

## What's in this repo

```
da_browser-qute/
├── build.json                     SoT (paths, integrations, data sources)
├── build.sh                       engine: lint-json / check / print-config / diff
└── src/
    ├── flake.nix                  exposes homeManagerModules.default
    ├── 2_configs/
    │   ├── qute-settings.json     content blocking, JS, cookies, fonts, etc.
    │   ├── qute-search-engines.json   ddg / g / yt / gh / wp / nix / vault / auth / git
    │   ├── qute-keybindings.json  Ctrl-Shift-{P,U,L,O} → autofill daemon hooks
    │   └── qute-bookmarks.json    quickmarks for the diegonmarcos.com stack
    └── nix/
        └── home-module.nix        reads JSON, projects into programs.qutebrowser
```

## Operator path

In your home flake (`~/git/unix/c{a,b}_*nix*` or wherever home-manager lives):

```nix
{
  inputs.da_browser-qute.url = "path:../../da_browser-qute/src";

  outputs = { self, nixpkgs, home-manager, da_browser-qute, ... }: {
    homeConfigurations.diego = home-manager.lib.homeManagerConfiguration {
      modules = [
        da_browser-qute.homeManagerModules.default
        ({...}: {
          programs.da_browser-qute = {
            enable = true;
            defaultBrowser = true;     # xdg.mime → qutebrowser
          };
        })
      ];
    };
  };
}
```

Then:

```bash
~/git/unix/cb_user_diego_nix/build.sh switch    # or wherever home-manager is
qutebrowser                                     # daily-driver running
```

## Editing the config

```bash
$EDITOR ~/git/unix/da_browser-qute/src/2_configs/qute-search-engines.json
~/git/unix/da_browser-qute/build.sh check       # validate JSON + nix eval
~/git/unix/cb_user_diego_nix/build.sh switch    # apply
# qutebrowser already running picks up new config on next config-source
```

## Daemon integration

| Daemon | Browser interaction |
|---|---|
| `da_fido2-vault-broker` | Passive — qutebrowser/Chromium discovers /dev/hidraw5 (FIDO2 VID `F1D0`) automatically when WebAuthn is invoked. Zero browser config. |
| `da_autofill-rbw-rofi` | Active — keybindings `Ctrl-Shift-{P,U,L,O}` (in `qute-keybindings.json`) fire the daemon directly from a qutebrowser focus context, on top of the global system-wide hotkey. |

## Status

- ✅ Scaffold + JSON SoT
- ✅ home-manager module (reads JSON, projects to `programs.qutebrowser`)
- ⏳ Wire into the actual home-manager flake (`cb_user_diego_nix` or equivalent) — not done yet
- ⏳ Theme / colors block (currently empty placeholder in qute-settings.json)
- ⏳ Userscript dir for advanced integrations (e.g. fire `da_fido2-vault-broker` admin commands from the browser)

## Why not fork qutebrowser

Upstream qutebrowser is already minimal and the home-manager surface is rich
enough that "what we'd customise in a fork" is reachable through pure config.
Forking would mean tracking upstream + maintaining patches. Not worth it.

If you ever want a *new* browser engine: see Servo (Rust, research-grade) or
Ladybird (C++, pre-alpha). Both are 5+ year projects. This is not that.
