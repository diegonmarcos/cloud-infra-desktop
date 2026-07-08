// term.js — one xterm.js instance + Rust PTY per tab. Konsole keybindings.
const invoke = window.__TAURI__.core.invoke;
const listen = window.__TAURI__.event.listen;

const MYK = {
  terms: new Map(),   // id -> { term, fit, search, host, unlisten }
  active: null,
  seq: 0,

  theme: {
    background: "#232629", foreground: "#fcfcfc", cursor: "#fcfcfc",
    black: "#232629", red: "#ed1515", green: "#11d116", yellow: "#f67400",
    blue: "#1d99f3", magenta: "#9b59b6", cyan: "#1abc9c", white: "#fcfcfc",
    brightBlack: "#7f8c8d", brightRed: "#c0392b", brightGreen: "#1cdc9a",
    brightYellow: "#fdbc4b", brightBlue: "#3daee9", brightMagenta: "#8e44ad",
    brightCyan: "#16a085", brightWhite: "#ffffff",
  },

  async newTerm(title) {
    const id = "t" + ++this.seq;
    const host = document.createElement("div");
    host.className = "term";
    host.dataset.id = id;
    document.getElementById("terms").appendChild(host);

    const term = new Terminal({
      fontFamily: '"JetBrainsMono Nerd Font", "JetBrains Mono", monospace',
      fontSize: 11, scrollback: 5000, cursorBlink: true, theme: this.theme,
      allowProposedApi: true,
    });
    const fit = new FitAddon.FitAddon();
    const search = new SearchAddon.SearchAddon();
    term.loadAddon(fit);
    term.loadAddon(search);
    term.open(host);

    this._bindKeys(term, id);
    term.onData((d) => invoke("pty_write", { id, data: d }));
    term.onResize(({ cols, rows }) => invoke("pty_resize", { id, cols, rows }));
    term.onTitleChange((t) => Tabs.setTitle(id, t));

    const unlisten = await listen(`pty:${id}`, (e) => term.write(e.payload.data));
    await listen(`pty-exit:${id}`, () => Tabs.close(id));

    this.terms.set(id, { term, fit, search, host, unlisten });
    fit.fit();
    await invoke("pty_start", { id, cols: term.cols, rows: term.rows, cwd: null });
    Tabs.add(id, title || "shell");
    this.activate(id);
    return id;
  },

  activate(id) {
    this.active = id;
    for (const [tid, t] of this.terms) {
      const on = tid === id;
      t.host.classList.toggle("active", on);
      if (on) { t.fit.fit(); t.term.focus(); }
    }
  },

  dispose(id) {
    const t = this.terms.get(id);
    if (!t) return;
    invoke("pty_kill", { id });
    if (t.unlisten) t.unlisten();
    t.term.dispose();
    t.host.remove();
    this.terms.delete(id);
  },

  fitActive() { const t = this.terms.get(this.active); if (t) t.fit.fit(); },

  // Konsole default keybindings.
  _bindKeys(term, id) {
    term.attachCustomKeyEventHandler((e) => {
      if (e.type !== "keydown") return true;
      const c = e.ctrlKey && e.shiftKey;
      if (c && e.code === "KeyT") { Tabs.newTab(); return false; }          // new tab
      if (c && e.code === "KeyW") { Tabs.close(this.active); return false; } // close TAB
      if (c && e.code === "KeyC") {                                          // copy
        const sel = term.getSelection();
        if (sel) { navigator.clipboard.writeText(sel); return false; }
        return true; // no selection → let Ctrl+Shift+C fall through
      }
      if (c && e.code === "KeyV") {                                          // paste
        navigator.clipboard.readText().then((t) => invoke("pty_write", { id, data: t }));
        return false;
      }
      if (c && e.code === "KeyF") { Find.open(); return false; }            // find
      if (e.ctrlKey && e.code === "PageDown") { Tabs.next(); return false; }
      if (e.ctrlKey && e.code === "PageUp")   { Tabs.prev(); return false; }
      return true;
    });
  },
};

// Find bar (Konsole Ctrl+Shift+F)
const Find = {
  open() {
    const bar = document.getElementById("findbar");
    bar.hidden = false;
    document.getElementById("find-input").focus();
  },
  close() { document.getElementById("findbar").hidden = true; MYK.terms.get(MYK.active)?.term.focus(); },
  _s() { return MYK.terms.get(MYK.active)?.search; },
  next() { const q = document.getElementById("find-input").value; if (q) this._s()?.findNext(q); },
  prev() { const q = document.getElementById("find-input").value; if (q) this._s()?.findPrevious(q); },
};
