# PLAN — Cloud-IDE Constellation

> **Status**: APPROVED ARCHITECTURE — ready for development agent
> **Architect session**: 2026-06-11
> **Sibling plan**: `PLAN_cloud-comms-constellation.md` — Cloud-IDE inherits its two owner decisions verbatim:
> 1. UI hosting = **Constellation**: minimally-forked upstream APKs + thin Cloud-IDE hub APK (NOT a merged APK, NOT WebView wrappers).
> 2. SuperApp ↔ IDE link = **AIDL bound service + ContentProvider** gated by signature-level permission (no localhost ports — same Doze/auth reasoning).
>
> Whichever constellation (Comms or IDE) is built first establishes the hub/engine pattern; the second one MUST reuse it (see §3 hub-sharing note), not re-invent it.
>
> **Owner decision (2026-06-11) — one icon + wrapper chrome** (`contract/ide-ipc-v1.json::navigation`, wired hub-side, CI-green):
> 3. **One launcher icon = the hub.** Forks ship ICON-LESS (branding patch drops `<category LAUNCHER>` and adds an `<intent-filter>` for `open_fork_action` `com.diegonmarcos.ide.action.OPEN_FORK`, signature-gated). The hub launches them by that action (`ForkLauncher`), never `getLaunchIntentForPackage` (null for icon-less apps). Keeps the constellation's clean per-app DBs while presenting the single-door mental model.
> 4. **Wrapper chrome.** Because we own every app in the tree, each injects a PERSISTENT consistency top bar (`NavBar`) with up-nav chips to its ancestors in `parent_chain` (Cloud-IDE → Cloud-SuperApp) — data-driven from the contract, baked into BuildConfig. The hub's own bar (→ Cloud-SuperApp) is live; the fork bars are the new **wrapper** fork-patch concern (see `forks/README.md`, patch concern 5).

---

## 1. Goal

Add a development/file-management app family ("Cloud-IDE") to the phone, built from full clones of three upstream FOSS apps: a code editor, a file manager, and the file manager's analysis companion. SuperApp gains a small "dev" surface (recent files, workspaces, storage summary) read from Cloud-IDE over on-device IPC — it never embeds an editor or file browser itself.

| Domain | Upstream app | Verified facts (2026-06-11) |
|---|---|---|
| Editor | Acode (`Acode-Foundation/Acode`, **MIT**, Cordova hybrid: JS 62% / Java 14% / TS 12%) | v1.12.4 released 2026-06-10 — very active, ~weekly releases. Real plugin system (JS plugins). Built-in FTP/SFTP remote file access. |
| Files | Amaze File Manager (`TeamAmaze/AmazeFileManager`, **GPLv3+**, Kotlin 51% / Java 49%, Gradle) | v3.11.2 (2025-12-28), actively maintained. Tabs, archive, encryption, root explorer; cloud via separate plugin. |
| Utils | Amaze File Utilities (`TeamAmaze/AmazeFileUtilities`, **GPLv3**, Kotlin 94%, Gradle, already contains AIDL) | v1.94 (2024-07-17) — slow-moving/near-dormant upstream. Storage analysis, media players, document viewer, trash bin, WiFi-P2P transfer. Designed by the same team as FM's companion app. |

Unlike Cloud-Comms there are **no server-side sync engines** — the shared resource is the **local filesystem** (a common workspace tree) plus remote dev endpoints we already run:
- `git.diegonmarcos.com` (gitea) — git remotes over HTTPS :443 (public).
- SFTP to the 4 VMs — **WireGuard-only** (`10.0.0.x:22`; public surface is 443+51820+25, so port 22 is unreachable without the WG tunnel up on the phone).
- `ide.diegonmarcos.com` (code-server) — browser-only; hub gets a deep-link tile, nothing more.

Why constellation (re-validated for this trio): Acode is a Cordova/JS app, Amaze is native Kotlin/Java — merging them is the same dependency hell as Comms' RN+Java+Rust. License mixing (MIT + GPLv3) is avoided: each APK keeps its upstream license; hub + SuperApp stay independent. Amaze FM↔Utilities already ship as a designed two-app pair — the constellation preserves that, we just re-point their cross-app wiring.

