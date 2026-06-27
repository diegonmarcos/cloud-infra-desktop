# PLAN — Cloud Dialer (Fossify): "Call with WhatsApp/Telegram/Signal/Meet" — INCREMENTAL

**Fork**: `ea_cloud-comms/forks/dialer` · upstream FossifyOrg/Phone pinned `1.11.1` · appId `com.diegonmarcos.comms.dialer`
**Engine**: `ea_cloud-comms/build.sh` — patch-series: `materialize-fork dialer` (clone+pin → `git am` patches) → `build-fork dialer` (gradle `assembleFossRelease` via `nix develop`).
**Tracker**: `ea_upstreams-sources/dialer-fossify/` (gitignored). Patches land in `forks/dialer/patches/NNNN-*.patch`.

## Decisions (locked)
- VoIP data-row if available, else deep-link open, else cellular.
- Chooser on **every** call tap (Cellular is an option). *(pending final confirm — see Q at bottom)*
- Providers data-driven via bundled JSON asset. Voice-only this pass.

## Evidence (verified mimetypes)
| Provider | package | VoIP voice mimetype | deep-link |
|---|---|---|---|
| WhatsApp | `com.whatsapp` | `vnd.android.cursor.item/vnd.com.whatsapp.voip.call` | `https://wa.me/{e164_no_plus}` |
| Telegram | `org.telegram.messenger` | `vnd.android.cursor.item/vnd.org.telegram.messenger.android.call` | `tg://resolve?phone={e164_no_plus}` |
| Signal | `org.thoughtcrime.securesms` | `vnd.android.cursor.item/vnd.org.thoughtcrime.securesms.call` | — |
| Google Meet | `com.google.android.apps.tachyon` | `vnd.android.cursor.item/com.google.android.apps.tachyon.phone.audio` | — |

VoIP = `ACTION_VIEW` on `content://com.android.contacts/data/<dataId>` + `setType(mimetype)` + `setPackage(pkg)`. Deep-link = `ACTION_VIEW` on URL. Cellular = existing `startCallWithConfirmationCheck`.

## Authoring loop (per increment)
1. `./build.sh materialize-fork dialer` (first time only / to re-verify series).
2. Edit tracker, `git commit` the increment.
3. `git format-patch 1.11.1..` → copy the new `NNNN-*.patch` into `forks/dialer/patches/`.
4. **Verify**: fresh `materialize-fork dialer` → series `git am`s clean (no `.rej`); `build-fork dialer` compiles.
5. Commit the patch file(s) to the unix repo.

---

## Increments (each = one patch, applies clean + compiles before the next)

### Inc 1 — Branding (proves the pipeline) → `0001-branding-cloud-dialer.patch`
- `app/src/main/res/values/strings.xml`: `app_launcher_name` → "Cloud Dialer".
- **Verify**: materialize+am+`build-fork` → signed APK whose launcher reads "Cloud Dialer". Establishes the whole patch→build path works before any feature code.

### Inc 2 — Provider model, no UI → `0002-call-providers-model.patch`
- `app/src/main/assets/call_providers.json` — the 4 providers (id, label, package, voip_mimetype, deep_link|null). Single source of truth.
- `helpers/CallProviders.kt` — parse asset; `resolveAvailability(context, number): List<ProviderOption>`:
  contact lookup for `number` → one `ContactsContract.Data` query filtered to provider mimetypes → map provider→dataId; option kind = VoIP (dataId present) / DeepLink (deep_link!=null && pkg installed) / omitted.
- `app/src/test/.../CallProvidersTest.kt` — JVM test with a fake Data cursor (only WhatsApp row) → asserts WhatsApp=VoIP, Telegram=DeepLink-if-installed, Signal/Meet=omitted.
- **Verify**: unit test green + compile. No behavior change yet.

### Inc 3 — Chooser dialog on the dialpad button, VoIP+Cellular only → `0003-provider-chooser-dialpad.patch`
- `dialogs/CallProviderChooserDialog.kt` — bottom sheet (reuse Fossify bottom-sheet/RadioGroup pattern). Rows: "Cellular" + available VoIP providers. Pick → launch intent.
- `extensions/CallExt.kt`: `startCallWithProviderChooser(number, name)`; Cellular → existing `startCallWithConfirmationCheck`.
- Reroute **one** site: `DialpadActivity.initCall` (`:362-364`).
- strings: `call_via_cellular`, `call_with`.
- **Verify**: compile; dialpad call shows chooser; Cellular path unchanged.

### Inc 4 — Deep-link fallback → `0004-provider-chooser-deeplink.patch`
- Chooser also renders DeepLink options ("Open in WhatsApp/Telegram"); launches the URL intent.
- strings: `open_in`.
- **Verify**: compile; non-contact number to WhatsApp opens `wa.me`.

### Inc 5 — Roll out to remaining call sites → `0005-provider-chooser-all-entrypoints.patch`
- Route through `startCallWithProviderChooser`: contact tap (`DialpadActivity:341-342`), CAB `ContactsAdapter.callContact` (`:240-242`), `RecentsFragment:61` / `RecentCallsAdapter:615`.
- **Verify**: compile; chooser appears from contacts + recents.

---

## Out of scope (later)
- Video-call mimetypes; per-contact default provider memory; settings toggle to disable chooser.

## Open question for user
- Confirm chooser on **every** call vs. only on **long-press** of the call button (long-press keeps plain tap = instant cellular). Affects Inc 3/5 wiring only.
