// ── Tauri IPC ──
// DEV CONTROL instrumentation: every invoke() call (SSH probes, docker
// stats, journal reads, process scans — everything a dashboard does) is
// timed and recorded into a rolling buffer so the DEV CONTROL tab can show
// exactly what's slow, how often it's called, and from which pane — instead
// of guessing which of 5 heavy dashboards is thrashing the UX. Near-zero
// overhead: one Date.now() before/after and a ring-buffer push, no
// allocation-heavy tracing.
const _rawInvoke = window.__TAURI__.core.invoke
const DEVCTL_MAX = 500
const devctlLog = []          // ring buffer: {cmd, args, ms, at, ok}
const devctlListeners = new Set()
function devctlPush(entry) {
  devctlLog.push(entry)
  if (devctlLog.length > DEVCTL_MAX) devctlLog.shift()
  for (const fn of devctlListeners) { try { fn(entry) } catch (_) {} }
}
const invoke = (cmd, args) => {
  const t0 = Date.now()
  return _rawInvoke(cmd, args).then(
    r => { devctlPush({ cmd, args, ms: Date.now() - t0, at: t0, ok: true }); return r },
    e => { devctlPush({ cmd, args, ms: Date.now() - t0, at: t0, ok: false, err: String(e) }); throw e }
  )
}
const listen = window.__TAURI__.event.listen
// Shared decimal-separator formatter — every number shown anywhere in the
// app MUST carry a decimal or thousands separator, never a bare integer.
const fmtNum = n => (n || 0).toLocaleString(undefined, { minimumFractionDigits: 1, maximumFractionDigits: 1 })
const Terminal = window.Terminal
const FitAddon = window.FitAddon.FitAddon
const clip = {
  write: (t) => { try { navigator.clipboard.writeText(t) } catch (_) {} },
  read:  ()  => navigator.clipboard.readText().catch(() => ''),
}

let allProfiles = []
let active = null
let curTheme = {}

// ── Model ──
// panes: ptyId → { term, fit, leaf(DOM), tabId }.  Each leaf is one PTY.
// tabs:  tabId → { root(DOM), btn, title, profile, type, cmd }. A tab holds a
//        binary split tree of .leaf / .split.row / .split.col nodes
//        (KDE-style splits). `profile` scopes the tab to ONE profile pill —
//        all profile pills share this window's DOM, so tabs are shown/hidden
//        by profile rather than living in separate documents.
const panes = new Map()
const tabs  = new Map()
let paneSeq = 0
let tabSeq  = 0
let activeTab = null
let activePane = null
const profileActiveTab = {}     // profile name -> last-active tabId (restored on pill switch)
const initializedProfiles = new Set()
let sessionData = {}            // loaded once at boot: { [profile]: { tabs:[{type,title,cmd,arg}], active } }
let sessionReady = false        // don't save() until the initial load+restore finished
let saveTimer = null

function termTheme(theme) {
  return { background: theme.bg || '#0e0f1a', foreground: '#e2e8f0', cursor: theme.accent || '#7b7fff' }
}
