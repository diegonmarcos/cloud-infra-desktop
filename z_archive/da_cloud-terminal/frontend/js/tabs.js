// Generic special-pane tab (no PTY): monitor / journal / cloud dashboards.
function newSpecialTab(makeFn, labelText, type, profile, activate) {
  if (activate == null) activate = true
  profile = profile || active.name
  const tabId = ++tabSeq
  const root = document.createElement('div')
  root.className = 'tab-root'; root.dataset.tab = String(tabId)
  document.getElementById('terms').appendChild(root)
  const btn = document.createElement('button')
  btn.className = 'term-tab'
  const label = document.createElement('span'); label.textContent = labelText
  const close = document.createElement('span'); close.className = 'close'; close.textContent = '×'
  close.onclick = ev => { ev.stopPropagation(); closeTab(tabId) }
  btn.append(label, close); btn.onclick = () => activateTab(tabId)
  document.getElementById('termtabs').insertBefore(btn, document.getElementById('newmon'))
  // LAZY: register the tab (cheap — a button + empty root) but do NOT call
  // makeFn yet. Each special tab's make* spawns an SSH-mux probe, a journal
  // read, or a docker query the instant it's built — building all of a
  // profile's default tabs up front serialized that network work for panes
  // the user hadn't even looked at yet. ensureTabBuilt() calls makeFn on
  // first activation instead, so only the tab actually shown pays that cost.
  // activate=false lets a bulk restore (restoreOrDefaultTabs) register all
  // of a profile's tabs as buttons without building/activating each one in
  // turn — only the profile's actual starting tab gets built.
  tabs.set(tabId, { root, btn, title: label, profile, type, cmd: '', makeFn, built: false })
  if (activate) activateTab(tabId)
  saveSession()
  return tabId
}

// Realize a special tab's pane on first activation (see newSpecialTab). A
// no-op for already-built tabs and for plain shell tabs (built eagerly since
// spawning a local pty is cheap, unlike SSH/journal/docker probes).
function ensureTabBuilt(id) {
  const t = tabs.get(id)
  if (!t || t.built || !t.makeFn) return
  t.built = true
  const made = t.makeFn(id)
  t.root.appendChild(made.leaf)
  focusPane(made.id)
}
function newMonitorTab(profile, activate) { return newSpecialTab(makeMonitor, '📊 monitor', 'monitor', profile, activate) }
function newJournalTab(profile, activate) { return newSpecialTab(makeJournal, '📜 journal', 'journal', profile, activate) }
function newCloudTab(profile, activate) { return newSpecialTab(makeCloud, '☁ cloud', 'cloud', profile, activate) }
function newDataSyncTab(profile, activate) { return newSpecialTab(makeDataSync, '🔄 data-sync', 'datasync', profile, activate) }
function newAGITab(profile, activate) { return newSpecialTab(makeAGI, '🤖 agi', 'agi', profile, activate) }
function newDevControlTab(profile, activate) { return newSpecialTab(makeDevControl, '🛠 devctl', 'devctl', profile, activate) }
function newStackTab(profile, activate) { return newSpecialTab(makeStack, '📦 stack', 'stack', profile, activate) }

// ── Tabs ──
function setTabTitle(tabId, title) {
  const t = tabs.get(tabId); if (!t) return
  title = String(title).trim(); if (!title) return
  t.title.textContent = title.length > 22 ? title.slice(0, 21) + '…' : title
}
function newTab(profile, titleOverride) {
  profile = profile || active.name
  const tabId = ++tabSeq
  const root = document.createElement('div')
  root.className = 'tab-root'
  root.dataset.tab = String(tabId)
  document.getElementById('terms').appendChild(root)

  const btn = document.createElement('button')
  btn.className = 'term-tab'
  const label = document.createElement('span'); label.textContent = titleOverride || ('shell ' + tabId)
  const close = document.createElement('span'); close.className = 'close'; close.textContent = '×'
  close.onclick = ev => { ev.stopPropagation(); closeTab(tabId) }
  btn.append(label, close)
  btn.onclick = () => activateTab(tabId)
  document.getElementById('termtabs').insertBefore(btn, document.getElementById('newtab'))

  tabs.set(tabId, { root, btn, title: label, profile, type: 'shell', cmd: '' })
  const made = makePane(tabId)
  root.appendChild(made.leaf)
  activateTab(tabId)
  focusPane(made.id)
  saveSession()
  return tabId
}

// Show only the tabs belonging to `id`'s profile; skip cross-profile ones.
function activateTab(id) {
  const t = tabs.get(id); if (!t) return
  ensureTabBuilt(id)
  activeTab = id
  profileActiveTab[t.profile] = id
  for (const [tid, tt] of tabs) {
    const on = tid === id
    tt.root.classList.toggle('active', on)
    tt.btn.classList.toggle('active', on)
  }
  fitTab(id)
  for (const [pid, p] of panes) if (p.tabId === id) { focusPane(pid); break }
  saveSession()
}

