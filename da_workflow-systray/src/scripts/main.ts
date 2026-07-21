/**
 * Workflow Control Panel — Electron main process.
 * Native SNI tray (no xembedsniproxy, no "Input devices" portal popup).
 * All paths injected via env vars set by Nix makeWrapper.
 *
 * Data sources (all read from SYSTRAY_DATA JSON, never hardcoded here):
 *   - GHA status: SSE subscribe to https://<ntfyDomain>/<ntfyTopic>/sse,
 *     falling back to polling `gh run list` per repo when SSE is down.
 *   - Dagu: plain REST GET/POST against <daguBaseUrl>/api/v1/dags (WG-mesh auth model).
 */
import { app, Tray, BrowserWindow, Menu, ipcMain } from 'electron'
import { spawn, execFile, ChildProcess } from 'child_process'
import * as https from 'https'
import * as path  from 'path'
import * as fs    from 'fs'

// Route ALL uncaught errors to stderr → systemd journal instead of native dialog
process.on('uncaughtException', (err) => {
  console.error('[workflow-systray] UNCAUGHT:', err.stack ?? err.message)
  process.exit(1)
})
process.on('unhandledRejection', (reason) => {
  console.error('[workflow-systray] UNHANDLED REJECTION:', reason)
  process.exit(1)
})

// ── env vars baked in by Nix makeWrapper ──────────────────────────────────────
const DATA      = process.env.SYSTRAY_DATA!
const BASH      = process.env.SYSTRAY_BASH!
const KONSOLE   = process.env.SYSTRAY_KONSOLE!
const XDG       = process.env.SYSTRAY_XDG!
const GH        = process.env.SYSTRAY_GH ?? 'gh'
const ICON_PATH = process.env.SYSTRAY_ICON!

// ── types ─────────────────────────────────────────────────────────────────────
interface Item {
  label:    string
  type:     'shell' | 'open' | 'xdg' | 'gh-run-list' | 'gh-workflow-run' | 'dagu-list' | 'dagu-start'
  arg?:     string
  icon?:    string
  repo?:    string
  workflow?: string
  dag?:     string
}
interface Section { title: string; items: Item[] }
interface CpData {
  sections:      Section[]
  tray_tooltip?: string
  tray_icon?:    string
  repos:         string[]
  ghOwner:       string
  ntfyDomain:    string
  ntfyTopic:     string
  daguBaseUrl:   string
  pollIntervalMs: number
}

interface GhaRun {
  databaseId:  number
  status:      string
  conclusion:  string | null
  workflowName: string
  headBranch:  string
  updatedAt:   string
}

// ── helpers ───────────────────────────────────────────────────────────────────
function loadData(): CpData {
  return JSON.parse(fs.readFileSync(DATA, 'utf8'))
}

function flatItems(data: CpData): Item[] {
  return data.sections.flatMap(s => s.items)
}

function genTooltip(data: CpData): string {
  return data.tray_tooltip ?? 'Workflows'
}

// ── state ─────────────────────────────────────────────────────────────────────
let proc: ChildProcess | null = null
let sseReq: any = null
let pollTimer: any = null
let sseRetryTimer: any = null

function killProc() {
  if (proc) { try { proc.kill() } catch {} proc = null }
}

// ── GHA status: SSE (primary) + gh CLI poll (fallback) ────────────────────────
function startGhaStatus(data: CpData, win: BrowserWindow | null) {
  connectSSE(data, win)
}

