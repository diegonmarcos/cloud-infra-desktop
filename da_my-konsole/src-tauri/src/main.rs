// my-konsole — Rust KDE Konsole alternative (Tauri v2).
// PTYs (one per terminal tab) come from the shared pty-core crate; this file just
// wires its broker into Tauri state and forwards its events to the webview as
// `pty:<id>` / `pty-exit:<id>`. The frontend (xterm.js) renders it.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use pty_core::{PtyBroker, PtyEvent};
use serde::Serialize;
use tauri::{Emitter, Manager, State};

#[derive(Serialize, Clone)]
struct PtyChunk {
    id: String,
    data: String,
}

// Spawn a shell attached to a fresh PTY (via pty-core); stream its output to the webview.
#[tauri::command]
fn pty_start(
    app: tauri::AppHandle,
    broker: State<PtyBroker>,
    id: String,
    cols: u16,
    rows: u16,
    cwd: Option<String>,
) -> Result<(), String> {
    let app2 = app.clone();
    broker.start(id.clone(), cols, rows, cwd, move |ev| match ev {
        PtyEvent::Output { id, data } => {
            let _ = app2.emit(&format!("pty:{id}"), PtyChunk { id: id.clone(), data });
        }
        PtyEvent::Exit { id } => {
            let _ = app2.emit(&format!("pty-exit:{id}"), ());
        }
    })
}

#[tauri::command]
fn pty_write(broker: State<PtyBroker>, id: String, data: String) -> Result<(), String> {
    broker.write(&id, &data)
}

#[tauri::command]
fn pty_resize(broker: State<PtyBroker>, id: String, cols: u16, rows: u16) -> Result<(), String> {
    broker.resize(&id, cols, rows)
}

#[tauri::command]
fn pty_kill(broker: State<PtyBroker>, id: String) {
    broker.kill(&id); // drops the PTY → shell gets SIGHUP
}

// Load profiles (top-nav + command sections). Data-driven: each profile is a
// <slug>/profile.json (dirs sorted, so numeric prefixes control order). Prefer
// the USER dir (~/.local/share/my-konsole/profiles) so edits apply on restart
// WITHOUT a recompile; fall back to the bundled Resource copy.
fn read_profiles_dir(base: &std::path::Path) -> Vec<serde_json::Value> {
    let mut profiles = Vec::new();
    if let Ok(entries) = std::fs::read_dir(base) {
        let mut dirs: Vec<_> = entries.flatten().map(|e| e.path()).collect();
        dirs.sort();
        for d in dirs {
            if let Ok(txt) = std::fs::read_to_string(d.join("profile.json")) {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&txt) {
                    profiles.push(v);
                }
            }
        }
    }
    profiles
}

// Runtime UI config (theme/font/terminal/keybindings). Same user-dir-first
// resolution as profiles, so config.json edits apply on restart without rebuild.
#[tauri::command]
fn get_config(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
    if let Some(home) = std::env::var_os("HOME") {
        let user = std::path::Path::new(&home).join(".local/share/my-konsole/config.json");
        if let Ok(txt) = std::fs::read_to_string(&user) {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&txt) {
                return Ok(v);
            }
        }
    }
    if let Ok(p) = app.path().resolve("config.json", tauri::path::BaseDirectory::Resource) {
        if let Ok(txt) = std::fs::read_to_string(&p) {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&txt) {
                return Ok(v);
            }
        }
    }
    Ok(serde_json::json!({}))
}

#[tauri::command]
fn get_profiles(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
    // 1. user dir (instant edits, no rebuild)
    if let Some(home) = std::env::var_os("HOME") {
        let user = std::path::Path::new(&home).join(".local/share/my-konsole/profiles");
        let p = read_profiles_dir(&user);
        if !p.is_empty() {
            return Ok(serde_json::json!({ "profiles": p }));
        }
    }
    // 2. bundled resource fallback
    if let Ok(base) = app.path().resolve("profiles", tauri::path::BaseDirectory::Resource) {
        return Ok(serde_json::json!({ "profiles": read_profiles_dir(&base) }));
    }
    Ok(serde_json::json!({ "profiles": [] }))
}

// Lists one directory (yazi-style miller columns read one level at a time).
// Not gated by Tauri's fs-plugin ACL — plain std::fs, shared with the engine via pty-core::fs.
#[tauri::command]
fn fs_list_dir(path: String) -> Result<Vec<pty_core::fs::FsEntry>, String> {
    pty_core::fs::list_dir(&path)
}

#[tauri::command]
fn fs_read_file(path: String) -> Result<String, String> {
    pty_core::fs::read_file(&path)
}