function closeTab(id) {
  const t = tabs.get(id)
  if (!t) return
  const profile = t.profile
  for (const [pid, p] of [...panes]) if (p.tabId === id) { if (p.stop) { try { p.stop() } catch (_) {} } else { invoke('pty_kill', { id: pid }); try { p.term.dispose() } catch (_) {} } panes.delete(pid) }
  t.root.remove(); t.btn.remove()
  tabs.delete(id)
  if (activeTab === id) {
    // fall back to another tab OF THE SAME PROFILE — never borrow a tab from
    // a different profile pill.
    const next = [...tabs.entries()].find(([, tt]) => tt.profile === profile)
    if (next) activateTab(next[0]); else newTab(profile)
  }
  saveSession()
}

// ── Per-profile tab visibility (all pills share this window's DOM) ───────
// Hide every tab button/root not belonging to `name`; show the rest. Lazily
// builds that profile's tabs (from the saved session, else its data-driven
// default_tabs) the first time its pill is visited.
function switchProfileTabs(name) {
  for (const [, t] of tabs) {
    const on = t.profile === name
    t.btn.style.display = on ? '' : 'none'   // .tab-root's own .active class (CSS) hides the pane
    if (!on) t.root.classList.remove('active')
  }
  if (!initializedProfiles.has(name)) {
    initializedProfiles.add(name)
    restoreOrDefaultTabs(name)
    return
  }
  const mine = [...tabs.entries()].filter(([, t]) => t.profile === name)
  // Stack is the pinned home landing page — clicking back to this profile
  // always lands there, never "wherever I left off" (that's what
  // profileActiveTab would otherwise restore).
  const stackEntry = mine.find(([, t]) => t.type === 'stack')
  const want = profileActiveTab[name]
  if (stackEntry) activateTab(stackEntry[0])
  else if (want != null && tabs.has(want)) activateTab(want)
  else if (mine.length) activateTab(mine[0][0])
  else restoreOrDefaultTabs(name)   // profile had all its tabs closed — reseed defaults
  setTimeout(doFit, 30)
}

// Build a profile's tab set from the saved session if present, else its
// profile.default_tabs (same shapes init() already understood).
function restoreOrDefaultTabs(name) {
  const prof = allProfiles.find(p => p.name === name)
  const saved = sessionData[name]
  const spec = (saved && Array.isArray(saved.tabs) && saved.tabs.length) ? saved.tabs
    : (Array.isArray(prof && prof.default_tabs) ? prof.default_tabs : [{ type: 'shell', title: 'shell' }])
  let firstTab = null, wantActive = null, stackTab = null
  const activeIdx = saved && typeof saved.active === 'number' ? saved.active : null
  spec.forEach((t, i) => {
    let tid
    if (t.type === 'monitor') tid = newMonitorTab(name, false)
    else if (t.type === 'journal') tid = newJournalTab(name, false)
    else if (t.type === 'cloud') tid = newCloudTab(name, false)
    else if (t.type === 'datasync') tid = newDataSyncTab(name, false)
    else if (t.type === 'agi') tid = newAGITab(name, false)
    else if (t.type === 'devctl') tid = newDevControlTab(name, false)
    else if (t.type === 'stack') tid = newStackTab(name, false)
    else { tid = newTab(name, t.title); if (t.cmd) autoRun(t.cmd) }
    if (t.cmd) { const tt = tabs.get(tid); if (tt) tt.cmd = t.cmd }
    if (firstTab == null) firstTab = tid
    if (t.type === 'stack') stackTab = tid
    if (t.active || i === activeIdx) wantActive = tid
  })
  // Stack is the pinned home landing page — always wins over whatever tab a
  // restored session happened to be on last, so opening the app (or
  // clicking back to this profile) always lands there, not "wherever I left
  // off". Session restore still applies to every OTHER tab's existence/order.
  activateTab(stackTab != null ? stackTab : (wantActive != null ? wantActive : firstTab))
}

// ── Session persistence (~/.cloud-terminal/session.json) ─────────────────
// Debounced: any tab open/close/switch schedules a save ~500ms later so a
// burst of activity (opening several default tabs) writes once, not per-tab.
function saveSession() {
  if (!sessionReady) return
  clearTimeout(saveTimer)
  saveTimer = setTimeout(() => {
    const out = {}
    for (const p of allProfiles) {
      const mine = [...tabs.entries()].filter(([, t]) => t.profile === p.name)
      if (!mine.length) continue
      const activeIdx = mine.findIndex(([tid]) => tid === profileActiveTab[p.name])
      out[p.name] = {
        active: activeIdx >= 0 ? activeIdx : 0,
        tabs: mine.map(([, t]) => ({ type: t.type, title: t.title.textContent, cmd: t.cmd || '' })),
      }
    }
    invoke('session_save', { data: out }).catch(() => {})
  }, 500)
}