function connectSSE(data: CpData, win: BrowserWindow | null) {
  if (sseReq) { try { sseReq.destroy() } catch {} sseReq = null }

  const url = `https://${data.ntfyDomain}/${data.ntfyTopic}/sse`
  let buf = ''

  const req = https.get(url, { headers: { Accept: 'text/event-stream' } }, (res) => {
    if (res.statusCode !== 200) {
      res.destroy()
      fallbackToPolling(data, win)
      return
    }
    // SSE connected — stop polling if it was running, keep a retry timer
    // just in case the connection drops silently later.
    stopPolling()
    win?.webContents.send('gha-source', 'sse')
    res.setEncoding('utf8')
    res.on('data', (chunk: string) => {
      buf += chunk
      let idx: number
      while ((idx = buf.indexOf('\n\n')) !== -1) {
        const event = buf.slice(0, idx)
        buf = buf.slice(idx + 2)
        const dataLine = event.split('\n').find(l => l.startsWith('data:'))
        if (!dataLine) continue
        const payload = dataLine.slice(5).trim()
        try {
          const msg = JSON.parse(payload)
          win?.webContents.send('gha-event', msg)
        } catch { /* non-JSON ntfy keepalive line — ignore */ }
      }
    })
    res.on('end',   () => fallbackToPolling(data, win))
    res.on('error', () => fallbackToPolling(data, win))
  })
  req.on('error', () => fallbackToPolling(data, win))
  req.setTimeout(15000, () => { req.destroy() })
  sseReq = req
}

function fallbackToPolling(data: CpData, win: BrowserWindow | null) {
  win?.webContents.send('gha-source', 'poll')
  startPolling(data, win)
  // Periodically retry SSE so we switch back to push once it recovers.
  if (!sseRetryTimer) {
    sseRetryTimer = setInterval(() => connectSSE(data, win), Math.max(data.pollIntervalMs * 2, 120000))
  }
}

function startPolling(data: CpData, win: BrowserWindow | null) {
  if (pollTimer) return
  const poll = () => pollGhRuns(data, win)
  poll()
  pollTimer = setInterval(poll, data.pollIntervalMs)
}

function stopPolling() {
  if (pollTimer) { clearInterval(pollTimer); pollTimer = null }
}

function pollGhRuns(data: CpData, win: BrowserWindow | null) {
  for (const repo of data.repos) {
    execFile(GH, [
      'run', 'list', '--repo', `${data.ghOwner}/${repo}`, '--limit', '5',
      '--json', 'databaseId,status,conclusion,workflowName,headBranch,updatedAt',
    ], { timeout: 20000 }, (err, stdout) => {
      if (err) { win?.webContents.send('gha-poll-error', { repo, error: String(err) }); return }
      try {
        const runs: GhaRun[] = JSON.parse(stdout)
        win?.webContents.send('gha-poll', { repo, runs })
      } catch { /* ignore malformed output */ }
    })
  }
}

// ── Dagu: plain REST, no auth headers (WG mesh membership is the auth model) ──
function daguRequest(baseUrl: string, urlPath: string, method: 'GET' | 'POST', cb: (err: Error | null, body?: any) => void) {
  const u = new URL(baseUrl + urlPath)
  const isHttps = u.protocol === 'https:'
  const lib: any = isHttps ? https : require('http')
  const req = lib.request({
    hostname: u.hostname,
    port:     u.port ? Number(u.port) : (isHttps ? 443 : 80),
    path:     u.pathname + u.search,
    method,
  }, (res: any) => {
    let body = ''
    res.setEncoding('utf8')
    res.on('data', (c: string) => body += c)
    res.on('end', () => {
      try { cb(null, body ? JSON.parse(body) : null) }
      catch { cb(null, body) }
    })
  })
  req.on('error', (e: Error) => cb(e))
  req.setTimeout(10000, () => req.destroy())
  req.end()
}

function daguList(data: CpData, cb: (err: Error | null, body?: any) => void) {
  daguRequest(data.daguBaseUrl, '/api/v1/dags', 'GET', cb)
}

function daguStart(data: CpData, name: string, cb: (err: Error | null, body?: any) => void) {
  daguRequest(data.daguBaseUrl, `/api/v1/dags/${encodeURIComponent(name)}/start`, 'POST', cb)
}

// ── gh workflow trigger ────────────────────────────────────────────────────────
function ghWorkflowRun(data: CpData, repo: string, workflow: string, win: BrowserWindow | null) {
  const sendOut = (s: string) => win?.webContents.send('output', s)
  killProc()
  const arg = `${GH} workflow run '${workflow}' --repo '${data.ghOwner}/${repo}'`
  sendOut(`\n$ ${arg}\n${'─'.repeat(70)}\n`)
  proc = spawn(BASH, ['-lc', arg])
  proc.stdout?.on('data', d => sendOut(d.toString()))
  proc.stderr?.on('data', d => sendOut(d.toString()))
  proc.on('close', code => { proc = null; win?.webContents.send('done', code ?? 0) })
}

