// tabs.js — tab strip. Each tab owns a `.tab-root` in #terms that holds its
// pane split-tree (term.js). Switching tabs shows/hides roots.
const Tabs = {
  tabs: new Map(),  // tabId -> { rootEl, tabEl }
  order: [],
  active: null,
  seq: 0,

  async newTab() {
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

    this.tabs.set(tabId, { rootEl, tabEl });
    this.order.push(tabId);
    const paneId = await MYK.makePane(tabId, rootEl);
    this.activate(tabId);
    MYK.focusPane(paneId);
    return tabId;
  },

  activate(tabId) {
    if (!this.tabs.has(tabId)) return;
    this.active = tabId;
    for (const [tid, t] of this.tabs) {
      const on = tid === tabId;
      t.rootEl.classList.toggle("active", on);
      t.tabEl.classList.toggle("active", on);
    }
    const first = this.tabs.get(tabId).rootEl.querySelector(".pane");
    if (first) MYK.focusPane(first.dataset.id);
  },

  setTitle(tabId, title) {
    const t = this.tabs.get(tabId);
    if (t && title) t.tabEl.querySelector(".tab-title").textContent = title;
  },

  close(tabId) {
    if (!this.tabs.has(tabId)) return;
    MYK.disposeTab(tabId);
    const t = this.tabs.get(tabId);
    t.rootEl.remove(); t.tabEl.remove();
    this.tabs.delete(tabId);
    this.order = this.order.filter((x) => x !== tabId);
    if (this.order.length === 0) { this.newTab(); return; }
    if (this.active === tabId) this.activate(this.order[this.order.length - 1]);
  },

  next() { this._step(+1); },
  prev() { this._step(-1); },
  _step(d) {
    const i = this.order.indexOf(this.active);
    if (i < 0) return;
    this.activate(this.order[(i + d + this.order.length) % this.order.length]);
  },

  // Move the active tab left/right in the strip + order.
  move(d) {
    const i = this.order.indexOf(this.active);
    const j = i + d;
    if (i < 0 || j < 0 || j >= this.order.length) return;
    [this.order[i], this.order[j]] = [this.order[j], this.order[i]];
    const strip = document.getElementById("tabstrip");
    const els = this.order.map((id) => this.tabs.get(id).tabEl);
    els.forEach((el) => strip.appendChild(el)); // reorder DOM to match
  },
};
