function applyTheme(theme) {
  curTheme = theme || {}
  const r = document.documentElement.style
  if (theme.accent)  r.setProperty('--accent',  theme.accent)
  if (theme.accent2) r.setProperty('--accent2', theme.accent2)
  if (theme.bg)      r.setProperty('--bg',      theme.bg)
  for (const p of panes.values()) if (p.kind === 'term') p.term.options.theme = termTheme(theme)
}

function runItem(item) { invoke('run_item', { item }) }
function focusActivePaneTerm() { const p = panes.get(activePane); if (p && p.kind === 'term') p.term.focus() }

// ── command history (Last 5 / Most Used) — persisted in localStorage ──
function historyLoad() { try { return JSON.parse(localStorage.getItem('ct-history') || '[]') } catch (_) { return [] } }
function historySave(h) { try { localStorage.setItem('ct-history', JSON.stringify(h.slice(0, 200))) } catch (_) {} }
function recordHistory(item) {
  if (!item || !item.label) return
  const h = historyLoad(), e = h.find(x => x.key === item.label), now = Date.now()
  if (e) { e.count++; e.last = now } else h.push({ key: item.label, label: item.label, type: item.type, arg: item.arg || '', cmd: item.cmd || '', count: 1, last: now })
  historySave(h)
}
function historyItems(kind) {
  const h = historyLoad()
  return (kind === 'most' ? h.slice().sort((a, b) => b.count - a.count) : h.slice().sort((a, b) => b.last - a.last)).slice(0, 5)
}
// dispatch a sidebar/history item (dashboards open a pane; others run a command)
function openItem(item, profileName) {
  recordHistory(item)
  const dash = { monitor: newMonitorTab, journal: newJournalTab, cloud: newCloudTab, datasync: newDataSyncTab, agi: newAGITab, devctl: newDevControlTab, stack: newStackTab }[item.type]
  if (dash) { dash() } else { runItem({ ...item, profile: profileName, ptyId: activePane }); focusActivePaneTerm() }
  if ((active.sections || []).some(s => s.dynamic)) buildSidebar(active)   // refresh Last/Most
}

function buildSidebar(profile) {
  const sb = document.getElementById('sidebar-list')
  sb.innerHTML = ''
  for (const section of (profile.sections || [])) {
    const grp = document.createElement('div'); grp.className = 'cmd-group'
    const t = document.createElement('div'); t.className = 'section-title'; t.textContent = section.title
    grp.appendChild(t)
    const items = section.dynamic ? historyItems(section.dynamic) : (section.items || [])
    if (section.dynamic && !items.length) {
      const e = document.createElement('div'); e.className = 'cmd-item'; e.style.color = '#4b5563'; e.style.cursor = 'default'
      e.textContent = '— none yet —'; grp.appendChild(e)
    }
    for (const item of items) {
      const btn = document.createElement('button')
      btn.className = 'cmd-item'; btn.textContent = item.label
      btn.dataset.search = ((item.label || '') + ' ' + (item.arg || '')).toLowerCase()
      btn.onclick = () => openItem(item, profile.name)
      grp.appendChild(btn)
    }
    const sep = document.createElement('div'); sep.className = 'sep-line'; grp.appendChild(sep)
    sb.appendChild(grp)
  }
  filterSidebar(document.getElementById('sidebar-search').value)
}

function filterSidebar(q) {
  q = (q || '').trim().toLowerCase()
  for (const grp of document.querySelectorAll('#sidebar-list .cmd-group')) {
    let shown = 0
    for (const btn of grp.querySelectorAll('.cmd-item')) {
      const hit = !q || btn.dataset.search.indexOf(q) !== -1
      btn.style.display = hit ? '' : 'none'
      if (hit) shown++
    }
    grp.style.display = shown ? '' : 'none'
  }
}

function buildProfileTabs() {
  const bar = document.getElementById('tabbar'); bar.innerHTML = ''
  for (const p of allProfiles) {
    const btn = document.createElement('button')
    btn.className = 'profile-pill' + (p.name === active.name ? ' active' : '')
    btn.textContent = (p.logo ? p.logo + ' ' : '') + p.display_name
    btn.onclick = () => { if (p.name !== active.name) showProfile(p) }
    bar.appendChild(btn)
  }
}

