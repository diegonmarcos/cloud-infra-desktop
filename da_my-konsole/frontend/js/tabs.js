// tabs.js — tab strip. Each tab belongs to a profile (its "group"); switching
// profile shows only that group's tabs in the strip + center pane. Each tab
// owns a `.tab-root` in #terms that holds its pane split-tree (term.js).
const Tabs = {
  tabs: new Map(),  // tabId -> { rootEl, tabEl, profile, isBrowser }
  order: [],
  active: null,
  activeProfile: null,
  lastActiveByProfile: new Map(),
  seq: 0,

  async newTab(profile = this.activeProfile) {
    const tabId = "T" + ++this.seq;
    const rootEl = document.createElement("div");
    rootEl.className = "tab-root";
    rootEl.dataset.id = tabId;
    document.getElementById("terms").appendChild(rootEl);

    const tabEl = document.createElement("div");
    tabEl.className = "tab"; tabEl.dataset.id = tabId;
    tabEl.innerHTML = `<span class="tab-title">shell</span><span class="tab-close">✕</span>`;
    tabEl.addEventListener("click", (e) => {
      if (e.target.classList.contains("tab-close")) { this.close(tabId); return; }
      this.activate(tabId);
    });
    document.getElementById("tabstrip").appendChild(tabEl);

    this.tabs.set(tabId, { rootEl, tabEl, profile });
    this.order.push(tabId);
    const paneId = await MYK.makePane(tabId, rootEl);
    this.activate(tabId);
    MYK.focusPane(paneId);
    return tabId;
  },

  // ── Browser tab: single iframe, no PTY. Reuses the OS webview engine
  // (WebKitGTK) — no bundled Chromium, no extra deps. One per profile.
  openBrowserTab(url, profile = this.activeProfile) {
    const tabId = "T" + ++this.seq;
    const rootEl = document.createElement("div");
    rootEl.className = "tab-root";
    rootEl.dataset.id = tabId;
    rootEl.innerHTML = `<iframe class="browser-frame" src="${url}"></iframe>`;
    document.getElementById("terms").appendChild(rootEl);

    const tabEl = document.createElement("div");
    tabEl.className = "tab"; tabEl.dataset.id = tabId;
    tabEl.innerHTML = `<span class="tab-title">Browser</span><span class="tab-close">✕</span>`;
    tabEl.addEventListener("click", (e) => {
      if (e.target.classList.contains("tab-close")) { this.close(tabId); return; }
      this.activate(tabId);
    });
    document.getElementById("tabstrip").appendChild(tabEl);

    this.tabs.set(tabId, { rootEl, tabEl, profile, isBrowser: true });
    this.order.push(tabId);
    this.activate(tabId);
    return tabId;
  },

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
  },

  // Switch to a profile's tab group: show only its tabs in the strip,
  // resume its last-active tab, or open a fresh one if it has none yet.
  switchProfile(p) {
    const name = p.name;
    if (this.activeProfile === name) return;
    this.activeProfile = name;
    for (const [, t] of this.tabs) t.tabEl.style.display = t.profile === name ? "" : "none";

    const last = this.lastActiveByProfile.get(name);
    if (last && this.tabs.has(last)) { this.activate(last); return; }
    if (p.browser) this.openBrowserTab(p.url, name);
    else this.newTab(name);
  },

  setTitle(tabId, title) {
    const t = this.tabs.get(tabId);
    if (t && title) t.tabEl.querySelector(".tab-title").textContent = title;
  },

  close(tabId) {
    if (!this.tabs.has(tabId)) return;
    const profile = this.tabs.get(tabId).profile;
    MYK.disposeTab(tabId);
    const t = this.tabs.get(tabId);
    t.rootEl.remove(); t.tabEl.remove();
    this.tabs.delete(tabId);
    this.order = this.order.filter((x) => x !== tabId);

    const remaining = this.order.filter((id) => this.tabs.get(id)?.profile === profile);
    if (remaining.length === 0) { this.newTab(profile); return; }
    if (this.active === tabId) this.activate(remaining[remaining.length - 1]);
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
    const strip = document.getElementById("tabstrip");
    group.forEach((id) => strip.appendChild(this.tabs.get(id).tabEl));
  },
};