#[tauri::command]
fn fs_write_file(path: String, content: String) -> Result<(), String> {
    pty_core::fs::write_file(&path, &content)
}

// Expands the glob patterns behind the sidebar "Configs" panel (a profile's
// `configs[].paths`) into concrete files. `~` is the only shorthand a
// profile.json pattern uses — glob itself knows nothing about home dirs, so
// it's expanded by hand before handing the pattern to the crate. Skips build/
// vcs noise dirs and caps the result so a runaway pattern (e.g. bare "~/**")
// can't hang the UI; the cap is silent to the caller by design — the frontend
// just sees "up to 500" and shows the count next to each group title.
#[tauri::command]
fn fs_glob(patterns: Vec<String>) -> Result<Vec<String>, String> {
    const SKIP_DIRS: [&str; 4] = [".git", "target", "node_modules", "result"];
    const MAX_RESULTS: usize = 500;
    let home = std::env::var("HOME").unwrap_or_default();
    let mut out: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    for pat in patterns {
        let expanded = if pat == "~" {
            home.clone()
        } else if let Some(rest) = pat.strip_prefix("~/") {
            format!("{home}/{rest}")
        } else {
            pat
        };
        let Ok(entries) = glob::glob(&expanded) else { continue };
        for path in entries.flatten() {
            if !path.is_file() {
                continue;
            }
            let skip = path.components().any(|c| {
                SKIP_DIRS.contains(&c.as_os_str().to_string_lossy().as_ref())
            });
            if skip {
                continue;
            }
            out.insert(path.to_string_lossy().into_owned());
        }
    }
    Ok(out.into_iter().take(MAX_RESULTS).collect())
}

// ── Browser tabs are NATIVE child webviews, not <iframe>s.
//
// The iframe version could not browse the web, and not by a little: an iframe
// obeys X-Frame-Options, and essentially every site worth opening sends it —
// including our OWN home page (linktree.diegonmarcos.com: SAMEORIGIN). The
// result was a blank rectangle with no error, i.e. "the browser has no
// internet". No amount of frontend work fixes that; the header is enforced by
// WebKit itself and it is enforced correctly. An embedded browser has to be a
// real webview.
//
// The cost is manual bounds/visibility syncing (a native webview floats above
// the DOM and is not clipped by CSS), which is what the frontend's
// browser_bounds polling handles. Hiding is done by parking the webview far
// offscreen rather than a hide() call: it is the one operation guaranteed to
// exist on every platform backend, and it survives a webview that is mid-load.
const OFFSCREEN: f64 = -100_000.0;

fn parse_url(u: &str) -> Result<tauri::Url, String> {
    u.parse::<tauri::Url>().map_err(|e| e.to_string())
}