// Switching a pill only changes theme/sidebar/header — tab VISIBILITY is
// handled by switchProfileTabs (all pills share this one window's DOM, so
// each profile's tabs must be shown/hidden, not rebuilt).
function showProfile(p) {
  active = p
  applyTheme(p.theme || {})
  buildProfileTabs(); buildSidebar(p)
  document.getElementById('hdr-logo').textContent = p.logo || ''
  document.getElementById('hdr-name').textContent = p.display_name || ''
  document.title = 'Cloud Terminal — ' + (p.display_name || '')
  switchProfileTabs(p.name)
}

// ── boot ──
async function init() {
  const data = await invoke('get_init')
  allProfiles = data.profiles || [data]
  const label = data.name
  document.getElementById('hdr-host').textContent = '@ ' + (data.host || '')
  sessionData = await invoke('session_load').catch(() => null) || {}
  await cacheLoad()   // must finish before showProfile() builds the first frames (cachePeek needs it populated)
  showProfile(allProfiles.find(p => p.name === data.name) || data)  // builds this profile's tabs via switchProfileTabs
  try {
    await Promise.all([
      listen('pty-data:' + label, e => { const [id, d] = e.payload; const p = panes.get(id); if (p) p.term.write(d) }),
      listen('pty-exit:' + label, e => { const id = e.payload; const p = panes.get(id); if (p) p.term.write('\r\n\x1b[33m[shell exited]\x1b[0m\r\n') }),
      listen('tray-run:' + label, e => runItem({ ...e.payload, ptyId: activePane })),
    ])
  } catch (err) { console.error('event listen failed:', err) }
  sessionReady = true
  setTimeout(doFit, 60)
}

// Type a command into the JUST-created tab's shell (for default "command"
// tabs). activePane is that tab's pane (newTab focuses it). Small delay so the
// login shell has drawn its prompt before we feed the line.
function autoRun(cmd) {
  const id = activePane
  setTimeout(() => { const p = panes.get(id); if (p && p.kind === 'term') invoke('pty_input', { id, d: cmd + '\r' }) }, 700)
}

// ── context menu ──
const ctx = document.getElementById('ctxmenu')
function showCtxMenu(x, y) {
  ctx.style.display = 'block'
  const w = ctx.offsetWidth, h = ctx.offsetHeight
  ctx.style.left = Math.min(x, window.innerWidth  - w - 4) + 'px'
  ctx.style.top  = Math.min(y, window.innerHeight - h - 4) + 'px'
}
function hideCtxMenu() { ctx.style.display = 'none' }
window.addEventListener('click', hideCtxMenu)
window.addEventListener('blur', hideCtxMenu)
ctx.addEventListener('click', e => {
  const it = e.target.closest('.ctx-item'); if (!it) return
  const p = panes.get(activePane)
  const isTerm = p && p.kind === 'term'
  switch (it.dataset.act) {
    case 'copy':      { if (isTerm) { const s = p.term.getSelection(); if (s) clip.write(s) } break }
    case 'paste':     if (isTerm) clip.read().then(x => { if (x) invoke('pty_input', { id: activePane, d: x }) }); break
    case 'selall':    if (isTerm) p.term.selectAll(); break
    case 'split-h':   splitActive('row'); break
    case 'split-v':   splitActive('col'); break
    case 'closepane': closePane(activePane); break
    case 'clear':     if (isTerm) p.term.clear(); break
    case 'newtab':    newTab(); break
  }
  hideCtxMenu(); focusActivePaneTerm()
})

document.getElementById('newtab').onclick        = () => newTab()
document.getElementById('newmon').onclick        = () => newMonitorTab()
document.getElementById('split-h').onclick      = () => splitActive('row')
document.getElementById('split-v').onclick      = () => splitActive('col')
document.getElementById('closepane-btn').onclick = () => closePane(activePane)
document.getElementById('clear-btn').onclick    = () => { const p = panes.get(activePane); if (p && p.kind === 'term') { p.term.clear(); p.term.focus() } }
document.getElementById('kill-btn').onclick     = () => { if (activePane != null) invoke('pty_input', { id: activePane, d: '\x03' }) }

const _search = document.getElementById('sidebar-search')
_search.addEventListener('input', () => filterSidebar(_search.value))
_search.addEventListener('keydown', e => { if (e.key === 'Escape') { _search.value = ''; filterSidebar('') } })

window.addEventListener('DOMContentLoaded', init)
