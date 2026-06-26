/**
 * NixOS Control Panel — Electron main process.
 * Native SNI tray (no xembedsniproxy, no "Input devices" portal popup).
 * All paths injected via env vars set by Nix makeWrapper.
 */
import { app, Tray, BrowserWindow, Menu, ipcMain } from 'electron'
import { spawn, ChildProcess } from 'child_process'
import * as path from 'path'
import * as fs   from 'fs'

// ── env vars baked in by Nix makeWrapper ──────────────────────────────────────
const DATA       = process.env.SYSTRAY_DATA!
const BASH       = process.env.SYSTRAY_BASH!
const KONSOLE    = process.env.SYSTRAY_KONSOLE!
const XDG        = process.env.SYSTRAY_XDG!
const SWITCH_GUI = process.env.SYSTRAY_SWITCH_GUI!
const FLAKE      = process.env.SYSTRAY_FLAKE!
const ICON_PATH  = process.env.SYSTRAY_ICON!

// ── types ─────────────────────────────────────────────────────────────────────
interface Item {
  label: string
  type:  'build' | 'shell' | 'log' | 'open' | 'xdg'
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

function genTooltip(data: CpData): string {
  const base = data.tray_tooltip ?? 'NixOS Control Panel'
  let gen = '?'
  try {
    const link = fs.readlinkSync('/nix/var/nix/profiles/system')
    gen = link.split('-')[1] ?? '?'
  } catch {}
  let last = 'no builds yet'
  try {
    const logDir = path.join(FLAKE, 'logs')
    if (fs.existsSync(logDir)) {
      const logs = fs.readdirSync(logDir).filter(f => f.endsWith('.log')).sort()
      if (logs.length) {
        const mtime = fs.statSync(path.join(logDir, logs[logs.length - 1])).mtime
        last = mtime.toLocaleString()
      }
    }
  } catch {}
  return `${base} | Gen ${gen} | Last: ${last}`
}

// ── state ─────────────────────────────────────────────────────────────────────
let proc: ChildProcess | null = null

function killProc() {
  if (proc) { try { proc.kill() } catch {} proc = null }
}

// ── dispatch (called from both context menu and panel window) ─────────────────
function dispatch(item: Item, win: BrowserWindow | null) {
  const arg = (item.arg ?? '').replace('{FLAKE}', FLAKE)

  const sendOut  = (s: string) => win?.webContents.send('output', s)
  const sendDone = (c: number) => win?.webContents.send('done', c)

  switch (item.type) {
    case 'build':
      // kdialog progress window via switch-gui.sh
      spawn(SWITCH_GUI, [arg], { detached: true, stdio: 'ignore' }).unref()
      sendOut(`[${item.label}] build launched — see kdialog progress window\n`)
      break

    case 'shell': {
      const needsTty = arg.includes('sudo') || arg.includes('loginctl')
      if (needsTty) {
        spawn(KONSOLE, ['--hold', '--separate', '-p', 'ColorScheme=Breeze',
          '--title', `NixOS — ${item.label}`,
          '-e', BASH, '-lc', `${arg}; printf '\\n=== done (exit %s) ===\\n' "$?"`],
          { detached: true, stdio: 'ignore' }).unref()
        sendOut(`[${item.label}] needs sudo — opened Konsole\n`)
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

    case 'log': {
      const logDir = path.join(FLAKE, 'logs')
      const logs   = fs.existsSync(logDir)
        ? fs.readdirSync(logDir).filter(f => f.endsWith('.log')).sort()
        : []
      if (logs.length) {
        const tgt = path.join(logDir, logs[logs.length - 1])
        killProc()
        sendOut(`\n[tail] ${tgt}\n${'─'.repeat(70)}\n`)
        proc = spawn(BASH, ['-lc', `tail -n 200 '${tgt}'`])
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
      sendOut(`[${item.label}] opened: ${arg}\n`)
      break
  }
}

// ── main ──────────────────────────────────────────────────────────────────────
app.on('ready', () => {
  const data  = loadData()
  const items = flatItems(data)

  // ── panel window (hidden until left-click) ──
  const win = new BrowserWindow({
    width: 960, height: 580,
    title: 'NixOS Control Panel',
    show: false,
    webPreferences: { nodeIntegration: true, contextIsolation: false },
  })
  win.loadFile(path.join(__dirname, 'panel.html'))
  win.on('close', (e: any) => { e.preventDefault(); win.hide() })

  // ── IPC from renderer ──
  ipcMain.on('get-data',  (_e)          => { _e.reply('data', data) })
  ipcMain.on('run-cmd',   (_e, idx: number) => dispatch(items[idx], win))
  ipcMain.on('kill-cmd',  ()            => killProc())

  // ── tray ──
  const tray = new Tray(ICON_PATH)
  tray.setToolTip(genTooltip(data))

  // right-click context menu (quick-run without opening panel)
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

  // left-click → toggle panel
  tray.on('click', () => {
    if (win.isVisible()) { win.hide() }
    else { win.show(); win.focus() }
  })
})

app.on('window-all-closed', () => { /* keep alive — tray app */ })
