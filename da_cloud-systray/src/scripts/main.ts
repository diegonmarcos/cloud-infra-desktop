/**
 * Cloud & Infra Control Panel — Electron main process.
 * Native SNI tray (no xembedsniproxy, no "Input devices" portal popup).
 * All paths injected via env vars set by Nix makeWrapper.
 */
import { app, Tray, BrowserWindow, Menu, ipcMain } from 'electron'
import { spawn, ChildProcess } from 'child_process'
import * as path from 'path'
import * as fs   from 'fs'

// Route ALL uncaught errors to stderr → systemd journal instead of native dialog
process.on('uncaughtException', (err) => {
  console.error('[cloud-systray] UNCAUGHT:', err.stack ?? err.message)
  process.exit(1)
})
process.on('unhandledRejection', (reason) => {
  console.error('[cloud-systray] UNHANDLED REJECTION:', reason)
  process.exit(1)
})

// ── env vars baked in by Nix makeWrapper ──────────────────────────────────────
const DATA           = process.env.SYSTRAY_DATA!
const BASH           = process.env.SYSTRAY_BASH!
const KONSOLE        = process.env.SYSTRAY_KONSOLE!
const XDG            = process.env.SYSTRAY_XDG!
const ICON_PATH      = process.env.SYSTRAY_ICON!
const FLAKE_SYSTEM   = process.env.SYSTRAY_FLAKE_SYSTEM   ?? ''
const FLAKE_DESKTOP  = process.env.SYSTRAY_FLAKE_DESKTOP  ?? ''
const FLAKE_CLOUD    = process.env.SYSTRAY_FLAKE_CLOUD    ?? ''

// ── types ─────────────────────────────────────────────────────────────────────
interface Item {
  label: string
  type:  'build-system' | 'build-desktop' | 'shell' | 'log-system' | 'log-desktop' | 'open' | 'xdg'
  arg?:  string
  icon?: string
}
interface Section { title: string; items: Item[] }
interface CpData  { sections: Section[]; tray_tooltip?: string; tray_icon?: string }

// ── helpers ───────────────────────────────────────────────────────────────────
function loadData(): CpData {
  return JSON.parse(fs.readFileSync(DATA, 'utf8'))
}

function flatItems(data: CpData): Item[] {
  return data.sections.flatMap(s => s.items)
}

function expandArg(arg: string): string {
  return arg
    .replace('{FLAKE_SYSTEM}',  FLAKE_SYSTEM)
    .replace('{FLAKE_DESKTOP}', FLAKE_DESKTOP)
    .replace('{FLAKE_CLOUD}',   FLAKE_CLOUD)
    .replace('{FLAKE}',         FLAKE_SYSTEM)
}

function latestLog(flake: string): string | null {
  const logDir = path.join(flake, 'logs')
  if (!fs.existsSync(logDir)) return null
  const logs = fs.readdirSync(logDir).filter(f => f.endsWith('.log')).sort()
  return logs.length ? path.join(logDir, logs[logs.length - 1]) : null
}

function genTooltip(data: CpData): string {
  const base = data.tray_tooltip ?? 'Cloud & Infra'
  let gen = '?'
  try {
    const link = fs.readlinkSync('/nix/var/nix/profiles/system')
    gen = link.split('-')[1] ?? '?'
  } catch {}
  let last = 'no builds yet'
  const log = FLAKE_SYSTEM ? latestLog(FLAKE_SYSTEM) : null
  if (log) {
    try { last = fs.statSync(log).mtime.toLocaleString() } catch {}
  }
  return `${base} | Sys Gen ${gen} | Last: ${last}`
}

// ── state ─────────────────────────────────────────────────────────────────────
let proc: ChildProcess | null = null

function killProc() {
  if (proc) { try { proc.kill() } catch {} proc = null }
}

