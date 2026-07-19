// my-konsole — Rust KDE Konsole alternative (Tauri v2).
// In-process PTYs via portable-pty; one PTY per terminal tab. Output is streamed
// to the webview as `pty:<id>` events; the frontend (xterm.js) renders it.
// ponytail: no bundled node/pty-server — portable-pty is the whole backend.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::Mutex;

use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use serde::Serialize;
use tauri::{Emitter, Manager, State};

struct Pty {
    writer: Box<dyn Write + Send>,
    master: Box<dyn portable_pty::MasterPty + Send>,
}

#[derive(Default)]
struct Ptys(Mutex<HashMap<String, Pty>>);

#[derive(Serialize, Clone)]
struct PtyChunk {
    id: String,
    data: String,
}

fn user_shell() -> String {
    std::env::var("MYK_SHELL")
        .or_else(|_| std::env::var("SHELL"))
        .unwrap_or_else(|_| "/bin/bash".into())
}

// Spawn a shell attached to a fresh PTY; stream its output to the webview.
#[tauri::command]
fn pty_start(
    app: tauri::AppHandle,
    ptys: State<Ptys>,
    id: String,
    cols: u16,
    rows: u16,
    cwd: Option<String>,
) -> Result<(), String> {
    let pair = native_pty_system()
        .openpty(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
        .map_err(|e| e.to_string())?;

    let mut cmd = CommandBuilder::new(user_shell());
    cmd.env("TERM", "xterm-256color");
    cmd.env("COLORTERM", "truecolor");
    if let Some(dir) = cwd.filter(|d| !d.is_empty()) {
        cmd.cwd(dir);
    } else if let Some(home) = std::env::var_os("HOME") {
        cmd.cwd(home);
    }

    let _child = pair.slave.spawn_command(cmd).map_err(|e| e.to_string())?;
    let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
    let writer = pair.master.take_writer().map_err(|e| e.to_string())?;

    ptys.0.lock().unwrap().insert(id.clone(), Pty { writer, master: pair.master });

    // Reader thread → emit chunks to the webview.
    let ev = format!("pty:{id}");
    let app2 = app.clone();
    std::thread::spawn(move || {
        let mut buf = [0u8; 8192];
        loop {
            match reader.read(&mut buf) {
                Ok(0) | Err(_) => {
                    let _ = app2.emit(&format!("pty-exit:{id}"), ());
                    break;
                }
                Ok(n) => {
                    let data = String::from_utf8_lossy(&buf[..n]).to_string();
                    let _ = app2.emit(&ev, PtyChunk { id: id.clone(), data });
                }
            }
        }
    });
    Ok(())
}

#[tauri::command]
fn pty_write(ptys: State<Ptys>, id: String, data: String) -> Result<(), String> {
    if let Some(p) = ptys.0.lock().unwrap().get_mut(&id) {
        p.writer.write_all(data.as_bytes()).map_err(|e| e.to_string())?;
        p.writer.flush().map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
fn pty_resize(ptys: State<Ptys>, id: String, cols: u16, rows: u16) -> Result<(), String> {
    if let Some(p) = ptys.0.lock().unwrap().get(&id) {
        p.master
            .resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
fn pty_kill(ptys: State<Ptys>, id: String) {
    ptys.0.lock().unwrap().remove(&id); // drop closes the PTY → shell gets SIGHUP
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

#[derive(serde::Serialize)]
struct FsEntry { name: String, is_dir: bool }

// Lists one directory (yazi-style miller columns read one level at a time).
// Not gated by Tauri's fs-plugin ACL — plain std::fs in a native command.
#[tauri::command]
fn fs_list_dir(path: String) -> Result<Vec<FsEntry>, String> {
    let expanded = if let Some(rest) = path.strip_prefix('~') {
        let home = std::env::var("HOME").map_err(|e| e.to_string())?;
        format!("{home}{rest}")
    } else {
        path
    };
    let mut entries: Vec<FsEntry> = std::fs::read_dir(&expanded)
        .map_err(|e| e.to_string())?
        .flatten()
        .filter_map(|e| {
            let is_dir = e.file_type().ok()?.is_dir();
            Some(FsEntry { name: e.file_name().to_string_lossy().into_owned(), is_dir })
        })
        .collect();
    entries.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then(a.name.to_lowercase().cmp(&b.name.to_lowercase())));
    Ok(entries)
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(Ptys::default())
        .invoke_handler(tauri::generate_handler![
            pty_start, pty_write, pty_resize, pty_kill, get_profiles, get_config, fs_list_dir
        ])
        .run(tauri::generate_context!())
        .expect("error while running my-konsole");
}
