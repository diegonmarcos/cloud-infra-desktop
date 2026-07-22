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

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(PtyBroker::new())
        .invoke_handler(tauri::generate_handler![
            pty_start, pty_write, pty_resize, pty_kill, get_profiles, get_config,
            fs_list_dir, fs_read_file, fs_write_file
        ])
        .run(tauri::generate_context!())
        .expect("error while running my-konsole");
}
