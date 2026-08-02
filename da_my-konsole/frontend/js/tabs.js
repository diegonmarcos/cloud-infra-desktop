// tabs.js — tab strip. Each tab belongs to a profile (its "group"); switching
// profile shows only that group's tabs in the strip + center pane. Each tab
// owns a `.tab-root` in #terms that holds its pane split-tree (term.js).
// Browser tabs are a plain <iframe> — CSS-positioned like any other DOM
// element (no floating native webview, no manual bounds-syncing). On Tauri,
// opening one first fires an "ensure_agentic_backend" invoke so our own
// localhost static servers / local goosed are lazily started before load.
// The browser tab's home page, and the fallback for any site that refuses to be
// framed. Kept as one constant so the address bar's "home" and a fresh tab can
// never disagree.
const HOME_URL = "https://linktree.diegonmarcos.com";

const ensureAgenticBackend = (url) => {
  if (window.__TAURI__) window.__TAURI__.core.invoke("ensure_agentic_backend", { url }).catch(() => {});
};

// ── Native child webviews ──────────────────────────────────────────────────
// A native webview floats above the DOM: nothing in CSS clips it, so its
// rectangle has to be pushed to the backend by hand. The rect is measured from
// a placeholder <div> that IS laid out by CSS, so the webview tracks whatever
// the stylesheet does (sidebar hidden, top nav hidden, window resized, tab
// strip growing a row) without any of those paths needing to know it exists.
//
// One 4 Hz poll drives every browser tab, and only invokes when a rect actually
// changed. Hooking the individual layout paths instead was the previous design
// and it is what let the webview render over the sidebar: every new layout path
// was a new chance to forget one. Measuring the truth is cheaper than
// enumerating the causes.
const NativeBrowser = {
  slots: new Map(),                       // label -> { host, last }
  timer: null,
  on() { return !!window.__TAURI__; },
  invoke(cmd, args) {
    if (!this.on()) return Promise.resolve();
    return window.__TAURI__.core.invoke(cmd, args).catch((e) => console.error(`[browser] ${cmd}`, e));
  },
  register(label, host) {
    this.slots.set(label, { host, last: null });
    if (!this.timer) this.timer = setInterval(() => this.sync(), 250);
  },
  unregister(label) {
    this.slots.delete(label);
    this.invoke("browser_close", { label });
    if (!this.slots.size && this.timer) { clearInterval(this.timer); this.timer = null; }
  },
  rectOf(host) {
    const r = host.getBoundingClientRect();
    // offsetParent===null means the element (or an ancestor) is display:none —
    // i.e. an inactive tab. getBoundingClientRect alone reports 0x0 for that,
    // which is indistinguishable from "not laid out yet".
    const visible = host.offsetParent !== null && r.width > 0 && r.height > 0;
    return { x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height), visible };
  },
  sync() {
    for (const [label, slot] of this.slots) {
      const r = this.rectOf(slot.host);
      const key = `${r.x},${r.y},${r.w},${r.h},${r.visible}`;
      if (key === slot.last) continue;
      slot.last = key;
      this.invoke("browser_bounds", { label, ...r });
    }
  },
  open(label, url, host) {
    this.register(label, host);
    const r = this.rectOf(host);
    return this.invoke("browser_open", { label, url, x: r.x, y: r.y, w: r.w, h: r.h });
  },
  navigate(label, url) { return this.invoke("browser_navigate", { label, url }); },
  back(label) { return this.invoke("browser_back", { label }); },
};

