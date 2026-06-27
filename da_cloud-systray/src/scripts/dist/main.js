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
 * Cloud & Infra Control Panel — Electron main process.
 * Native SNI tray (no xembedsniproxy, no "Input devices" portal popup).
 * All paths injected via env vars set by Nix makeWrapper.
 */
const electron_1 = require("electron");
const child_process_1 = require("child_process");
const path = __importStar(require("path"));
const fs = __importStar(require("fs"));
// Route ALL uncaught errors to stderr → systemd journal instead of native dialog
process.on('uncaughtException', (err) => {
    console.error('[cloud-systray] UNCAUGHT:', err.stack ?? err.message);
    process.exit(1);
});
process.on('unhandledRejection', (reason) => {
    console.error('[cloud-systray] UNHANDLED REJECTION:', reason);
    process.exit(1);
});
// ── env vars baked in by Nix makeWrapper ──────────────────────────────────────
const DATA = process.env.SYSTRAY_DATA;
const BASH = process.env.SYSTRAY_BASH;
const KONSOLE = process.env.SYSTRAY_KONSOLE;
const XDG = process.env.SYSTRAY_XDG;
const ICON_PATH = process.env.SYSTRAY_ICON;
const FLAKE_SYSTEM = process.env.SYSTRAY_FLAKE_SYSTEM ?? '';
const FLAKE_DESKTOP = process.env.SYSTRAY_FLAKE_DESKTOP ?? '';
const FLAKE_CLOUD = process.env.SYSTRAY_FLAKE_CLOUD ?? '';
// ── helpers ───────────────────────────────────────────────────────────────────
function loadData() {
    return JSON.parse(fs.readFileSync(DATA, 'utf8'));
}
function flatItems(data) {
    return data.sections.flatMap(s => s.items);
}
function expandArg(arg) {
    return arg
        .replace('{FLAKE_SYSTEM}', FLAKE_SYSTEM)
        .replace('{FLAKE_DESKTOP}', FLAKE_DESKTOP)
        .replace('{FLAKE_CLOUD}', FLAKE_CLOUD)
        .replace('{FLAKE}', FLAKE_SYSTEM);
}
function latestLog(flake) {
    const logDir = path.join(flake, 'logs');
    if (!fs.existsSync(logDir))
        return null;
    const logs = fs.readdirSync(logDir).filter(f => f.endsWith('.log')).sort();
    return logs.length ? path.join(logDir, logs[logs.length - 1]) : null;
}
function genTooltip(data) {
    const base = data.tray_tooltip ?? 'Cloud & Infra';
    let gen = '?';
    try {
        const link = fs.readlinkSync('/nix/var/nix/profiles/system');
        gen = link.split('-')[1] ?? '?';
    }
    catch { }
    let last = 'no builds yet';
    const log = FLAKE_SYSTEM ? latestLog(FLAKE_SYSTEM) : null;
    if (log) {
        try {
            last = fs.statSync(log).mtime.toLocaleString();
        }
        catch { }
    }
    return `${base} | Sys Gen ${gen} | Last: ${last}`;
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
// ── dispatch ──────────────────────────────────────────────────────────────────
function dispatch(item, win) {
    const arg = expandArg(item.arg ?? '');
    const label = item.label;
    const sendOut = (s) => win?.webContents.send('output', s);
    const sendDone = (c) => win?.webContents.send('done', c);
    switch (item.type) {
        case 'build-system':
        case 'build-desktop': {
            const flake = item.type === 'build-system' ? FLAKE_SYSTEM : FLAKE_DESKTOP;
            (0, child_process_1.spawn)(KONSOLE, [
                '--hold', '--separate', '-p', 'ColorScheme=Breeze',
                '--title', `Build — ${label}`,
                '-e', BASH, '-lc',
                `cd '${flake}' && PATH=/run/wrappers/bin:$PATH ./build.sh '${arg}'; printf '\\n=== done (exit %s) ===\\n' "$?"`,
            ], { detached: true, stdio: 'ignore' }).unref();
            sendOut(`[${label}] build launched in Konsole\n`);
            break;
        }
        case 'shell': {
            const needsTty = arg.includes('sudo') || arg.includes('nix-env');
            if (needsTty) {
                (0, child_process_1.spawn)(KONSOLE, [
                    '--hold', '--separate', '-p', 'ColorScheme=Breeze',
                    '--title', `Cloud — ${label}`,
                    '-e', BASH, '-lc',
                    `${arg}; printf '\\n=== done (exit %s) ===\\n' "$?"`,
                ], { detached: true, stdio: 'ignore' }).unref();
                sendOut(`[${label}] needs sudo — opened Konsole\n`);
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
        case 'log-system':
        case 'log-desktop': {
            const flake = item.type === 'log-system' ? FLAKE_SYSTEM : FLAKE_DESKTOP;
            const log = latestLog(flake);
            if (log) {
                killProc();
                sendOut(`\n[tail] ${log}\n${'─'.repeat(70)}\n`);
                proc = (0, child_process_1.spawn)(BASH, ['-lc', `tail -n 200 '${log}'`]);
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
            sendOut(`[${label}] opened: ${arg}\n`);
            break;
    }
}
// ── main ──────────────────────────────────────────────────────────────────────
electron_1.app.on('ready', () => {
    const data = loadData();
    const items = flatItems(data);
    const showOnStart = process.argv.includes('--show');
    const win = new electron_1.BrowserWindow({
        width: 1000, height: 620,
        title: 'Cloud & Infra Control Panel',
        show: showOnStart,
        webPreferences: { nodeIntegration: true, contextIsolation: false },
    });
    win.loadFile(path.join(__dirname, 'panel.html'));
    win.on('close', (e) => { e.preventDefault(); win.hide(); });
    electron_1.ipcMain.on('get-data', (_e) => { _e.reply('data', data); });
    electron_1.ipcMain.on('run-cmd', (_e, idx) => dispatch(items[idx], win));
    electron_1.ipcMain.on('kill-cmd', () => killProc());
    const tray = new electron_1.Tray(ICON_PATH);
    tray.setToolTip(genTooltip(data));
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
