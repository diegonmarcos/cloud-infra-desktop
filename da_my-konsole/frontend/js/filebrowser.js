// filebrowser.js — yazi-style miller columns. One Rust round-trip per level
// (fs_list_dir), no client-side fs caching/watching — simplest thing that works.
const FileBrowser = {
  invoke: null,

  mount(container, startPath) {
    this.invoke = window.__TAURI__.core.invoke;
    container.innerHTML = `
      <div class="fb-wrap">
        <div class="fb-addr"><input class="fb-addr-input" type="text" spellcheck="false" /></div>
        <div class="fb-cols"></div>
      </div>`;
    const addr = container.querySelector(".fb-addr-input");
    const cols = container.querySelector(".fb-cols");
    const state = { columns: [], lastClicked: null };

    const join = (base, name) => (base.endsWith("/") ? base : base + "/") + name;

    const render = () => {
      cols.innerHTML = "";
      state.columns.forEach((col, i) => {
        const colEl = document.createElement("div");
        colEl.className = "fb-col";
        col.entries.forEach((ent) => {
          const li = document.createElement("div");
          li.className = "fb-entry" + (ent.is_dir ? " dir" : "") + (col.selected === ent.name ? " sel" : "");
          li.textContent = ent.name + (ent.is_dir ? "/" : "");
          li.addEventListener("click", () => selectEntry(i, ent));
          colEl.appendChild(li);
        });
        cols.appendChild(colEl);
      });
      cols.scrollLeft = cols.scrollWidth;
    };

    const selectEntry = async (colIndex, ent) => {
      const col = state.columns[colIndex];
      col.selected = ent.name;
      const full = join(col.path, ent.name);
      state.lastClicked = full;
      state.columns = state.columns.slice(0, colIndex + 1);
      addr.value = full;
      if (ent.is_dir) {
        try {
          const entries = await this.invoke("fs_list_dir", { path: full });
          state.columns.push({ path: full, entries, selected: null });
        } catch (e) { console.error("fs_list_dir failed", e); }
      }
      render();
      container.focus();
    };

    const openPath = async (path) => {
      try {
        const entries = await this.invoke("fs_list_dir", { path });
        state.columns = [{ path, entries, selected: null }];
        state.lastClicked = null;
        addr.value = path;
        render();
      } catch (e) { console.error("fs_list_dir failed", e); }
    };

    addr.addEventListener("keydown", (e) => {
      if (e.key === "Enter") openPath(addr.value.trim());
    });

    container.addEventListener("keydown", (e) => {
      if (e.ctrlKey && e.altKey && e.code === "KeyC" && state.lastClicked) {
        navigator.clipboard.writeText(state.lastClicked);
      }
    });
    container.tabIndex = -1; // make it a keydown target without stealing tab order

    openPath(startPath).then(() => container.focus());
    return { currentPath: () => addr.value };
  },
};
