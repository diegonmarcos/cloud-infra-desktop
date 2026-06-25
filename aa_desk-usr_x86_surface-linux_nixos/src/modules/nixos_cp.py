#!/usr/bin/env python3
"""NixOS Control Panel — a Qt6 (PySide6) system-tray app with a dark UI for
rebuilding and managing the host. Tray icon + grouped submenus (data-driven
from /etc/nixos-cp.json), real Qt progress windows with a live log, and GUI
sudo via ksshaskpass (so build.sh's `sudo nixos-rebuild` works without a TTY)."""

import os
import re
import json
import shutil
import subprocess

from PySide6.QtCore import Qt, QProcess, QProcessEnvironment, QTimer, QFileSystemWatcher
from PySide6.QtGui import QIcon, QAction, QPalette, QColor, QFont, QCursor, QDesktopServices
from PySide6.QtCore import QUrl
from PySide6.QtWidgets import (
    QApplication, QSystemTrayIcon, QMenu, QDialog, QVBoxLayout, QHBoxLayout,
    QLabel, QProgressBar, QPlainTextEdit, QPushButton, QMessageBox, QStyle,
)

CONF = os.environ.get("NIXOS_CP_CONF", "/etc/nixos-cp.json")
FLAKE = os.environ.get("NIXOS_CP_FLAKE", "/home/diego/git/unix/aa_desk-usr_x86_surface-linux_nixos")
ASKPASS = shutil.which("ksshaskpass") or os.environ.get("SUDO_ASKPASS", "")

ACCENT = "#3daee9"   # Breeze blue


def load_conf():
    try:
        with open(CONF) as fh:
            return json.load(fh)
    except Exception:
        return {"tray_icon": "nix-snowflake", "tray_tooltip": "NixOS", "sections": []}


def subst(s):
    return (s or "").replace("{FLAKE}", FLAKE)


def apply_dark(app):
    app.setStyle("Fusion")
    p = QPalette()
    window = QColor(35, 38, 41)
    base = QColor(27, 30, 32)
    text = QColor(239, 240, 241)
    disabled = QColor(120, 124, 128)
    accent = QColor(ACCENT)
    p.setColor(QPalette.Window, window)
    p.setColor(QPalette.WindowText, text)
    p.setColor(QPalette.Base, base)
    p.setColor(QPalette.AlternateBase, window)
    p.setColor(QPalette.ToolTipBase, base)
    p.setColor(QPalette.ToolTipText, text)
    p.setColor(QPalette.Text, text)
    p.setColor(QPalette.Button, window)
    p.setColor(QPalette.ButtonText, text)
    p.setColor(QPalette.BrightText, QColor("#ff5555"))
    p.setColor(QPalette.Highlight, accent)
    p.setColor(QPalette.HighlightedText, QColor(0, 0, 0))
    p.setColor(QPalette.PlaceholderText, disabled)
    p.setColor(QPalette.Disabled, QPalette.Text, disabled)
    p.setColor(QPalette.Disabled, QPalette.ButtonText, disabled)
    app.setPalette(p)
    app.setStyleSheet(
        "QDialog{background:#232629;}"
        "QPlainTextEdit{background:#1b1e20;color:#eff0f1;border:1px solid #31363b;"
        "border-radius:6px;padding:6px;}"
        "QProgressBar{border:1px solid #31363b;border-radius:7px;height:16px;"
        "text-align:center;background:#1b1e20;color:#eff0f1;}"
        "QProgressBar::chunk{background:%s;border-radius:6px;}"
        "QPushButton{background:#31363b;border:1px solid #41464b;border-radius:6px;"
        "padding:6px 16px;}QPushButton:hover{background:#3b4045;}"
        "QPushButton:disabled{color:#787c80;}"
        "QLabel#hdr{font-size:15px;font-weight:bold;}"
        "QMenu{background:#232629;border:1px solid #31363b;padding:4px;}"
        "QMenu::item{padding:6px 26px;border-radius:5px;}"
        "QMenu::item:selected{background:%s;color:#000;}"
        "QMenu::separator{height:1px;background:#31363b;margin:4px 8px;}" % (ACCENT, ACCENT)
    )


def icon(name, fallback=QStyle.SP_FileIcon):
    ic = QIcon.fromTheme(name)
    if ic.isNull() and name:
        for ext in ("png", "svg"):
            path = "/run/current-system/sw/share/icons/hicolor/128x128/apps/%s.%s" % (name, ext)
            if os.path.exists(path):
                return QIcon(path)
    return ic


