// boot.js — wire the shell: profiles top-nav, command sections, search, find.
(async function () {
  let profiles = [];
  let current = null;

  // Load runtime UI config (theme/font/terminal/keybindings) BEFORE any pane.
  // ponytail: Phase 2b — on Tauri, invoke the Rust commands directly; on the
  // WebView/browser path (no __TAURI__) load the static JSON the build emits
  // instead (frozen paths/format: data/config.json, data/profiles.json).
  try {
    MYK.config = window.__TAURI__
      ? await window.__TAURI__.core.invoke("get_config")
      : await fetch("data/config.json").then((r) => (r.ok ? r.json() : {})).catch(() => ({}));
  } catch (e) { console.error("get_config failed", e); MYK.config = {}; }

  try {
    const res = window.__TAURI__
      ? await window.__TAURI__.core.invoke("get_profiles")
      : await fetch("data/profiles.json").then((r) => (r.ok ? r.json() : { profiles: [] })).catch(() => ({ profiles: [] }));
    profiles = res.profiles || [];
  } catch (e) { console.error("get_profiles failed", e); }
  if (profiles.length === 0) profiles = [{ name: "default", display_name: "Shell", sections: [] }];
  console.log("[boot] tauri=" + !!window.__TAURI__ + " config.keys=" + Object.keys(MYK.config || {}).join(","));
  console.log("[boot] profiles(" + profiles.length + "): " + profiles.map((p) => p.name + (p.home ? "*" : "")).join(", "));
  console.log("[boot] home profiles: " + profiles.filter((p) => p.home).map((p) => p.name).join(", "));
  Palette.profiles = profiles;
  Palette.runItem = runItem;

  // Top-nav pills — Row 1 (the CLI tools, each with its own bookmark sections).
  // Profiles flagged `home` are the GUI-demanding tools and live in Row 0.
  //
  // Ordering is data-driven: `order` in each profile.json, not the directory
  // name. Directory prefixes (00-, 01-, ...) are how the files sort on disk,
  // which is not the same question as how the nav should read — Home belongs
  // first in the nav regardless of where its folder sorts. Profiles with no
  // `order` fall to the end, in their existing order, so adding one is not a
  // silent reshuffle.
  const nav = document.getElementById("profiles");
  const row1 = profiles
    .filter((p) => !p.home)
    .map((p, idx) => ({ p, idx }))
    .sort((a, b) => (a.p.order ?? 999) - (b.p.order ?? 999) || a.idx - b.idx)
    .map((x) => x.p);
  row1.forEach((p, i) => {
    const pill = document.createElement("div");
    pill.className = "profile-pill" + (i === 0 ? " active" : "");
    pill.textContent = p.display_name || p.name;
    pill.addEventListener("click", () => selectProfile(p, pill));
    nav.appendChild(pill);
  });

  const byName = (n) => profiles.find((p) => p.name === n);

  // Every profile switch — pill OR Row-1 home button — goes through here, so the
  // sidebar command sections ALWAYS match the active profile (no stale bleed) and
  // tabs stay grouped per profile. `pill` is null for home buttons; `opener`
  // forces a specific new tab (e.g. Vim) instead of the group's default.
  function selectProfile(p, pill, opener) {
    if (!p) { console.error("[selectProfile] null profile — byName miss? (button wired to a profile that isn't loaded)"); return; }
    console.log(`[selectProfile] ${p.name} pill=${!!pill} opener=${!!opener} sections=${(p.sections || []).length}`);
    current = p;
    for (const el of document.querySelectorAll(".profile-pill")) el.classList.remove("active");
    if (pill) pill.classList.add("active");
    buildSections(p);
    Tabs.switchProfile(p, opener);
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
  // An item with `url` (no `cmd`) opens a pinned native browser tab instead —
  // same mechanism as a `browser:true` profile (Tabs.openBrowserTab), just
  // triggered from a section item rather than being the profile's home tab.
  function runItem(item) {
    if (item.url && !item.cmd) { Tabs.openBrowserTab(item.url, item.label); return; }
    const id = MYK.activePane;
    if (!id || !item.cmd) return;
    const run = !/\s$/.test(item.cmd);
    Transport.ptyWrite(id, run ? item.cmd + "\n" : item.cmd);
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
  document.getElementById("btn-sidebar").addEventListener("click", () => {
    document.getElementById("sidebar").classList.toggle("hidden");
  });
  document.getElementById("find-next").addEventListener("click", () => Find.next());
  document.getElementById("find-prev").addEventListener("click", () => Find.prev());
  document.getElementById("find-close").addEventListener("click", () => Find.close());
  document.getElementById("find-input").addEventListener("keydown", (e) => {
    if (e.key === "Enter") Find.next();
    if (e.key === "Escape") Find.close();
  });
  window.addEventListener("resize", () => { if (Tabs.active) MYK._fitTab(Tabs.active); });
  window.addEventListener("beforeunload", () => Tabs.saveSession());

  // Global menu (top-right ⋮): restore session, about
  const menuBtn = document.getElementById("btn-menu");
  const menuDrop = document.getElementById("menu-dropdown");
  menuBtn.addEventListener("click", (e) => { e.stopPropagation(); menuDrop.hidden = !menuDrop.hidden; });
  document.addEventListener("click", () => { menuDrop.hidden = true; });

  document.getElementById("menu-restore-session").addEventListener("click", () => Tabs.restoreSession());

  // Updater — all params from the engine-derived MYK.config.app (single source:
  // build.json). Commands run in a visible PTY tab so the user sees progress.
  // ponytail: no bespoke updater UI — a terminal tab IS the progress view.
  const app = (MYK.config && MYK.config.app) || {};
  document.getElementById("menu-update").addEventListener("click", () => {
    if (!app.repo) return;
    const s = app.store, b = app.bin, d = app.dash;
    Tabs.openRunTab(
      `gh release download ${app.release_tag} --repo ${app.repo} --pattern ${b} --pattern ${d} --dir ${s} --clobber ` +
      `&& chmod +x ${s}/${b} ${s}/${d} 2>/dev/null; echo '✓ Fetched — restart my-konsole to load the new binary'`,
      "update");
  });
  document.getElementById("menu-clone-build").addEventListener("click", () => {
    if (!app.repo_url) return;
    Tabs.openRunTab(
      `git clone ${app.repo_url} ${app.clone_dir} 2>/dev/null || git -C ${app.clone_dir} pull; ` +
      `cd ${app.clone_dir}/${app.subdir} && ./build.sh build && ./build.sh install ` +
      `&& echo '✓ Built + installed locally (heavy — CI is the normal path)'`,
      "clone+build");
  });

  async function showAbout() {
    let appVersion = "unknown", tauriVersion = "unknown";
    if (window.__TAURI__) {
      try { appVersion = await window.__TAURI__.app.getVersion(); } catch {}
      try { tauriVersion = await window.__TAURI__.app.getTauriVersion(); } catch {}
    }
    document.getElementById("about-body").textContent =
      `Version: ${appVersion}\nTauri: ${tauriVersion}\nProfiles loaded: ${profiles.length}\nTabs open: ${Tabs.tabs.size}`;
    // Repo / location block — from the derived app metadata.
    const url = document.getElementById("about-repo-url");
    url.textContent = app.repo_url || "—"; url.href = app.repo_url || "#";
    document.getElementById("about-repo-path").textContent = app.clone_dir ? `${app.clone_dir}/${app.subdir}` : "—";
    document.getElementById("about-bin-path").textContent = (app.store && app.bin) ? `${app.store}/${app.bin}` : "—";
    document.getElementById("about").hidden = false;
  }
  document.getElementById("about-clone").addEventListener("click", () => {
    if (!app.repo_url) return;
    document.getElementById("about").hidden = true;
    Tabs.openRunTab(
      `git clone ${app.repo_url} ${app.clone_dir} 2>/dev/null || git -C ${app.clone_dir} pull; ` +
      `echo '✓ Repo at ${app.clone_dir}'`,
      "clone");
  });
  // ── Dependency solver ────────────────────────────────────────────────────
  // The hub's dependency list is DERIVED, never hand-written: every bookmark in
  // every profile is a shell command, and the first word of that command is the
  // binary it needs. A hand-kept list would rot the moment someone adds a
  // bookmark — this cannot, because the bookmarks ARE the list.
  //
  // It reports where each one came from, so a missing binary tells you which
  // profile stops working rather than just naming something absent.
  function scanDeps() {
    const SHELL_BUILTINS = new Set([
      "cd", "export", "source", ".", "echo", "exit", "set", "unset", "alias",
      "if", "for", "while", "read", "eval", "exec", "trap", "true", "false",
      "clear", "pushd", "popd", "wait", "kill", "jobs", "fg", "bg", "printf",
    ]);
    const deps = new Map(); // binary -> Set(profile display names)
    for (const p of profiles) {
      const label = p.display_name || p.name;
      for (const sec of p.sections || []) {
        for (const it of sec.items || []) {
          if (!it.cmd) continue;
          // Take the first word of each ;/&&/| segment: a bookmark is often a
          // pipeline, and every stage of it is a dependency too.
          for (const seg of it.cmd.split(/\|\||&&|[;|]/)) {
            let w = seg.trim().split(/\s+/)[0] || "";
            w = w.replace(/^\(+/, "");                 // "(cmd ..." subshells
            if (!w || w.startsWith("$") || w.startsWith("-")) continue;
            if (w.includes("/")) w = w.split("/").pop(); // /usr/bin/x -> x
            if (!/^[A-Za-z][\w.+-]*$/.test(w)) continue;
            if (SHELL_BUILTINS.has(w)) continue;
            if (!deps.has(w)) deps.set(w, new Set());
            deps.get(w).add(label);
          }
        }
      }
    }
    return deps;
  }

  document.getElementById("menu-deps").addEventListener("click", () => {
    const deps = scanDeps();
    const names = [...deps.keys()].sort();
    console.log(`[deps] ${names.length} binaries referenced by ${profiles.length} profiles`);
    // Checked in a real shell rather than guessed at: `command -v` is the only
    // answer that accounts for PATH, nix profiles, shell functions and aliases.
    // Output is a tab so it is copy-pasteable and scrolls like anything else.
    const list = names.join(" ");
    const script =
      `printf '%s\\n' 'DEPENDENCY SOLVER — ${names.length} binaries referenced by this hub' ''; ` +
      `miss=0; have=0; ` +
      `for b in ${list}; do ` +
      `  if p=$(command -v "$b" 2>/dev/null); then have=$((have+1)); printf '  \\033[32m✓\\033[0m %-24s %s\\n' "$b" "$p"; ` +
      `  else miss=$((miss+1)); printf '  \\033[31m✗\\033[0m %-24s MISSING\\n' "$b"; fi; ` +
      `done; ` +
      `printf '\\n  %s installed, \\033[31m%s missing\\033[0m\\n' "$have" "$miss"`;
    Tabs.openRunTab(script, "Deps", current?.name);
    // The which-profile-needs-it mapping is only useful next to a miss, so it
    // goes to the console rather than doubling the length of the tab output.
    for (const [b, who] of [...deps].sort()) console.log(`[deps] ${b} <- ${[...who].join(", ")}`);
  });

  document.getElementById("menu-about").addEventListener("click", showAbout);
  document.getElementById("about-close").addEventListener("click", () => { document.getElementById("about").hidden = true; });

  // Logs (logcat) viewer + export — captures console.* via DevLog. Export writes
  // console buffer + a live state snapshot to DevLog.PATH for offline debugging.
  const logsBody = document.getElementById("logs-body");
  const renderLogs = () => { logsBody.textContent = DevLog.buffer.join("\n") || "(no logs yet)"; logsBody.scrollTop = logsBody.scrollHeight; };
  const doExport = async () => {
    const p = await DevLog.export();
    console.log(p ? `Logs exported → ${p}` : "Log export failed");
    renderLogs();
  };
  document.getElementById("menu-logs").addEventListener("click", () => { renderLogs(); document.getElementById("logs").hidden = false; });
  document.getElementById("menu-export-logs").addEventListener("click", doExport);
  document.getElementById("logs-refresh").addEventListener("click", renderLogs);
  document.getElementById("logs-export").addEventListener("click", doExport);
  document.getElementById("logs-clear").addEventListener("click", () => { DevLog.clear(); renderLogs(); });
  document.getElementById("logs-close").addEventListener("click", () => { document.getElementById("logs").hidden = true; });

  // Row 1 (Home): each button selects its own home profile → its own tab group +
  // its own (empty) command sidebar. Reuses the group's tab instead of spawning.
  document.getElementById("btn-home-filebrowser").addEventListener("click", () => selectProfile(byName("file-browser"), null));
  document.getElementById("btn-home-browser").addEventListener("click", () => selectProfile(byName("web-browser"), null));
  document.getElementById("btn-home-agentic").addEventListener("click", () => selectProfile(byName("agentic"), null));
  // Any other `home:true` profile (e.g. goose-desktop, cloud-agentic) gets its
  // button generated here instead of a hardcoded HTML entry — new pinned tabs
  // are then just a new profile.json, no code change. The 4 above are hand-wired
  // because file-editor is a dropdown menu, not a plain profile click, and
  // file-browser/web-browser/agentic predate this loop.
  const fixedHomeBtns = new Set(["file-browser", "file-editor", "web-browser", "agentic"]);
  const homeActions = document.getElementById("home-actions");
  profiles.filter((p) => p.home && !fixedHomeBtns.has(p.name)).forEach((p) => {
    const b = document.createElement("button");
    b.className = "home-btn";
    b.textContent = p.display_name || p.name;
    b.addEventListener("click", () => selectProfile(p, null));
    homeActions.appendChild(b);
  });
  // File Editor is a mode dropdown: Plain (in-app textarea) | Vim (real vim in a
  // PTY). Both open in the file-editor group; Vim uses the opener override.
  const editorBtn = document.getElementById("btn-home-fileeditor");
  const editorMenu = document.getElementById("editor-menu");
  editorBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    const show = editorMenu.hidden;
    editorMenu.hidden = !show;
    if (show) {  // position the fixed menu right under the button
      const r = editorBtn.getBoundingClientRect();
      editorMenu.style.top = `${r.bottom + 2}px`;
      editorMenu.style.left = `${r.left}px`;
    }
    console.log("[editor] dropdown", editorMenu.hidden ? "closed" : "opened");
  });
  document.addEventListener("click", () => { editorMenu.hidden = true; });
  document.getElementById("editor-plain").addEventListener("click", () => {
    console.log("[editor] Plain clicked → file-editor profile");
    selectProfile(byName("file-editor"), null);
  });
  document.getElementById("editor-vim").addEventListener("click", () => {
    console.log("[editor] Vim clicked → file-editor profile + vim");
    selectProfile(byName("file-editor"), null, () => Tabs.openVimTab("file-editor"));
  });
  // About lives in the Configs (⋮ → menu-about) dropdown now — no standalone button.

  // Sidebar view switcher: Commands (search + per-profile items) | Tabs (vertical, grouped)
  for (const btn of document.querySelectorAll(".sidebar-toggle-btn")) {
    btn.addEventListener("click", () => {
      for (const b of document.querySelectorAll(".sidebar-toggle-btn")) b.classList.toggle("active", b === btn);
      const isTabs = btn.dataset.view === "tabs";
      document.getElementById("commands-panel").hidden = isTabs;
      document.getElementById("tabs-panel").hidden = !isTabs;
      if (isTabs) Tabs.renderTabList();
    });
  }

  // First profile + its first tab (one pane, or a browser tab)
  current = profiles[0];
  buildSections(current);
  Tabs.activeProfile = current.name;
  if (current.browser) Tabs.openBrowserTab(current.url, current.name);
  else if (current.filebrowser) Tabs.openFileBrowserTab(current.start_path || "~", current.name);
  else await Tabs.newTab(current.name);
})();
