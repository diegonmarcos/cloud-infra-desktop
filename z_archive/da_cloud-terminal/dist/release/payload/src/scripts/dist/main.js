"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const electron_1 = require("electron");
const fs_1 = require("fs");
const path_1 = require("path");
const child_process_1 = require("child_process");
process.on('uncaughtException', (err) => console.error('[ct] uncaught:', err.message, err.stack));
process.on('unhandledRejection', (reason) => console.error('[ct] rejection:', reason));
// ── Env config ───────────────────────────────────────────────────────────────
const profileName = process.env.CT_PROFILE || 'nix-flakes';
const profilesDir = process.env.CT_PROFILES_DIR || (0, path_1.join)(__dirname, '..', '..', 'data');
const panelPath = process.env.CT_PANEL || (0, path_1.join)(__dirname, '..', '..', '..', 'lib', 'panel.html');
const iconPath = process.env.CT_ICON || (0, path_1.join)(__dirname, '..', '..', 'assets', profileName + '.png');
const binDir = process.env.CT_BIN_DIR || '';
const XDG = process.env.CT_XDG || 'xdg-open';
// PTY helper: runs under SYSTEM node (ABI-safe for the prebuilt node-pty).
const NODE = process.env.CT_NODE || 'node';
const ptyServer = process.env.CT_PTY_SERVER || (0, path_1.join)(__dirname, 'pty-server.js');
// ── Load all profiles from profilesDir ──────────────────────────────────────
let profiles = [];
let profile = null;
try {
    const files = (0, fs_1.readdirSync)(profilesDir)
        .filter(f => f.startsWith('profile-') && f.endsWith('.json'))
        .sort();
    profiles = files.map(f => JSON.parse((0, fs_1.readFileSync)((0, path_1.join)(profilesDir, f), 'utf8')));
    profile = profiles.find(p => p.name === profileName) ?? profiles[0];
    if (!profile)
        throw new Error('no profiles found in ' + profilesDir);
}
catch (e) {
    console.error('[ct] profile load failed:', e);
    process.exit(1);
}
// ── Per-profile single-instance domain ───────────────────────────────────────
// Each profile is its own tray daemon. Distinct userData → distinct instance lock,
// so the same main.js can run once per profile, but never twice for one profile.
// Distinct app identity per profile → distinct StatusNotifierItem id, so KDE
// renders one tray icon PER profile instead of collapsing them into one.
electron_1.app.setName('cloud-terminal-' + profile.name);
try {
    electron_1.app.setAppUserModelId?.('com.diegonmarcos.cloud-terminal.' + profile.name);
}
catch (_) { }
electron_1.app.setPath('userData', (0, path_1.join)(electron_1.app.getPath('appData'), 'cloud-terminal-' + profile.name));
if (!electron_1.app.requestSingleInstanceLock()) {
    // another instance of THIS profile is already running — it will show itself
    electron_1.app.quit();
}
else {
    electron_1.app.on('second-instance', () => showWin());
    main();
}
// ── Placeholder resolution ───────────────────────────────────────────────────
function resolve(arg, prof) {
    return arg
        .replace(/\{FLAKE\}/g, prof.flake || '')
        .replace(/\{FLAKE_SYSTEM\}/g, prof.flakes?.system || '')
        .replace(/\{FLAKE_DESKTOP\}/g, prof.flakes?.desktop || '')
        .replace(/\{FLAKE_CLOUD\}/g, prof.flakes?.cloud || '');
}
function profByName(name) {
    return profiles.find(p => p.name === name) || profile;
}
// ── App ──────────────────────────────────────────────────────────────────────
let win = null;
let tray = null;
function main() {
    electron_1.app.on('window-all-closed', () => { });
    electron_1.app.on('ready', () => {
        // Tray — nativeImage required on Linux; bare string path silently fails
        const icon = electron_1.nativeImage.createFromPath((0, fs_1.existsSync)(iconPath) ? iconPath : '');
        tray = new electron_1.Tray(icon);
        tray.setToolTip(profile.tray_tooltip || profile.display_name);
        tray.setContextMenu(buildTrayMenu());
        tray.on('click', () => toggleWin());
        win = new electron_1.BrowserWindow({
            width: 1040, height: 660, show: false, frame: true,
            backgroundColor: profile.theme?.bg || '#0e0f1a',
            webPreferences: { nodeIntegration: true, contextIsolation: false },
        });
        win.loadFile(panelPath);
        win.webContents.on('did-finish-load', () => {
            win.webContents.send('init', { ...profile, profiles });
        });
        win.on('close', (e) => { e.preventDefault(); win.hide(); });
        if (process.argv.includes('--show'))
            showWin();
    });
}
// ── Tray right-click menu = the profile's command shortcuts (data-driven) ─────
function buildTrayMenu() {
    const tpl = [
        { label: (profile.logo || '') + '  ' + profile.display_name, enabled: false },
        { type: 'separator' },
        { label: 'Open Panel', click: () => showWin() },
        { type: 'separator' },
    ];
    for (const section of (profile.sections || [])) {
        const items = (section.items || []).map((it) => ({
            label: it.label,
            click: () => dispatch(it),
        }));
        tpl.push({ label: section.title, submenu: items });
    }
    tpl.push({ type: 'separator' });
    for (const p of profiles.filter(p => p.name !== profile.name)) {
        tpl.push({ label: 'Switch → ' + (p.logo ? p.logo + ' ' : '') + p.display_name, click: () => launchProfile(p.name) });
    }
    tpl.push({ type: 'separator' }, { label: 'Quit', click: () => electron_1.app.quit() });
    return electron_1.Menu.buildFromTemplate(tpl);
}
function showWin() { win?.show(); win?.focus(); }
function toggleWin() { win?.isVisible() ? win.hide() : showWin(); }
// ── PTY broker (multi-session: one helper process per terminal tab) ──────────
// Each tab has a numeric id (assigned by the renderer). The system-node helper
// is ABI-safe for the prebuilt node-pty. Output/exit events carry the id.
const ptys = new Map();
const ptyBufs = new Map();
function ptyStart(id, cols, rows) {
    if (ptys.has(id))
        return;
    const p = (0, child_process_1.spawn)(NODE, [ptyServer], {
        stdio: ['pipe', 'pipe', 'pipe'],
        env: { ...process.env, CT_COLS: String(cols || 80), CT_ROWS: String(rows || 24), CT_CWD: process.env.HOME || '/' },
    });
    ptys.set(id, p);
    ptyBufs.set(id, '');
    p.stdout?.on('data', (d) => win?.webContents.send('pty-data', id, d.toString()));
    p.stderr?.on('data', (d) => {
        let buf = (ptyBufs.get(id) || '') + d.toString();
        let nl;
        while ((nl = buf.indexOf('\n')) >= 0) {
            const line = buf.slice(0, nl);
            buf = buf.slice(nl + 1);
            if (line)
                win?.webContents.send('pty-exit', id, line);
        }
        ptyBufs.set(id, buf);
    });
    p.on('close', () => { ptys.delete(id); ptyBufs.delete(id); });
}
function ptySend(id, msg) {
    const p = ptys.get(id);
    if (p && p.stdin)
        p.stdin.write(JSON.stringify(msg) + '\n');
}
function ptyKill(id) {
    const p = ptys.get(id);
    if (p) {
        try {
            p.kill();
        }
        catch (_) { }
        ptys.delete(id);
        ptyBufs.delete(id);
    }
}
// ── Central dispatch (used by both panel clicks and tray menu) ───────────────
// `prof` = the profile the item belongs to (the active in-window profile, which
// may differ from the launched tray profile after an in-window tab switch).
// Everything except xdg/open is TYPED INTO THE INTERACTIVE SHELL so it runs
// inside our terminal (btop, ssh, dtk menus, builds — all real & interactive).
function dispatch(item, prof = profile) {
    const a = resolve(item.arg || '', prof);
    if (item.type === 'xdg' || item.type === 'open') { // GUI apps → external (correct)
        (0, child_process_1.spawn)(XDG, [a], { detached: true, stdio: 'ignore' }).unref();
        return;
    }
    let line = a;
    if (item.type === 'build' || item.type === 'build-system' || item.type === 'build-desktop') {
        const flake = item.type === 'build' ? (prof.flake || '') :
            item.type === 'build-system' ? (prof.flakes?.system || prof.flake || '') :
                (prof.flakes?.desktop || prof.flake || '');
        line = `cd ${shq(flake)} && PATH="/run/wrappers/bin:$PATH" bash build.sh ${a}`;
    }
    else if (item.type === 'log' || item.type === 'log-system' || item.type === 'log-desktop') {
        const logDir = item.type === 'log' ? (prof.flake || '') :
            item.type === 'log-system' ? (prof.flakes?.system || prof.flake || '') :
                (prof.flakes?.desktop || prof.flake || '');
        line = `ls -t ${shq(logDir)}/logs/*.log 2>/dev/null | head -1 | xargs -r tail -f`;
    }
    // shell / term / build / log → type the command into the selected tab's PTY
    showWin();
    const id = item.ptyId;
    if (id == null)
        return;
    ptySend(id, { type: 'data', d: line + '\r' });
}
function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }
electron_1.ipcMain.on('run-item', (_e, item) => dispatch(item, profByName(item.profile)));
electron_1.ipcMain.on('pty-start', (_e, a) => ptyStart(a.id, a.cols, a.rows));
electron_1.ipcMain.on('pty-input', (_e, a) => ptySend(a.id, { type: 'data', d: a.d }));
electron_1.ipcMain.on('pty-resize', (_e, a) => ptySend(a.id, { type: 'resize', cols: a.cols, rows: a.rows }));
electron_1.ipcMain.on('pty-kill', (_e, a) => ptyKill(a.id));
electron_1.ipcMain.on('switch-profile', (_e, name) => launchProfile(name));
// Fixed: spawn the sibling launcher by absolute path (CT_BIN_DIR). Bare name was
// never on PATH → silent ENOENT → switch did nothing.
function launchProfile(name) {
    const bin = binDir ? (0, path_1.join)(binDir, 'cloud-terminal-' + name) : '';
    if (bin && (0, fs_1.existsSync)(bin)) {
        (0, child_process_1.spawn)(bin, ['--show'], { detached: true, stdio: 'ignore' }).unref();
    }
    else {
        // fallback: re-exec this same main.js under a different profile
        (0, child_process_1.spawn)(process.execPath, [(0, path_1.join)(__dirname, 'main.js'), '--show'], { detached: true, stdio: 'ignore', env: { ...process.env, CT_PROFILE: name, CT_ICON: '' } }).unref();
    }
}