class RunWindow(QDialog):
    """Dark window: a live log + progress bar streaming a command via QProcess."""

    def __init__(self, title, command, needs_root):
        super().__init__()
        self.setWindowTitle("NixOS — " + title)
        self.setMinimumSize(940, 600)
        self.command = command
        v = QVBoxLayout(self)
        self.hdr = QLabel(title)
        self.hdr.setObjectName("hdr")
        v.addWidget(self.hdr)
        self.status = QLabel("Starting…")
        v.addWidget(self.status)
        self.bar = QProgressBar()
        self.bar.setRange(0, 0)  # indeterminate until we parse [n/m built]
        v.addWidget(self.bar)
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMaximumBlockCount(8000)
        self.log.setFont(QFont("monospace", 10))
        v.addWidget(self.log, 1)
        h = QHBoxLayout()
        h.addStretch(1)
        self.cancel = QPushButton("Cancel")
        self.cancel.clicked.connect(self.on_cancel)
        self.close_btn = QPushButton("Close")
        self.close_btn.setEnabled(False)
        self.close_btn.clicked.connect(self.accept)
        h.addWidget(self.cancel)
        h.addWidget(self.close_btn)
        v.addLayout(h)

        self.proc = QProcess(self)
        self.proc.setProcessChannelMode(QProcess.MergedChannels)
        self.proc.readyRead.connect(self.on_output)
        self.proc.finished.connect(self.on_finished)
        QTimer.singleShot(60, lambda: self.start(needs_root))

    def append(self, text):
        self.log.appendPlainText(text.rstrip("\n"))

    def start(self, needs_root):
        if needs_root and ASKPASS:
            # Pre-authorize sudo via the KDE GUI prompt so build.sh's internal
            # `sudo` uses the cached credential (no TTY needed in a GUI app).
            self.status.setText("Authorizing (enter your password)…")
            QApplication.processEvents()
            try:
                env = dict(os.environ, SUDO_ASKPASS=ASKPASS)
                r = subprocess.run(["sudo", "-A", "-v"], env=env, timeout=180)
                if r.returncode != 0:
                    self.append("[auth] cancelled or failed — aborting.")
                    self.finish_ui(1)
                    return
            except Exception as exc:
                self.append("[auth] %s" % exc)
                self.finish_ui(1)
                return
        env = QProcessEnvironment.systemEnvironment()
        if ASKPASS:
            env.insert("SUDO_ASKPASS", ASKPASS)
        self.proc.setProcessEnvironment(env)
        self.status.setText("Running: %s" % self.command)
        self.proc.start("bash", ["-lc", self.command])

    def on_output(self):
        data = bytes(self.proc.readAll()).decode("utf-8", "replace")
        for line in data.splitlines():
            self.append(line)
            m = re.search(r"\[(\d+)/(\d+)\s+built", line) or re.search(r"\[(\d+)/(\d+)\]", line)
            if m:
                done, total = int(m.group(1)), int(m.group(2))
                if total:
                    self.bar.setRange(0, total)
                    self.bar.setValue(done)
                    self.status.setText("Building %d / %d…" % (done, total))

    def on_finished(self, code, _status):
        self.finish_ui(code)

    def finish_ui(self, code):
        self.bar.setRange(0, 1)
        self.bar.setValue(1)
        ok = code == 0
        self.bar.setStyleSheet("" if ok else "QProgressBar::chunk{background:#ed1515;}")
        self.status.setText("✓ Finished successfully." if ok else "✗ Failed (exit %d)." % code)
        self.cancel.setEnabled(False)
        self.close_btn.setEnabled(True)
        self.close_btn.setDefault(True)

    def on_cancel(self):
        if self.proc.state() != QProcess.NotRunning:
            self.proc.kill()
        self.append("[cancelled]")
        self.finish_ui(1)


