// ── Data cache — "all pages open seamless using cached data" ─────────
// In-memory Map, keyed cmd+JSON.stringify(args) → {data, at}, persisted to
// ~/.cloud-terminal/cache.json on the same debounce saveSession() already
// uses, loaded once at boot. Two primitives:
//
//   cachePeek(cmd, args)   — synchronous read of whatever's cached (or
//                            null); used by a frame's make() to render
//                            instantly on open, no network, no invoke().
//   cachedInvoke(cmd, args) — the real fetch: calls the (already
//                            instrumented) invoke(), stores the result +
//                            timestamp, schedules a persist, returns the
//                            fresh data. Drop-in replacement for invoke()
//                            in a frame's refresh() for the calls worth
//                            caching (cloud_targets, stack_info, data_sync,
//                            agi_usage — see each frame's refresh()).
//
// Stale-but-shown is the whole point here — a frame's own "as of HH:MM"
// stamp (frame.js) already tells the user how old what they're looking at
// is; this cache never expires entries on its own, it just gets replaced
// every time cachedInvoke actually runs.
const cacheMap = new Map()
let cacheReady = false     // mirrors sessionReady — don't persist until loaded
let cacheSaveTimer = null

function cacheKey(cmd, args) { return cmd + ':' + JSON.stringify(args || {}) }

function cachePeek(cmd, args) {
  const e = cacheMap.get(cacheKey(cmd, args))
  return e ? e.data : null
}

function cacheScheduleSave() {
  if (!cacheReady) return
  clearTimeout(cacheSaveTimer)
  cacheSaveTimer = setTimeout(() => {
    const out = {}
    for (const [k, v] of cacheMap) out[k] = v
    invoke('cache_save', { data: out }).catch(() => {})
  }, 500)
}

async function cachedInvoke(cmd, args) {
  const data = await invoke(cmd, args)
  cacheMap.set(cacheKey(cmd, args), { data, at: Date.now() })
  cacheScheduleSave()
  return data
}

async function cacheLoad() {
  const saved = await invoke('cache_load').catch(() => null)
  if (saved && typeof saved === 'object') {
    for (const k of Object.keys(saved)) cacheMap.set(k, saved[k])
  }
  cacheReady = true
}
