import { app, BrowserWindow, Tray, Menu, ipcMain, nativeImage } from 'electron'
import { readFileSync, readdirSync, existsSync } from 'fs'
import { join } from 'path'
import { spawn } from 'child_process'

process.on('uncaughtException',  (err)    => console.error('[ct] uncaught:', err.message, err.stack))
process.on('unhandledRejection', (reason) => console.error('[ct] rejection:', reason))

// ── Env config ───────────────────────────────────────────────────────────────
const profileName = process.env.CT_PROFILE      || 'nix-flakes'
const profilesDir = process.env.CT_PROFILES_DIR || join(__dirname, '..', '..', 'data')
const assetsDir   = process.env.CT_ASSETS_DIR   || join(__dirname, '..', '..', 'assets')
const panelPath   = process.env.CT_PANEL        || join(__dirname, '..', '..', '..', 'lib', 'panel.html')
const binDir      = process.env.CT_BIN_DIR      || ''
const XDG         = process.env.CT_XDG          || 'xdg-open'
// CT_MULTI=1 → one process draws a tray icon for EVERY profile (memory-saving
// consolidation). Unset → legacy single-profile-per-process behaviour.
const multi       = !!process.env.CT_MULTI
// PTY helper: runs under SYSTEM node (ABI-safe for the prebuilt node-pty).
const NODE        = process.env.CT_NODE         || 'node'
const ptyServer   = process.env.CT_PTY_SERVER   || join(__dirname, 'pty-server.js')

// ── Load all profiles from profilesDir ──────────────────────────────────────
let profiles: any[] = []
let profile:  any   = null    // the "primary" profile (single-mode selection)

try {
  const files = readdirSync(profilesDir)
    .filter(f => f.startsWith('profile-') && f.endsWith('.json'))
    .sort()
  profiles = files.map(f => JSON.parse(readFileSync(join(profilesDir, f), 'utf8')))
  profile  = profiles.find(p => p.name === profileName) ?? profiles[0]
  if (!profile) throw new Error('no profiles found in ' + profilesDir)
} catch (e) {
  console.error('[ct] profile load failed:', e)
  process.exit(1)
}

// Profiles this process is responsible for: all of them in multi mode, else one.
const ownProfiles: any[] = multi ? profiles : [profile]

// Per-profile icon path (multi mode has no single CT_ICON — resolve per profile).
function iconFor(prof: any): string {
  if (!multi && process.env.CT_ICON) return process.env.CT_ICON
  return join(assetsDir, prof.name + '.png')
}

// ── App identity / single-instance ───────────────────────────────────────────
// multi: one identity for the whole app (one process, many trays).
// single: distinct identity per profile so KDE renders one icon PER process.
if (multi) {
  app.setName('cloud-terminal')
  try { (app as any).setAppUserModelId?.('com.diegonmarcos.cloud-terminal') } catch (_) {}
  app.setPath('userData', join(app.getPath('appData'), 'cloud-terminal'))
} else {
  app.setName('cloud-terminal-' + profile.name)
  try { (app as any).setAppUserModelId?.('com.diegonmarcos.cloud-terminal.' + profile.name) } catch (_) {}
  app.setPath('userData', join(app.getPath('appData'), 'cloud-terminal-' + profile.name))
}
if (!app.requestSingleInstanceLock()) {
  app.quit()
} else {
  app.on('second-instance', () => { const w = firstWin(); if (w) { w.show(); w.focus() } })
  main()
}

// ── Placeholder resolution ───────────────────────────────────────────────────
function resolve(arg: string, prof: any): string {
  return arg
    .replace(/\{FLAKE\}/g,         prof.flake           || '')
    .replace(/\{FLAKE_SYSTEM\}/g,  prof.flakes?.system  || '')
    .replace(/\{FLAKE_DESKTOP\}/g, prof.flakes?.desktop || '')
    .replace(/\{FLAKE_CLOUD\}/g,   prof.flakes?.cloud   || '')
}

function profByName(name?: string): any {
  return profiles.find(p => p.name === name) || profile
}

// ── App state (per-profile windows + trays) ──────────────────────────────────
const wins:  Map<string, InstanceType<typeof BrowserWindow>> = new Map()
const trays: InstanceType<typeof Tray>[] = []

