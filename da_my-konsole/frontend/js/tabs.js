// tabs.js — tab strip management. One tab ↔ one MYK terminal id.
const Tabs = {
  order: [],

  newTab() { MYK.newTerm("shell"); },

  add(id, title) {
    this.order.push(id);
    const strip = document.getElementById("tabstrip");
    const el = document.createElement("div");
    el.className = "tab"; el.dataset.id = id;
    el.innerHTML = `<span class="tab-title"></span><span class="tab-close">✕</span>`;
    el.querySelector(".tab-title").textContent = title;
    el.addEventListener("click", (e) => {
      if (e.target.classList.contains("tab-close")) { this.close(id); return; }
      MYK.activate(id); this._paint();
    });
    strip.appendChild(el);
    this._paint();
  },

  setTitle(id, title) {
    const el = document.querySelector(`.tab[data-id="${id}"] .tab-title`);
    if (el && title) el.textContent = title;
  },

  close(id) {
    MYK.dispose(id);
    document.querySelector(`.tab[data-id="${id}"]`)?.remove();
    this.order = this.order.filter((x) => x !== id);
    if (this.order.length === 0) { MYK.newTerm("shell"); return; }
    if (MYK.active === id) MYK.activate(this.order[this.order.length - 1]);
    this._paint();
  },

  next() { this._step(+1); },
  prev() { this._step(-1); },
  _step(d) {
    const i = this.order.indexOf(MYK.active);
    if (i < 0) return;
    const j = (i + d + this.order.length) % this.order.length;
    MYK.activate(this.order[j]); this._paint();
  },

  _paint() {
    for (const el of document.querySelectorAll(".tab"))
      el.classList.toggle("active", el.dataset.id === MYK.active);
  },
};
