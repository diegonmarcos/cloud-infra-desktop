// ── Pane (leaf = one terminal + PTY) ──
function makePane(tabId) {
  const id = ++paneSeq
  const leaf = document.createElement('div')
  leaf.className = 'leaf'
  leaf.dataset.pane = String(id)

  const term = new Terminal({
    fontFamily: "'JetBrains Mono','Fira Code',monospace",
    fontSize: 13, cursorBlink: true, scrollback: 10000, theme: termTheme(curTheme),
  })
  const fit = new FitAddon()
  term.loadAddon(fit)
  term.open(leaf)

  term.attachCustomKeyEventHandler(e => {
    if (e.type !== 'keydown') return true
    if (e.ctrlKey && e.shiftKey && e.code === 'KeyC') { const s = term.getSelection(); if (s) clip.write(s); return false }
    if (e.ctrlKey && e.shiftKey && e.code === 'KeyV') { clip.read().then(t => { if (t) invoke('pty_input', { id, d: t }) }); return false }
    if (e.ctrlKey && e.shiftKey && e.code === 'KeyE') { splitActive('row'); return false }
    if (e.ctrlKey && e.shiftKey && e.code === 'KeyD') { splitActive('col'); return false }
    if (e.ctrlKey && e.shiftKey && e.code === 'KeyW') { closePane(activePane); return false }
    // Font zoom for THIS pane: Ctrl+= / Ctrl++ in, Ctrl+- out, Ctrl+0 reset.
    if (e.ctrlKey && !e.shiftKey && (e.code === 'Equal' || e.code === 'NumpadAdd'))      { setFont(id, +1); return false }
    if (e.ctrlKey &&  e.shiftKey &&  e.code === 'Equal')                                 { setFont(id, +1); return false }
    if (e.ctrlKey && (e.code === 'Minus' || e.code === 'NumpadSubtract'))                { setFont(id, -1); return false }
    if (e.ctrlKey && (e.code === 'Digit0' || e.code === 'Numpad0'))                      { setFont(id,  0); return false }
    return true
  })
  term.onData(d => invoke('pty_input', { id, d }))
  // Rename the tab to the shell's title (fish sets it to the running command /
  // cwd via the OSC title escape). Reflects the last command run in the tab.
  term.onTitleChange(t => { if (t) setTabTitle(tabId, t) })
  // focus-follows-click; capture so it fires before xterm handles it
  leaf.addEventListener('mousedown', () => focusPane(id), true)
  leaf.addEventListener('contextmenu', e => { e.preventDefault(); focusPane(id); showCtxMenu(e.clientX, e.clientY) })

  panes.set(id, { term, fit, leaf, tabId, kind: 'term' })
  invoke('pty_start', { id, cols: term.cols || 80, rows: term.rows || 24 })
  return { id, leaf }
}

function paneIdOf(leaf) { return parseInt(leaf.dataset.pane, 10) }

function focusPane(id) {
  const p = panes.get(id)
  if (!p) return
  activePane = id
  for (const q of panes.values()) q.leaf.classList.toggle('focused', q === p)
  if (p.kind === 'term') p.term.focus()
}

// ── Split the ACTIVE pane: dir 'row' = left/right, 'col' = top/bottom ──
function splitActive(dir) {
  const p = panes.get(activePane)
  if (!p) return
  const leaf = p.leaf
  const parent = leaf.parentElement
  const split = document.createElement('div')
  split.className = 'split ' + dir
  const div = document.createElement('div')
  div.className = 'divider'
  parent.replaceChild(split, leaf)          // put the split where the leaf was
  const made = makePane(p.tabId)
  split.append(leaf, div, made.leaf)         // [old, divider, new]
  attachDivider(div, dir)
  fitTab(p.tabId)
  focusPane(made.id)
}

// ── Close a pane; collapse its parent split; close tab if it was the last ──
function closePane(id) {
  const p = panes.get(id)
  if (!p) return
  if (p.stop) { try { p.stop() } catch (_) {} }   // special pane (monitor/journal): clear its timer
  else { invoke('pty_kill', { id }); try { p.term.dispose() } catch (_) {} }
  const leaf = p.leaf, parent = leaf.parentElement
  panes.delete(id)
  if (parent && parent.classList.contains('split')) {
    // sibling (the other non-divider child) takes the split's place
    const sib = [...parent.children].find(c => c !== leaf && !c.classList.contains('divider'))
    parent.parentElement.replaceChild(sib, parent)
    fitTab(p.tabId)
    // focus any surviving pane in this tab
    for (const [qid, q] of panes) if (q.tabId === p.tabId) { focusPane(qid); break }
  } else {
    closeTab(p.tabId)                          // leaf was the tab's whole content
  }
}

// ── Divider drag → resize the two adjacent nodes ──
function attachDivider(div, dir) {
  div.addEventListener('mousedown', e => {
    e.preventDefault()
    const prev = div.previousElementSibling, next = div.nextElementSibling
    const horiz = dir === 'row'
    const start = horiz ? e.clientX : e.clientY
    const ps = horiz ? prev.offsetWidth : prev.offsetHeight
    const ns = horiz ? next.offsetWidth : next.offsetHeight
    const move = ev => {
      const delta = (horiz ? ev.clientX : ev.clientY) - start
      const np = Math.max(48, ps + delta), nn = Math.max(48, ns - delta)
      prev.style.flex = '0 0 ' + np + 'px'
      next.style.flex = '0 0 ' + nn + 'px'
    }
    const up = () => {
      document.removeEventListener('mousemove', move)
      document.removeEventListener('mouseup', up)
      if (activeTab != null) fitTab(activeTab)
    }
    document.addEventListener('mousemove', move)
    document.addEventListener('mouseup', up)
  })
}

// ── Fit ── (only the visible/active tab has non-zero sized leaves)
function fitPane(id) {
  const p = panes.get(id); if (!p || p.kind !== 'term') return
  try { p.fit.fit() } catch (_) {}
  invoke('pty_resize', { id, cols: p.term.cols, rows: p.term.rows })
}
function fitTab(tabId) { for (const [id, p] of panes) if (p.tabId === tabId) fitPane(id) }
function doFit() { if (activeTab != null) fitTab(activeTab) }

// Per-pane font zoom. delta +1/-1 steps; 0 resets to the default 13. Re-fit so
// cols/rows (and the PTY size) track the new glyph size.
function setFont(id, delta) {
  const p = panes.get(id); if (!p) return
  const cur = p.term.options.fontSize || 13
  const next = delta === 0 ? 13 : Math.max(6, Math.min(40, cur + delta))
  p.term.options.fontSize = next
  fitPane(id)
}
window.addEventListener('resize', doFit)