const Tabs = {
  tabs: new Map(),  // tabId -> { rootEl, tabEl, profile, isBrowser }
  order: [],
  active: null,
  activeProfile: null,
  lastActiveByProfile: new Map(),
  seq: 0,

  // ── Drag-to-reorder (Konsole-style): click-hold + drag a tab to move it.
  // Native HTML5 DnD — no library. Works on both the horizontal strip tabEl
  // and the vertical sidebar row for the same tabId. Drop position (left/right
  // half for the strip, top/bottom half for the vertical list) decides
  // before/after; reorderTo() rebuilds this.order + both DOM listings.
  _bindDrag(el, tabId, vertical = false) {
    el.draggable = true;
    el.addEventListener("dragstart", (e) => {
      e.dataTransfer.setData("text/plain", tabId);
      e.dataTransfer.effectAllowed = "move";
      el.classList.add("dragging");
    });
    el.addEventListener("dragend", () => el.classList.remove("dragging"));
    el.addEventListener("dragover", (e) => {
      e.preventDefault();
      const r = el.getBoundingClientRect();
      const after = vertical ? e.clientY - r.top > r.height / 2 : e.clientX - r.left > r.width / 2;
      el.classList.toggle("drag-over-after", after);
      el.classList.toggle("drag-over-before", !after);
    });
    el.addEventListener("dragleave", () => el.classList.remove("drag-over-after", "drag-over-before"));
    el.addEventListener("drop", (e) => {
      e.preventDefault();
      el.classList.remove("drag-over-after", "drag-over-before");
      const draggedId = e.dataTransfer.getData("text/plain");
      const r = el.getBoundingClientRect();
      const after = vertical ? e.clientY - r.top > r.height / 2 : e.clientX - r.left > r.width / 2;
      this.reorderTo(draggedId, tabId, after);
    });
  },

  reorderTo(draggedId, targetId, after) {
    if (draggedId === targetId || !this.tabs.has(draggedId) || !this.tabs.has(targetId)) return;
    this.order = this.order.filter((id) => id !== draggedId);
    let idx = this.order.indexOf(targetId);
    if (after) idx++;
    this.order.splice(idx, 0, draggedId);
    this._syncStripOrder();
    this.renderTabList();
  },

  _syncStripOrder() {
    const strip = document.getElementById("tabstrip"), btn = document.getElementById("btn-newtab");
    for (const id of this.order) if (this.tabs.has(id)) strip.insertBefore(this.tabs.get(id).tabEl, btn);
  },

  // ── Wire the strip's tabEl: click/close, right-click group menu, drag ──
  _wireTabEl(tabEl, tabId) {
    tabEl.addEventListener("click", (e) => {
      if (e.target.classList.contains("tab-close")) { this.close(tabId); return; }
      this.activate(tabId);
    });
    tabEl.addEventListener("contextmenu", (e) => {
      e.preventDefault();
      this.showTabMenu(tabId, e.clientX, e.clientY);
    });
    this._bindDrag(tabEl, tabId);
  },

  // ── Tab grouping: cluster tabs under a named, color-coded group. Purely
  // organizational (no isolation) — group tabs sit adjacent in both the
  // strip and the vertical sidebar list, tagged with a deterministic color.
  groupColor(name) {
    if (!name) return "transparent";
    let h = 0;
    for (let i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) % 360;
    return `hsl(${h}, 65%, 55%)`;
  },

  setGroup(tabId, name) {
    const t = this.tabs.get(tabId);
    if (!t) return;
    t.group = name || null;
    t.tabEl.style.borderLeftColor = this.groupColor(t.group);
    if (t.group) {
      const mates = this.order.filter((id) => id !== tabId && this.tabs.get(id)?.profile === t.profile && this.tabs.get(id)?.group === t.group);
      if (mates.length) {
        this.order = this.order.filter((id) => id !== tabId);
        this.order.splice(this.order.indexOf(mates[mates.length - 1]) + 1, 0, tabId);
      }
    }
    this._syncStripOrder();
    this.renderTabList();
  },

  showTabMenu(tabId, x, y) {
    document.getElementById("tab-menu")?.remove();
    const t = this.tabs.get(tabId);
    if (!t) return;
    const menu = document.createElement("div");
    menu.id = "tab-menu";
    const items = [
      [t.group ? "Rename Group…" : "New Group…", () => {
        const name = prompt("Group name:", t.group || "");
        if (name !== null) this.setGroup(tabId, name.trim());
      }],
    ];
    if (t.group) items.push(["Remove from Group", () => this.setGroup(tabId, null)]);
    items.push(["Close Tab", () => this.close(tabId)]);
    for (const [label, fn] of items) {
      const it = document.createElement("div");
      it.className = "pane-menu-item";
      it.textContent = label;
      it.addEventListener("click", () => { menu.remove(); fn(); });
      menu.appendChild(it);
    }
    document.body.appendChild(menu);
    const r = menu.getBoundingClientRect();
    menu.style.left = Math.min(x, window.innerWidth - r.width - 4) + "px";
    menu.style.top = Math.min(y, window.innerHeight - r.height - 4) + "px";
    const closeOnce = (e) => { if (!menu.contains(e.target)) menu.remove(); };
    setTimeout(() => document.addEventListener("mousedown", closeOnce, { once: true }), 0);
  },

  // ── Vertical tab list (sidebar "Tabs" view): current profile's tabs,
  // clustered by group (ungrouped last), draggable to reorder same as strip.
  renderTabList() {
    const host = document.getElementById("tabs-panel");
    if (!host) return;
    host.innerHTML = "";
    const ids = this._group();
    const byGroup = new Map();
    for (const id of ids) {
      const g = this.tabs.get(id)?.group || null;
      if (!byGroup.has(g)) byGroup.set(g, []);
      byGroup.get(g).push(id);
    }
    const keys = [...byGroup.keys()].sort((a, b) => (a === null) - (b === null));
    for (const g of keys) {
      if (g) {
        const h = document.createElement("div");
        h.className = "tabpanel-group-title";
        h.style.borderLeftColor = this.groupColor(g);
        h.textContent = g;
        host.appendChild(h);
      }
      for (const id of byGroup.get(g)) {
        const t = this.tabs.get(id);
        const row = document.createElement("div");
        row.className = "tabpanel-item" + (id === this.active ? " active" : "");
        row.dataset.id = id;
        row.style.borderLeftColor = g ? this.groupColor(g) : "transparent";
        row.innerHTML = `<span class="tab-icon">${t.icon}</span><span class="tabpanel-title">${t.tabEl.querySelector(".tab-title").textContent}</span><span class="tab-close">✕</span>`;
        row.addEventListener("click", (e) => {
          if (e.target.classList.contains("tab-close")) { this.close(id); return; }
          this.activate(id);
        });
        row.addEventListener("contextmenu", (e) => { e.preventDefault(); this.showTabMenu(id, e.clientX, e.clientY); });
        this._bindDrag(row, id, true);
        host.appendChild(row);
      }
    }
  },

  async newTab(profile = this.activeProfile) {
    const tabId = "T" + ++this.seq;
    const rootEl = document.createElement("div");
    rootEl.className = "tab-root";
    rootEl.dataset.id = tabId;
    document.getElementById("terms").appendChild(rootEl);

    const tabEl = document.createElement("div");
    tabEl.className = "tab"; tabEl.dataset.id = tabId;
    tabEl.innerHTML = `<span class="tab-icon">💻</span><span class="tab-title">shell</span><span class="tab-close">✕</span>`;
    this._wireTabEl(tabEl, tabId);
    document.getElementById("tabstrip").insertBefore(tabEl, document.getElementById("btn-newtab"));

    this.tabs.set(tabId, { rootEl, tabEl, profile, icon: "💻", group: null });
    this.order.push(tabId);
    const paneId = await MYK.makePane(tabId, rootEl);
    this.activate(tabId);
    MYK.focusPane(paneId);
    return tabId;
  },

  // ── Browser tab: a plain <iframe>, a normal DOM element laid out and
  // clipped by CSS exactly like every other tab pane — no floating native
  // webview, no manual bounds/visibility syncing, nothing that can render
  // outside the tab area. Closing the tab removes the iframe from the DOM,
  // which tears it down; no explicit close call needed.
  // `label` names the tab. Without it every browser tab was titled "Browser",
  // so a profile with several (agentic: Goose Desktop / Goose Cloud / Hermes
  // Cloud) showed three identical tabs and you could not tell the modes apart.
  openBrowserTab(url, profile = this.activeProfile, label) {
    url = url || HOME_URL;
    const tabId = "T" + ++this.seq;
    const wvLabel = "browser-" + tabId;
    const rootEl = document.createElement("div");
    rootEl.className = "tab-root";
    rootEl.dataset.id = tabId;
    // The address bar stays DOM (it must be clipped and scrolled with the tab);
    // .browser-host is an empty placeholder whose only job is to be measured —
    // the page itself is painted by the native webview parked over it.
    rootEl.innerHTML = `
      <div class="browser-wrap">
        <div class="browser-addr">
          <button class="browser-btn" data-act="back" title="Back">‹</button>
          <button class="browser-btn" data-act="reload" title="Reload">↻</button>
          <button class="browser-btn" data-act="home" title="Home">⌂</button>
          <input class="browser-addr-input" type="text" spellcheck="false" value="${url}" />
          <button class="browser-btn" data-act="external" title="Open in system browser">↗</button>
          <button class="browser-btn browser-btn-close" data-act="close" title="Close tab">✕</button>
        </div>
        <div class="browser-host"></div>
      </div>`;
    document.getElementById("terms").appendChild(rootEl);

    const addr = rootEl.querySelector(".browser-addr-input");
    const host = rootEl.querySelector(".browser-host");
    console.log(`[openBrowserTab] native webview ${wvLabel} url=${url} profile=${profile}`);
    // The rect is only real after the tab-root is activated + laid out; open on
    // the next frame so the first bounds we send are not 0x0.
    requestAnimationFrame(() => NativeBrowser.open(wvLabel, url, host));

    const go = (v) => {
      if (!/^[a-z]+:\/\//i.test(v)) v = "https://" + v;
      addr.value = v;
      const t = this.tabs.get(tabId); if (t) t.browserUrl = v;
      NativeBrowser.navigate(wvLabel, v);
    };
    addr.addEventListener("keydown", (e) => { if (e.key === "Enter") go(addr.value.trim()); });
    rootEl.querySelector('[data-act="back"]').addEventListener("click", () => NativeBrowser.back(wvLabel));
    rootEl.querySelector('[data-act="reload"]').addEventListener("click", () => go(addr.value.trim()));
    rootEl.querySelector('[data-act="home"]').addEventListener("click", () => go(HOME_URL));
    rootEl.querySelector('[data-act="external"]').addEventListener("click", () => {
      const target = addr.value.trim();
      if (window.__TAURI__?.opener?.openUrl) window.__TAURI__.opener.openUrl(target).catch(() => {});
      else if (window.__TAURI__?.shell?.open) window.__TAURI__.shell.open(target).catch(() => {});
      else window.open(target, "_blank", "noopener");
    });
    rootEl.querySelector('[data-act="close"]').addEventListener("click", () => this.close(tabId));

    const tabEl = document.createElement("div");
    tabEl.className = "tab"; tabEl.dataset.id = tabId;
    tabEl.innerHTML = `<span class="tab-icon">🌐</span><span class="tab-title"></span><span class="tab-close">✕</span>`;
    tabEl.querySelector(".tab-title").textContent = label || "Browser";
    this._wireTabEl(tabEl, tabId);
    document.getElementById("tabstrip").insertBefore(tabEl, document.getElementById("btn-newtab"));

    this.tabs.set(tabId, { rootEl, tabEl, profile, isBrowser: true, wvLabel, browserUrl: url, icon: "🌐", group: null });
    this.order.push(tabId);
    this.activate(tabId);
    return tabId;
  },

  // ── Home tab: the hub's inventory. DERIVED from the loaded profiles, never a
  // hand-written list — a new profile.json shows up here on its own, and one
  // that is removed disappears. The cards are the navigation: clicking a
  // terminal-cli card switches to that profile, so this doubles as the "what is
  // in this thing" answer and the fastest way to get anywhere in it.
  openHomeTab(profile = this.activeProfile) {
    const tabId = "T" + ++this.seq;
    const rootEl = document.createElement("div");
    rootEl.className = "tab-root";
    rootEl.dataset.id = tabId;

    const all = this.allProfiles || [];
    const apps = all.filter((p) => p.home && p.name !== "home");
    const clis = all.filter((p) => !p.home);
    const bookmarks = clis.reduce((n, p) => n + (p.sections || []).reduce((m, s) => m + (s.items || []).length, 0), 0);
    const app = (window.MYK?.config?.app) || {};
    const card = (t, d, target) =>
      `<div class="home-card"${target ? ` data-go="${target}"` : ""}><div class="t">${t}</div><div class="d">${d}</div></div>`;

    rootEl.innerHTML = `
      <div class="home-page">
        <div class="home-hero">
          <h1>my-konsole</h1>
          <div class="sub">The unix constellation hub — tauri apps, terminal CLIs and system trays in one window.</div>
        </div>
        <div class="home-stats">
          <div><b>${apps.length}</b>tauri-apps</div>
          <div><b>${clis.length}</b>terminal-clis</div>
          <div><b>${bookmarks}</b>bookmarks</div>
        </div>
        <div class="home-sec">tauri-apps</div>
        <div class="home-grid">${apps.map((p) =>
          card(p.display_name || p.name, p.browser ? "embedded web browser" : p.filebrowser ? "miller-column file browser" : p.fileeditor ? "plain + vim editor" : "GUI tab", p.name)).join("")}</div>
        <div class="home-sec">terminal-clis</div>
        <div class="home-grid">${clis.map((p) => {
          const n = (p.sections || []).reduce((m, s) => m + (s.items || []).length, 0);
          return card(p.display_name || p.name, `${n} bookmark${n === 1 ? "" : "s"}`, p.name);
        }).join("")}</div>
        <div class="home-sec">this build</div>
        <div class="home-stats">
          <div><b>${app.repo || "—"}</b>repo</div>
          <div><b>${app.bin || "—"}</b>binary</div>
        </div>
      </div>`;
    document.getElementById("terms").appendChild(rootEl);
    rootEl.addEventListener("click", (e) => {
      const c = e.target.closest("[data-go]");
      if (c) this.selectProfileByName?.(c.dataset.go);
    });

    const tabEl = document.createElement("div");
    tabEl.className = "tab"; tabEl.dataset.id = tabId;
    tabEl.innerHTML = `<span class="tab-icon">🏠</span><span class="tab-title">Home</span><span class="tab-close">✕</span>`;
    this._wireTabEl(tabEl, tabId);
    document.getElementById("tabstrip").insertBefore(tabEl, document.getElementById("btn-newtab"));

    this.tabs.set(tabId, { rootEl, tabEl, profile, isHome: true, icon: "🏠", group: null });
    this.order.push(tabId);
    this.activate(tabId);
    return tabId;
  },

  // ── File browser tab: yazi-style miller columns, no PTY.
  openFileBrowserTab(startPath, profile = this.activeProfile) {
    const tabId = "T" + ++this.seq;
    const rootEl = document.createElement("div");
    rootEl.className = "tab-root";
    rootEl.dataset.id = tabId;
    document.getElementById("terms").appendChild(rootEl);
    FileBrowser.mount(rootEl, startPath);

    const tabEl = document.createElement("div");
    tabEl.className = "tab"; tabEl.dataset.id = tabId;
    tabEl.innerHTML = `<span class="tab-icon">📁</span><span class="tab-title">Files</span><span class="tab-close">✕</span>`;
    this._wireTabEl(tabEl, tabId);
    document.getElementById("tabstrip").insertBefore(tabEl, document.getElementById("btn-newtab"));

    this.tabs.set(tabId, { rootEl, tabEl, profile, isFileBrowser: true, icon: "📁", group: null });
    this.order.push(tabId);
    this.activate(tabId);
    return tabId;
  },

  // ── File editor tab: plain textarea editor, no PTY. ponytail: syntax
  // highlighting later — this is deliberately just a <textarea>, no
  // CodeMirror/Monaco dependency.
  openFileEditorTab(path, profile = this.activeProfile) {
    console.log(`[openFileEditorTab] path=${path} profile=${profile}`);
    const tabId = "T" + ++this.seq;
    const rootEl = document.createElement("div");
    rootEl.className = "tab-root";
    rootEl.dataset.id = tabId;
    rootEl.innerHTML = `
      <div class="editor-wrap">
        <div class="editor-addr">
          <input class="editor-path-input" type="text" spellcheck="false" value="${path || ""}" />
          <button class="editor-reload" title="Reload">⟳</button>
          <button class="editor-save" title="Save">Save</button>
        </div>
        <textarea class="editor-area" spellcheck="false"></textarea>
      </div>`;
    document.getElementById("terms").appendChild(rootEl);

    const pathInput = rootEl.querySelector(".editor-path-input");
    const area = rootEl.querySelector(".editor-area");
    const load = async (p) => {
      if (!p) return;
      try { area.value = await Transport.readFile(p); }
      catch (e) { console.error("readFile failed", e); }
    };
    rootEl.querySelector(".editor-reload").addEventListener("click", () => load(pathInput.value.trim()));
    rootEl.querySelector(".editor-save").addEventListener("click", async () => {
      try { await Transport.writeFile(pathInput.value.trim(), area.value); console.log("saved", pathInput.value.trim()); }
      catch (e) { console.error("writeFile failed", e); }
    });

    const tabEl = document.createElement("div");
    tabEl.className = "tab"; tabEl.dataset.id = tabId;
    const title = path ? (path.split("/").filter(Boolean).pop() || path) : "untitled";
    tabEl.innerHTML = `<span class="tab-icon">📝</span><span class="tab-title">${title}</span><span class="tab-close">✕</span>`;
    this._wireTabEl(tabEl, tabId);
    document.getElementById("tabstrip").insertBefore(tabEl, document.getElementById("btn-newtab"));

    this.tabs.set(tabId, { rootEl, tabEl, profile, isFileEditor: true, icon: "📝", group: null });
    this.order.push(tabId);
    this.activate(tabId);
    if (path) load(path);
    return tabId;
  },

  // ── Run tab: a normal PTY tab that immediately runs a command. newTab awaits
  // the pane spawn, so the write lands on a ready shell (no timing hack).
  async openRunTab(cmd, title, profile = this.activeProfile) {
    console.log(`[openRunTab] profile=${profile} title=${title} cmd=${cmd}`);
    const tabId = await this.newTab(profile);
    if (title) this.setTitle(tabId, title);
    if (!cmd) return tabId;
    // Write to THIS tab's pane, and only once it exists. Reading MYK.activePane
    // straight after newTab() raced the pane being created and focused: the
    // write either went to the previously-focused pane or was dropped, which is
    // why "File Editor → Vim" opened a bare shell with no vim in it. Resolve the
    // pane from the tab we just made, and give the PTY a few frames to appear
    // before giving up.
    const paneOf = () => this.tabs.get(tabId)?.rootEl.querySelector(".pane")?.dataset.id;
    for (let i = 0; i < 40; i++) {
      const pane = paneOf();
      if (pane) { Transport.ptyWrite(pane, cmd + "\n"); return tabId; }
      await new Promise((r) => setTimeout(r, 50));
    }
    console.error(`[openRunTab] no pane after 2s — dropped: ${cmd}`);
    return tabId;
  },
  openVimTab(profile = this.activeProfile) { return this.openRunTab("vim", "vim", profile); },

  activate(tabId) {
    if (!this.tabs.has(tabId)) return;
    this.active = tabId;
    const profile = this.tabs.get(tabId).profile;
    this.activeProfile = profile;
    this.lastActiveByProfile.set(profile, tabId);
    for (const [tid, t] of this.tabs) {
      const on = tid === tabId;
      t.rootEl.classList.toggle("active", on);
      t.tabEl.classList.toggle("active", on);
    }
    const first = this.tabs.get(tabId).rootEl.querySelector(".pane");
    if (first) MYK.focusPane(first.dataset.id);
    this.renderTabList();
  },

  // Switch to a profile's tab group: show only its tabs in the strip,
  // resume its last-active tab, or open a fresh one if it has none yet.
  // Make `p`'s group the visible one. Always re-filters the strip so each
  // profile shows ONLY its own tabs (no cross-profile bleed). `opener` (optional)
  // forces a specific new tab — e.g. Vim — otherwise we resume the group's
  // last-active tab, or open its default kind if the group is empty. Re-selecting
  // the active profile reuses its tab instead of spawning a new one.
  switchProfile(p, opener) {
    const name = p.name;
    this.activeProfile = name;
    for (const [, t] of this.tabs) t.tabEl.style.display = t.profile === name ? "" : "none";
    // Hide the outgoing profile's CONTENT immediately, not just its tab button.
    // Only `activate()` used to clear `.active`, and several paths below reach
    // it late or not at all: `auto_tabs` activates inside an async IIFE, and
    // opening can fail outright. Until then the previous tab kept painting — so
    // a browser opened under one profile stayed visible under every other one.
    // activate() re-adds `.active` a moment later; an extra frame with an empty
    // pane is the correct trade against a tab that never goes away.
    for (const [, t] of this.tabs) {
      if (t.profile !== name) t.rootEl.classList.remove("active");
    }
    if (opener) { console.log(`[switchProfile] ${name} → opener()`); opener(name); return; }
    const last = this.lastActiveByProfile.get(name);
    if (last && this.tabs.has(last)) { console.log(`[switchProfile] ${name} → resume ${last}`); this.activate(last); return; }
    if (p.auto_tabs && p.auto_tabs.length) {
      console.log(`[switchProfile] ${name} → open ${p.auto_tabs.length} auto_tabs`);
      (async () => {
        const ids = [];
        for (const t of p.auto_tabs) {
          ids.push(t.kind === "browser" ? this.openBrowserTab(t.url, name, t.label) : await this.openRunTab(t.cmd, t.label, name));
        }
        if (ids[0]) this.activate(ids[0]);
      })();
      return;
    }
    const kind = p.homepage ? "homepage" : p.browser ? "browser" : p.filebrowser ? "filebrowser" : p.fileeditor ? "fileeditor" : p.home_cmd ? "hometab" : "shell";
    console.log(`[switchProfile] ${name} → open new ${kind}`);
    if (p.homepage) this.openHomeTab(name);
    else if (p.browser) this.openBrowserTab(p.url, name, p.display_name);
    else if (p.filebrowser) this.openFileBrowserTab(p.start_path || "~", name);
    else if (p.fileeditor) this.openFileEditorTab(null, name);
    else if (p.home_cmd) this.openRunTab(p.home_cmd, "Home", name);
    else this.newTab(name);
  },

  setTitle(tabId, title) {
    const t = this.tabs.get(tabId);
    if (t && title) t.tabEl.querySelector(".tab-title").textContent = title;
    this.renderTabList();
  },

  close(tabId) {
    if (!this.tabs.has(tabId)) return;
    const profile = this.tabs.get(tabId).profile;
    MYK.disposeTab(tabId);
    const t = this.tabs.get(tabId);
    // A native webview is not a DOM node — removing rootEl does NOT tear it
    // down, it would stay floating over the window forever.
    if (t.wvLabel) NativeBrowser.unregister(t.wvLabel);
    t.rootEl.remove(); t.tabEl.remove();
    this.tabs.delete(tabId);
    this.order = this.order.filter((x) => x !== tabId);

    const remaining = this.order.filter((id) => this.tabs.get(id)?.profile === profile);
    if (remaining.length === 0) { this.newTab(profile); return; }
    if (this.active === tabId) this.activate(remaining[remaining.length - 1]);
  },

  // ── Session snapshot: dump {profile, kind, url/startPath} per tab to
  // localStorage. No cwd tracking for shell tabs — restoring just opens a
  // fresh shell in that profile (ponytail: good enough, not a full state dump).
  saveSession() {
    const snap = this.order.map((id) => {
      const t = this.tabs.get(id);
      if (t.isHome) return { profile: t.profile, kind: "home" };
      if (t.isBrowser) return { profile: t.profile, kind: "browser", url: t.rootEl.querySelector(".browser-addr-input")?.value };
      if (t.isFileBrowser) return { profile: t.profile, kind: "filebrowser", startPath: t.rootEl.querySelector(".fb-addr-input")?.value };
      if (t.isFileEditor) return { profile: t.profile, kind: "fileeditor", path: t.rootEl.querySelector(".editor-path-input")?.value };
      return { profile: t.profile, kind: "shell" };
    });
    localStorage.setItem("myk-session", JSON.stringify(snap));
  },

  async restoreSession() {
    let snap;
    try { snap = JSON.parse(localStorage.getItem("myk-session") || "[]"); } catch { snap = []; }
    if (snap.length === 0) return;
    for (const t of snap) {
      if (t.kind === "home") this.openHomeTab(t.profile);
      else if (t.kind === "browser") this.openBrowserTab(t.url, t.profile);
      else if (t.kind === "filebrowser") this.openFileBrowserTab(t.startPath || "~", t.profile);
      else if (t.kind === "fileeditor") this.openFileEditorTab(t.path || null, t.profile);
      else await this.newTab(t.profile);
    }
  },

  next() { this._step(+1); },
  prev() { this._step(-1); },
  _group() { return this.order.filter((id) => this.tabs.get(id)?.profile === this.activeProfile); },
  _step(d) {
    const group = this._group();
    const i = group.indexOf(this.active);
    if (i < 0) return;
    this.activate(group[(i + d + group.length) % group.length]);
  },

  // Move the active tab left/right within its profile group.
  move(d) {
    const group = this._group();
    const i = group.indexOf(this.active);
    const j = i + d;
    if (i < 0 || j < 0 || j >= group.length) return;
    [group[i], group[j]] = [group[j], group[i]];
    const firstIdx = this.order.findIndex((id) => this.tabs.get(id)?.profile === this.activeProfile);
    this.order = this.order.filter((id) => this.tabs.get(id)?.profile !== this.activeProfile);
    this.order.splice(firstIdx, 0, ...group);
    const strip = document.getElementById("tabstrip"), btn = document.getElementById("btn-newtab");
    group.forEach((id) => strip.insertBefore(this.tabs.get(id).tabEl, btn));
    this.renderTabList();
  },
};
