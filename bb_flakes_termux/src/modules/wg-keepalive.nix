{ config, pkgs, lib, ... }:

# WireGuard tunnel keepalive for Termux on Android.
#
# Why this exists:
#   The Android WireGuard app is the only process that holds the wg0 tunnel
#   on rootless Android. Doze / App-Standby / aggressive battery management
#   freezes the WG userspace process after the screen has been off for a
#   while, which pauses the 25 s in-app keepalive timer. Once the timer
#   doesn't fire for >180 s, the kernel-side peer state on the hub
#   (gcp-proxy 10.0.0.1) ages out — leaving handshakes "23h stale" in
#   `wg show` even though the in-app config still says "every 25 seconds".
#   The keepalive setting is a request to the WG userspace process, which
#   Android pauses; it is NOT a kernel timer.
#
# What this does:
#   - Installs ~/.local/bin/wg-keepalive that pings the WG hub and, on
#     failure, sends a stop+start Intent broadcast to the Android WG app.
#   - Registers the script with Android's `JobScheduler` (via Termux:API's
#     `termux-job-scheduler` binary) at home-manager activation time. The
#     job runs every 15 min (Android's minimum), survives reboot
#     (--persisted), and only fires when there's connectivity (--network
#     any). JobScheduler is the ONLY Android-supported way to wake an app
#     under Doze.
#
# Prerequisite (one-time, manual on the phone):
#   The Termux:API APK must be installed. The `termux-job-scheduler`
#   binary is the userspace side of that APK's Android API surface. If
#   the APK isn't installed, the activation hook logs a notice and
#   skips registration — it does NOT fail the home-manager switch.
#
# Removal: drop this module from flake.nix `imports` and run
#   termux-job-scheduler --cancel --job-id 901
# manually before re-running `build.sh switch`.

let
  wgKeepalive = pkgs.writeShellScript "wg-keepalive" ''
    set -u
    PATH="$HOME/.nix-profile/bin:/data/data/com.termux.nix/files/usr/bin:$PATH"
    LOG="$HOME/.cache/wg-keepalive.log"
    mkdir -p "$(dirname "$LOG")"
    ts() { date -u +%FT%TZ; }

    HUB="''${WG_KEEPALIVE_HUB:-10.0.0.1}"

    # 1) Wake the WireGuard Android app (idempotent — no toggle if already up)
    if command -v am >/dev/null 2>&1; then
      am start -n com.wireguard.android/.activity.MainActivity \
        >/dev/null 2>&1 || true
    fi

    # 2) Force a handshake by hitting the hub through wg0
    if ping -c 1 -W 4 "$HUB" >/dev/null 2>&1; then
      echo "$(ts) wg-keepalive: hub $HUB reachable" >> "$LOG"
      exit 0
    fi

    echo "$(ts) wg-keepalive: hub $HUB UNREACHABLE — toggling tunnel" >> "$LOG"

    # 3) Send the tunnel toggle Intent the WireGuard Android app exposes.
    # Reference: com.wireguard.android.action.SET_TUNNEL_DOWN/UP
    if command -v am >/dev/null 2>&1; then
      am broadcast -a com.wireguard.android.action.SET_TUNNEL_DOWN \
        -n com.wireguard.android/.model.TunnelManager$IntentReceiver \
        --es tunnel wg0 >/dev/null 2>&1 || true
      sleep 2
      am broadcast -a com.wireguard.android.action.SET_TUNNEL_UP \
        -n com.wireguard.android/.model.TunnelManager$IntentReceiver \
        --es tunnel wg0 >/dev/null 2>&1 || true
    fi

    # 4) Re-test after toggle (best effort, log only)
    sleep 3
    if ping -c 1 -W 4 "$HUB" >/dev/null 2>&1; then
      echo "$(ts) wg-keepalive: recovered after toggle" >> "$LOG"
    else
      echo "$(ts) wg-keepalive: still down after toggle" >> "$LOG"
    fi
  '';

in {
  home.file.".local/bin/wg-keepalive" = {
    source = wgKeepalive;
    executable = true;
  };

  # Register with Android JobScheduler at activation. Idempotent: re-running
  # with the same --job-id replaces the previous schedule.
  # Period 15 min = Android's enforced minimum for JobScheduler.
  home.activation.registerWgKeepalive =
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      JS="/data/data/com.termux.nix/files/usr/bin/termux-job-scheduler"
      if [ -x "$JS" ]; then
        $DRY_RUN_CMD "$JS" \
          --job-id 901 \
          --period-ms 900000 \
          --persisted true \
          --network any \
          --script "$HOME/.local/bin/wg-keepalive" \
          >/dev/null 2>&1 \
          && echo "[wg-keepalive] JobScheduler job 901 registered (15 min period)" \
          || echo "[wg-keepalive] JobScheduler register failed (Termux:API APK installed?)"
      else
        echo "[wg-keepalive] termux-job-scheduler missing — install Termux:API APK to enable"
      fi
    '';
}