#[tauri::command]
fn browser_open(
    app: tauri::AppHandle,
    label: String,
    url: String,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
) -> Result<(), String> {
    use tauri::{LogicalPosition, LogicalSize};
    let u = parse_url(&url)?;
    ensure_agentic_backend(app.clone(), url.clone())?;
    // Re-opening an existing label navigates it instead of stacking a second
    // webview on the same rectangle (which would leak one per restore-session).
    if let Some(wv) = app.get_webview(&label) {
        return wv.navigate(u).map_err(|e| e.to_string());
    }
    let win = app.get_window("main").ok_or("no main window")?;
    win.add_child(
        // No .auto_resize(): the 4 Hz bounds poll is already the authority on
        // this webview's rectangle, and auto-resize would fight it on every
        // window resize.
        tauri::webview::WebviewBuilder::new(&label, tauri::WebviewUrl::External(u)),
        LogicalPosition::new(x, y),
        LogicalSize::new(w.max(1.0), h.max(1.0)),
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
fn browser_bounds(
    app: tauri::AppHandle,
    label: String,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    visible: bool,
) -> Result<(), String> {
    use tauri::{LogicalPosition, LogicalSize};
    let Some(wv) = app.get_webview(&label) else { return Ok(()) };
    // Size first, then position: a zero/negative size is rejected by the
    // backend, and an inactive tab legitimately measures 0x0 while hidden.
    wv.set_size(LogicalSize::new(w.max(1.0), h.max(1.0)))
        .map_err(|e| e.to_string())?;
    let pos = if visible {
        LogicalPosition::new(x, y)
    } else {
        LogicalPosition::new(OFFSCREEN, OFFSCREEN)
    };
    wv.set_position(pos).map_err(|e| e.to_string())
}

#[tauri::command]
fn browser_navigate(app: tauri::AppHandle, label: String, url: String) -> Result<(), String> {
    let u = parse_url(&url)?;
    ensure_agentic_backend(app.clone(), url)?;
    let wv = app.get_webview(&label).ok_or("no such webview")?;
    wv.navigate(u).map_err(|e| e.to_string())
}

#[tauri::command]
fn browser_back(app: tauri::AppHandle, label: String) -> Result<(), String> {
    let wv = app.get_webview(&label).ok_or("no such webview")?;
    wv.eval("history.back()").map_err(|e| e.to_string())
}

#[tauri::command]
fn browser_close(app: tauri::AppHandle, label: String) -> Result<(), String> {
    if let Some(wv) = app.get_webview(&label) {
        wv.close().map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
fn ensure_agentic_backend(app: tauri::AppHandle, url: String) -> Result<(), String> {
    let u = parse_url(&url)?;
    if let Some(dist) = agentic_ui_dist_dir(&app) {
        if u.port() == Some(AGENTIC_UI_PORT) {
            agentic_ui_serve_once(dist, AGENTIC_UI_PORT, false);
        } else if u.port() == Some(AGENTIC_UI_LOCAL_PORT) {
            agentic_ui_serve_once(dist, AGENTIC_UI_LOCAL_PORT, true);
        }
    }
    Ok(())
}

// ── Agentic UI static server: the goose-desktop-derived React fork (vendored
// at da_my-konsole/agentic-ui) is a static build, but the frontend's <iframe>
// needs a real http:// URL to point at (no file:// asset-serving story here).
// tiny_http on a fixed localhost port serves the dist dir, same user-dir-first
// resolution as get_profiles/get_config so `build.sh fetch` updates apply
// without a rebuild. /config.json is synthesized (not a file on disk) so the
// goosed URL/secret never sit in the static bundle — sourced the same way the
// my-ai CLI does (GOOSE_SERVER__SECRET_KEY env var; WG endpoint is fixed).
const AGENTIC_UI_PORT: u16 = 58765;
const AGENTIC_UI_LOCAL_PORT: u16 = 58767;
// Local-run mode: the goose-desktop-ui clone can also talk to a `goose serve`
// spawned right here in the Tauri process instead of the remote my-ai-api one
// (10.0.0.6:3227) — this app IS the desktop client goose-desktop always was,
// no reason the agent has to live on a remote box. Loopback-only, so a fixed
// key is fine (never leaves 127.0.0.1, no WG/network exposure).
const LOCAL_GOOSE_PORT: u16 = 58766;
const LOCAL_GOOSE_SECRET: &str = "my-konsole-local-agent";

fn local_goose_ensure_running() {
    static STARTED: std::sync::Once = std::sync::Once::new();
    STARTED.call_once(|| {
        let spawned = std::process::Command::new("goose")
            .args([
                "serve", "--platform", "desktop",
                "--host", "127.0.0.1",
                "--port", &LOCAL_GOOSE_PORT.to_string(),
            ])
            .env("GOOSE_SERVER__SECRET_KEY", LOCAL_GOOSE_SECRET)
            .spawn();
        match spawned {
            Ok(_) => eprintln!("local-goose: serving on 127.0.0.1:{LOCAL_GOOSE_PORT}"),
            Err(e) => eprintln!("local-goose: failed to spawn `goose serve` — {e}"),
        }
    });
}

fn agentic_ui_dist_dir(app: &tauri::AppHandle) -> Option<std::path::PathBuf> {
    if let Some(home) = std::env::var_os("HOME") {
        let user = std::path::Path::new(&home).join(".local/share/my-konsole/agentic-ui/dist");
        if user.is_dir() {
            return Some(user);
        }
    }
    app.path()
        .resolve("agentic-ui-dist", tauri::path::BaseDirectory::Resource)
        .ok()
        .filter(|p| p.is_dir())
}

fn content_type_for(path: &std::path::Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()) {
        Some("html") => "text/html; charset=utf-8",
        Some("js") | Some("mjs") => "text/javascript; charset=utf-8",
        Some("css") => "text/css; charset=utf-8",
        Some("json") => "application/json; charset=utf-8",
        Some("svg") => "image/svg+xml",
        Some("png") => "image/png",
        Some("woff2") => "font/woff2",
        _ => "application/octet-stream",
    }
}

fn agentic_ui_serve_once(dist_dir: std::path::PathBuf, port: u16, local: bool) {
    static CLOUD_STARTED: std::sync::Once = std::sync::Once::new();
    static LOCAL_STARTED: std::sync::Once = std::sync::Once::new();
    let once = if local { &LOCAL_STARTED } else { &CLOUD_STARTED };
    once.call_once(|| agentic_ui_serve(dist_dir, port, local));
}

// `local` selects which goosed this static agentic-ui build talks to:
// false = remote my-ai-api goosed (10.0.0.6:3227, cloud-agentic tab),
// true  = `goose serve` spawned locally by this app (goose-desktop tab).
fn agentic_ui_serve(dist_dir: std::path::PathBuf, port: u16, local: bool) {
    std::thread::spawn(move || {
        let server = match tiny_http::Server::http(("127.0.0.1", port)) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("agentic-ui: static server bind failed on :{port}: {e}");
                return;
            }
        };
        for req in server.incoming_requests() {
            let url_path = req.url().trim_start_matches('/');
            if url_path == "config.json" {
                let (goosed_url, secret) = if local {
                    local_goose_ensure_running();
                    (format!("http://127.0.0.1:{LOCAL_GOOSE_PORT}"), LOCAL_GOOSE_SECRET.to_string())
                } else {
                    // GOOSE_SERVER__SECRET_KEY: same env var my-ai-api's container reads
                    // from sops (see da_my-ai/core/src/lib.rs). Empty if unset — the UI
                    // then shows a connection error rather than silently no-op'ing.
                    ("http://10.0.0.6:3227".to_string(), std::env::var("GOOSE_SERVER__SECRET_KEY").unwrap_or_default())
                };
                let body = serde_json::json!({
                    "goosedUrl": goosed_url,
                    "secretKey": secret,
                })
                .to_string();
                let resp = tiny_http::Response::from_string(body).with_header(
                    tiny_http::Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..])
                        .unwrap(),
                );
                let _ = req.respond(resp);
                continue;
            }
            let rel = if url_path.is_empty() { "index.html" } else { url_path };
            let mut file_path = dist_dir.join(rel);
            if !file_path.is_file() {
                file_path = dist_dir.join("index.html"); // SPA fallback
            }
            match std::fs::read(&file_path) {
                Ok(bytes) => {
                    let ct = content_type_for(&file_path);
                    let resp = tiny_http::Response::from_data(bytes).with_header(
                        tiny_http::Header::from_bytes(&b"Content-Type"[..], ct.as_bytes()).unwrap(),
                    );
                    let _ = req.respond(resp);
                }
                Err(_) => {
                    let _ = req.respond(tiny_http::Response::from_string("not found").with_status_code(404));
                }
            }
        }
    });
}

