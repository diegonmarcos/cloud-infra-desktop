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

## The four patch concerns (keep them as SEPARATE numbered patches)

Minimal + orthogonal patches survive upstream churn. Every fork's series should
factor into at most these four:

1. **branding** — applicationId → `com.diegonmarcos.comms.<domain>`, app name/icon.
2. **provisioning** — lock/pre-fill the server from `data/comms-endpoints.json`.
3. **exporter** — the `<domain>` ContentProvider + `ICommsService` stub that
   implements `contract/comms-ipc-v1.json` under `com.diegonmarcos.comms.<domain>.provider`.
4. **switcher** — a "back to Cloud-Comms" entry that deep-links the hub.

## Materialized tracker dirs (gitignored)

| key | tracker dir | upstream | runtime |
|-----|-------------|----------|---------|
| mail | `ea_mail-fairmail/` (shared with ea_cloud-superapp) | FairEmail (GPL-3.0) | native Java |
| chat | `ea_chat-mattermost/` | mattermost-mobile (Apache-2.0) | React Native |
| matrix | `ea_chat-element/` | element-x-android (AGPL-3.0) | Kotlin + Rust SDK |

All three match the `ea_*-*/` gitignore rule and are never committed — only the
patch series under `forks/` is version-controlled.