## 2. Target architecture

```
phone (all APKs signed with the SAME key as SuperApp + Cloud-Comms)
├── cloud-superapp            com.diegonmarcos.superapp        (existing)
│     └── NEW libs:ide-client → reads hub provider; if hub absent,
│                               the dev card simply hides (no fallback engine —
│                               there is nothing to fall back to)
├── cloud-ide-hub             com.diegonmarcos.ide             (NEW, original code)
│     ├── switcher UI: 3 tiles + code-server browser deep-link tile
│     ├── broker: aggregates the 3 fork providers → ONE unified
│     │   IdeProvider (reads) + IIdeService AIDL (actions, callbacks)
│     ├── workspace owner: creates/announces the shared workspace root
│     └── updater: manages install/update of all 4 IDE APKs from GHCR
├── acode fork                com.diegonmarcos.ide.editor      (upstream + patch series)
│     └── exporter: Cordova native plugin (Java) = EditorExportProvider + AIDL stub;
│         JS-side integration shipped as a REGULAR Acode plugin (minimal native diff)
├── amaze-fm fork             com.diegonmarcos.ide.files       (upstream + patch series)
│     └── exporter patch: FilesExportProvider + AIDL stub → hub
└── amaze-utils fork          com.diegonmarcos.ide.utils       (upstream + patch series)
      └── exporter patch: UtilsExportProvider (storage analysis results) → hub

IPC security: custom permission com.diegonmarcos.ide.permission.IPC,
protectionLevel="signature" — declared by hub, required on every exported
provider/service in the forks AND on the hub surface SuperApp consumes.
```

**Shared workspace (the storage contract)**: hub declares `/storage/emulated/0/CloudIDE/` (workspaces + transfer inbox). Amaze FM/Utils request `MANAGE_EXTERNAL_STORAGE` (they are file managers; we self-distribute via GHCR, no Play policy constraint). Acode opens workspace folders via SAF/content-URIs handed over in the `openFolder` deep-link. Forks own their internal DBs (recent files, analysis results); the hub never copies data — provider queries proxy through, same as Comms.

## 3. Repo layout (in `~/git/cloud-unix/`)

```
aa_cloud-ide/                        ← NEW top-level project (sibling of aa_cloud-superapp / ea_cloud-comms)
├── build.sh                         ← universal dispatcher, same engine pattern as aa_cloud-superapp
├── build.json                       ← module graph + toolchain pins + fork pins (single source of truth)
├── flake.nix                        ← Nix devShell: JDK 17 + Gradle + AGP + Android SDK + Node/Cordova CLI (Acode)
├── contract/
│   └── ide-ipc-v1.json              ← versioned IPC contract (see §4) — SOURCE OF TRUTH
├── data/
│   └── ide-endpoints.json           ← gitea URL, per-VM SFTP (WG IPs + note "wg-only"), code-server URL, workspace root
├── hub/                             ← the hub APK (gradle project, original code)
└── forks/
    ├── acode/
    │   ├── build.json               ← { upstream_repo, pinned_tag, patches: [...] }
    │   ├── patches/                 ← numbered git patch series (the ENTIRE native fork diff)
    │   └── acode-plugin/            ← the JS-side Acode plugin (original code, not a patch)
    ├── amaze-fm/
    │   ├── build.json
    │   └── patches/
    └── amaze-utils/
        ├── build.json
        └── patches/
```

**Declarative fork rule (non-negotiable, same as Comms)**: a fork is *never* a long-lived divergent clone. It is `pinned upstream tag + committed patch series`, materialized by the engine at build time into gitignored working clones under `aa_upstreams-sources/` (`ide-acode/`, `files-amaze/`, `files-amaze-utils/`). Same input → same APK. Upstream bump = edit `pinned_tag`, re-apply patches, fix rejects, commit.

