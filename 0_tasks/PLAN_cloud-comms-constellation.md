# PLAN — Cloud-Comms Constellation

> **Status**: APPROVED ARCHITECTURE — ready for development agent
> **Architect session**: 2026-06-11
> **Owner decisions** (Diego, 2026-06-11):
> 1. UI hosting = **Constellation**: 3 minimally-forked upstream APKs + thin Cloud-Comms hub APK (NOT a single merged APK, NOT WebView wrappers).
> 2. SuperApp ↔ Comms link = **AIDL bound service + ContentProvider** gated by signature-level permission (NOT localhost websockets — Doze kills background servers, ports need their own auth; AIDL/Provider survives the OS lifecycle with zero open ports).

---

## 1. Goal

Move the mail/chat **engines** out of `ea_cloud-superapp` into a parallel app family ("Cloud-Comms") built from full clones of three upstream FOSS apps, each pointed at our own servers (all three server DBs already self-hosted). SuperApp keeps showing the same mail/chat data it shows today (`libs:mail` JMAP summary, `libs:chat` Mattermost summary) but reads it from Cloud-Comms over on-device IPC instead of running its own thin sync clients.

| Domain | Upstream app | Server (already ours) |
|---|---|---|
| Mail | FairEmail (`M66B/FairEmail`, GPLv3, Java) | Maddy + Stalwart on oci-mail (`imap.`/`smtps.diegonmarcos.com` **via SNI on :443**, JMAP on `jmap.`) |
| Chat (team) | Mattermost mobile (`mattermost/mattermost-mobile`, Apache-2.0, **React Native**) | `chat.diegonmarcos.com` on oci-apps |
| Chat (Matrix) | Element X Android (`element-hq/element-x-android`, AGPL-3.0, Kotlin + Rust matrix-sdk FFI) | continuwuity + mautrix-whatsapp + Element Web — **merged to main 2026-06-10 but NOT SHIPPED** (hard prereq for Phase 2c) |

Why constellation won over merge/WebView:
- Mattermost mobile is React Native — merging an RN runtime + FairEmail's ~1000-file Java monolith + Element X's Rust FFI into one APK is manifest-merge/dependency hell and a permanent three-front merge war.
- Near-zero-diff forks keep upstream sync almost free (the whole point of abandoning the cherry-pick strategy).
- Clean licensing: each APK keeps its upstream license (GPLv3 / Apache-2.0 / AGPL-3.0); hub + SuperApp stay independent. No license mixing.
- Trade-off accepted by owner: switching between apps shows Android task animations — "seamless" is hub-deep-link quality, not in-app-tab quality.

## 2. Target architecture

```
phone (all 5 APKs signed with the SAME key)
├── cloud-superapp            com.diegonmarcos.superapp        (existing)
│     └── libs:mail / libs:chat → CommsDataSource ──┐ (reads hub provider,
│                                                   │  falls back to direct
│                                                   │  JMAP/REST when hub absent)
├── cloud-comms-hub           com.diegonmarcos.comms           (NEW, original code)
│     ├── switcher UI: launcher tiles + deep links into the 3 forks
│     ├── broker: aggregates the 3 fork providers → ONE unified
│     │   CommsProvider (reads) + ICommsService AIDL (actions, push callbacks)
│     └── updater: manages install/update of all 4 comms APKs from GHCR
├── fairemail fork            com.diegonmarcos.comms.mail      (upstream + patch series)
│     └── exporter patch: MailExportProvider + AIDL stub  → hub
├── mattermost fork           com.diegonmarcos.comms.chat      (upstream + patch series)
│     └── exporter patch: native Kotlin module ChatExportProvider → hub
└── element-x fork            com.diegonmarcos.comms.matrix    (upstream + patch series)
      └── exporter patch: MatrixExportProvider (reads via the app's
          Rust-SDK Kotlin bindings layer, NOT raw sqlite) → hub

IPC security: custom permission com.diegonmarcos.comms.permission.IPC,
protectionLevel="signature" — declared by hub, required on every exported
provider/service in the forks AND on the hub surface SuperApp consumes.
```

Data flow: forks own their sync engines and local DBs (FairEmail Room/SQLite, Mattermost WatermelonDB, Element X Rust SDK store). Hub never copies data — it proxies queries through to fork providers and merges results. SuperApp talks ONLY to the hub surface.

## 3. Repo layout (in `~/git/unix/`)

```
ea_cloud-comms/                      ← NEW top-level project (sibling of ea_cloud-superapp)
├── build.sh                         ← universal dispatcher, same engine pattern as ea_cloud-superapp
├── build.json                       ← module graph + toolchain pins + fork pins (single source of truth)
├── flake.nix                        ← Nix devShell: JDK 17 + Gradle + AGP + Android SDK + Node (for RN fork)
├── contract/
│   └── comms-ipc-v1.json            ← versioned IPC contract (see §4) — SOURCE OF TRUTH
├── data/
│   └── comms-endpoints.json         ← server endpoints per domain (mail SNI hosts, chat URL, homeserver URL)
├── hub/                             ← the hub APK (gradle project, original code)
└── forks/
    ├── fairemail/
    │   ├── build.json               ← { upstream_repo, pinned_tag, patches: [...] }
    │   └── patches/                 ← numbered git patch series (the ENTIRE fork diff)
    ├── mattermost/
    │   ├── build.json
    │   └── patches/
    └── element-x/
        ├── build.json
        └── patches/
```

