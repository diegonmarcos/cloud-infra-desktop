"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const electron_1 = require("electron");
const fs_1 = require("fs");
const path_1 = require("path");
const child_process_1 = require("child_process");
process.on('uncaughtException', (err) => console.error('[et] uncaught:', err.message, err.stack));
process.on('unhandledRejection', (reason) => console.error('[et] rejection:', reason));
// ── Env config ──────────────────────────────────────────────────────────────
const profileName = process.env.ET_PROFILE || 'nix-flakes';
const profilesDir = process.env.ET_PROFILES_DIR || (0, path_1.join)(__dirname, '..', '..', 'data');
const panelPath = process.env.ET_PANEL || (0, path_1.join)(__dirname, '..', '..', '..', 'lib', 'panel.html');
const iconPath = process.env.ET_ICON || (0, path_1.join)(__dirname, '..', '..', 'assets', profileName + '.png');
const switchGui = process.env.ET_SWITCH_GUI || '';
const KONSOLE = process.env.ET_KONSOLE || 'konsole';
const BASH = process.env.ET_BASH || '/bin/bash';
const XDG = process.env.ET_XDG || 'xdg-open';
// ── Load profiles ────────────────────────────────────────────────────────────
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
    console.error('[et] profile load failed:', e);
    process.exit(1);
}
// ── Placeholder resolution ───────────────────────────────────────────────────
function resolve(arg) {
    return arg
        .replace('{FLAKE}', profile.flake || '')
        .replace('{FLAKE_SYSTEM}', profile.flakes?.system || '')
        .replace('{FLAKE_DESKTOP}', profile.flakes?.desktop || '')
        .replace('{FLAKE_CLOUD}', profile.flakes?.cloud || '');
}
// ── Konsole helper ───────────────────────────────────────────────────────────
function konsole(cmd) {
    (0, child_process_1.spawn)(KONSOLE, ['-e', BASH, '-c', cmd + '; echo; read -p "[done, enter to close] "'], { detached: true, stdio: 'ignore' }).unref();
}
// ── App ──────────────────────────────────────────────────────────────────────
let win = null;
let tray = null;
electron_1.app.setQuitOnLastWindowClose(false);
electron_1.app.on('ready', () => {
    // Tray — must use nativeImage on Linux (bare path string fails)
    const icon = (0, fs_1.existsSync)(iconPath) ? electron_1.nativeImage.createFromPath(iconPath) : electron_1.nativeImage.createFromPath('');
    tray = new electron_1.Tray(icon);
    tray.setToolTip(profile.tray_tooltip || profile.display_name);
    tray.setContextMenu(electron_1.Menu.buildFromTemplate([
        { label: profile.logo + '  ' + profile.display_name, enabled: false },
        { type: 'separator' },
        { label: 'Open Panel', click: () => showWin() },
        { type: 'separator' },
        ...profiles
            .filter(p => p.name !== profile.name)
            .map(p => ({ label: 'Switch → ' + p.display_name, click: () => launchProfile(p.name) })),
        { type: 'separator' },
        { label: 'Quit', click: () => electron_1.app.quit() },
    ]));
    tray.on('click', () => toggleWin());
    // Window
    win = new electron_1.BrowserWindow({
        width: 1000, height: 620, show: false, frame: true,
        backgroundColor: profile.theme.bg,
        webPreferences: { nodeIntegration: true, contextIsolation: false },
    });
    win.loadFile(panelPath);
    win.webContents.on('did-finish-load', () => {
        win.webContents.send('init', { profile, profiles });
    });
    win.on('close', (e) => { e.preventDefault(); win.hide(); });
    if (process.argv.includes('--show'))
        showWin();
});
function showWin() { win?.show(); win?.focus(); }
function toggleWin() { win?.isVisible() ? win.hide() : showWin(); }
// ── Dispatch ─────────────────────────────────────────────────────────────────
electron_1.ipcMain.on('dispatch', (_e, { type, arg }) => {
    const a = resolve(arg);
    // open URL or folder
    if (type === 'xdg' || type === 'open') {
        (0, child_process_1.spawn)(XDG, [a], { detached: true, stdio: 'ignore' }).unref();
        return;
    }
    // nix build — kdialog progress OR konsole
    if (type === 'build' || type === 'build-system' || type === 'build-desktop') {
        const flake = type === 'build' ? (profile.flake || '') :
            type === 'build-system' ? (profile.flakes?.system || profile.flake || '') :
                (profile.flakes?.desktop || profile.flake || '');
        if (type === 'build' && switchGui && flake) {
            (0, child_process_1.spawn)(BASH, [switchGui, a], { detached: true, stdio: 'ignore', cwd: flake }).unref();
        }
        else {
            konsole(`cd "${flake}" && PATH="/run/wrappers/bin:$PATH" bash build.sh ${a}`);
        }
        return;
    }
    // tail build log
    if (type === 'log' || type === 'log-system' || type === 'log-desktop') {
        const logDir = type === 'log' ? (profile.flake || '') :
            type === 'log-system' ? (profile.flakes?.system || profile.flake || '') :
                (profile.flakes?.desktop || profile.flake || '');
        konsole(`ls -t "${logDir}/logs/"*.log 2>/dev/null | head -1 | xargs tail -f 2>/dev/null || echo "No logs in ${logDir}/logs/"`);
        return;
    }
    // shell — stream stdout/stderr into the panel output div
    if (!win)
        return;
    const proc = (0, child_process_1.spawn)(BASH, ['-c', a], { stdio: 'pipe' });
    proc.stdout?.on('data', (d) => win?.webContents.send('output', d.toString()));
    proc.stderr?.on('data', (d) => win?.webContents.send('output', d.toString()));
    proc.on('close', (code) => win?.webContents.send('done', code ?? -1));
});
electron_1.ipcMain.on('switch-profile', (_e, name) => launchProfile(name));
function launchProfile(name) {
    (0, child_process_1.spawn)(`electron-terminal-${name}`, ['--show'], { detached: true, stdio: 'ignore' }).unref();
}
