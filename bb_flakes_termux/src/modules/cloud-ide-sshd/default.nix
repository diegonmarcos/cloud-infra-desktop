# Termux SSHD — declarative SSH daemon on port ${toString sshPort}, openssh-based.
#
# Recipe taken from the nix-on-droid maintainers (issue #32):
# https://github.com/nix-community/nix-on-droid/issues/32
#
# Why these specifics:
#   1. Run sshd via $HOME/.nix-profile/bin/sshd (the user-profile path),
#      NOT /nix/store/.../bin/sshd. The profile path is what nix-on-droid's
#      proot wrapper resolves correctly for privilege-separation re-exec.
#   2. Pass `-f <absolute>/sshd_config`. A real config file (with HostKey
#      and Port) works where inline `-o HostKey=...` flags fail under proot.
#   3. Connecting shells get `/bin/sh` which does NOT read `.bashrc` —
#      put nix env loading in `~/.profile` so PATH and tooling resolve.
#
# Provides: cloud-ide-sshd command (start|stop|status|restart|ensure) — serves the Cloud IDE APK over 127.0.0.1 and WG. Never public.
# Trusted pubkeys: data-driven from data/authorized-keys.json.
{ config, pkgs, lib, ... }:

let
  # Use the stock openssh from the default closure. The 8.9p1 pin was a
  # workaround for proot's execveat-with-fd issue, but the rescue path
  # (sh -c command) doesn't trigger that code path on stock 9.x — and
  # building 8.9p1 from source on aarch64 phone (~10min compile) is too
  # slow on a swap-thrashing device. Pin source kept in pkgs/openssh-pinned.nix
  # for emergency wire-up if a future kernel/proot combo needs it.
  opensshPinned = pkgs.openssh;

  # NOTE: prootPatched (pkgs/proot-termux-patched/) is currently disabled.
  # Building it natively on aarch64 pulls pkgs.pkgsStatic.talloc, which drags
  # in python3-static + tzdata-static — and tzdata-static fails to build on
  # aarch64-musl (Makefile:815 to2050new.tzs error). Until either:
  #   (a) nixpkgs fixes tzdata-static-aarch64-musl, OR
  #   (b) we build the patched proot via cross-compile from x86_64 cache,
  # we rely on OpenSSH 8.9p1 pin (see opensshPinned) which mostly avoids
  # the proot execveat-with-fd path. The patch is still on disk in
  # pkgs/proot-termux-patched/ ready to wire up when one of those lands.

  authData = builtins.fromJSON (builtins.readFile ../data/authorized-keys.json);
  authorizedKeysContent =
    lib.concatStringsSep "\n" authData.trusted_pubkeys + "\n";
  # Cloud IDE APK pubkey, sops-encrypted (decrypted at activation).
  secretsFile = ./secrets.yaml;

  # Read the WG IP + SSH port from build.json (data-driven). sshd answers on
  # wgIp and 127.0.0.1 and NOTHING ELSE — a public bind is forbidden, and the
  # wrapper has no code path that can produce one.
  #
  # This comment used to claim sshd bound wgIp alone and refused to start when
  # wg0 was down. Neither was true: loopback was always bound, and a wg0-down
  # start silently produced a loopback-only daemon that never re-bound, because
  # the fish shellInit below only ever started sshd when it was fully dead.
  # The phone then answered ICMP on the mesh while :ssh_port returned RST.
  # cloud-ide-sshd `ensure` is the fix; see cloud-ide-sshd.sh.
  #
  # Fallback port is 8024, matching build.json defaults.ssh_port and
  # build.sh — the three sources used to disagree (8023 here) so a missing
  # build.json made nix bind a port the probe never checked (2026-08-08).
  # (8022 hits EADDRINUSE on this device
  # despite /proc/net/tcp showing the port free (suspected kernel TIME_WAIT
  # or Android sandbox lock invisible to proot's view).
  # ../../build.json = src/build.json (vendored by build.sh). Must NOT reach
  # outside src/ — a path: flake escaping src/ copies the whole repo (proot dies).
  buildJson = builtins.fromJSON (builtins.readFile ../../build.json);
  wgIp = buildJson.defaults.wg_ip or "127.0.0.1";

  # One identity, several mesh addresses (v4 via one hub, v4-public and v6 via
  # another). Which of them the interface actually holds depends on the active
  # WireGuard profile, and the phone gained four of those on 2026-08-20. Binding
  # wgIp alone meant selecting a v6 profile left sshd loopback-only — up, and
  # unreachable from every peer. sshd warns about an address it cannot bind and
  # carries on, so listing all of them is safe and profile-independent.
  wgIps = buildJson.defaults.wg_ips or [ wgIp ];
  sshPort = buildJson.defaults.ssh_port or 8024;

  # Runtime JSON (fire-rule 4 + 6): wg_ip/ssh_port still originate from
  # build.json above at Nix eval time; only their *consumption* moved from
  # Nix-eval-time interpolation into a runtime jq read in cloud-ide-sshd.sh.
  # Deployed to ${XDG_CONFIG_HOME:-$HOME/.config}/cloud-data/cloud-ide-sshd.json
  sshdRuntimeJson = builtins.toJSON {
    wg_ip = wgIp;
    wg_ips = wgIps;
    ssh_port = sshPort;
  };

  sshdPkg = pkgs.writeShellApplication {
    name = "cloud-ide-sshd";
    runtimeInputs = [ pkgs.jq pkgs.iproute2 pkgs.gawk pkgs.gnugrep pkgs.gnused pkgs.procps pkgs.coreutils ];
    runtimeEnv = {
      CLOUD_IDE_SSHD_BIN = "${opensshPinned}/bin/sshd";
      CLOUD_IDE_SSH_KEYGEN_BIN = "${opensshPinned}/bin/ssh-keygen";
    };
    text = builtins.readFile ./cloud-ide-sshd.sh;
  };
  profileText = ''
    # Generated by sshd.nix — required for SSH sessions on nix-on-droid.
    # Without this, /bin/sh sessions have no nix tooling on PATH.
    if [ -r "$HOME/.nix-profile/etc/profile.d/nix-on-droid-session-init.sh" ]; then
      . "$HOME/.nix-profile/etc/profile.d/nix-on-droid-session-init.sh"
    elif [ -r "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
      . "$HOME/.nix-profile/etc/profile.d/nix.sh"
    fi
    [ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"
  '';
in
{
  # stock pkgs.openssh (8.9p1 pin abandoned) — wrapper interpolates its absolute store path so
  # there's no PATH ambiguity. Also expose it on PATH for ad-hoc use.
  home.packages = [ opensshPinned ];

  # home.activation.installPatchedProot — DISABLED until tzdata-static-musl
  # builds again. See the comment near prootPatched above for context.

  # ── Runtime JSON deploy (Home Manager: xdg.configFile) ─────────────────
  xdg.configFile."cloud-data/cloud-ide-sshd.json".text = sshdRuntimeJson;

  home.file.".local/bin/cloud-ide-sshd".source = "${sshdPkg}/bin/cloud-ide-sshd";

  # authorized_keys is generated at activation: static trusted keys (baked
  # from authorized-keys.json) are ALWAYS written first so a sops failure
  # can never lock us out of WG SSH; the Cloud IDE key is then appended
  # best-effort from the sops-encrypted secrets.yaml.
  # body in ./authorized-keys-render.sh (no-inline-scripts decree 2026-08-08)
  home.activation.cloudIdeAuthorizedKeys = lib.hm.dag.entryAfter ["linkGeneration"] ''
    YQ_BIN="${pkgs.yq-go}/bin/yq" \
    SECRETS="${secretsFile}" \
    STATIC_KEYS_FILE="${pkgs.writeText "static-authorized-keys" authorizedKeysContent}" \
    ${pkgs.bash}/bin/bash ${./authorized-keys-render.sh} || true
  '';

  # ~/.profile loads nix env for ssh-spawned /bin/sh sessions
  home.file.".profile".text = profileText;

  # `ensure`, not `start`: start only fires when sshd is fully dead, which
  # cannot recover a daemon that is alive but bound to loopback alone. ensure
  # also rebinds that case once wg0 is up. Cheap enough to run per shell — it
  # is two greps when everything is already correct.
  programs.fish.shellInit = lib.mkAfter ''
    cloud-ide-sshd ensure >/dev/null 2>&1
  '';

  # Boot hook. Until this existed, EVERY path that started sshd needed a human
  # already at the phone: fish's shellInit (someone opens a terminal) or the
  # tail of build.sh (someone runs a switch). So after a reboot — or after
  # Android reaped the proot — the device was unreachable over wg0 until it was
  # picked up and unlocked, which is exactly when remote access is least
  # available and most wanted. 2026-08-20: lost the phone mid-switch for hours
  # for precisely this reason.
  #
  # Termux:Boot runs everything in ~/.termux/boot at device boot. The addon is a
  # separate APK and may not be installed; writing the script anyway is free and
  # makes the machine correct the moment it is. Nothing else reads this path.
  #
  # `ensure`, not `start`: at boot wg0 usually is not up yet, so the first
  # attempt binds loopback only. ensure is what notices that and rebinds, and
  # the retry loop covers the tunnel arriving a few seconds after us. Losing the
  # race here is normal, not exceptional — treat it as the expected case.
  home.file.".termux/boot/10-cloud-ide-sshd.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env sh
      # Wait for wg0 to carry the address before giving up on it. 12 x 5s = 1min.
      i=0
      while [ "$i" -lt 12 ]; do
        ${config.home.homeDirectory}/.local/bin/cloud-ide-sshd ensure >/dev/null 2>&1
        i=$((i + 1))
        sleep 5
      done
    '';
  };
}
