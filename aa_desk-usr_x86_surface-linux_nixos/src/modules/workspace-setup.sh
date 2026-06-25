#!/usr/bin/env bash
# workspace-setup.sh — arrange apps across KDE virtual desktops
# Called from nixos-systray "Setup Workspace" menu item.
# Customize freely — this file is not managed by Nix.
#
# Requires: kstart (from kdebase), wmctrl (optional), xdotool (optional)
# Desktop numbering: 1-indexed in kstart, 0-indexed in wmctrl

echo "Setting up workspace..."

# ── Desktop 1: Terminal + Editor ─────────────────────────────────────────────
kstart --desktop 1 konsole &

# ── Desktop 2: Browsers ──────────────────────────────────────────────────────
kstart --desktop 2 brave &
kstart --desktop 2 qutebrowser \
  "localhost:8000" \
  "https://cloud.diegonmarcos.com" \
  "https://proxy.diegonmarcos.com" \
  "https://claude.ai/new#settings/usage" &

# ── Desktop 3: Files + Waydroid ──────────────────────────────────────────────
kstart --desktop 3 dolphin &
sleep 2
WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 waydroid show-full-ui &

# ── Desktop 4: Communication ─────────────────────────────────────────────────
# kstart --desktop 4 thunderbird &

echo "Workspace setup complete. Windows may take a moment to appear."
