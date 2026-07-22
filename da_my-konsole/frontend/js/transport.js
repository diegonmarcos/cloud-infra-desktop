// transport.js — PTY I/O transport: Tauri IPC (desktop) or WebSocket (Android
// WebView / plain browser) to the my-konsole-engine ws server. Selected ONCE
// at load by `window.__TAURI__` presence. Desktop path is byte-identical to
// the old direct invoke/listen calls it replaces.
//
// Wire protocol (frozen, matches my-konsole-engine):
//   client→server: {op:"start",id,cols,rows,cwd} {op:"write",id,data}
//                  {op:"resize",id,cols,rows} {op:"kill",id}
//   server→client: {ev:"output",id,data} {ev:"exit",id}

// ── pure wire-protocol fns — importable under node, no window/DOM needed ──
function _encode(op) { return JSON.stringify(op); }
function _decode(str) { return JSON.parse(str); }

// ── browser wiring — skipped entirely under node (no `window` there) ──
if (typeof window !== "undefined") {
  const hasTauri = !!window.__TAURI__;

  // Tauri impl (desktop): thin wrapper over invoke/listen, same calls as before.
  const tauriImpl = {
    ptyStart: (id, cols, rows, cwd) => window.__TAURI__.core.invoke("pty_start", { id, cols, rows, cwd }),
    ptyWrite: (id, data) => window.__TAURI__.core.invoke("pty_write", { id, data }),
    ptyResize: (id, cols, rows) => window.__TAURI__.core.invoke("pty_resize", { id, cols, rows }),
    ptyKill: (id) => window.__TAURI__.core.invoke("pty_kill", { id }),
    onPty: (id, cb) => window.__TAURI__.event.listen(`pty:${id}`, (e) => cb(e.payload.data)),
    onPtyExit: (id, cb) => window.__TAURI__.event.listen(`pty-exit:${id}`, () => cb()),
  };

  // WebSocket impl (Android WebView / browser): one shared socket to the engine.
  // Outbound frames sent before `open` are queued and flushed on open.
  function makeWsImpl() {
    const url = window.MYK_ENGINE_URL || "ws://127.0.0.1:7333";
    const subs = new Map(); // id -> { out, exit }
    let open = false, queue = [];
    const ws = new WebSocket(url);
    const send = (op) => { const f = _encode(op); if (open) ws.send(f); else queue.push(f); };

    ws.addEventListener("open", () => {
      open = true;
      if (window.MYK_ENGINE_TOKEN) ws.send(_encode({ op: "auth", token: window.MYK_ENGINE_TOKEN }));
      queue.forEach((f) => ws.send(f));
      queue = [];
    });
    ws.addEventListener("message", (e) => {
      const m = _decode(e.data);
      const s = subs.get(m.id);
      if (!s) return;
      if (m.ev === "output") s.out?.(m.data);
      else if (m.ev === "exit") s.exit?.();
    });
    // ponytail: no reconnect/backoff — add if the engine proves flaky in the field.

    return {
      ptyStart: (id, cols, rows, cwd) => { send({ op: "start", id, cols, rows, cwd }); return Promise.resolve(); },
      ptyWrite: (id, data) => { send({ op: "write", id, data }); return Promise.resolve(); },
      ptyResize: (id, cols, rows) => send({ op: "resize", id, cols, rows }),
      ptyKill: (id) => send({ op: "kill", id }),
      onPty: (id, cb) => {
        const s = subs.get(id) || {}; s.out = cb; subs.set(id, s);
        return () => { s.out = null; };
      },
      onPtyExit: (id, cb) => {
        const s = subs.get(id) || {}; s.exit = cb; subs.set(id, s);
        return () => { s.exit = null; };
      },
    };
  }

  const impl = hasTauri ? tauriImpl : makeWsImpl();
  window.Transport = { ...impl, _encode, _decode };
}

// ── node test import (see transport.test.js) — no-op in the browser ──
if (typeof module !== "undefined" && module.exports) {
  module.exports = { _encode, _decode };
}
