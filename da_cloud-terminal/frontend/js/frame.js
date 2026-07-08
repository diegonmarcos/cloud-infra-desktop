// ── Dashboard frame contract ──────────────────────────────────────────
// One shared implementation of "refresh button + auto-toggle switch +
// lazy/no-background-polling + a hung dashboard can't wedge the app" —
// previously each dashboard (Stack/Monitor/Journal/Cloud/DataSync/AGI/
// DevControl) reimplemented this by hand, which is exactly how the
// "buttons hidden in some dashboards" and "Cloud auto-probed on open and
// froze" bugs happened. Frames only describe WHAT to render; frame.js
// owns WHEN.
//
// (Classic script, not an ES module — see js/tabs.js's header comment
// for why: several shared scalars are reassigned across files, and ES
// module imported bindings are read-only.)
//
// Usage (see js/dash/journal.js for the reference conversion):
//   registerFrame({
//     type: 'journal',        // matches profile.json default_tabs type
//     title: '📜 journal',    // tab label
//     refreshMs: 5000,        // auto-refresh cadence when the toggle is on
//     autoFirstOpen: true,    // local-only data: refresh once on first build
//     make(el, ctx) { ... return api },   // build DOM once; NO fetching here
//     refresh(api, ctx) { ... },          // one refresh pass; manager-called only
//     destroy(api) { ... },               // optional cleanup beyond the timer
//   })
// Then point the profile dispatcher at it exactly like the old inline
// dashboards: `function newJournalTab(profile, activate) { return
// newSpecialTab(id => buildFrame('journal', id), '📜 journal', 'journal', profile, activate) }`

const frameDefs = new Map()
function registerFrame(def) { frameDefs.set(def.type, def) }

// A refresh that never returns (hung SSH probe, etc.) must not wedge the
// dashboard forever — race it against a timeout. refresh() can be sync or
// return a Promise; either is fine.
const FRAME_WATCHDOG_MS = 15000
function withWatchdog(fn) {
  return Promise.race([
    Promise.resolve().then(fn),
    new Promise((_, rej) => setTimeout(() => rej(new Error('refresh() timed out after 15s')), FRAME_WATCHDOG_MS)),
  ])
}

// Builds one frame instance into a fresh leaf, matching the shape
// newSpecialTab/ensureTabBuilt/panes already expect: { id, leaf }, with
// panes.set(id, {..., kind, stop}).
function buildFrame(type, tabId) {
  const def = frameDefs.get(type)
  if (!def) throw new Error('no frame registered for type: ' + type)
  const id = ++paneSeq
  const leaf = document.createElement('div')
  leaf.className = 'leaf frame-' + type
  leaf.dataset.pane = String(id)

  leaf.innerHTML = `
    <div class="frame-toolbar">
      <span class="frame-title">${def.title || type}</span>
      <span class="frame-stamp" id="frame-stamp-${id}"></span>
      <span style="flex:1"></span>
      <button class="cpbtn" id="frame-refresh-${id}">↻ refresh</button>
      <button class="auto-toggle" id="frame-auto-${id}" title="Auto-refresh (${Math.round((def.refreshMs || 5000) / 1000)}s) — off by default, only ticks while this tab is visible"><i class="sw"></i>auto</button>
    </div>
    <div class="frame-body" id="frame-body-${id}"></div>
  `
  const $ = s => leaf.querySelector(s)
  const stampEl = $('#frame-stamp-' + id)
  const bodyEl = $('#frame-body-' + id)

  // auto/isActiveTab declared before ctx so frames that live-push their own
  // updates (e.g. DevControl, driven by devctlListeners rather than a
  // polling interval) can gate that push on the same on/off + visibility
  // rules the manager's own timer already respects.
  let auto = false
  const isActiveTab = () => leaf.parentElement && leaf.parentElement.classList.contains('active')
  const ctx = { id, leaf, isAuto: () => auto, isActiveTab }
  const api = def.make(bodyEl, ctx)

  let busy = false
  const stampNow = () => { stampEl.textContent = 'as of ' + new Date().toLocaleTimeString() }

  async function doRefresh() {
    if (busy) return               // never overlap two refreshes of the same frame
    busy = true
    $('#frame-refresh-' + id).textContent = '… loading'
    try {
      await withWatchdog(() => def.refresh(api, ctx))
      stampNow()
    } catch (e) {
      bodyEl.insertAdjacentHTML('afterbegin', `<div class="frame-error">⚠ ${String(e.message || e)}</div>`)
    } finally {
      busy = false
      $('#frame-refresh-' + id).textContent = '↻ refresh'
    }
  }

  $('#frame-refresh-' + id).addEventListener('click', doRefresh)
  $('#frame-auto-' + id).addEventListener('click', () => {
    auto = !auto
    $('#frame-auto-' + id).classList.toggle('on', auto)
  })

  // First paint: local-only frames (no network) refresh once immediately
  // so they're never empty; network-backed frames (cloud, agi) wait for
  // an explicit refresh click or the auto-toggle — never on open.
  if (def.autoFirstOpen) doRefresh()

  const timer = setInterval(() => { if (auto && isActiveTab()) doRefresh() }, def.refreshMs || 5000)
  const stop = () => { clearInterval(timer); if (def.destroy) try { def.destroy(api) } catch (_) {} }

  panes.set(id, { leaf, tabId, kind: 'frame:' + type, stop })
  return { id, leaf }
}
