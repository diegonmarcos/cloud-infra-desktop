# Cloud-Comms

A **constellation** of three minimally-forked upstream communication apps plus a
thin original **hub** APK. The hub switches between the forks and brokers their
data to [Cloud-SuperApp](../ea_cloud-superapp/) over signature-gated IPC, so
SuperApp keeps showing mail/chat data while the *engines* live in the forks.

```
ea_cloud-comms/
├── build.sh            ← universal dispatcher (build/verify-contract/materialize-fork/…)
├── build.json          ← data-driven: module graph + toolchain + FORK REGISTRY + IPC
├── flake.nix           ← Nix devShell: JDK 17 + Gradle + AGP + Android SDK + Node (RN fork)
├── settings.gradle     ← mirrors build.json::modules (hub only)
├── contract/
│   ├── comms-ipc-v1.json         ← THE IPC contract (tables + AIDL) — source of truth
│   └── comms-ipc-v1.schema.json  ← JSON Schema; `./build.sh verify-contract`
├── data/
│   └── comms-endpoints.json      ← per-domain server endpoints (no secrets)
├── hub/                ← the hub APK (original code): switcher + CommsProvider + CommsService
└── forks/
    ├── mail/    (FairEmail, GPL-3.0, native Java)        — patches + docs
    ├── chat/    (Mattermost mobile, Apache-2.0, RN)      — patches + docs
    └── matrix/  (Element X, AGPL-3.0, Kotlin+Rust SDK)   — patches + docs [BLOCKED]
```

## Architecture

Five APKs, **all signed with one key** (the IPC permission is
`protectionLevel="signature"`):

| APK | id | role |
|-----|-----|------|
| hub | `com.diegonmarcos.comms` | switcher + unified `CommsProvider` (reads) + `ICommsService` (AIDL actions/push) |
| mail fork | `com.diegonmarcos.comms.mail` | FairEmail + exporter → hub |
| chat fork | `com.diegonmarcos.comms.chat` | Mattermost + exporter → hub |
| matrix fork | `com.diegonmarcos.comms.matrix` | Element X + exporter → hub |
| SuperApp | `com.diegonmarcos.superapp` | consumes the hub surface (with direct-client fallback) |

Forks own their sync engines and local DBs; the hub never copies data — it
proxies queries to the per-fork exporter providers and UNIONs them. Only body
*previews* cross the boundary; full content is reached via `openInApp` deep links.

### Delivery: one download, embedded-installer (owner decision 2026-06-11)

The three forks are **separate APKs** (separate DBs, independent upstream sync)
but ship as **ONE download**: `build.sh bundle-forks` embeds each published fork
APK into `hub/src/main/assets/forks/<domain>.apk`, so the single Cloud-Comms hub
APK physically carries them. On first launch the hub installs them via
PackageInstaller (`BundledForkInstaller`) — Android's no-root model shows one
confirmation per fork, once. After setup you see **one icon** (the forks are
launcher-icon-less) with the wrapper top bar. The embedded copies are gitignored
build artifacts (seeded at build time, never committed); the `FleetUpdater` keeps
each fork current from GHCR afterwards.

## Build

```bash
./build.sh shell             # enter Nix devShell
./build.sh verify-contract   # validate the IPC contract (Phase-0 gate)
./build.sh build             # hub debug APK → dist/cloud-comms-hub-debug.apk
./build.sh materialize-fork mail   # clone FairEmail@pin → tracker + apply patches
./build.sh build-fork mail         # build the materialized fork
```

## Status — Phase 0/1 scaffold

- **Done**: project scaffold, IPC contract + schema + validator, hub APK
  (switcher UI, signature-gated `CommsProvider` + `ICommsService`, data-driven
  fork registry), declarative fork structure, instrumented tests.
- **Next**: pin + materialize + patch the **mail** fork first (live server,
  pure Java); then **chat** (after the push-notification decision); **matrix**
  is **blocked** until the Matrix cloud stack ships.
- **SuperApp wiring** (`CommsDataSource` + fallback) is Phase 3 — additive, does
  not touch SuperApp until the forks prove out.

Full plan + decisions: [`../0_tasks/PLAN_cloud-comms-constellation.md`](../0_tasks/PLAN_cloud-comms-constellation.md).

## License

Each fork keeps its upstream license (GPL-3.0 / Apache-2.0 / AGPL-3.0); they are
separate APKs, so no license mixing. The hub is original code.