class LogWindow(QDialog):
    """Live-tail the newest build log."""

    def __init__(self):
        super().__init__()
        self.setWindowTitle("NixOS — latest build log")
        self.setMinimumSize(940, 600)
        v = QVBoxLayout(self)
        self.path = self.newest_log()
        hdr = QLabel(self.path or "no build logs yet")
        hdr.setObjectName("hdr")
        v.addWidget(hdr)
        self.view = QPlainTextEdit()
        self.view.setReadOnly(True)
        self.view.setMaximumBlockCount(20000)
        self.view.setFont(QFont("monospace", 10))
        v.addWidget(self.view, 1)
        btn = QPushButton("Close")
        btn.clicked.connect(self.accept)
        h = QHBoxLayout()
        h.addStretch(1)
        h.addWidget(btn)
        v.addLayout(h)
        self._pos = 0
        if self.path:
            self.refresh()
            self.timer = QTimer(self)
            self.timer.timeout.connect(self.refresh)
            self.timer.start(800)

    def newest_log(self):
        import glob
        logs = sorted(glob.glob(os.path.join(FLAKE, "logs", "build-*.log")), key=os.path.getmtime)
        return logs[-1] if logs else ""

    def refresh(self):
        try:
            with open(self.path, "r", errors="replace") as fh:
                fh.seek(self._pos)
                chunk = fh.read()
                self._pos = fh.tell()
            if chunk:
                self.view.appendPlainText(chunk.rstrip("\n"))
        except Exception:
            pass


class Tray:
    def __init__(self, app):
        self.app = app
        self.windows = []
        self.conf = load_conf()
        self.icon = QSystemTrayIcon(icon(self.conf.get("tray_icon", "nix-snowflake")))
        self.icon.setToolTip(self.conf.get("tray_tooltip", "NixOS"))
        self.menu = self.build_menu()
        self.icon.setContextMenu(self.menu)
        self.icon.activated.connect(self.on_activated)
        self.icon.show()

    def build_menu(self):
        m = QMenu()
        title = QAction("NixOS Control Panel", m)
        title.setEnabled(False)
        m.addAction(title)
        m.addSeparator()
        for sec in self.conf.get("sections", []):
            sub = m.addMenu(icon(sec.get("icon", "")), sec.get("title", "…"))
            for it in sec.get("items", []):
                act = sub.addAction(icon(it.get("icon", "")), it.get("label", "?"))
                act.triggered.connect(lambda _=False, i=it: self.run(i))
        m.addSeparator()
        about = m.addAction(icon("help-about"), "About")
        about.triggered.connect(self.about)
        quit_a = m.addAction(icon("application-exit"), "Quit tray")
        quit_a.triggered.connect(self.app.quit)
        return m

    def on_activated(self, reason):
        if reason in (QSystemTrayIcon.Trigger, QSystemTrayIcon.Context):
            self.menu.popup(QCursor.pos())

    def run(self, item):
        t = item.get("type")
        arg = subst(item.get("arg", ""))
        label = item.get("label", "")
        if t == "build":
            cmd = "cd '%s' && PATH=/run/wrappers/bin:$PATH ./build.sh '%s'" % (FLAKE, arg)
            self.open_window(RunWindow(label, cmd, needs_root=True))
        elif t == "shell":
            self.open_window(RunWindow(label, arg, needs_root=("sudo" in arg)))
        elif t == "log":
            self.open_window(LogWindow())
        elif t == "open":
            QDesktopServices.openUrl(QUrl.fromLocalFile(arg))

    def open_window(self, w):
        self.windows.append(w)
        w.finished.connect(lambda _=0, w=w: self.windows.remove(w) if w in self.windows else None)
        w.show()
        w.raise_()
        w.activateWindow()

    def about(self):
        QMessageBox.information(
            None, "NixOS Control Panel",
            "NixOS Control Panel\n\nTray + dark Qt UI for rebuilding and managing "
            "this Surface NixOS host.\nMenu is data-driven from %s.\nFlake: %s" % (CONF, FLAKE),
        )


def main():
    from PySide6.QtCore import QLockFile, QDir
    lock = QLockFile(QDir.tempPath() + "/nixos-cp-%d.lock" % os.getuid())
    lock.setStaleLockTime(0)
    if not lock.tryLock(50):
        return 0  # another instance already owns the tray
    app = QApplication([])
    app._lock = lock  # keep the lock alive for the app's lifetime
    app.setApplicationName("NixOS Control Panel")
    # Stable identity so the StatusNotifierItem id is constant ("nixos-cp")
    # across restarts — required for Plasma's "always shown" pin to stick.
    app.setDesktopFileName("nixos-cp")
    app.setApplicationDisplayName("NixOS Control Panel")
    app.setQuitOnLastWindowClosed(False)
    apply_dark(app)
    if not QSystemTrayIcon.isSystemTrayAvailable():
        QMessageBox.critical(None, "NixOS Control Panel", "No system tray available.")
        return 1
    Tray(app)
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
