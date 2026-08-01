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

// ── Browser tabs are plain <iframe>s in the frontend now (a normal DOM
// element, CSS-clipped like any other tab pane) — no child webview, no
// bounds/visibility syncing. The only backend work left is lazily starting
// our own localhost servers (agentic-ui static server, local goosed) the
// first time a tab actually navigates to one of their ports.
fn parse_url(u: &str) -> Result<tauri::Url, String> {
    u.parse::<tauri::Url>().map_err(|e| e.to_string())
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
    let icon = app.default_window_icon().cloned();

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

        let mut tb = TrayIconBuilder::with_id(id.clone()).tooltip(&title).menu(&menu);
        if let Some(ic) = icon.clone() {
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
            fs_list_dir, fs_read_file, fs_write_file,
            ensure_agentic_backend
        ])
        .run(tauri::generate_context!())
        .expect("error while running my-konsole");
}