**Gitignore change required** (`~/git/cloud-unix/0_git/src/gitignore`, source of `.gitignore`): add `!aa_cloud-ide/` + `!aa_cloud-ide/**` exceptions following the documented `aa_cloud-superapp` precedent (lines 71–76) — **Phase 0, first commit**, or all work is silently untracked.

**Signing**: the SAME key as SuperApp + Cloud-Comms (one signature-permission family across both constellations). Key material in `~/git/cloud-vault/A0_keys/providers/system/` (vault carve-out); CI consumption via sops `src/secrets.yaml` in `aa_cloud-ide/`. If Cloud-Comms Phase 0 already generated this key, REUSE it — do not mint a second one.

**Hub sharing**: the hub APK is structurally identical to cloud-comms-hub (switcher + broker + updater, only the contract differs). If comms-hub exists when this plan executes, extract its broker/updater into a shared gradle module (e.g. `ea_cloud-comms/hub-core/` consumed by both hubs, or a sibling `ea_constellation-hub-core/`) instead of copy-pasting. If IDE goes first, build hub with that extraction in mind. Dev agent documents the choice in `hub/README.md`.

## 4. IPC contract (`contract/ide-ipc-v1.json`)

Data-driven: the JSON file is the source of truth; Kotlin/Java constants in hub + SuperApp + exporters mirror it; the Phase-5 conformance tester validates every implementation against the JSON.

```jsonc
{
  "version": 1,
  "authority": "com.diegonmarcos.ide.provider",
  "permission": "com.diegonmarcos.ide.permission.IPC",
  "tables": {
    "workspaces":      ["domain", "workspace_id", "name", "root_uri", "kind", "last_opened_ts"],
    "recent_files":    ["domain", "workspace_id", "file_uri", "display_name", "mime", "last_opened_ts"],
    "git_repos":       ["workspace_id", "remote_url", "branch", "dirty", "ahead", "behind", "last_fetch_ts"],
    "storage_summary": ["volume", "total_bytes", "used_bytes", "junk_bytes", "duplicate_bytes", "scanned_ts"],
    "transfers":       ["transfer_id", "direction", "peer", "file_uri", "state", "bytes_done", "bytes_total"]
  },
  "domains": ["editor", "files", "utils"],
  "aidl": {
    "service": "com.diegonmarcos.ide.IIdeService",
    "actions": ["openFile(file_uri)",
                 "openWorkspace(workspace_id)",
                 "revealInFiles(file_uri)",
                 "analyzeStorage(volume)",
                 "openRemote(endpoint_id)"],
    "callbacks": ["onRecentChanged(domain)", "onStorageScanComplete(volume)", "onTransferStateChanged(transfer_id)"]
  }
}
```

Fork exporters implement the table shapes they own under their own authorities (`…ide.editor.provider` → workspaces/recent_files/git_repos; `…ide.files.provider` → recent_files/transfers; `…ide.utils.provider` → storage_summary); the hub re-exposes the union under the single authority above. URIs and metadata only — file *content* never crosses the contract; `openFile`/`revealInFiles` deep-link into the owning app (same "preview only, deep-link for full content" principle as Comms).

## 5. Phases (each phase ends with its tester — FIRE rule 5)

### Phase 0 — Scaffold + contract + keys
- gitignore exceptions (see §3) — **first commit**.
- `aa_cloud-ide/` skeleton: build.sh / build.json / flake.nix (copy engine pattern from `aa_cloud-superapp`; devShell adds nodejs + Cordova CLI for the Acode fork).
- `contract/ide-ipc-v1.json` + `data/ide-endpoints.json` (gitea HTTPS, 4× SFTP-over-WG entries flagged `"wg_only": true`, code-server URL, workspace root path).
- Signing key: reuse the constellation key if Cloud-Comms already created it; otherwise generate, store in vault, wire sops.
- Two design assumptions PRE-VERIFIED at architecture time (2026-06-11) — dev agent confirms versions at the pinned tags, does not re-investigate from scratch:
  - **Cordova can host the provider/AIDL natively**: Cordova plugins inject manifest components via `<config-file target="AndroidManifest.xml" parent="/*">` in `plugin.xml` (a generic `cordova-ContentProviderPlugin` precedent exists). The Acode exporter is therefore one Cordova plugin declaring `<provider>` + `<service>` — confirmed viable, not a spike.
  - **Amaze FM↔Utils cross-package coupling is small and located** (at `release/4.0`): FM→Utils is `AboutActivity.java` `PACKAGE_AMAZE_UTILS = "com.amaze.fileutilities"` (launch constant); Utils→FM is the namespaced intent-extra key `com.amaze.fileutilities.AFM_LOCATE_FILE_NAME` read in `MainActivity.java`. Both must be renamed symmetrically across the FM and Utils forks (§2a/2b). Dev agent re-greps both forks at their pinned tags for any additional refs before finalizing the rename patch.
