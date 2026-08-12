# Licensing

The original code in this repository is licensed under the **PolyForm
Noncommercial License 1.0.0** (see [`LICENSE`](./LICENSE)). SPDX:
`PolyForm-Noncommercial-1.0.0`.

**Plain English:** free to use, copy, modify, and share for any **noncommercial**
purpose; **commercial use is not granted** without a separate license. This is a
**source-available** license, not OSI "open source" / FSF "free software".

## What the root license covers

All the licensor's own work: the NixOS host + home-manager flakes, bootloader
engine, `9_others/`, the Cloud-SuperApp **app** (`ea_cloud-superapp/`), and
the Cloud-Comms / Cloud-IDE **hubs** + scaffolding (their `build.sh`,
`build.json`, `contract/`, original `hub/` code).

> **Note on `ea_cloud-superapp`:** this APK contains **no copied GPL source** —
> its modules (`libs/mail`, `libs/chat`, `libs/kde-connect`, …) are original
> code that reaches the separate fork apps over **IPC** (AIDL / ContentProvider).
> Because nothing GPL is linked in-process, the SuperApp is the licensor's own
> work and is covered by the noncommercial license. **This holds only while no
> GPL/AGPL upstream is vendored in-process.** If a `libs:*` module ever embeds
> GPL source directly (e.g. a full in-process vendor of kdeconnect-android),
> that APK becomes (A)GPL and leaves the noncommercial license automatically.

## Carve-outs — inherited copyleft that MUST stay (not relicensed)

The FOSS-app forks are **separate APKs**; their source derives from copyleft
upstreams and is governed by those upstreams' licenses, **never** by the root
`LICENSE`:

| Path | SPDX | Upstream |
|------|------|----------|
| `ea_cloud-comms/forks/mail/**`   | `GPL-3.0-or-later`  | FairEmail (eu.faircode.email) |
| `ea_cloud-comms/forks/chat/**`   | `Apache-2.0`        | Mattermost mobile |
| `ea_cloud-comms/forks/matrix/**` | `AGPL-3.0-or-later` | Element X Android |
| `ea_cloud-ide/forks/files/**`    | `GPL-3.0-or-later`  | Amaze File Manager |
| `ea_cloud-ide/forks/utils/**`    | `GPL-3.0-or-later`  | Amaze File Utilities |
| `ea_cloud-ide/forks/editor/**`   | `MIT`               | Acode |
| materialized tracker clones `ea_*-*/` (gitignored), `ea_upstreams-sources/**` | per-upstream | Build-time checkouts of the above upstreams |

The committed `forks/<x>/patches/` are **derivative works** of those upstreams
and inherit the upstream license (see each `forks/LICENSE`). The **built fork
APKs** ship under (A)GPL/Apache/MIT accordingly — which, for the GPL/AGPL ones,
means they remain FOSS and *may* be used commercially per those licenses. That
is an unavoidable consequence of forking copyleft software and cannot be
overridden by this repository's noncommercial license.

Contact for commercial licensing of the *original* parts: Diego Nepomuceno
Marcos — <https://diegonmarcos.com>.

> Not legal advice.
