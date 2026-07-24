// my-konsole — Rust KDE Konsole alternative (Tauri v2).
// PTYs (one per terminal tab) come from the shared pty-core crate; this file just
// wires its broker into Tauri state and forwards its events to the webview as
// `pty:<id>` / `pty-exit:<id>`. The frontend (xterm.js) renders it.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use pty_core::{PtyBroker, PtyEvent};
use serde::Serialize;
use tauri::webview::WebviewBuilder;
use tauri::{Emitter, LogicalPosition, LogicalSize, Manager, State, WebviewUrl};

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

// ── Native browser tabs: a real child webview (WebKitGTK) embedded over the tab
// area, so any site loads (no iframe X-Frame-Options limit). The frontend drives
// bounds/visibility because a child webview floats above the DOM and is NOT
// clipped by CSS — it must be repositioned on layout changes and moved off-screen
// when its tab isn't active. One webview per browser tab, keyed by the tab id.
fn parse_url(u: &str) -> Result<tauri::Url, String> {
    u.parse::<tauri::Url>().map_err(|e| e.to_string())
}

#[tauri::command]
fn browser_open(
    app: tauri::AppHandle,
    label: String, url: String,
    x: f64, y: f64, w: f64, h: f64,
) -> Result<(), String> {
    let u = parse_url(&url)?;
    // Already exists → just navigate + reposition (reuse, don't stack webviews).
    if let Some(wv) = app.get_webview(&label) {
        wv.navigate(u).map_err(|e| e.to_string())?;
        let _ = wv.set_position(LogicalPosition::new(x, y));
        let _ = wv.set_size(LogicalSize::new(w, h));
        return Ok(());
    }
    let window = app.get_window("main").ok_or_else(|| "no main window".to_string())?;
    window
        .add_child(
            WebviewBuilder::new(&label, WebviewUrl::External(u)),
            LogicalPosition::new(x, y),
            LogicalSize::new(w, h),
        )
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
fn browser_navigate(app: tauri::AppHandle, label: String, url: String) -> Result<(), String> {
    let wv = app.get_webview(&label).ok_or_else(|| "no such webview".to_string())?;
    wv.navigate(parse_url(&url)?).map_err(|e| e.to_string())
}

#[tauri::command]
fn browser_bounds(app: tauri::AppHandle, label: String, x: f64, y: f64, w: f64, h: f64) {
    if let Some(wv) = app.get_webview(&label) {
        let _ = wv.set_position(LogicalPosition::new(x, y));
        let _ = wv.set_size(LogicalSize::new(w, h));
    }
}

#[tauri::command]
fn browser_hide(app: tauri::AppHandle, label: String) {
    // Child Webview has no hide(); moving it off-screen reliably takes it out of view.
    if let Some(wv) = app.get_webview(&label) {
        let _ = wv.set_position(LogicalPosition::new(-20000.0, -20000.0));
    }
}

#[tauri::command]
fn browser_close(app: tauri::AppHandle, label: String) {
    if let Some(wv) = app.get_webview(&label) {
        let _ = wv.close();
    }
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(PtyBroker::new())
        .invoke_handler(tauri::generate_handler![
            pty_start, pty_write, pty_resize, pty_kill, get_profiles, get_config,
            fs_list_dir, fs_read_file, fs_write_file,
            browser_open, browser_navigate, browser_bounds, browser_hide, browser_close
        ])
        .run(tauri::generate_context!())
        .expect("error while running my-konsole");
}
