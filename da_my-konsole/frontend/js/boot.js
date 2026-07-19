// boot.js — wire the shell: profiles top-nav, command sections, search, find.
(async function () {
  const invoke = window.__TAURI__.core.invoke;
  let profiles = [];
  let current = null;

  // Load runtime UI config (theme/font/terminal/keybindings) BEFORE any pane.
  try { MYK.config = await invoke("get_config"); }
  catch (e) { console.error("get_config failed", e); MYK.config = {}; }

  try {
    const res = await invoke("get_profiles");
    profiles = res.profiles || [];
  } catch (e) { console.error("get_profiles failed", e); }
  if (profiles.length === 0) profiles = [{ name: "default", display_name: "Shell", sections: [] }];
  Palette.profiles = profiles;
  Palette.runItem = runItem;

  // Top-nav pills
  const nav = document.getElementById("profiles");
  profiles.forEach((p, i) => {
    const pill = document.createElement("div");
    pill.className = "profile-pill" + (i === 0 ? " active" : "");
    pill.textContent = p.display_name || p.name;
    pill.addEventListener("click", () => selectProfile(p, pill));
    nav.appendChild(pill);
  });

  function selectProfile(p, pill) {
    current = p;
    for (const el of document.querySelectorAll(".profile-pill")) el.classList.remove("active");
    pill.classList.add("active");
    buildSections(p);
    Tabs.switchProfile(p);
  }

  // Per-profile command sections
  function buildSections(p) {
    const host = document.getElementById("sections");
    host.innerHTML = "";
    for (const sec of p.sections || []) {
      const t = document.createElement("div");
      t.className = "section-title"; t.textContent = sec.title;
      host.appendChild(t);
      for (const item of sec.items || []) {
        const b = document.createElement("button");
        b.className = "cmd-item";
        b.textContent = item.label;
        b.dataset.search = (item.label + " " + (item.cmd || "")).toLowerCase();
        b.addEventListener("click", () => runItem(item));
        host.appendChild(b);
      }
    }
    filterSearch(document.getElementById("search").value);
  }

  // Run a command item in the active pane. Convention: a cmd ending in a
  // space is PREFILLED (no Enter) so the user can add args; otherwise it runs.
  function runItem(item) {
    const id = MYK.activePane;
    if (!id || !item.cmd) return;
    const run = !/\s$/.test(item.cmd);
    invoke("pty_write", { id, data: run ? item.cmd + "\n" : item.cmd });
    MYK.panes.get(id)?.term.focus();
  }

  // Live search filter over command items
  function filterSearch(q) {
    q = (q || "").toLowerCase();
    for (const b of document.querySelectorAll(".cmd-item"))
      b.classList.toggle("hidden", q && !b.dataset.search.includes(q));
    for (const t of document.querySelectorAll(".section-title")) t.style.display = "";
  }
  document.getElementById("search").addEventListener("input", (e) => filterSearch(e.target.value));

  // Buttons + find bar
  document.getElementById("btn-newtab").addEventListener("click", () => Tabs.newTab());
  document.getElementById("btn-sidebar").addEventListener("click", () =>
    document.getElementById("sidebar").classList.toggle("hidden"));
  document.getElementById("find-next").addEventListener("click", () => Find.next());
  document.getElementById("find-prev").addEventListener("click", () => Find.prev());
  document.getElementById("find-close").addEventListener("click", () => Find.close());
  document.getElementById("find-input").addEventListener("keydown", (e) => {
    if (e.key === "Enter") Find.next();
    if (e.key === "Escape") Find.close();
  });
  window.addEventListener("resize", () => { if (Tabs.active) MYK._fitTab(Tabs.active); });

  // First profile + its first tab (one pane, or a browser tab)
  current = profiles[0];
  buildSections(current);
  Tabs.activeProfile = current.name;
  if (current.browser) Tabs.openBrowserTab(current.url, current.name);
  else if (current.filebrowser) Tabs.openFileBrowserTab(current.start_path || "~", current.name);
  else await Tabs.newTab(current.name);
})();