- **Tester**: `./build.sh build hub` produces an installable empty-shell APK from a clean clone; JSON files validate against a checked-in JSON Schema; `git status` shows everything tracked.

### Phase 1 — Hub APK
- Switcher UI (3 tiles + code-server browser tile + last-state quick switch), broker (ContentProvider proxy + `IIdeService` AIDL dispatching to fork services), signature permission declaration, workspace-root creation/announcement, graceful "fork not installed" states.
- Hub-managed updater for the 4 IDE APKs via GHCR OCI HTTP API — reuse (or share, §3) the comms-hub/SuperApp `libs:updater` flow; all knobs in `build.json`, no hardcoded URLs.
- **Tester**: instrumented tests — provider returns empty-but-well-formed cursors per contract; an APK signed with a *different* key gets `SecurityException` on query (permission enforcement proof).

### Phase 2a — Amaze File Manager fork (first: native Kotlin/Java, core of the file domain)
- Pin v3.11.2 (or latest stable). Patch series: applicationId/branding → `com.diegonmarcos.ide.files`; re-point the Utilities launch constant `AboutActivity.PACKAGE_AMAZE_UTILS` → `com.diegonmarcos.ide.utils`; default bookmarks/shortcuts from `ide-endpoints.json` (workspace root + SFTP entries); exporter (FilesExportProvider + AIDL stub per contract); "switch app" entry → hub deep link.
- **Tester**: (a) CI: clean clone at pin + patch series applies with zero fuzz; (b) instrumented: `recent_files` provider rows match files actually opened in a scripted session; (c) e2e: SFTP bookmark connects to `10.0.0.6:22` with WG up, fails cleanly with WG down.