// ── System tray icons — my-konsole IS the systray daemon. No separate
// per-tray process, no python/GTK, no nix module: build.sh install writes
// ~/.local/share/my-konsole/systrays.json (mirrored from configs/systrays.json,
// same user-dir-first convention as profiles/config) and a systemd --user
// service running `my-konsole --tray-daemon` (Restart=always). Every enabled
// tray in that manifest becomes a real StatusNotifierItem via Tauri's native
// tray-icon feature; each menu item just shell-execs its `command`.
fn load_systrays() -> serde_json::Value {
    if let Some(home) = std::env::var_os("HOME") {
        let user = std::path::Path::new(&home).join(".local/share/my-konsole/systrays.json");
        if let Ok(txt) = std::fs::read_to_string(&user) {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&txt) {
                return v;
            }
        }
    }
    serde_json::json!({ "trays": [] })
}

// Rasterise configs/systray-icons/<name>.svg to a 32x32 RGBA tray image.
// Same user-dir-first lookup as profiles/config: build.sh install mirrors the
// repo's icons into ~/.local/share/my-konsole/systray-icons/.
fn load_systray_icon(name: &str) -> Option<tauri::image::Image<'static>> {
    const SIZE: u32 = 32;
    let home = std::env::var_os("HOME")?;
    let path = std::path::Path::new(&home)
        .join(".local/share/my-konsole/systray-icons")
        .join(format!("{name}.svg"));
    let data = std::fs::read(&path).ok()?;
    let tree = resvg::usvg::Tree::from_data(&data, &resvg::usvg::Options::default()).ok()?;
    let mut pixmap = resvg::tiny_skia::Pixmap::new(SIZE, SIZE)?;
    let s = tree.size();
    // Fit the SVG's own viewBox into 32x32 rather than assuming it is already
    // that size — the icons are authored at whatever viewBox reads clearly.
    let scale = (SIZE as f32 / s.width()).min(SIZE as f32 / s.height());
    resvg::render(
        &tree,
        resvg::tiny_skia::Transform::from_scale(scale, scale),
        &mut pixmap.as_mut(),
    );
    Some(tauri::image::Image::new_owned(pixmap.take(), SIZE, SIZE))
}

