# Cloud-Comms forks

Each fork is **declarative**: a pinned upstream tag + a committed patch series.
It is *never* a long-lived divergent clone.

The canonical registry — upstream repo, tracker dir, pinned tag, app id, blocked
state — lives in **`../build.json::forks`** (single source of truth; do not
duplicate it here). Each `forks/<key>/` directory holds only:

- `patches/NNNN-*.patch` — the entire fork diff as a `git am`-applicable series,
  in lexical order. Empty = a pure upstream checkout (valid during scaffolding).
- `SYNC_LOG.md` — one line per upstream bump recording the cost of re-applying.

## Lifecycle

```bash
# 1. Pin a tag in build.json::forks.<key>.pinned_tag, then:
./build.sh materialize-fork mail     # clone@tag → ea_mail-fairmail/ + apply patches
# 2. Hack in the materialized tracker clone, then export the diff back as patches:
git -C ../ea_mail-fairmail format-patch <upstream-tag> -o forks/mail/patches
# 3. Build:
./build.sh build-fork mail
```

## The patch concerns (keep them as SEPARATE numbered patches)

Minimal + orthogonal patches survive upstream churn. Every fork's series should
factor into at most these:

1. **branding** — applicationId → `com.diegonmarcos.comms.<domain>`, app name.
2. **icon-less + open-action** (the one-icon model — owner decision 2026-06-11):
   - REMOVE the `<category android:name="android.intent.category.LAUNCHER" />`
     from the fork's main activity so the fork has **no home-screen icon**. The
     Cloud-Comms hub is the only icon; it's the single door to all three forks.
   - ADD an exported, signature-permission-gated `<intent-filter>` for the
     action `contract::launch_action` (`com.diegonmarcos.comms.action.OPEN`) on
     that same activity, reading the optional `com.diegonmarcos.comms.extra.THREAD_ID`
     extra for deep-linking a conversation. This is how the hub / SuperApp open
     the icon-less fork (`Intent(OPEN).setPackage(<fork app id>)`).
3. **provisioning** — lock/pre-fill the server from `data/comms-endpoints.json`.
4. **exporter** — the `<domain>` ContentProvider + `ICommsService` stub that
   implements `contract/comms-ipc-v1.json` under `com.diegonmarcos.comms.<domain>.provider`.
5. **constellation chrome** (the wrapper top bar — owner decision 2026-06-11):
   inject a **permanent** top bar above the fork's own UI rendering
   `[↑ Cloud-SuperApp][↑ Cloud-Comms]` (every `data/constellation-chrome.json::chain`
   entry that isn't this fork), so the hierarchy
   `Cloud-SuperApp ▸ Cloud-Comms ▸ {Mail,Mattermost,Element}` feels like ONE
   owned product. Port the hub's reference builder
   `hub/src/main/java/com/diegonmarcos/comms/ConstellationBar.kt` verbatim and
   ship `constellation-chrome.json` in the fork's assets (the fork can't depend
   on the hub APK's code). Tapping a button opens that ancestor app. The bar
   must stay visible while using the fork — pin it, don't let the fork's scroll
   cover it.

## Materialized tracker dirs (gitignored)

| key | tracker dir | upstream | runtime |
|-----|-------------|----------|---------|
| mail | `ea_mail-fairmail/` (shared with ea_cloud-superapp) | FairEmail (GPL-3.0) | native Java |
| chat | `ea_chat-mattermost/` | mattermost-mobile (Apache-2.0) | React Native |
| matrix | `ea_chat-element/` | element-x-android (AGPL-3.0) | Kotlin + Rust SDK |

All three match the `ea_*-*/` gitignore rule and are never committed — only the
patch series under `forks/` is version-controlled.