// ── dispatch ──────────────────────────────────────────────────────────────────
function dispatch(item: Item, data: CpData, win: BrowserWindow | null) {
  const label = item.label
  const sendOut  = (s: string) => win?.webContents.send('output', s)
  const sendDone = (c: number) => win?.webContents.send('done', c)

  switch (item.type) {
    case 'shell': {
      killProc()
      const arg = item.arg ?? ''
      sendOut(`\n$ ${arg}\n${'─'.repeat(70)}\n`)
      proc = spawn(BASH, ['-lc', arg])
      proc.stdout?.on('data', d => sendOut(d.toString()))
      proc.stderr?.on('data', d => sendOut(d.toString()))
      proc.on('close', code => { proc = null; sendDone(code ?? 0) })
      break
    }

    case 'open':
    case 'xdg':
      spawn(XDG, [item.arg ?? ''], { detached: true, stdio: 'ignore' }).unref()
      sendOut(`[${label}] opened: ${item.arg}\n`)
      break

    case 'gh-run-list':
      sendOut(`[${label}] polling gh run list for ${data.repos.join(', ')}…\n`)
      pollGhRuns(data, win)
      break

    case 'gh-workflow-run':
      if (item.repo && item.workflow) ghWorkflowRun(data, item.repo, item.workflow, win)
      break

    case 'dagu-list':
      sendOut(`[${label}] GET ${data.daguBaseUrl}/api/v1/dags\n`)
      daguList(data, (err, body) => {
        if (err) { sendOut(`dagu-list error: ${err.message}\n`); sendDone(1); return }
        sendOut(JSON.stringify(body, null, 2) + '\n')
        win?.webContents.send('dagu-list', body)
        sendDone(0)
      })
      break

    case 'dagu-start':
      if (!item.dag) break
      sendOut(`[${label}] POST ${data.daguBaseUrl}/api/v1/dags/${item.dag}/start\n`)
      daguStart(data, item.dag, (err, body) => {
        if (err) { sendOut(`dagu-start error: ${err.message}\n`); sendDone(1); return }
        sendOut(JSON.stringify(body, null, 2) + '\n')
        sendDone(0)
      })
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
    title: 'Workflow Control Panel',
    show: showOnStart,
    webPreferences: { nodeIntegration: true, contextIsolation: false },
  })
  win.loadFile(path.join(__dirname, 'panel.html'))
  win.on('close', (e: any) => { e.preventDefault(); win.hide() })

  ipcMain.on('get-data',   (_e)              => { _e.reply('data', data) })
  ipcMain.on('run-cmd',    (_e, idx: number) => dispatch(items[idx], data, win))
  ipcMain.on('kill-cmd',   ()                => killProc())
  ipcMain.on('get-about',  (_e)              => { _e.reply('about', {
    version: '0.1.0', data: DATA, icon: ICON_PATH,
  }) })
  ipcMain.on('dagu-list',  (_e)              => daguList(data, (err, body) => _e.reply('dagu-list', err ? { error: err.message } : body)))
  ipcMain.on('dagu-start', (_e, name: string) => daguStart(data, name, (err, body) => _e.reply('dagu-start', err ? { error: err.message } : body)))
  ipcMain.on('gh-run-list', ()               => pollGhRuns(data, win))
  ipcMain.on('gh-workflow-run', (_e, repo: string, workflow: string) => ghWorkflowRun(data, repo, workflow, win))

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
    menuItems.push({ label: item.label, click: () => dispatch(item, data, win.isVisible() ? win : null) })
  }
  menuItems.push({ type: 'separator' }, { label: 'Quit', click: () => { killProc(); stopPolling(); app.quit() } })
  tray.setContextMenu(Menu.buildFromTemplate(menuItems))

  tray.on('click', () => {
    if (win.isVisible()) { win.hide() }
    else { win.show(); win.focus() }
  })

  startGhaStatus(data, win)
})

app.on('window-all-closed', () => { /* keep alive — tray app */ })
