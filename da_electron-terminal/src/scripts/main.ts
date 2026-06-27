import { app, BrowserWindow, Tray, Menu, ipcMain, nativeImage } from 'electron'
import { readFileSync, readdirSync, existsSync } from 'fs'
import { join } from 'path'
import { spawn } from 'child_process'

process.on('uncaughtException',   (err)    => console.error('[et] uncaught:', err.message, err.stack))
process.on('unhandledRejection',  (reason) => console.error('[et] rejection:', reason))

// ── Env config ──────────────────────────────────────────────────────────────
const profileName = process.env.ET_PROFILE       || 'nix-flakes'
const profilesDir = process.env.ET_PROFILES_DIR  || join(__dirname, '..', '..', 'data')
const panelPath   = process.env.ET_PANEL         || join(__dirname, '..', '..', '..', 'lib', 'panel.html')
const iconPath    = process.env.ET_ICON          || join(__dirname, '..', '..', 'assets', profileName + '.png')
const switchGui   = process.env.ET_SWITCH_GUI    || ''
const KONSOLE     = process.env.ET_KONSOLE       || 'konsole'
const BASH        = process.env.ET_BASH          || '/bin/bash'
const XDG         = process.env.ET_XDG           || 'xdg-open'

// ── Load profiles ────────────────────────────────────────────────────────────
let profiles: any[] = []
let profile:  any   = null

try {
  const files = readdirSync(profilesDir)
    .filter(f => f.startsWith('profile-') && f.endsWith('.json'))
    .sort()
  profiles = files.map(f => JSON.parse(readFileSync(join(profilesDir, f), 'utf8')))
  profile  = profiles.find(p => p.name === profileName) ?? profiles[0]
  if (!profile) throw new Error('no profiles found in ' + profilesDir)
} catch (e) {
  console.error('[et] profile load failed:', e)
  process.exit(1)
}

// ── Placeholder resolution ───────────────────────────────────────────────────
function resolve(arg: string): string {
  return arg
    .replace('{FLAKE}',         profile.flake            || '')
    .replace('{FLAKE_SYSTEM}',  profile.flakes?.system   || '')
    .replace('{FLAKE_DESKTOP}', profile.flakes?.desktop  || '')
    .replace('{FLAKE_CLOUD}',   profile.flakes?.cloud    || '')
}

// ── Konsole helper ───────────────────────────────────────────────────────────
function konsole(cmd: string) {
  spawn(KONSOLE, ['-e', BASH, '-c', cmd + '; echo; read -p "[done, enter to close] "'],
    { detached: true, stdio: 'ignore' }).unref()
}

// ── App ──────────────────────────────────────────────────────────────────────
let win:  InstanceType<typeof BrowserWindow> | null = null
let tray: InstanceType<typeof Tray>          | null = null

app.setQuitOnLastWindowClose(false)

app.on('ready', () => {
  // Tray — must use nativeImage on Linux (bare path string fails)
  const icon = existsSync(iconPath) ? nativeImage.createFromPath(iconPath) : nativeImage.createFromPath('')
  tray = new Tray(icon)
  tray.setToolTip(profile.tray_tooltip || profile.display_name)
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: profile.logo + '  ' + profile.display_name, enabled: false },
    { type: 'separator' },
    { label: 'Open Panel', click: () => showWin() },
    { type: 'separator' },
    ...profiles
      .filter(p => p.name !== profile.name)
      .map(p => ({ label: 'Switch → ' + p.display_name, click: () => launchProfile(p.name) })),
    { type: 'separator' },
    { label: 'Quit', click: () => app.quit() },
  ]))
  tray.on('click', () => toggleWin())

  // Window
  win = new BrowserWindow({
    width: 1000, height: 620, show: false, frame: true,
    backgroundColor: profile.theme.bg,
    webPreferences: { nodeIntegration: true, contextIsolation: false },
  })
  win.loadFile(panelPath)
  win.webContents.on('did-finish-load', () => {
    win!.webContents.send('init', { profile, profiles })
  })
  win.on('close', (e) => { e.preventDefault(); win!.hide() })

  if (process.argv.includes('--show')) showWin()
})

function showWin()   { win?.show(); win?.focus() }
function toggleWin() { win?.isVisible() ? win.hide() : showWin() }

// ── Dispatch ─────────────────────────────────────────────────────────────────
ipcMain.on('dispatch', (_e, { type, arg }: { type: string; arg: string }) => {
  const a = resolve(arg)

  // open URL or folder
  if (type === 'xdg' || type === 'open') {
    spawn(XDG, [a], { detached: true, stdio: 'ignore' }).unref()
    return
  }

  // nix build — kdialog progress OR konsole
  if (type === 'build' || type === 'build-system' || type === 'build-desktop') {
    const flake =
      type === 'build'         ? (profile.flake           || '') :
      type === 'build-system'  ? (profile.flakes?.system  || profile.flake || '') :
                                 (profile.flakes?.desktop || profile.flake || '')
    if (type === 'build' && switchGui && flake) {
      spawn(BASH, [switchGui, a], { detached: true, stdio: 'ignore', cwd: flake }).unref()
    } else {
      konsole(`cd "${flake}" && PATH="/run/wrappers/bin:$PATH" bash build.sh ${a}`)
    }
    return
  }

  // tail build log
  if (type === 'log' || type === 'log-system' || type === 'log-desktop') {
    const logDir =
      type === 'log'         ? (profile.flake           || '') :
      type === 'log-system'  ? (profile.flakes?.system  || profile.flake || '') :
                               (profile.flakes?.desktop || profile.flake || '')
    konsole(`ls -t "${logDir}/logs/"*.log 2>/dev/null | head -1 | xargs tail -f 2>/dev/null || echo "No logs in ${logDir}/logs/"`)
    return
  }

  // shell — stream stdout/stderr into the panel output div
  if (!win) return
  const proc = spawn(BASH, ['-c', a], { stdio: 'pipe' })
  proc.stdout?.on('data', (d: Buffer) => win?.webContents.send('output', d.toString()))
  proc.stderr?.on('data', (d: Buffer) => win?.webContents.send('output', d.toString()))
  proc.on('close', (code: number | null) => win?.webContents.send('done', code ?? -1))
})

ipcMain.on('switch-profile', (_e, name: string) => launchProfile(name))

function launchProfile(name: string) {
  spawn(`electron-terminal-${name}`, ['--show'], { detached: true, stdio: 'ignore' }).unref()
}