function firstWin(): InstanceType<typeof BrowserWindow> | null {
  for (const w of wins.values()) return w
  return null
}
function winFor(prof: any): InstanceType<typeof BrowserWindow> | null {
  return wins.get(prof.name) ?? null
}

function main() {
  app.on('window-all-closed', () => { /* managed by tray — never quit on window close */ })

  app.on('ready', () => {
    for (const prof of ownProfiles) {
      // Tray — nativeImage required on Linux; bare string path silently fails
      const ip = iconFor(prof)
      const icon = nativeImage.createFromPath(existsSync(ip) ? ip : '')
      const tray = new Tray(icon)
      tray.setToolTip(prof.tray_tooltip || prof.display_name)
      tray.setContextMenu(buildTrayMenu(prof))
      tray.on('click', () => toggleWin(prof))
      trays.push(tray)

      const win = new BrowserWindow({
        width: 1040, height: 660, show: false, frame: true,
        title: prof.display_name || prof.name,
        backgroundColor: prof.theme?.bg || '#0e0f1a',
        webPreferences: { nodeIntegration: true, contextIsolation: false },
      })
      win.loadFile(panelPath)
      // Pin the taskbar/hover label to THIS profile — without this every window
      // shows the generic app name (or the panel's <title>) instead of "Cloud & Infra" etc.
      win.setTitle(prof.display_name || prof.name)
      win.on('page-title-updated', (e: any) => { e.preventDefault() })
      win.webContents.on('did-finish-load', () => {
        win.webContents.send('init', { ...prof, profiles })
      })
      win.on('close', (e: any) => { e.preventDefault(); win.hide() })
      wins.set(prof.name, win)
    }

    if (process.argv.includes('--show')) { const w = winFor(profile) ?? firstWin(); if (w) { w.show(); w.focus() } }
  })
}

// ── Tray right-click menu = the profile's command shortcuts (data-driven) ─────
function buildTrayMenu(prof: any) {
  const tpl: any[] = [
    { label: (prof.logo || '') + '  ' + prof.display_name, enabled: false },
    { type: 'separator' },
    { label: 'Open Panel', click: () => showWin(prof) },
    { type: 'separator' },
  ]
  for (const section of (prof.sections || [])) {
    const items = (section.items || []).map((it: any) => ({
      label: it.label,
      click: () => dispatch(it, prof),
    }))
    tpl.push({ label: section.title, submenu: items })
  }
  // In single mode, offer "Switch → other profile" (launches another process).
  // In multi mode every profile already has its own tray, so no switch entries.
  if (!multi) {
    tpl.push({ type: 'separator' })
    for (const p of profiles.filter(p => p.name !== prof.name)) {
      tpl.push({ label: 'Switch → ' + (p.logo ? p.logo + ' ' : '') + p.display_name, click: () => launchProfile(p.name) })
    }
  }
  tpl.push({ type: 'separator' }, { label: 'Quit', click: () => app.quit() })
  return Menu.buildFromTemplate(tpl)
}

function showWin(prof: any)   { const w = winFor(prof); w?.show(); w?.focus() }
function toggleWin(prof: any) { const w = winFor(prof); if (!w) return; w.isVisible() ? w.hide() : (w.show(), w.focus()) }

// ── PTY broker (multi-session: one helper process per terminal tab) ──────────
// Keyed by "<webContents.id>:<tabId>" so multiple windows never collide. Output
// is routed back to the ORIGINATING webContents, not a global window.
const ptys    = new Map<string, ReturnType<typeof spawn>>()
const ptyBufs = new Map<string, string>()
function pk(senderId: number, id: number): string { return senderId + ':' + id }

function ptyStart(sender: any, id: number, cols: number, rows: number) {
  const k = pk(sender.id, id)
  if (ptys.has(k)) return
  const p = spawn(NODE, [ptyServer], {
    stdio: ['pipe', 'pipe', 'pipe'],
    env: { ...process.env, CT_COLS: String(cols || 80), CT_ROWS: String(rows || 24), CT_CWD: process.env.HOME || '/' },
  })
  ptys.set(k, p)
  ptyBufs.set(k, '')
  p.stdout?.on('data', (d: Buffer) => { if (!sender.isDestroyed()) sender.send('pty-data', id, d.toString()) })
  p.stderr?.on('data', (d: Buffer) => {       // control channel (exit)
    let buf = (ptyBufs.get(k) || '') + d.toString()
    let nl
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl); buf = buf.slice(nl + 1)
      if (line && !sender.isDestroyed()) sender.send('pty-exit', id, line)
    }
    ptyBufs.set(k, buf)
  })
  p.on('close', () => { ptys.delete(k); ptyBufs.delete(k) })
}

