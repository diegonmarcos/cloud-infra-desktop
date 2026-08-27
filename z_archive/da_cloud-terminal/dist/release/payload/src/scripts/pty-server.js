#!/usr/bin/env node
// PTY helper — runs under SYSTEM node (not Electron) so the prebuilt node-pty
// .node binary matches the ABI. Electron main spawns this and brokers bytes to
// the renderer's xterm.js. One helper process == one interactive shell.
//
// Protocol (newline-delimited JSON on stdin):
//   {"type":"data","d":"<keystrokes>"}
//   {"type":"resize","cols":N,"rows":N}
// Output: raw PTY bytes on stdout. Control (exit) as JSON line on stderr.

const pty = require('@homebridge/node-pty-prebuilt-multiarch')

const shell = process.env.CT_SHELL || 'fish'
const cwd   = process.env.CT_CWD   || process.env.HOME || '/'
const cols  = parseInt(process.env.CT_COLS || '80', 10)
const rows  = parseInt(process.env.CT_ROWS || '24', 10)

// NixOS: the setuid sudo lives in /run/wrappers/bin — it MUST precede
// /run/current-system/sw/bin (whose sudo is not setuid) or sudo refuses to run.
const wrappers = '/run/wrappers/bin'
const basePath = process.env.PATH || ''
const PATH = basePath.split(':').includes(wrappers) ? basePath : `${wrappers}:${basePath}`

const term = pty.spawn(shell, ['-l'], {
  name: 'xterm-256color',
  cols, rows, cwd,
  env: { ...process.env, TERM: 'xterm-256color', PATH },
})

term.onData(d => process.stdout.write(d))
term.onExit(({ exitCode }) => {
  try { process.stderr.write(JSON.stringify({ type: 'exit', code: exitCode }) + '\n') } catch (_) {}
  process.exit(0)
})

// Read newline-delimited JSON control messages on stdin
let buf = ''
process.stdin.setEncoding('utf8')
process.stdin.on('data', chunk => {
  buf += chunk
  let nl
  while ((nl = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, nl); buf = buf.slice(nl + 1)
    if (!line) continue
    let msg
    try { msg = JSON.parse(line) } catch (_) { continue }
    if (msg.type === 'data')        term.write(msg.d)
    else if (msg.type === 'resize') { try { term.resize(msg.cols, msg.rows) } catch (_) {} }
  }
})
process.stdin.on('end', () => { try { term.kill() } catch (_) {} process.exit(0) })