**Declarative fork rule (non-negotiable)**: a fork is *never* a long-lived divergent clone. It is `pinned upstream tag + committed patch series`, materialized by the engine at build time into a gitignored working clone (`ea_chat-mattermost/`, `ea_chat-element/`; FairEmail reuses existing `ea_mail-fairmail/` — engine must check out the pin, not trust the tracker's HEAD). Same input → same APK. Upstream bump = edit `pinned_tag` in `forks/<x>/build.json`, re-apply patches, fix rejects, commit.

**Gitignore change required** (`~/git/unix/1_workflows/src/gitignore`, source of `.gitignore`): `ea_cloud-comms/` matches the `ea_*-*/` tracker pattern — add `!ea_cloud-comms/` + `!ea_cloud-comms/**` exceptions, exactly following the documented `ea_cloud-superapp` precedent at lines 71–76. Do this in **Phase 0, first commit**, or all work is silently untracked.

**Signing**: one upload/signing key for all comms APKs + SuperApp (signature permission requires it). Key material lives in `~/git/vault/A0_keys/providers/system/` (vault carve-out); CI consumption via sops `src/secrets.yaml` in `ea_cloud-comms/`. NOTE: SuperApp's current signing config must be checked — if it ships with a different key today, plan a coordinated re-sign (uninstall/reinstall on device) at Phase 3.

## 4. IPC contract (`contract/comms-ipc-v1.json`)

Data-driven: the JSON file is the source of truth; Kotlin constants in hub + SuperApp + exporter patches mirror it; the Phase-5 conformance tester validates every implementation against the JSON.

```jsonc
{
  "version": 1,
  "authority": "com.diegonmarcos.comms.provider",
  "permission": "com.diegonmarcos.comms.permission.IPC",
  "tables": {
    "accounts":   ["domain", "account_id", "display_name", "server", "state", "last_sync_ts"],
    "summary":    ["domain", "account_id", "unread_count", "total_count", "updated_ts"],
    "threads":    ["domain", "account_id", "thread_id", "title", "snippet", "unread", "ts"],
    "messages":   ["domain", "account_id", "thread_id", "message_id", "sender", "body_preview", "ts", "flags"]
  },
  "domains": ["mail", "chat", "matrix"],
  "aidl": {
    "service": "com.diegonmarcos.comms.ICommsService",
    "actions": ["send(domain, account_id, thread_id, body)",
                 "markRead(domain, account_id, thread_id)",
                 "openInApp(domain, thread_id)",
                 "forceSync(domain)"],
    "callbacks": ["onNewMessage(domain, thread_id)", "onSyncStateChanged(domain, state)"]
  }
}
```

Fork exporters implement the same table shapes under their own authorities (`…comms.mail.provider`, etc.); the hub re-exposes the union under the single authority above. `body_preview` only — full bodies stay in the owning app; `openInApp` deep-links for full content (keeps the contract small and avoids re-implementing renderers in SuperApp).

## 5. Phases (each phase ends with its tester — FIRE rule 5)

### Phase 0 — Scaffold + contract + keys
- gitignore exceptions (see §3) — **first commit**.
- `ea_cloud-comms/` skeleton: build.sh / build.json / flake.nix (copy engine pattern from `ea_cloud-superapp`, add nodejs for the RN fork's devShell).
- `contract/comms-ipc-v1.json` + `data/comms-endpoints.json` (mail = `imap.diegonmarcos.com:443` + `smtps.diegonmarcos.com:443` implicit-TLS-with-SNI, jmap host; chat = `https://chat.diegonmarcos.com`; matrix = homeserver URL once shipped).
- Signing key: generate, store in vault, wire sops.
- **Tester**: `./build.sh build hub` produces an installable empty-shell APK from a clean clone; JSON files validate against a checked-in JSON Schema; `git status` shows everything tracked.

### Phase 1 — Hub APK
- Switcher UI (3 tiles + last-state quick switch), broker (ContentProvider proxy + `ICommsService` AIDL dispatching to fork services), `protectionLevel="signature"` permission declaration, graceful "fork not installed" states.
- Hub-managed updater for the 4 comms APKs via GHCR OCI HTTP API — reuse the exact flow of SuperApp `libs:updater` (see its build.json comment); all knobs in `build.json`, no hardcoded URLs.
- **Tester**: instrumented tests — provider returns empty-but-well-formed cursors per contract; an APK signed with a *different* key gets `SecurityException` on query (permission enforcement proof).

### Phase 2a — FairEmail fork (do this one first: Java, no RN/Rust, mail server live)
- Pin latest stable upstream tag. Patch series: applicationId/branding → `com.diegonmarcos.comms.mail`; pre-provisioned account profile from `comms-endpoints.json` (FairEmail supports custom host:port with implicit TLS — :443 SNI works); exporter module (provider + AIDL stub per contract); "switch app" entry → hub deep link.
- **Tester**: (a) CI: clean clone at pin + patch series applies with zero fuzz; (b) instrumented: provider `summary.unread_count` equals IMAP STATUS unread for the test account; (c) e2e: `send()` via AIDL → message lands in Maddy (verify via existing `services_email_imap_*` tooling).

### Phase 2b — Mattermost fork
- Pin upstream tag. Patches: applicationId → `com.diegonmarcos.comms.chat`; default/locked server URL; exporter as a **native Kotlin module** (RN side untouched as far as possible — read WatermelonDB through a small native query layer, or subscribe via the app's existing native bridge).
- Open item the dev agent must resolve and document: push notifications — upstream relies on Mattermost's hosted push proxy; options are self-hosting `mattermost-push-proxy` (new cloud service, `aa-sui_` prefix) or accepting sync-on-open + ntfy. Decide with owner before building.
- **Tester**: patch-applies-clean CI check; provider unread parity vs Mattermost REST (`/api/v4/users/me/teams/unread`) for the test account.

### Phase 2c — Element X fork — **BLOCKED until the Matrix stack ships**
- Prereq: ship `continuwuity + mautrix-whatsapp + element` (cloud repo, merged 2026-06-10). Coordinate — no out-of-scope deploys beyond these three services.
- Pin upstream tag (Element X Android — classic Element Android is in maintenance; X is the survivable fork base). Patches: applicationId → `com.diegonmarcos.comms.matrix`; default homeserver; exporter reading through the Rust-SDK **Kotlin bindings** (never raw store files — the store format is SDK-private); push via **UnifiedPush with our ntfy** (`rss.diegonmarcos.com`) as distributor — Element X supports UnifiedPush natively, zero patch beyond default-config.
- **Tester**: patch-applies-clean CI; provider room list + unread parity vs client-server `/sync` for the test account.

### Phase 3 — SuperApp consumption
- In `ea_cloud-superapp`: add `CommsDataSource` to `libs:core` (or a new `libs:comms-client`) that queries the hub provider + binds the AIDL service; refactor `libs:mail` (10 files) and `libs:chat` (5 files) UIs to read it. **Keep the existing JMAP/Mattermost clients as automatic fallback** when the hub isn't installed — SuperApp must never hard-depend on Cloud-Comms.
- Matrix gets its first SuperApp surface (chat tab section) via the same data source.
- **Tester**: instrumented A/B — same screen renders identical counts in hub-mode vs fallback-mode; uninstalling hub at runtime degrades gracefully (no crash, fallback engages).

### Phase 4 — Distribution
- `./build.sh ship` per app → GHCR OCI artifacts (consistent with SuperApp updater flow); hub updater drives the fleet on-device.
- **Tester**: bump a fork `version_code`, push to GHCR, hub detects + offers update.

### Phase 5 — Upstream-sync drill + conformance
- Conformance tester: one instrumented suite, driven by `contract/comms-ipc-v1.json`, run against all three exporters + the hub surface.
- Sync drill: bump each fork's `pinned_tag` by one upstream release, re-apply patches, record the cost in `forks/<x>/SYNC_LOG.md`. Add a scheduled CI job `fork-sync-check` (weekly) that dry-runs patch application against upstream HEAD and opens a report on drift.
- **Tester**: the drill itself + green conformance suite is the acceptance gate.

## 6. Risks / honest notes for the dev agent

| Risk | Mitigation |
|---|---|
| Mattermost exporter inside an RN app | Keep it a pure native module; if WatermelonDB internals churn, fall back to the app's own client layer events. Highest-effort fork — budget accordingly. |
| Element X Rust-SDK data access | Only via Kotlin bindings; pin SDK version with the app tag. If bindings can't express a query, expose it via a tiny patch to the bindings layer, upstream-style. |
| Patch drift over time | Patches must be minimal and orthogonal (branding / provisioning / exporter / switcher as separate numbered patches). Weekly `fork-sync-check`. |
| 3 sync engines + SuperApp on one phone (battery) | Accepted by design (fallback clients in SuperApp disable themselves when hub is present, so net engines ≈ today + Element). Revisit only with evidence. |
| Same-signing-key requirement vs SuperApp's current key | Audit in Phase 0; coordinated re-sign in Phase 3 if needed. |
| Mattermost push | Open decision (Phase 2b) — needs owner sign-off before any new cloud service. |

## 7. Out of scope

- Removing the fallback JMAP/Mattermost clients from SuperApp (only after Cloud-Comms proves itself).
- Any single-APK merge of the three upstreams.
- WhatsApp bridge UX beyond what Element shows natively via mautrix.
- Shipping any cloud service other than the already-merged Matrix stack (no-unnecessary-deploys rule).