fn setup_systrays(app: &tauri::App) {
    use tauri::menu::MenuBuilder;
    use tauri::menu::MenuItemBuilder;
    use tauri::tray::TrayIconBuilder;

    let data = load_systrays();
    let trays = data
        .get("trays")
        .and_then(|t| t.as_array())
        .cloned()
        .unwrap_or_default();
    // NOT app.default_window_icon(): on this platform it returns a raw RGBA
    // buffer whose length doesn't match its own reported width/height (a 2x
    // HiDPI variant leaking through), which tray_icon's stricter size check
    // rejects outright ("wrong data size, expected 4096 got 8192"). Decode
    // the bundled 32x32 PNG ourselves instead — Image has no from_path in
    // this tauri version, only new_owned(rgba, width, height).
    let icon = app
        .path()
        .resolve("icons/32x32.png", tauri::path::BaseDirectory::Resource)
        .ok()
        .and_then(|p| image::open(p).ok())
        .map(|img| {
            let rgba = img.to_rgba8();
            let (w, h) = (rgba.width(), rgba.height());
            tauri::image::Image::new_owned(rgba.into_raw(), w, h)
        });

    for tray in trays {
        if !tray.get("enable").and_then(|v| v.as_bool()).unwrap_or(false) {
            continue;
        }
        let id = tray.get("id").and_then(|v| v.as_str()).unwrap_or("systray").to_string();
        let title = tray.get("title").and_then(|v| v.as_str()).unwrap_or(&id).to_string();
        let menu_items = tray.get("menu").and_then(|v| v.as_array()).cloned().unwrap_or_default();

        let mut commands: std::collections::HashMap<String, String> = std::collections::HashMap::new();
        let mut builder = MenuBuilder::new(app);
        for (i, item) in menu_items.iter().enumerate() {
            let label = item.get("label").and_then(|v| v.as_str()).unwrap_or("").to_string();
            let cmd = item.get("command").and_then(|v| v.as_str()).unwrap_or("").to_string();
            let item_id = format!("{id}::{i}");
            commands.insert(item_id.clone(), cmd);
            if let Ok(mi) = MenuItemBuilder::with_id(item_id, label).build(app) {
                builder = builder.item(&mi);
            }
        }
        let Ok(menu) = builder.build() else { continue };

        // Per-tray icon, app icon only as the fallback. Every tray used to get
        // `icon.clone()` unconditionally and the manifest's `icon` field was
        // read by nothing — so seven trays showed seven copies of the same
        // my-konsole logo and were impossible to tell apart in the tray.
        let tray_icon = tray
            .get("icon")
            .and_then(|v| v.as_str())
            .and_then(load_systray_icon)
            .or_else(|| icon.clone());
        let mut tb = TrayIconBuilder::with_id(id.clone()).tooltip(&title).menu(&menu);
        if let Some(ic) = tray_icon {
            tb = tb.icon(ic);
        }
        let tb = tb.on_menu_event(move |_app, event| {
            let eid: &str = event.id().as_ref();
            if let Some(cmd) = commands.get(eid) {
                let _ = std::process::Command::new("sh").arg("-c").arg(cmd).spawn();
            }
        });
        if let Err(e) = tb.build(app) {
            eprintln!("systray: failed to build tray '{id}': {e}");
        }
    }
}

fn main() {
    let tray_daemon = std::env::args().any(|a| a == "--tray-daemon");
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(PtyBroker::new())
        .setup(move |app| {
            // agentic-ui's static server(s) + the local `goose serve` are started
            // lazily from ensure_agentic_backend when their tab is actually opened, not here.
            if agentic_ui_dist_dir(app.handle()).is_none() {
                eprintln!("agentic-ui: no dist dir found (fetch it via build.sh fetch) — tab will fail to load");
            }
            setup_systrays(app);
            // --tray-daemon: this launch exists only to host the persistent tray
            // icons (systemd --user service) — hide the terminal window instead
            // of showing it, so it doesn't pop a Konsole-alternative window at login.
            if tray_daemon {
                if let Some(w) = app.get_webview_window("main") {
                    let _ = w.hide();
                }
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            pty_start, pty_write, pty_resize, pty_kill, get_profiles, get_config,
            fs_list_dir, fs_read_file, fs_write_file, fs_glob,
            ensure_agentic_backend,
            browser_open, browser_bounds, browser_navigate, browser_back, browser_close
        ])
        .run(tauri::generate_context!())
        .expect("error while running my-konsole");
}