function ptySend(sender: any, id: number, msg: any) {
  const p = ptys.get(pk(sender.id, id))
  if (p && p.stdin) (p.stdin as any).write(JSON.stringify(msg) + '\n')
}

function ptyKill(sender: any, id: number) {
  const k = pk(sender.id, id)
  const p = ptys.get(k)
  if (p) { try { p.kill() } catch (_) {} ptys.delete(k); ptyBufs.delete(k) }
}

// ── Central dispatch (used by both panel clicks and tray menu) ───────────────
// `prof` = the profile the item belongs to. `sender` = originating webContents
// when invoked from the panel (carries the tab's PTY); null from a tray menu.
function dispatch(item: { type: string; arg: string; label?: string; profile?: string; ptyId?: number },
                  prof: any = profile, sender?: any) {
  const a = resolve(item.arg || '', prof)

  if (item.type === 'xdg' || item.type === 'open') {     // GUI apps → external (correct)
    spawn(XDG, [a], { detached: true, stdio: 'ignore' }).unref()
    return
  }

  let line = a
  if (item.type === 'build' || item.type === 'build-system' || item.type === 'build-desktop') {
    const flake =
      item.type === 'build'        ? (prof.flake            || '') :
      item.type === 'build-system' ? (prof.flakes?.system   || prof.flake || '') :
                                     (prof.flakes?.desktop  || prof.flake || '')
    line = `cd ${shq(flake)} && PATH="/run/wrappers/bin:$PATH" bash build.sh ${a}`
  } else if (item.type === 'log' || item.type === 'log-system' || item.type === 'log-desktop') {
    const logDir =
      item.type === 'log'         ? (prof.flake            || '') :
      item.type === 'log-system'  ? (prof.flakes?.system   || prof.flake || '') :
                                    (prof.flakes?.desktop  || prof.flake || '')
    line = `ls -t ${shq(logDir)}/logs/*.log 2>/dev/null | head -1 | xargs -r tail -f`
  }
  // shell / term / build / log → type the command into the selected tab's PTY
  showWin(prof)
  const id = item.ptyId
  if (id == null || !sender) return
  ptySend(sender, id, { type: 'data', d: line + '\r' })
}

function shq(s: string): string { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

ipcMain.on('run-item', (e, item: any) => dispatch(item, profByName(item.profile), e.sender))
ipcMain.on('pty-start',  (e, a: { id: number; cols: number; rows: number }) => ptyStart(e.sender, a.id, a.cols, a.rows))
ipcMain.on('pty-input',  (e, a: { id: number; d: string })                  => ptySend(e.sender, a.id, { type: 'data', d: a.d }))
ipcMain.on('pty-resize', (e, a: { id: number; cols: number; rows: number }) => ptySend(e.sender, a.id, { type: 'resize', cols: a.cols, rows: a.rows }))
ipcMain.on('pty-kill',   (e, a: { id: number })                             => ptyKill(e.sender, a.id))

ipcMain.on('switch-profile', (_e, name: string) => {
  if (multi) { const p = profByName(name); showWin(p) }   // just focus that tray's window
  else launchProfile(name)
})

// Single-mode only: spawn the sibling launcher by absolute path (CT_BIN_DIR).
function launchProfile(name: string) {
  const bin = binDir ? join(binDir, 'cloud-terminal-' + name) : ''
  if (bin && existsSync(bin)) {
    spawn(bin, ['--show'], { detached: true, stdio: 'ignore' }).unref()
  } else {
    spawn(process.execPath, [join(__dirname, 'main.js'), '--show'],
      { detached: true, stdio: 'ignore', env: { ...process.env, CT_PROFILE: name, CT_ICON: '' } }).unref()
  }
}