### Phase 2b — Amaze File Utilities fork (second: smallest diff, must follow FM for the pairing patches)
- Pin v1.94. Patches: applicationId → `com.diegonmarcos.ide.utils`; re-namespace the FM-targeted intent-extra key `com.amaze.fileutilities.AFM_LOCATE_FILE_NAME` → `com.diegonmarcos.ide.utils.AFM_LOCATE_FILE_NAME` (must match the FM fork's `MainActivity` reader from §2a — this is the pairing patch); exporter (UtilsExportProvider: storage_summary + transfers).
- Honest note: upstream is near-dormant (last release 2024-07) — drift cost ≈ zero, but expect no upstream fixes either; treat it as the most "owned" of the three forks.
- **Tester**: patch-applies-clean CI; `storage_summary` parity vs the app's own UI numbers after a scan; FM "Analyse" entry launches our Utils fork (pairing proof).

### Phase 2c — Acode fork (last: fastest-moving upstream ~weekly — land it once the patch pipeline is proven)
- Pin latest stable tag. Native patch series kept MINIMAL: applicationId/branding → `com.diegonmarcos.ide.editor`; one Cordova plugin (Java) providing EditorExportProvider + AIDL stub + deep-link intents. Everything else (recent-file reporting, workspace registration, hub switcher entry, gitea remote presets) lives in `forks/acode/acode-plugin/` as a normal Acode JS plugin bundled at build time — JS plugins ride upstream updates for free.
- Built-in SFTP gets per-VM presets from `ide-endpoints.json` (wg_only flag surfaced in the UI string). Git workflow: evaluate the existing Acode git/SSH plugin ecosystem first (e.g. `acode.ssh.client`); only write our own plugin if nothing fits — document the choice.
- **Tester**: patch-applies-clean CI; instrumented: opening a file in Acode appears in hub `recent_files` within 5s; `openFile()` via AIDL opens the right buffer; SFTP preset connects over WG.

### Phase 3 — SuperApp consumption
- In `aa_cloud-superapp`: new `libs:ide-client` (mirror the CommsDataSource pattern) that queries the hub provider + binds the AIDL service; a "dev card" surface — recent files, workspaces with git dirty/ahead markers, storage summary, tap-through deep links. **No fallback engine**: hub absent → card hides. SuperApp must never hard-depend on Cloud-IDE.
- **Tester**: instrumented — card renders counts matching provider cursors; uninstalling hub at runtime hides the card without crash.

### Phase 4 — Distribution
- `./build.sh ship` per app → GHCR OCI artifacts (same flow as SuperApp/Comms updater); hub updater drives the fleet on-device.
- **Tester**: bump a fork `version_code`, push to GHCR, hub detects + offers update.

### Phase 5 — Upstream-sync drill + conformance
- Conformance tester: one instrumented suite, driven by `contract/ide-ipc-v1.json`, run against all three exporters + the hub surface.
- Sync drill: bump each fork's `pinned_tag` by one upstream release (Acode is the real test — weekly cadence), re-apply patches, record cost in `forks/<x>/SYNC_LOG.md`. Add scheduled CI `fork-sync-check` (weekly) dry-running patch application against upstream HEAD; share the job pattern with Cloud-Comms' identical check.
- **Tester**: the drill itself + green conformance suite is the acceptance gate.

## 6. Risks / honest notes for the dev agent

| Risk | Mitigation |
|---|---|
| Acode's ~weekly release cadence → patch drift | Keep the native diff to applicationId + one Cordova plugin; ALL behavior in the bundled JS plugin (plugin API is stable across releases). Weekly `fork-sync-check`. |
| Cordova plugin hosting a ContentProvider/AIDL service | PRE-VERIFIED viable: `<config-file target="AndroidManifest.xml">` in `plugin.xml` injects `<provider>`/`<service>` (generic `cordova-ContentProviderPlugin` precedent). Dev agent only confirms at the pinned Acode tag. |
| Scoped storage: three apps sharing one workspace tree | FM/Utils use `MANAGE_EXTERNAL_STORAGE` (self-distributed, no Play policy); Acode gets SAF grants via hub deep-links. The workspace root + URI-grant flow is part of the Phase 1 hub tester, not an afterthought. |
| Amaze FM↔Utils hardcoded cross-package references break on rename | PRE-LOCATED (§0): FM `AboutActivity.PACKAGE_AMAZE_UTILS` + Utils `…AFM_LOCATE_FILE_NAME` intent key. Patched symmetrically in 2a/2b; pairing proof in the 2b tester; dev agent re-greps both forks at pin for stragglers. |
| Amaze Utilities upstream near-dormant | Accept: lowest drift cost; we effectively own it. If it dies entirely, its features (storage analysis) are the easiest to absorb into FM later. |
| SFTP unreachable without WG | `wg_only` flag in `ide-endpoints.json` surfaced in every preset UI; testers cover both WG-up and WG-down paths. Never "fix" by opening port 22 publicly. |
| Hub duplication vs cloud-comms-hub | §3 hub-sharing rule: extract or build-for-extraction; the second constellation to land MUST consume the shared module. |

## 7. Out of scope

- Replacing or self-hosting changes to code-server (`ide.diegonmarcos.com`) — browser deep-link only.
- A Termux/terminal app fork (Acode's built-in/plugin terminal is what we get; revisit only with evidence of need).
- A filebrowser (`files.diegonmarcos.com`) API client in Amaze — no WebDAV upstream support; not worth a deep patch.
- Any single-APK merge of the three upstreams.
- Removing anything from SuperApp — `libs:ide-client` is additive only.
- Shipping any cloud service (gitea/code-server/filebrowser already run; no-unnecessary-deploys rule).