// ── dispatch ──────────────────────────────────────────────────────────────────
function dispatch(item: Item, win: BrowserWindow | null) {
  const arg   = expandArg(item.arg ?? '')
  const label = item.label

  const sendOut  = (s: string) => win?.webContents.send('output', s)
  const sendDone = (c: number) => win?.webContents.send('done', c)

  switch (item.type) {
    case 'build-system':
    case 'build-desktop': {
      const flake = item.type === 'build-system' ? FLAKE_SYSTEM : FLAKE_DESKTOP
      spawn(KONSOLE, [
        '--hold', '--separate', '-p', 'ColorScheme=Breeze',
        '--title', `Build — ${label}`,
        '-e', BASH, '-lc',
        `cd '${flake}' && PATH=/run/wrappers/bin:$PATH ./build.sh '${arg}'; printf '\\n=== done (exit %s) ===\\n' "$?"`,
      ], { detached: true, stdio: 'ignore' }).unref()
      sendOut(`[${label}] build launched in Konsole\n`)
      break
    }

    case 'shell': {
      const needsTty = arg.includes('sudo') || arg.includes('nix-env')
      if (needsTty) {
        spawn(KONSOLE, [
          '--hold', '--separate', '-p', 'ColorScheme=Breeze',
          '--title', `Cloud — ${label}`,
          '-e', BASH, '-lc',
          `${arg}; printf '\\n=== done (exit %s) ===\\n' "$?"`,
        ], { detached: true, stdio: 'ignore' }).unref()
        sendOut(`[${label}] needs sudo — opened Konsole\n`)
      } else {
        killProc()
        sendOut(`\n$ ${arg}\n${'─'.repeat(70)}\n`)
        proc = spawn(BASH, ['-lc', arg])
        proc.stdout?.on('data', d => sendOut(d.toString()))
        proc.stderr?.on('data', d => sendOut(d.toString()))
        proc.on('close', code => { proc = null; sendDone(code ?? 0) })
      }
      break
    }

    case 'log-system':
    case 'log-desktop': {
      const flake = item.type === 'log-system' ? FLAKE_SYSTEM : FLAKE_DESKTOP
      const log   = latestLog(flake)
      if (log) {
        killProc()
        sendOut(`\n[tail] ${log}\n${'─'.repeat(70)}\n`)
        proc = spawn(BASH, ['-lc', `tail -n 200 '${log}'`])
        proc.stdout?.on('data', d => sendOut(d.toString()))
        proc.stderr?.on('data', d => sendOut(d.toString()))
        proc.on('close', code => { proc = null; sendDone(code ?? 0) })
      } else {
        sendOut('No build logs yet.\n')
      }
      break
    }

    case 'open':
    case 'xdg':
      spawn(XDG, [arg], { detached: true, stdio: 'ignore' }).unref()
      sendOut(`[${label}] opened: ${arg}\n`)
      break
  }
}

// ── main ──────────────────────────────────────────────────────────────────────
app.on('ready', () => {
  const data  = loadData()
  const items = flatItems(data)

  const showOnStart = process.argv.includes('--show')

  const win = new BrowserWindow({
    width: 1000, height: 620,
    title: 'Cloud & Infra Control Panel',
    show: showOnStart,
    webPreferences: { nodeIntegration: true, contextIsolation: false },
  })
  win.loadFile(path.join(__dirname, 'panel.html'))
  win.on('close', (e: any) => { e.preventDefault(); win.hide() })

  ipcMain.on('get-data',  (_e)          => { _e.reply('data', data) })
  ipcMain.on('run-cmd',   (_e, idx: number) => dispatch(items[idx], win))
  ipcMain.on('kill-cmd',  ()            => killProc())

  const tray = new Tray(ICON_PATH)
  tray.setToolTip(genTooltip(data))

  const menuItems: any[] = []
  let curSection = ''
  for (let i = 0; i < items.length; i++) {
    const item = items[i]
    const sec  = data.sections.find(s => s.items.includes(item))!.title
    if (sec !== curSection) {
      if (curSection) menuItems.push({ type: 'separator' })
      menuItems.push({ label: sec, enabled: false })
      curSection = sec
    }
    menuItems.push({ label: item.label, click: () => dispatch(item, win.isVisible() ? win : null) })
  }
  menuItems.push({ type: 'separator' }, { label: 'Quit', click: () => { killProc(); app.quit() } })
  tray.setContextMenu(Menu.buildFromTemplate(menuItems))

  tray.on('click', () => {
    if (win.isVisible()) { win.hide() }
    else { win.show(); win.focus() }
  })
})

app.on('window-all-closed', () => { /* keep alive — tray app */ })
