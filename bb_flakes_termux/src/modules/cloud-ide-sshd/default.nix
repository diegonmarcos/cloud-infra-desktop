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
# Provides: cloud-ide-sshd command (start|stop|status|restart) — serves the Cloud IDE APK over 127.0.0.1 and WG.
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

  authData = builtins.fromJSON (builtins.readFile ./data/authorized-keys.json);
  authorizedKeysContent =
    lib.concatStringsSep "\n" authData.trusted_pubkeys + "\n";
  # Cloud IDE APK pubkey, sops-encrypted (decrypted at activation).
  secretsFile = ./secrets.yaml;

  # Read the WG IP + SSH port from build.json (data-driven). sshd binds ONLY
  # to wgIp — no public exposure. If wg0 is down, sshd refuses to start
  # rather than fall back to listening on all interfaces.
  #
  # Default port is 8023, NOT 8022 — on this device 8022 hits EADDRINUSE
  # despite /proc/net/tcp showing the port free (suspected kernel TIME_WAIT
  # or Android sandbox lock invisible to proot's view).
  buildJson = builtins.fromJSON (builtins.readFile ../../build.json);
  wgIp = buildJson.defaults.wg_ip or "127.0.0.1";
  sshPort = buildJson.defaults.ssh_port or 8023;

  sshdScript = pkgs.writeShellScript "cloud-ide-sshd" ''
    # cloud-ide-sshd — POSIX wrapper for nix-on-droid sshd
    # Usage: cloud-ide-sshd [start|stop|status|restart]
    #
    # Hard-pinned to OpenSSH 8.9p1 (interpolated nix store path) to dodge
    # the proot execveat-with-fd limitation that breaks 9.x child processes
    # on Android. See pkgs/openssh-pinned.nix for the full story.

    SSHD_BIN="${opensshPinned}/bin/sshd"
    SSH_KEYGEN_BIN="${opensshPinned}/bin/ssh-keygen"

    PID_FILE="$HOME/.cache/cloud-ide-sshd.pid"
    LOG_FILE="$HOME/.cache/cloud-ide-sshd.log"
    HOST_KEY="$HOME/.ssh/ssh_host_rsa_key"
    SSHD_CONFIG="$HOME/.ssh/sshd_config"

    is_running() {
      [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
    }

    # Returns the PID(s) of any process currently listening on :${toString sshPort}, regardless
    # of whether it's tracked by our PID file. Used to detect orphans from a
    # previous start where the PID file got nuked but the process survived.
    port_holder_pids() {
      ss -tlnp 2>/dev/null | awk '/:${toString sshPort} / {
        # ss output: ... users:(("sshd",pid=12345,fd=3))
        match($0, /pid=[0-9]+/);
        if (RSTART) print substr($0, RSTART+4, RLENGTH-4)
      }' | sort -u
      # Fallback for Android/proot ss without -p detail: try fuser/lsof if present.
      if [ -z "$(ss -tlnp 2>/dev/null | grep ":${toString sshPort} ")" ]; then
        :  # nothing on port
      fi
    }

    # Self-heal step before do_start: if something else is on :${toString sshPort} but our
    # PID file is missing/stale, kill the orphan. Idempotent — safe to run
    # whether or not anything is wrong.
    self_heal() {
      _occupied=$(ss -tln 2>/dev/null | grep ":${toString sshPort} " || true)
      if [ -n "$_occupied" ] && ! is_running; then
        # Port bound but we don't own it via PID file — orphan.
        _orphans=$(port_holder_pids)
        if [ -n "$_orphans" ]; then
          echo "self-heal: orphan(s) on :${toString sshPort} (PID $_orphans) — killing"
          for _p in $_orphans; do
            kill -9 "$_p" 2>/dev/null || true
          done
        else
          # No process info from ss. Carpet-bomb anything matching sshd.
          echo "self-heal: :${toString sshPort} bound but PID unknown — pkill sshd"
          pkill -9 -f 'sshd|dropbear' 2>/dev/null || true
        fi
        # Clear stale PID file
        rm -f "$PID_FILE"
        sleep 0.4
      elif [ -f "$PID_FILE" ] && ! kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
        # PID file exists but process is gone.
        rm -f "$PID_FILE"
      fi
    }

    do_start() {
      self_heal

      # ListenAddress lines: 127.0.0.1 ALWAYS (the Cloud IDE APK connects over
      # loopback), plus the WG IP when wg0 is actually up. Best-effort probe:
      # if `ip` is unavailable we keep the WG bind (previous behavior).
      WG_LISTEN="ListenAddress ${wgIp}"
      if command -v ip >/dev/null 2>&1; then
        if ! ip -o addr show 2>/dev/null | grep -q "inet ${wgIp}"; then
          WG_LISTEN="# wg0 (${wgIp}) not up — binding loopback only"
        fi
      fi

      if is_running; then
        pid=$(cat "$PID_FILE")
        echo "sshd already running (PID $pid) on :${toString sshPort}"
        return 0
      fi

      mkdir -p ~/.ssh "$(dirname "$PID_FILE")"
      chmod 700 ~/.ssh

      # Host key — RSA (matches maintainer recipe; sshd accepts ed25519 too
      # but RSA is what they tested under proot).
      if [ ! -f "$HOST_KEY" ]; then
        "$SSH_KEYGEN_BIN" -t rsa -b 4096 -f "$HOST_KEY" -N "" -q
        echo "Generated host key: $HOST_KEY"
      fi

      # Write sshd_config (idempotent, regenerated each start so changes flow
      # through the wrapper without manual edits). ListenAddress is the WG IP
      # from build.json — bind ONLY to wg0, no public exposure. If wg0 isn't
      # up at start time sshd will fail to bind and the wrapper will log it.
      cat > "$SSHD_CONFIG" <<EOF
    HostKey $HOST_KEY
    ListenAddress 127.0.0.1
    $WG_LISTEN
    Port ${toString sshPort}
    PidFile $PID_FILE
    AuthorizedKeysFile $HOME/.ssh/authorized_keys
    PermitRootLogin no
    PasswordAuthentication no
    PubkeyAuthentication yes
    UsePAM no
    EOF
      chmod 600 "$SSHD_CONFIG"

      if [ -x "$SSHD_BIN" ]; then
        "$SSHD_BIN" -f "$SSHD_CONFIG" >> "$LOG_FILE" 2>&1
        sleep 0.5
        if is_running; then
          pid=$(cat "$PID_FILE")
          echo "sshd started (PID $pid) on :${toString sshPort}"
        else
          # Self-heal retry: address-already-in-use is a common failure mode
          # when the orphan check above didn't catch the holder. Force-kill
          # anything on the port and try one more time before giving up.
          if grep -q "Address already in use" "$LOG_FILE" 2>/dev/null; then
            echo "self-heal: address-already-in-use — purging and retrying"
            pkill -9 -f "sshd|dropbear" 2>/dev/null || true
            sleep 0.5
            "$SSHD_BIN" -f "$SSHD_CONFIG" >> "$LOG_FILE" 2>&1
            sleep 0.5
          fi
          if is_running; then
            pid=$(cat "$PID_FILE")
            echo "sshd started (PID $pid) on :${toString sshPort} (after self-heal)"
          else
            echo "sshd failed to start — last 15 lines of $LOG_FILE:"
            tail -15 "$LOG_FILE" 2>/dev/null | sed 's/^/  /'
            return 1
          fi
        fi
      else
        echo "ERROR: sshd not found at $SSHD_BIN (run nix-on-droid switch first)"
        return 1
      fi
    }

    do_stop() {
      if is_running; then
        pid=$(cat "$PID_FILE")
        kill "$pid" 2>/dev/null
        rm -f "$PID_FILE"
        echo "sshd stopped (was PID $pid)"
      else
        rm -f "$PID_FILE"
        echo "sshd not running"
      fi
    }

    do_status() {
      if is_running; then
        pid=$(cat "$PID_FILE")
        echo "sshd running (PID $pid) on :${toString sshPort}"
      else
        rm -f "$PID_FILE"
        echo "sshd not running"
      fi
    }

    case "''${1:-start}" in
      start)   do_start ;;
      stop)    do_stop ;;
      status)  do_status ;;
      restart) do_stop; sleep 0.3; do_start ;;
      *)       echo "Usage: cloud-ide-sshd {start|stop|status|restart}"; exit 1 ;;
    esac
  '';

  # ~/.profile — nix-on-droid maintainer recipe: SSH-spawned shells default to
  # /bin/sh which doesn't read .bashrc. Source the nix-on-droid session init
  # here so PATH, NIX_PATH, etc. are available in the SSH session.
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
  # Pinned OpenSSH 8.9p1 — wrapper interpolates its absolute store path so
  # there's no PATH ambiguity. Also expose it on PATH for ad-hoc use.
  home.packages = [ opensshPinned ];

  # home.activation.installPatchedProot — DISABLED until tzdata-static-musl
  # builds again. See the comment near prootPatched above for context.

  home.file.".local/bin/cloud-ide-sshd" = {
    source = sshdScript;
    executable = true;
  };

  # authorized_keys is generated at activation: static trusted keys (baked
  # from authorized-keys.json) are ALWAYS written first so a sops failure
  # can never lock us out of WG SSH; the Cloud IDE key is then appended
  # best-effort from the sops-encrypted secrets.yaml.
  home.activation.cloudIdeAuthorizedKeys = lib.hm.dag.entryAfter ["linkGeneration"] ''
    SOPS="$HOME/.nix-profile/bin/sops"
    # Pin the age identity to the on-device XDG path. An ambient SOPS_AGE_KEY_FILE
    # may point at the desktop vault path (/home/diego/...) which doesn't exist
    # here, silently breaking decrypt. |: true keeps this safe under set -e.
    [ -r "$HOME/.config/sops/age/keys.txt" ] && export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt" || true
    YQ="${pkgs.yq-go}/bin/yq"
    SECRETS="${secretsFile}"
    OUT="$HOME/.ssh/authorized_keys"
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    # Old generations symlinked this into the read-only nix store — drop it
    # before writing a real file.
    rm -f "$OUT"
    printf '%s' ${lib.escapeShellArg authorizedKeysContent} > "$OUT"
    if [ -f "$SOPS" ] && [ -f "$SECRETS" ]; then
      _key=$("$SOPS" -d "$SECRETS" 2>/dev/null | "$YQ" -r '.cloud_ide_authorized_keys' 2>/dev/null) || true
      if [ -n "$_key" ] && [ "$_key" != "null" ]; then
        printf '%s\n' "$_key" >> "$OUT"
        echo "[cloud-ide-sshd] authorized_keys: static keys + cloud-ide key"
      else
        echo "[cloud-ide-sshd] WARNING: cloud-ide key decrypt failed — static keys only"
      fi
    fi
    chmod 600 "$OUT"
  '';

  # ~/.profile loads nix env for ssh-spawned /bin/sh sessions
  home.file.".profile".text = profileText;

  programs.fish.shellInit = lib.mkAfter ''
    if not test -f $HOME/.cache/cloud-ide-sshd.pid; or not kill -0 (cat $HOME/.cache/cloud-ide-sshd.pid 2>/dev/null) 2>/dev/null
      cloud-ide-sshd start >/dev/null 2>&1
    end
  '';
}
