"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
/**
 * NixOS Control Panel — Electron main process.
 * Native SNI tray (no xembedsniproxy, no "Input devices" portal popup).
 * All paths injected via env vars set by Nix makeWrapper.
 */
const electron_1 = require("electron");
const child_process_1 = require("child_process");
const path = __importStar(require("path"));
const fs = __importStar(require("fs"));
// Route ALL uncaught errors to stderr → systemd journal instead of native dialog
process.on('uncaughtException', (err) => {
    console.error('[nixos-systray] UNCAUGHT:', err.stack ?? err.message);
    process.exit(1);
});
process.on('unhandledRejection', (reason) => {
    console.error('[nixos-systray] UNHANDLED REJECTION:', reason);
    process.exit(1);
});
// ── env vars baked in by Nix makeWrapper ──────────────────────────────────────
const DATA = process.env.SYSTRAY_DATA;
const BASH = process.env.SYSTRAY_BASH;
const KONSOLE = process.env.SYSTRAY_KONSOLE;
const XDG = process.env.SYSTRAY_XDG;
const SWITCH_GUI = process.env.SYSTRAY_SWITCH_GUI;
const FLAKE = process.env.SYSTRAY_FLAKE;
const ICON_PATH = process.env.SYSTRAY_ICON;
// ── helpers ───────────────────────────────────────────────────────────────────
function loadData() {
    return JSON.parse(fs.readFileSync(DATA, 'utf8'));
}
function flatItems(data) {
    return data.sections.flatMap(s => s.items);
}
function genTooltip(data) {
    const base = data.tray_tooltip ?? 'NixOS Control Panel';
    let gen = '?';
    try {
        const link = fs.readlinkSync('/nix/var/nix/profiles/system');
        gen = link.split('-')[1] ?? '?';
    }
    catch { }
    let last = 'no builds yet';
    try {
        const logDir = path.join(FLAKE, 'logs');
        if (fs.existsSync(logDir)) {
            const logs = fs.readdirSync(logDir).filter(f => f.endsWith('.log')).sort();
            if (logs.length) {
                const mtime = fs.statSync(path.join(logDir, logs[logs.length - 1])).mtime;
                last = mtime.toLocaleString();
            }
        }
    }
    catch { }
    return `${base} | Gen ${gen} | Last: ${last}`;
}
// ── state ─────────────────────────────────────────────────────────────────────
let proc = null;
function killProc() {
    if (proc) {
        try {
            proc.kill();
        }
        catch { }
        proc = null;
    }
}
// ── dispatch (called from both context menu and panel window) ─────────────────
function dispatch(item, win) {
    const arg = (item.arg ?? '').replace('{FLAKE}', FLAKE);
    const sendOut = (s) => win?.webContents.send('output', s);
    const sendDone = (c) => win?.webContents.send('done', c);
    switch (item.type) {
        case 'build':
            // kdialog progress window via switch-gui.sh
            (0, child_process_1.spawn)(SWITCH_GUI, [arg], { detached: true, stdio: 'ignore' }).unref();
            sendOut(`[${item.label}] build launched — see kdialog progress window\n`);
            break;
        case 'shell': {
            const needsTty = arg.includes('sudo') || arg.includes('loginctl');
            if (needsTty) {
                (0, child_process_1.spawn)(KONSOLE, ['--hold', '--separate', '-p', 'ColorScheme=Breeze',
                    '--title', `NixOS — ${item.label}`,
                    '-e', BASH, '-lc', `${arg}; printf '\\n=== done (exit %s) ===\\n' "$?"`], { detached: true, stdio: 'ignore' }).unref();
                sendOut(`[${item.label}] needs sudo — opened Konsole\n`);
            }
            else {
                killProc();
                sendOut(`\n$ ${arg}\n${'─'.repeat(70)}\n`);
                proc = (0, child_process_1.spawn)(BASH, ['-lc', arg]);
                proc.stdout?.on('data', d => sendOut(d.toString()));
                proc.stderr?.on('data', d => sendOut(d.toString()));
                proc.on('close', code => { proc = null; sendDone(code ?? 0); });
            }
            break;
        }
        case 'log': {
            const logDir = path.join(FLAKE, 'logs');
            const logs = fs.existsSync(logDir)
                ? fs.readdirSync(logDir).filter(f => f.endsWith('.log')).sort()
                : [];
            if (logs.length) {
                const tgt = path.join(logDir, logs[logs.length - 1]);
                killProc();
                sendOut(`\n[tail] ${tgt}\n${'─'.repeat(70)}\n`);
                proc = (0, child_process_1.spawn)(BASH, ['-lc', `tail -n 200 '${tgt}'`]);
                proc.stdout?.on('data', d => sendOut(d.toString()));
                proc.stderr?.on('data', d => sendOut(d.toString()));
                proc.on('close', code => { proc = null; sendDone(code ?? 0); });
            }
            else {
                sendOut('No build logs yet.\n');
            }
            break;
        }
        case 'open':
        case 'xdg':
            (0, child_process_1.spawn)(XDG, [arg], { detached: true, stdio: 'ignore' }).unref();
            sendOut(`[${item.label}] opened: ${arg}\n`);
            break;
    }
}
// ── main ──────────────────────────────────────────────────────────────────────
electron_1.app.on('ready', () => {
    const data = loadData();
    const items = flatItems(data);
    // --show flag: launched from desktop shortcut → open window immediately
    const showOnStart = process.argv.includes('--show');
    // ── panel window ──
    const win = new electron_1.BrowserWindow({
        width: 1000, height: 620,
        title: 'NixOS Control Panel',
        show: showOnStart,
        webPreferences: { nodeIntegration: true, contextIsolation: false },
    });
    win.loadFile(path.join(__dirname, 'panel.html'));
    win.on('close', (e) => { e.preventDefault(); win.hide(); });
    // ── IPC from renderer ──
    electron_1.ipcMain.on('get-data', (_e) => { _e.reply('data', data); });
    electron_1.ipcMain.on('run-cmd', (_e, idx) => dispatch(items[idx], win));
    electron_1.ipcMain.on('kill-cmd', () => killProc());
    // ── tray ──
    const tray = new electron_1.Tray(ICON_PATH);
    tray.setToolTip(genTooltip(data));
    // right-click context menu (quick-run without opening panel)
    const menuItems = [];
    let curSection = '';
    for (let i = 0; i < items.length; i++) {
        const item = items[i];
        const sec = data.sections.find(s => s.items.includes(item)).title;
        if (sec !== curSection) {
            if (curSection)
                menuItems.push({ type: 'separator' });
            menuItems.push({ label: sec, enabled: false });
            curSection = sec;
        }
        menuItems.push({ label: item.label, click: () => dispatch(item, win.isVisible() ? win : null) });
    }
    menuItems.push({ type: 'separator' }, { label: 'Quit', click: () => { killProc(); electron_1.app.quit(); } });
    tray.setContextMenu(electron_1.Menu.buildFromTemplate(menuItems));
    // left-click → toggle panel
    tray.on('click', () => {
        if (win.isVisible()) {
            win.hide();
        }
        else {
            win.show();
            win.focus();
        }
    });
});
electron_1.app.on('window-all-closed', () => { });
