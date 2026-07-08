// boot.js — wire the shell: profiles top-nav, command sections, search, find.
(async function () {
  const invoke = window.__TAURI__.core.invoke;
  let profiles = [];
  let current = null;

  try {
    const res = await invoke("get_profiles");
    profiles = res.profiles || [];
  } catch (e) { console.error("get_profiles failed", e); }
  if (profiles.length === 0) profiles = [{ name: "default", display_name: "Shell", sections: [] }];

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

  // A command item types its command into the active terminal and runs it.
  function runItem(item) {
    const id = MYK.active;
    if (!id || !item.cmd) return;
    invoke("pty_write", { id, data: item.cmd + "\n" });
    MYK.terms.get(id)?.term.focus();
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
  document.getElementById("find-next").addEventListener("click", () => Find.next());
  document.getElementById("find-prev").addEventListener("click", () => Find.prev());
  document.getElementById("find-close").addEventListener("click", () => Find.close());
  document.getElementById("find-input").addEventListener("keydown", (e) => {
    if (e.key === "Enter") Find.next();
    if (e.key === "Escape") Find.close();
  });
  window.addEventListener("resize", () => MYK.fitActive());

  // First profile + first terminal
  current = profiles[0];
  buildSections(current);
  await MYK.newTerm("shell");
})();
