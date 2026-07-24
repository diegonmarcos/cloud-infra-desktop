{
  description = "Nix-on-Droid Termux configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    nixpkgs-new.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    nix-on-droid = {
      # release-24.05 hasn't moved since 2024-07-07 (effectively abandoned) —
      # its fixed-output-derivation binary pins (e.g. proot-termux-static)
      # decayed out of the substituter cache, breaking CI with
      # "path ... does not exist and cannot be created" (2026-07-03).
      # master is actively maintained and has current, fetchable pins.
      url = "github:nix-community/nix-on-droid/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-24.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-new, nixpkgs-unstable, nix-on-droid, home-manager }:
    let
      pkgsNew = import nixpkgs-new { system = "aarch64-linux"; };
      pkgsUnstable = import nixpkgs-unstable { system = "aarch64-linux"; };

      # Node identity for DTK webhooks (ntfy topic = dtk-cmd-<dtkNode>).
      # Source of truth: build.json -> defaults.dtk_node. Termux can't
      # sethostname() on Android (no root) so `hostname -s` returns
      # "localhost" — useless as a topic key. This makes the identity
      # declarative + data-driven instead.
      buildJson = builtins.fromJSON (builtins.readFile ../build.json);
      dtkNode = buildJson.defaults.dtk_node or "unset";

      # claude-api-superset endpoints (WG-only). Data-driven, not inlined in the
      # wrapper script — see modules/data/claude-superset.json.
      claudeSuperset = builtins.fromJSON (builtins.readFile ./modules/data/claude-superset.json);

      # Build termux-am from nix-on-droid source (provides `am` for Android intents)
      termux-am = (import nixpkgs { system = "aarch64-linux"; }).callPackage
        "${nix-on-droid}/pkgs/android-integration/termux-am.nix" {};

      # Shared aliases for all shells
      sharedAliases = {
        ll = "ls -alh";
        ".." = "cd ..";
        conf = "nano ~/git/unix/bb_flakes_termux/src/flake.nix";
        up = "~/git/unix/bb_flakes_termux/build.sh";
        dtk = "sh ~/git/tools/dtk.sh";
      };
    in
    {
      nixOnDroidConfigurations.default = nix-on-droid.lib.nixOnDroidConfiguration {
        pkgs = import nixpkgs { system = "aarch64-linux"; config.allowUnfree = true; };
        modules = [
          ({ config, lib, pkgs, ... }: {
            system.stateVersion = "24.05";
            environment.etcBackupExtension = ".bak";

            # proot resolver must match the vault termux WireGuard profile DNS
            # (10.0.0.1 Hickory wg0, 1.1.1.1 fallback — see
            # vault/A0_keys/providers/wireguard/termux{,-public}/config).
            # nix-on-droid's default resolv.conf is 1.1.1.1/8.8.8.8
            # — that bypasses Hickory, so *.diegonmarcos.com resolves to the
            # PUBLIC edge instead of the wg IP and WG-only services (MCP, etc.)
            # 403. Hickory-first = wg-IP resolution.
            # NOTE: 10.1.0.1 removed 2026-07-02 — NO DNS service exists on the
            # wg-public hub (oci-analytics has no :53 listener and none is
            # declared); a dead resolver in the list only adds per-lookup
            # timeouts (broke mail-client resolution on Android).
            environment.etc."resolv.conf".text = lib.mkForce ''
              nameserver 10.0.0.1
              nameserver 1.1.1.1
            '';

            nix.extraOptions = ''
              experimental-features = nix-command flakes
              # Phone has 7GB RAM. max-jobs=2 × cores=4 = up to 8 parallel
              # compile jobs which OOM-thrashed during openssh-pinned + ncurses
              # static builds (ate 4.6GB swap). Cap at 1 job × 2 cores so big
              # native compiles finish without swap death.
              max-jobs = 1
              cores = 2
              auto-optimise-store = false
              min-free = 1073741824
              min-free-check-interval = 30
              keep-derivations = false
            '';

            time.timeZone = "Europe/Athens";

            # Global PATH and SHELL for Bash/Zsh/Fish
            environment.sessionVariables = {
              SHELL = "${pkgs.bash}/bin/bash";
              PATH = "$HOME/.node_modules/node_modules/.bin:$HOME/.local/bin:$HOME/.nix-profile/bin:/run/current-system/sw/bin:$PATH";
              NODE_PATH = "$HOME/.node_modules/node_modules";
              # DTK webhooks node identity (Android can't sethostname; see flake.nix `dtkNode`)
              DTK_NODE_NAME = dtkNode;
              # Global memory allocator fix for Android - propagates to ALL child processes
              LD_PRELOAD = "${pkgs.mimalloc}/lib/libmimalloc.so";
              MIMALLOC_PAGE_RESET = "0";
              MIMALLOC_LARGE_OS_PAGES = "0";
              MALLOC_ARENA_MAX = "2";
              # Terraform: shared plugin cache (avoid 100MB+ provider binaries per project)
              TF_PLUGIN_CACHE_DIR = "$HOME/.terraform.d/plugin-cache";
            };

            user.shell = "${pkgs.fish}/bin/fish";

            environment.packages = with pkgs; [
              # Nerd Fonts (for terminal icons)
              (nerdfonts.override { fonts = [ "JetBrainsMono" "FiraCode" ]; })

              # Core Tools
              nano
              gnused
              gnugrep
              git
              curl
              wget
              # vim — provided by programs.vim in common.nix
              coreutils
              openssh
              strace
              unison
              rclone
              procps
              gawk
              findutils
              fzf
              atuin     # shell history search (arrow-up, Ctrl+R)
              tealdeer  # tldr — simplified man pages
              browsh    # terminal web browser (headless Firefox rendering)
              iproute2  # Provides 'ip' command for network interface management

              # Rust toolchain (unstable for edition2024 support, 1.85+)
              pkgsUnstable.rustc
              pkgsUnstable.cargo

              # Dependencies that stop npm from panicking
              python3
              gnumake
              gcc

              # Memory allocator fix for Android
              jemalloc
              mimalloc

              # JSON/YAML processing
              jq

              # Secrets & crypto
              openssl
              gnupg
              sops
              age
              yq-go

              # Cloud CLIs
              gh
              flarectl
              cloudflared
              google-cloud-sdk
              oci-cli
              awscli2

              # Infrastructure as Code
              terraform
              # wrangler: installed via npm global in node-bins.nix (needs 3.60+ for [observability])

              # VPN & networking
              # NOTE: wireguard-tools (wg CLI) requires root — useless on Android.
              # The WireGuard Android app manages the tunnel via VPN API instead.
              # We provide a wrapper that warns and redirects to `connect`.
              (writeShellScriptBin "wg" ''
                echo ""
                echo "  THIS IS A ROOTLESS ANDROID!"
                echo "  You should NEVER try to check WireGuard connection using wg!"
                echo ""
                echo "  Use the 'connect' command instead:"
                echo "    connect status       — unified dashboard"
                echo "    connect flex-status  — OCI VM status"
                echo "    connect mount-all-vm — mount VMs via SSHFS"
                echo "    connect logs | jq .mesh — mesh JSON data"
                echo ""
              '')
              # inetutils → telnet, ftp, rsh, rlogin, hostname, dnsdomainname, etc.
              # Demoted with lowPrio so iputils wins the ping/ping6/traceroute6 file
              # collisions. inetutils' ping uses SOCK_RAW + setuid() (bionic libc
              # has no setuid impl → "Function not implemented" on Termux).
              (lib.lowPrio inetutils)
              # iputils → ping (SOCK_DGRAM via IPPROTO_ICMP, no raw sockets, no
              # setuid), ping6, tracepath, traceroute6, arping, clockdiff. The
              # SOCK_DGRAM path works on Termux/Android as long as the user's
              # gid is in /proc/sys/net/ipv4/ping_group_range (Android default
              # range is wide-open). This is the same kernel path Android system
              # apps use for ping.
              iputils
              termux-am

              # getconf — POSIX sysconf utility needed by wrangler (Cloudflare Workers CLI)
              # Not included in Termux/nix-on-droid by default (normally from glibc)
              (writeShellScriptBin "getconf" ''
                case "$1" in
                  LONG_BIT)       echo 64 ;;
                  PAGE_SIZE)      echo 4096 ;;
                  _NPROCESSORS_ONLN) nproc 2>/dev/null || echo 1 ;;
                  *)              echo "" ;;
                esac
              '')

              # Node 22 (from nixos-24.11 for Vite 7 compat: requires >=22.12)
              pkgsNew.nodejs_22

              # claude family — every wrapper has the SAME failure-mode safety:
              # try native nix-store binary first, on ANY failure (missing,
              # SIGSEGV, exit≠0 from libc init, etc.) fall through to
              # claude-rescue's 12-fallback chain. This is intentional — the
              # phone is unreliable enough that a single-path wrapper is
              # guaranteed to fail eventually, and the user shouldn't have to
              # remember which command to run when it does.
              #
              # NOTE: NODE_OPTIONS is dropped — claude is a compiled native
              # binary, not Node.js. MALLOC_ARENA_MAX still applies (libc).

              (writeShellScriptBin "claude-termux" ''
                # Conservative malloc tuning for phone RAM.
                export MALLOC_ARENA_MAX=2

                # Sweep stale orphans before launching (see claude-malloc).
                command -v claude-orphan-sweep >/dev/null 2>&1 \
                  && claude-orphan-sweep >/dev/null 2>&1 || true

                _bin="$HOME/.nix-profile/bin/claude"
                if [ -x "$_bin" ]; then
                  # Same supervision as claude-malloc: setpriv --pdeathsig,
                  # synchronous foreground, NO tini (see claude-malloc for why
                  # tini is unusable under proot).
                  ${pkgs.util-linux}/bin/setpriv --pdeathsig TERM -- "$_bin" "$@"
                  _rc=$?
                  # exit codes 0–125 are user-meaningful. 126/127 = exec
                  # failure (interpreter/permission). 137/139 = SIGKILL/SEGV.
                  case "$_rc" in
                    126|127|137|139) ;;   # fall through to rescue
                    *) exit "$_rc" ;;
                  esac
                fi
                echo "[claude-termux] native exec failed — trying rescue chain..." >&2
                exec sh "$HOME/git/tools/5-infos/claude-rescue/claude-rescue.sh" "$@"
              '')

              (writeShellScriptBin "claude-malloc" ''
                # Max-isolation: tight malloc arenas + dedicated TMPDIR.
                export MALLOC_ARENA_MAX=2
                export CLAUDE_TMP="$HOME/tmp/claude"
                mkdir -p "$CLAUDE_TMP"
                export TMPDIR="$CLAUDE_TMP"

                # Sweep stale orphans from previous Android-OOM-killed sessions
                # before launching, so node/MCP zombies don't pile up over time.
                command -v claude-orphan-sweep >/dev/null 2>&1 \
                  && claude-orphan-sweep >/dev/null 2>&1 || true

                _bin="$HOME/.nix-profile/bin/claude"
                if [ -x "$_bin" ]; then
                  # Process supervision (countermeasure to lmkd / parent-shell exits):
                  #   setpriv --pdeathsig TERM : if THIS wrapper dies (any signal
                  #                              except SIGKILL), the kernel SIGTERMs
                  #                              claude directly. Claude runs in the
                  #                              foreground terminal pgroup (no -g, no
                  #                              &, no trap), so the interactive TUI
                  #                              keeps the controlling terminal —
                  #                              Ctrl-C, job control, etc.
                  #
                  # tini is DELIBERATELY NOT USED here. nix-on-droid runs the whole
                  # rootfs under proot, whose ptrace/seccomp layer returns ENOSYS for
                  # tini's reaper waitpid(-1, WNOHANG). tini treats any wait errno
                  # other than ECHILD as fatal, so it aborts with
                  #   [FATAL tini] Error while waiting for pids: 'Function not implemented'
                  # and takes claude down with it (the crash this fix resolves).
                  # proot is already the subreaper, so zombie reaping is handled;
                  # stray claude/node/MCP children that outlive a hard kill are mopped
                  # up by the claude-orphan-sweep call above (PPID=1 + session-group
                  # kill) at the next launch.
                  #
                  # SIGKILL on this wrapper is uncatchable (Android lmkd hard kill);
                  # the orphan-sweep likewise covers those survivors.
                  ${pkgs.util-linux}/bin/setpriv --pdeathsig TERM -- "$_bin" "$@"
                  _rc=$?
                  case "$_rc" in
                    126|127|137|139) ;;   # exec/signal failure → rescue
                    *) exit "$_rc" ;;
                  esac
                fi
                echo "[claude-malloc] native exec failed — trying rescue chain..." >&2
                exec sh "$HOME/git/tools/5-infos/claude-rescue/claude-rescue.sh" "$@"
              '')

              # claude-superset: route claude through claude-superset-api
              # Headroom proxy (token compression) over WireGuard, then hand off to
              # claude-malloc (keeps the Android isolation/supervision). Transparent
              # proxy (compress → forward to Anthropic with the client's own creds),
              # so interactive multi-turn / tool use is preserved. Health-checks the
              # proxy and falls back to direct Anthropic when it's unreachable.
              # Endpoint is data-driven (modules/data/claude-superset.json), override
              # via CLAUDE_SUPERSET_URL.
              # --help / -h: interactive status dashboard (probes all faces, MCPs,
              # plugins including Ponytail, and the direct Anthropic fallback).
              (writeShellScriptBin "claude-superset" ''
                set -u
                # ── Flags: mode / model / effort (parsed first) ────────────────
                # --auto (default): pass --dangerously-skip-permissions to claude.
                # --plan / --interactive: recorded for display; no extra CLI flags.
                # --model <id>: sets ANTHROPIC_MODEL. --effort <lvl>: CLAUDE_EFFORT.
                CC_EXTRA_FLAGS=""
                while :; do
                  case "''${1:-}" in
                    --auto)        CC_EXTRA_FLAGS="--dangerously-skip-permissions"; shift ;;
                    --plan)        shift ;;
                    --interactive) shift ;;
                    --model)       shift; [ -n "''${1:-}" ] && export ANTHROPIC_MODEL="$1"; shift ;;
                    --effort)      shift; export CLAUDE_EFFORT="''${1:-high}"; shift ;;
                    *) break ;;
                  esac
                done

                # help: plain-text usage + live status (agents, plugins, sessions).
                if [ "''${1:-}" = "help" ]; then
                  cat ${./modules/data/claude-superset-help.txt}
                  printf '\nMODEL ACTIVE\n  ANTHROPIC_MODEL=%s  CLAUDE_EFFORT=%s\n' \
                    "''${ANTHROPIC_MODEL:-<unset>}" "''${CLAUDE_EFFORT:-<unset>}"
                  printf '\nAGENTS\n'
                  _ag_dir="$HOME/.claude/agents"; _ag_c=0
                  if [ -d "$_ag_dir" ]; then
                    for _f in "$_ag_dir"/*.md; do
                      [ -f "$_f" ] || continue
                      _n="''${_f##*/}"; _n="''${_n%.md}"
                      case "$_n" in README*|readme*) continue ;; esac
                      printf '  %s\n' "$_n"; _ag_c=$((_ag_c+1))
                    done
                    [ "$_ag_c" -eq 0 ] && printf '  (none configured)\n'
                  else
                    printf '  (no agents dir)\n'
                  fi
                  printf '\nSTATUS LINE\n  '
                  bash "$HOME/.claude/claude-plugins-status.sh" --format plain 2>/dev/null || true
                  printf '\n'
                  _pdir="$HOME/.claude/projects"
                  printf '\nSESSIONS (last 48h — unique projects)\n'
                  if [ -d "$_pdir" ]; then
                    find "$_pdir" -name "*.jsonl" -mmin -2880 2>/dev/null \
                      | while IFS= read -r _f; do
                          _dir="''${_f%/*}"; printf '%s\n' "''${_dir##*/}"
                        done | sort -u | head -20 \
                      | while IFS= read -r _n; do printf '  %s\n' "$_n"; done
                  fi
                  printf '\nSESSIONS (last 5 by time)\n'
                  if [ -d "$_pdir" ]; then
                    _files=$(find "$_pdir" -name "*.jsonl" 2>/dev/null | tr '\n' ' ')
                    if [ -n "$_files" ]; then
                      ls -t $_files 2>/dev/null | head -5 \
                        | while IFS= read -r _f; do
                            _id="''${_f##*/}"; _id="''${_id%.jsonl}"
                            _dir="''${_f%/*}"; _proj="''${_dir##*/}"
                            printf '  %s  %s\n' "$_id" "$_proj"
                          done
                    fi
                  fi
                  exit 0
                fi

                if [ "''${1:-}" = "--help" ] || [ "''${1:-}" = "-h" ] || [ "''${1:-}" = "h" ]; then
                  export CAS_PROXY="${claudeSuperset.proxy}" CAS_API="${claudeSuperset.api}"
                  export CAS_OLLAMA="${claudeSuperset.ollama}" CAS_DASHBOARD="${claudeSuperset.dashboard}"
                  export CAS_COMPRESS="''${CAS_DASHBOARD%/dashboard}" CAS_LAUNCH="claude-malloc"
                  export CAS_ANTHROPIC="${claudeSuperset.anthropic}"
                  export CAS_MCP_C3_INFRA="${claudeSuperset.mcps.c3_infra}"
                  export CAS_MCP_C3_SVC="${claudeSuperset.mcps.c3_svc}"
                  export CAS_MCP_MATTERMOST="${claudeSuperset.mcps.mattermost}"
                  export CAS_MCP_MAIL="${claudeSuperset.mcps.mail}"
                  export CAS_MCP_GWS="${claudeSuperset.mcps.gws}"
                  export CAS_MCP_GP="${claudeSuperset.mcps.gp}"
                  export CAS_PLUGINS_SCRIPT="$HOME/.claude/claude-plugins-status.sh"
                  export CAS_MESH='${builtins.toJSON (claudeSuperset.mesh or {})}'
                  export CAS_PUBLIC='${builtins.toJSON (claudeSuperset.public or {})}'
                  export CAS_IMAGE="${claudeSuperset.image or ""}"
                  export CAS_PING="${pkgs.iputils}/bin/ping" CAS_DF="${pkgs.coreutils}/bin/df" CAS_GIT="${pkgs.git}/bin/git"
                  exec ${pkgs.nodejs}/bin/node ${./modules/data/claude-superset-tui.mjs}
                fi

                # Termux has no `local`/docker face — remote only. `claude` sets a
                # PLAIN flag (no proxy/plugins) but still flows through the restore
                # dispatch below, so `claude-superset claude restore N` works —
                # restore just reopens sessions via `claude --resume`.
                MODE="remote"; PLAIN=0
                case "''${1:-}" in
                  claude) MODE="claude"; PLAIN=1; shift ;;
                esac
                # Face → statusline (PL[M:{L|R|C} …]).
                export CLAUDE_SUPERSET_MODE="$MODE"
                # Plugin toggles (any order, before the action): headroom on|off,
                # ponytail on|off|lite|full|ultra . rtk on|off . caveman on|off.
                [ "$MODE" = "claude" ] || { export RTK_ENABLED=1 CAVEMAN_ENABLED=1; }
                HEADROOM="on"
                while :; do
                  case "''${1:-}" in
                    remote) shift ;;
                    headroom) HEADROOM="''${2:-on}"; shift 2 || shift ;;
                    ponytail)
                      case "''${2:-on}" in
                        on)              export PONYTAIL_DEFAULT_MODE="full" ;;
                        off)             export PONYTAIL_DEFAULT_MODE="off" ;;
                        lite|full|ultra) export PONYTAIL_DEFAULT_MODE="''${2}" ;;
                        *) echo "[claude-superset] ponytail: on|off|lite|full|ultra" >&2; exit 2 ;;
                      esac
                      shift 2 || shift ;;
                    rtk)     case "''${2:-on}" in on) export RTK_ENABLED=1 ;; off) unset RTK_ENABLED ;; *) echo "[claude-superset] rtk: on|off" >&2; exit 2 ;; esac; shift 2 || shift ;;
                    caveman) case "''${2:-on}" in on) export CAVEMAN_ENABLED=1 ;; off) unset CAVEMAN_ENABLED ;; *) echo "[claude-superset] caveman: on|off" >&2; exit 2 ;; esac; shift 2 || shift ;;
                    *) break ;;
                  esac
                done

                # Session engine env. No konsole in Termux → engine uses tmux.
                export CAS_API="${claudeSuperset.api}" CAS_SELF="claude-superset" CAS_FACE="$MODE"
                # ''${VAR-default}: a pre-set (even empty) CAS_TMUX survives — test override.
                export CAS_TMUX="''${CAS_TMUX-${pkgs.tmux}/bin/tmux}"
                ${if ((claudeSuperset.device or "") != "") then ''export CAS_DEVICE="${claudeSuperset.device}"'' else ""}
                CAS_DEVICE="''${CAS_DEVICE:-}"
                ENGINE="${pkgs.nodejs}/bin/node ${./modules/data/claude-superset-restore.mjs}"
                KEEP="${toString (claudeSuperset.sync_keep or 20)}"

                case "''${1:-}" in
                  sync) exec $ENGINE sync "$CAS_DEVICE" "$KEEP" ;;
                  restore|restore-hours)
                    sel=count; [ "$1" = "restore-hours" ] && sel=hours; shift
                    devsel="local"; a="''${1:-}"; b="''${2:-}"
                    case "$a" in
                      ""|*[!0-9]*) devsel="$a"; val="$b" ;;
                      *)           val="$a" ;;
                    esac
                    case "$val" in ""|*[!0-9]*)
                      echo "[claude-superset] restore needs a positive number" >&2; exit 2 ;;
                    esac
                    exec $ENGINE launch "$MODE" "$devsel" "$sel" "$val" ;;
                  fresh) shift ;;
                esac

                # Plain `claude` face: no proxy/plugins/sync. Restore already
                # dispatched above; a bare `claude-superset claude [args…]` (incl.
                # `--resume <id>` from a restored tab) execs plain claude-malloc.
                if [ "$PLAIN" = "1" ]; then
                  exec claude-malloc $CC_EXTRA_FLAGS "$@"
                fi

                if [ "$HEADROOM" = "on" ]; then
                  URL="''${CLAUDE_SUPERSET_URL:-${claudeSuperset.proxy}}"
                  if ${pkgs.curl}/bin/curl -fsS --max-time 2 "''${URL%/}/readyz" >/dev/null 2>&1; then
                    export ANTHROPIC_BASE_URL="$URL"
                    echo "[claude-superset] via superset proxy → $URL (Headroom compression ON)" >&2
                  else
                    echo "[claude-superset] proxy unreachable ($URL) — direct to Anthropic, no compression" >&2
                  fi
                else
                  echo "[claude-superset] Headroom OFF — direct to Anthropic (no compression)" >&2
                fi

                # Auto-sync recent sessions to the hub (background, best-effort)
                # unless this is a resumed session.
                case " $* " in
                  *" --resume "*) : ;;
                  *) ( $ENGINE sync "$CAS_DEVICE" "$KEEP" >/dev/null 2>&1 & ) ;;
                esac

                # Plugin status line (data-driven; mirrors the statusline PL[...] segment).
                pl=$(${pkgs.bash}/bin/bash "$HOME/.claude/claude-plugins-status.sh" --format plain 2>/dev/null)
                [ -n "$pl" ] && echo "[claude-superset] plugins: $pl" >&2
                exec claude-malloc $CC_EXTRA_FLAGS "$@"
              '')

              # my-ai: future replacement for claude-superset — shares the same
              # script via exec (single source of truth in claude-superset).
              (writeShellScriptBin "my-ai" ''
                exec claude-superset "$@"
              '')

              # claude-rescue: delegates to tools/5-infos/claude-rescue/
              # (12-fallback chain). The flake-side wrapper is intentionally
              # thin so the rescue logic has ONE home.
              (writeShellScriptBin "claude-rescue" ''
                exec sh "$HOME/git/tools/5-infos/claude-rescue/claude-rescue.sh" "$@"
              '')

              # claude-orphan-sweep: reap stale claude/tini orphans left over
              # from a previous SIGKILL'd session (Android lmkd hard kills are
              # uncatchable; their children get reparented to PID 1 and just
              # accumulate). Targets PPID=1 ONLY — active sessions parented by
              # a fish/bash are never touched. Called automatically at the
              # start of each claude-malloc / claude-termux launch.
              #
              # Teardown is by PROCESS GROUP, not session. fish's job control
              # puts each claude-malloc launch in its own process group (pgid =
              # claude-malloc's pid), and claude + its node/MCP children inherit
              # it — but they stay in the *login session* (sid = the fish/proot
              # session, shared by everything). So `kill -- -<session>` would
              # both MISS the claude subtree and signal the login session group.
              # We read field 5 (pgrp) of /proc/<pid>/stat and `kill -- -<pgrp>`,
              # which surgically takes down claude + all its children and nothing
              # else. (awk on $5 is safe here: it only runs after the comm has
              # already matched the space-free names below.)
              (writeShellScriptBin "claude-orphan-sweep" ''
                set -u
                swept=0
                _kill() {
                  local sig=$1 pid=$2 pgid=$3
                  if [ -n "$pgid" ] && [ "$pgid" -gt 1 ] 2>/dev/null; then
                    kill -"$sig" -- -"$pgid" 2>/dev/null || true
                  else
                    kill -"$sig" "$pid" 2>/dev/null || true
                  fi
                }
                for proc in /proc/[0-9]*; do
                  pid=''${proc##*/}
                  [ -r "$proc/status" ] || continue
                  ppid=$(${pkgs.gawk}/bin/awk '/^PPid:/ {print $2}' "$proc/status" 2>/dev/null) || continue
                  [ "$ppid" = "1" ] || continue
                  comm=$(cat "$proc/comm" 2>/dev/null) || continue
                  case "$comm" in
                    claude|claude-malloc|claude-termux|tini)
                      pgid=$(${pkgs.gawk}/bin/awk '{print $5}' "$proc/stat" 2>/dev/null)
                      _kill TERM "$pid" "$pgid"
                      swept=$((swept+1))
                      ;;
                  esac
                done
                if [ "$swept" -gt 0 ]; then
                  sleep 2
                  for proc in /proc/[0-9]*; do
                    pid=''${proc##*/}
                    [ -r "$proc/status" ] || continue
                    ppid=$(${pkgs.gawk}/bin/awk '/^PPid:/ {print $2}' "$proc/status" 2>/dev/null) || continue
                    [ "$ppid" = "1" ] || continue
                    comm=$(cat "$proc/comm" 2>/dev/null) || continue
                    case "$comm" in
                      claude|claude-malloc|claude-termux|tini)
                        pgid=$(${pkgs.gawk}/bin/awk '{print $5}' "$proc/stat" 2>/dev/null)
                        _kill KILL "$pid" "$pgid"
                        ;;
                    esac
                  done
                fi
                echo "claude-orphan-sweep: $swept process(es) reaped" >&2
              '')

              # 3. SYNC — unified sync engine (git + rclone)
              # Source: ~/git/tools/a-sync/sync.sh
              (writeShellScriptBin "sync" ''
                exec "$HOME/git/tools/a-sync/sync.sh" "$@"
              '')

              # 3b. SERVER — delegates to ~/git/front/server.sh (dev server control)
              (writeShellScriptBin "server" ''
                exec "$HOME/git/front/server.sh" "$@"
              '')

              # 4. CODE-SERVER (trying aggressive V8/Node fixes for Android)
              (writeShellScriptBin "code" ''
                # Force jemalloc for this process tree
                export LD_PRELOAD="${pkgs.jemalloc}/lib/libjemalloc.so"

                # Aggressive Node/V8 settings to prevent crashes
                export NODE_OPTIONS="--max-old-space-size=256 --v8-pool-size=1"
                export UV_THREADPOOL_SIZE=1
                export VSCODE_DISABLE_FILE_WATCHER=1

                # Disable features that cause issues on Android
                export ELECTRON_DISABLE_SANDBOX=1
                export ELECTRON_NO_ATTACH_CONSOLE=1

                # Colors
                C_RESET="\033[0m"
                C_CYAN="\033[0;36m"
                C_GREEN="\033[0;32m"
                C_YELLOW="\033[0;33m"
                C_RED="\033[0;31m"
                C_MAGENTA="\033[0;35m"
                C_BLUE="\033[0;34m"

                LOG_FILE="$HOME/.cache/code-server.log"
                PID_FILE="$HOME/.cache/code-server.pid"

                get_lan_ip() {
                  ${pkgs.python3}/bin/python3 -c "import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('8.8.8.8', 80)); print(s.getsockname()[0]); s.close()" 2>/dev/null || echo "<no-network>"
                }

                is_running() {
                  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
                }

                case "''${1:-}" in
                  local)
                    if is_running; then
                      printf "''${C_YELLOW}code-server already running (PID: $(cat "$PID_FILE"))''${C_RESET}\n"
                      exit 0
                    fi
                    printf "''${C_CYAN}Starting code-server on localhost:8080...''${C_RESET}\n"
                    mkdir -p "$(dirname "$LOG_FILE")"
                    nohup ${pkgs.code-server}/bin/code-server --bind-addr 127.0.0.1:8080 --auth none --disable-workspace-trust --disable-telemetry > "$LOG_FILE" 2>&1 &
                    echo $! > "$PID_FILE"
                    sleep 1
                    if is_running; then
                      printf "''${C_GREEN}Started on http://127.0.0.1:8080''${C_RESET}\n"
                    else
                      printf "''${C_RED}Failed to start. Check $LOG_FILE''${C_RESET}\n"
                    fi
                    ;;
                  lan)
                    if is_running; then
                      printf "''${C_YELLOW}code-server already running (PID: $(cat "$PID_FILE"))''${C_RESET}\n"
                      exit 0
                    fi
                    LAN_IP=$(get_lan_ip)
                    printf "''${C_CYAN}Starting code-server on LAN (daemon)...''${C_RESET}\n"
                    mkdir -p "$(dirname "$LOG_FILE")"
                    nohup ${pkgs.code-server}/bin/code-server --bind-addr 0.0.0.0:8080 --disable-workspace-trust --disable-telemetry > "$LOG_FILE" 2>&1 &
                    echo $! > "$PID_FILE"
                    sleep 1
                    if is_running; then
                      printf "''${C_GREEN}Started on http://$LAN_IP:8080''${C_RESET}\n"
                      printf "''${C_MAGENTA}Password:''${C_RESET} $(grep "^password:" ~/.config/code-server/config.yaml 2>/dev/null | cut -d' ' -f2 || echo 'not set')\n"
                    else
                      printf "''${C_RED}Failed to start. Check $LOG_FILE''${C_RESET}\n"
                    fi
                    ;;
                  stop)
                    printf "''${C_YELLOW}Stopping code-server...''${C_RESET}\n"
                    if is_running; then
                      kill "$(cat "$PID_FILE")" 2>/dev/null
                      rm -f "$PID_FILE"
                    fi
                    ps aux 2>/dev/null | grep "code-server" | grep -v grep | awk '{print $2}' | xargs -r kill -9 2>/dev/null
                    sleep 1
                    printf "''${C_GREEN}Stopped.''${C_RESET}\n"
                    ;;
                  log)
                    if [ -f "$LOG_FILE" ]; then
                      tail -50 "$LOG_FILE"
                    else
                      printf "''${C_RED}No log file found''${C_RESET}\n"
                    fi
                    ;;
                  *)
                    LAN_IP=$(get_lan_ip)
                    printf "''${C_CYAN}=== code-server ===''${C_RESET}\n"
                    if is_running; then
                      printf "''${C_GREEN}RUNNING''${C_RESET} (PID: $(cat "$PID_FILE"))\n"
                      printf "  Local: ''${C_CYAN}http://127.0.0.1:8080''${C_RESET}\n"
                      printf "  LAN:   ''${C_CYAN}http://$LAN_IP:8080''${C_RESET}\n"
                    else
                      printf "''${C_RED}STOPPED''${C_RESET}\n"
                    fi
                    echo ""
                    printf "''${C_YELLOW}Commands:''${C_RESET}\n"
                    printf "  ''${C_BLUE}code local''${C_RESET}   Start on localhost (daemon)\n"
                    printf "  ''${C_BLUE}code lan''${C_RESET}     Start on LAN (daemon)\n"
                    printf "  ''${C_BLUE}code stop''${C_RESET}    Stop code-server\n"
                    printf "  ''${C_BLUE}code log''${C_RESET}     Show recent logs\n"
                    echo ""
                    printf "''${C_MAGENTA}Password:''${C_RESET} $(grep "^password:" ~/.config/code-server/config.yaml 2>/dev/null | cut -d' ' -f2 || echo 'not set')\n"
                    echo ""
                    printf "''${C_RED}Note:''${C_RESET} Terminal/extensions may crash on Android.\n"
                    printf "       Access from another device for best experience.\n"
                    ;;
                esac
              '')

              # 5. GACP (Git Add, Commit, Push) — convenience wrapper for sync
              (writeShellScriptBin "gacp" ''
                exec "$HOME/git/tools/a-sync/sync.sh" git remote "$@"
              '')

              # 6. GCL (Git Clone shortcut)
              (writeShellScriptBin "gcl" ''
                if [ -z "$1" ]; then
                  printf "\033[0;31mError: Repository URL required\033[0m\n"
                  printf "Usage: gcl <url> [folder]\n"
                  printf "Examples:\n"
                  printf "  gcl git@github.com:user/repo.git\n"
                  printf "  gcl https://github.com/user/repo.git\n"
                  printf "  gcl https://github.com/user/repo.git myrepo\n"
                  exit 1
                fi
                printf "\033[0;36m→ Cloning $1...\033[0m\n"
                if [ -n "$2" ]; then
                  git clone "$1" "$2" || exit 1
                else
                  git clone "$1" || exit 1
                fi
                printf "\033[0;32m✓ Done\033[0m\n"
              '')

              # 7. CONNECT (Unified hub: HM, mesh, git, drives, sync, servers, security)
              # Source: ~/git/tools/a-connect/connect.sh
              (writeShellScriptBin "connect" ''
                exec "$HOME/git/tools/a-connect/connect.sh" "$@"
              '')

              # 7b. SYNC (Rclone sync manager)
              # Source: ~/git/tools/a-sync/sync.sh
              (writeShellScriptBin "sync" ''
                exec "$HOME/git/tools/a-sync/sync.sh" "$@"
              '')

              # 8. NIX-DRIFT (Version drift detection for nix flakes)
              # Source: ./nix-version-drift.sh
              (writeShellScriptBin "nix-drift" ''
                exec ${pkgs.bash}/bin/bash ${./nix-version-drift.sh} "$@"
              '')

              # 9. CLAUDE — native binary nix derivation. Permanent path,
              # no npm install at activation (which OOM-killed half the time).
              # Pulls the published native arm64-musl binary from npm registry
              # as a content-addressed source.
              (pkgs.callPackage ./pkgs/claude-code {})

              # 10. ANT — official Anthropic CLI for the Claude Developer
              # Platform (Managed Agents, Messages, Files, ...). Released
              # 2026-04-08. Pre-built linux/arm64 Go binary from GitHub
              # releases, fetched as a content-addressed source.
              (pkgs.callPackage ./pkgs/ant {})
            ];

            # --- HOME MANAGER CONFIG ---
            home-manager.config = { config, pkgs, lib, ... }: {
              _module.args.nodejs = pkgsNew.nodejs_22;
              # wstunnel 7.x (Rust) lives in pkgsUnstable. The old wstunnel 0.5.x
              # in pinned nixos-24.05 is Haskell and pulls connection-0.3.1 which
              # is marked broken upstream — blocking every home-manager switch.
              _module.args.wstunnel = pkgsUnstable.wstunnel;
              imports = [
                ./modules/common.nix
                ./modules/packages.nix
                ./modules/curl-wget-wrapper.nix
                ./modules/node-npm-deps.nix
                ./modules/node-bins.nix
                ./modules/web-server-md-eruda.nix
                ./modules/cloud-ide-sshd
                ./modules/wireguard.nix
                ./modules/wireguard-wstunnel.nix
              ];
              home.stateVersion = "24.05";

              # This runs BEFORE packages are linked
              home.activation.createUsrLib = lib.hm.dag.entryBefore ["writeBoundary"] ''
                $DRY_RUN_CMD mkdir -p /data/data/com.termux.nix/files/usr/lib
                $DRY_RUN_CMD chmod 755 /data/data/com.termux.nix/files/usr/lib
              '';

              # Create Unison target folder on Android storage
              home.activation.createUnisonTarget = lib.hm.dag.entryBefore ["writeBoundary"] ''
                $DRY_RUN_CMD mkdir -p "/storage/emulated/0/Mounts/Termux-Home"
              '';

              # Initialize $HOME as minimal git repo so Claude Code uses git ls-files (instant)
              # instead of ripgrep fallback (97s timeout scanning all of $HOME)
              home.activation.initHomeGit = lib.hm.dag.entryAfter ["linkGeneration"] ''
                if [ ! -d "$HOME/.git" ]; then
                  $DRY_RUN_CMD ${pkgs.git}/bin/git init "$HOME" 2>/dev/null
                fi
                # Ensure .gitignore is tracked (it's a nix-managed symlink)
                $DRY_RUN_CMD ${pkgs.git}/bin/git -C "$HOME" add -f .gitignore 2>/dev/null || true
              '';

              # Symlink nix-profile bins into Termux usr/bin so non-shell processes
              # (Claude Code, Android app launchers) can find nix-installed tools
              # without relying on shell init PATH expansion.
              home.activation.linkNixBinsToTermux = lib.hm.dag.entryAfter ["linkGeneration"] ''
                TERMUX_BIN="/data/data/com.termux.nix/files/usr/bin"
                NIX_BIN="$HOME/.nix-profile/bin"
                if [ -d "$TERMUX_BIN" ] && [ -d "$NIX_BIN" ]; then
                  for f in "$NIX_BIN"/*; do
                    name="$(basename "$f")"
                    target="$TERMUX_BIN/$name"
                    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
                      $DRY_RUN_CMD ln -sf "$f" "$target"
                    fi
                  done
                fi
              '';

              # Termux font — JetBrainsMono Nerd Font
              home.file.".termux/font.ttf".source =
                "${pkgs.nerdfonts.override { fonts = [ "JetBrainsMono" ]; }}/share/fonts/truetype/NerdFonts/JetBrainsMonoNerdFont-Regular.ttf";

              # Claude Code master context + MCP server config
              # CLAUDE.md is now a 1-char stub — all principles/reference content moved to
              # cloud-principles-ai-plugin (hooks-fragments/*.md, injected via SessionStart/
              # UserPromptSubmit hooks), shared with ba_flakes_desktop's cloud-marketplace
              # (one source of truth — see that flake's common.nix for the full rationale).
              home.file.".claude/CLAUDE.md".text = "\n";
              home.file.".claude/mcp.json.tpl".source = ../src/modules/dotfiles/claude/mcp.json.tpl;
              home.file.".claude/secrets.yaml".source = ../src/modules/dotfiles/claude/secrets.yaml;
              home.file.".claude/statusline-command.sh" = {
                source = ../src/modules/dotfiles/claude/statusline-command.sh;
                executable = true;
              };
              # Agent fleet manifest (explore/build/review/ops, all pinned model:sonnet)
              # — same roster as desktop (ba_flakes_desktop dotfiles/claude/agents).
              home.file.".claude/agents" = {
                source = ../src/modules/dotfiles/claude/agents;
                recursive = true;
              };
              # Plugin/MCP status for the statusline + claude-superset banner (data-driven).
              home.file.".claude/claude-plugins.json".source = ../src/modules/dotfiles/claude/claude-plugins.json;
              home.file.".claude/claude-plugins-status.sh" = {
                source = ../src/modules/dotfiles/claude/claude-plugins-status.sh;
                executable = true;
              };
              home.file.".claude/claude-mcp-status.sh" = {
                source = ../src/modules/dotfiles/claude/claude-mcp-status.sh;
                executable = true;
              };
              # Shared with ba_flakes_desktop (one source of truth) — reads the
              # cloud-marketplace plugin cache path, same on both platforms.
              home.file.".claude/claude-hooks-status.sh" = {
                source = ../../ba_flakes_desktop/src/modules/dotfiles/claude/claude-hooks-status.sh;
                executable = true;
              };
              home.file.".claude/claude-pricing.json".source =
                ../src/modules/dotfiles/claude/claude-pricing.json;
              # cloud-marketplace — SHARED with ba_flakes_desktop (one source of truth,
              # not a copy): local Claude Code plugin marketplace holding
              # cloud-principles-ai-plugin (the data-driven hook engine — replaces the
              # old tier-based a-/b-/c- hook scripts above) and ponytail. See
              # ba_flakes_desktop/src/modules/common.nix for the full rationale.
              home.file.".claude/cloud-marketplace".source =
                ../../ba_flakes_desktop/src/modules/dotfiles/claude/cloud-marketplace;
              # settings.json deployed as a writable real file (not a nix-store symlink)
              # so that runtime commands (/effort, /model, /fast) can persist their writes.
              # Source is authoritative: each switch resets runtime prefs back to declared values.
              home.activation.claudeSettingsWritable = lib.hm.dag.entryAfter ["linkGeneration"] ''
                _src=${../src/modules/dotfiles/claude/settings.json}
                _dst="$HOME/.claude/settings.json"
                [ -L "$_dst" ] && rm "$_dst"
                ${pkgs.coreutils}/bin/install -m 600 "$_src" "$_dst"
              '';
              # Register cloud-marketplace as a plugin marketplace (idempotent CLI call
              # from a nix-committed activation — same pattern as
              # ba_flakes_desktop's claudeMarketplace). claude-code is a real nix
              # derivation on PATH here (pkgs/claude-code), not a curl-installed binary.
              home.activation.claudeMarketplace = lib.hm.dag.entryAfter [ "claudeSettingsWritable" ] ''
                MARKETPLACE_DIR="$HOME/.claude/cloud-marketplace"
                JQ="${pkgs.jq}/bin/jq"
                if command -v claude >/dev/null 2>&1 && [ -d "$MARKETPLACE_DIR" ]; then
                  $DRY_RUN_CMD claude plugin marketplace add "$MARKETPLACE_DIR" >/dev/null 2>&1 || true
                  echo "[claude-marketplace] cloud-marketplace registered (enabledPlugins declared in settings.json)"
                  # Durable installPath materialization (see ba_flakes_desktop/common.nix
                  # for the rationale): Claude Code's /plugin loader validates
                  # plugins/cache/<marketplace>/<plugin>/<version>, which nothing
                  # populates for a directory-source marketplace — so it reports
                  # "cannot find the hooks" after a store-swap. Symlink each
                  # installPath into the store-backed marketplace dir. Data-driven:
                  # plugin names from marketplace.json, version from each plugin.json.
                  CACHE_DIR="$HOME/.claude/plugins/cache/cloud-marketplace"
                  MKT_JSON="$MARKETPLACE_DIR/.claude-plugin/marketplace.json"
                  if [ -f "$MKT_JSON" ]; then
                    for P in $("$JQ" -r '.plugins[].name' "$MKT_JSON" 2>/dev/null); do
                      VER=$("$JQ" -r '.version // "1.0.0"' "$MARKETPLACE_DIR/$P/.claude-plugin/plugin.json" 2>/dev/null || echo "1.0.0")
                      DEST="$CACHE_DIR/$P/$VER"
                      $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$CACHE_DIR/$P"
                      [ -e "$DEST" ] && [ ! -L "$DEST" ] && $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -rf "$DEST"
                      $DRY_RUN_CMD ${pkgs.coreutils}/bin/ln -sfn "$MARKETPLACE_DIR/$P" "$DEST"
                      echo "[claude-marketplace] materialized $P@$VER -> cache installPath"
                    done
                  fi
                else
                  echo "[claude-marketplace] WARNING: claude CLI or marketplace dir not found, skipping"
                fi
              '';
              # claude-api skill — pinned from anthropics/skills repo. Symlinks
              # the whole directory (SKILL.md + per-language assets) so updates
              # are a single rev/hash bump. https://github.com/anthropics/skills
              home.file.".claude/skills/claude-api".source =
                let anthropicSkills = pkgs.fetchFromGitHub {
                  owner = "anthropics";
                  repo  = "skills";
                  rev   = "da20c92503b2e8ff1cf28ca81a0df4673debdbf7";
                  sha256 = "08b3g2y0dx02bg5ypi8yvsd10dc19j9zm811hqq50aymbq8ny9h6";
                };
                in "${anthropicSkills}/skills/claude-api";

              # frontend-design — vendored from claude-plugins-official marketplace.
              home.file.".claude/skills/frontend-design".source = ../src/modules/dotfiles/claude/skills/frontend-design;

              # ── Writable dotfiles (see ba_flakes_desktop/common.nix for rationale) ──
              # Swap each store-backed HM symlink for a writable copy right after
              # linkGeneration so deployed files are editable for imperative tests;
              # the next switch re-links then re-copies (declarative always wins).
              # Data-driven from config.home.file (xdg.configFile feeds into it).
              home.activation.unfreezeHmFiles =
                let
                  _writableTargets = pkgs.writeText "hm-writable-targets"
                    (lib.concatMapStringsSep "\n" (f: f.target) (lib.attrValues config.home.file));
                in lib.hm.dag.entryAfter [ "linkGeneration" ] ''
                  while IFS= read -r _rel; do
                    [ -n "$_rel" ] || continue
                    _t="$HOME/$_rel"
                    [ -L "$_t" ] || continue
                    _r="$(${pkgs.coreutils}/bin/readlink -f "$_t" 2>/dev/null)"
                    [ -n "$_r" ] && [ -e "$_r" ] || continue
                    case "$_r" in /nix/store/*) ;; *) continue ;; esac
                    $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -f "$_t"
                    $DRY_RUN_CMD ${pkgs.coreutils}/bin/cp -RL "$_r" "$_t"
                    $DRY_RUN_CMD ${pkgs.coreutils}/bin/chmod -R u+w "$_t"
                  done < ${_writableTargets}
                '';

              home.file.".rgignore".source = ../src/modules/dotfiles/claude/rgignore;

              # Gemini CLI configuration + MCP server config
              home.file.".gemini/settings.json.tpl".source = ../src/modules/dotfiles/gemini/settings.json.tpl;

              # MCP secrets: decrypt secrets.yaml → awk subst ''${VAR} → ~/.mcp.json
              # Mimics Docker env_file + init.sh pattern using awk index() (literal, no regex)
              home.activation.mcpSecrets = lib.hm.dag.entryAfter ["linkGeneration"] ''
                SOPS="$HOME/.nix-profile/bin/sops"
                TPL="$HOME/.claude/mcp.json.tpl"
                SECRETS_YAML="$HOME/.claude/secrets.yaml"
                OUT="$HOME/.mcp.json"
                YQ="${pkgs.yq-go}/bin/yq"
                AWK="${pkgs.gawk}/bin/awk"

                if [ ! -f "$SOPS" ] || [ ! -f "$SECRETS_YAML" ] || [ ! -f "$TPL" ]; then
                  echo "[mcp-secrets] WARNING: sops/secrets/template not found, copying template as-is"
                  [ -f "$TPL" ] && cp "$TPL" "$OUT"
                  exit 0
                fi

                # Decrypt secrets.yaml (same as cloud/ _engine.sh pattern)
                DECRYPTED=$("$SOPS" -d "$SECRETS_YAML" 2>/dev/null) || true
                if [ -z "$DECRYPTED" ]; then
                  echo "[mcp-secrets] WARNING: failed to decrypt secrets.yaml"
                  cp "$TPL" "$OUT"
                  exit 0
                fi

                # Copy template to output
                cp "$TPL" "$OUT"

                # Extract ''${VAR} placeholders using awk (no sed, no regex on secrets)
                VARS=$($AWK '{
                  s = $0
                  while (match(s, /\$\{[A-Za-z_][A-Za-z0-9_-]*\}/)) {
                    v = substr(s, RSTART+2, RLENGTH-3)
                    print v
                    s = substr(s, RSTART+RLENGTH)
                  }
                }' "$OUT" | sort -u) || true

                # awk index() substitution — literal string match, no regex
                # Same proven pattern as Authelia init.sh and cloud/ _engine.sh
                for _var in $VARS; do
                  _val=$(printf '%s' "$DECRYPTED" | "$YQ" -r ".[\"$_var\"]" 2>/dev/null) || true
                  if [ -z "$_val" ] || [ "$_val" = "null" ]; then
                    echo "[mcp-secrets] WARNING: $_var not found in secrets — leaving placeholder"
                    continue
                  fi
                  _pat="\''${''${_var}}"
                  $AWK -v pat="$_pat" -v rep="$_val" '{
                    while (i = index($0, pat)) {
                      $0 = substr($0, 1, i-1) rep substr($0, i+length(pat))
                    }
                    print
                  }' "$OUT" > "$OUT.tmp"
                  mv "$OUT.tmp" "$OUT"
                done

                chmod 600 "$OUT"
                echo "[mcp-secrets] ~/.mcp.json templated ($(echo $VARS | wc -w) vars substituted)"
              '';

              # Gemini CLI: decrypt secrets.yaml → awk subst ''${VAR} → ~/.gemini/settings.json
              home.activation.geminiMcpSecrets = lib.hm.dag.entryAfter ["linkGeneration"] ''
                SOPS="$HOME/.nix-profile/bin/sops"
                TPL="$HOME/.gemini/settings.json.tpl"
                SECRETS_YAML="$HOME/.claude/secrets.yaml"
                OUT="$HOME/.gemini/settings.json"
                YQ="${pkgs.yq-go}/bin/yq"
                AWK="${pkgs.gawk}/bin/awk"

                if [ ! -f "$SOPS" ] || [ ! -f "$SECRETS_YAML" ] || [ ! -f "$TPL" ]; then
                  echo "[gemini-mcp] WARNING: sops/secrets/template not found, copying template as-is"
                  [ -f "$TPL" ] && cp "$TPL" "$OUT"
                  exit 0
                fi

                DECRYPTED=$("$SOPS" -d "$SECRETS_YAML" 2>/dev/null) || true
                if [ -z "$DECRYPTED" ]; then
                  echo "[gemini-mcp] WARNING: failed to decrypt secrets.yaml"
                  cp "$TPL" "$OUT"
                  exit 0
                fi

                cp "$TPL" "$OUT"

                VARS=$($AWK '{
                  s = $0
                  while (match(s, /\$\{[A-Za-z_][A-Za-z0-9_-]*\}/)) {
                    v = substr(s, RSTART+2, RLENGTH-3)
                    print v
                    s = substr(s, RSTART+RLENGTH)
                  }
                }' "$OUT" | sort -u) || true

                for _var in $VARS; do
                  _val=$(printf '%s' "$DECRYPTED" | "$YQ" -r ".[\"$_var\"]" 2>/dev/null) || true
                  if [ -z "$_val" ] || [ "$_val" = "null" ]; then
                    echo "[gemini-mcp] WARNING: $_var not found in secrets — leaving placeholder"
                    continue
                  fi
                  _pat="\''${''${_var}}"
                  $AWK -v pat="$_pat" -v rep="$_val" '{
                    while (i = index($0, pat)) {
                      $0 = substr($0, 1, i-1) rep substr($0, i+length(pat))
                    }
                    print
                  }' "$OUT" > "$OUT.tmp"
                  mv "$OUT.tmp" "$OUT"
                done

                chmod 600 "$OUT"
                echo "[gemini-mcp] ~/.gemini/settings.json templated ($(echo $VARS | wc -w) vars substituted)"
              '';

              # Minimal .gitignore so $HOME is a git repo (ignore everything)
              # This makes Claude Code use `git ls-files` (instant) instead of ripgrep (97s timeout)
              home.file.".gitignore".text = "*";

              # Unison profile for bidirectional sync
              home.file.".unison/termux-home.prf".text = ''
                # Bidirectional sync: Termux home <-> Android storage
                root = /data/data/com.termux.nix/files/home
                root = /storage/emulated/0/Mounts/Termux-Home

                # Android storage compatibility
                perms = 0
                dontchmod = true
                links = false

                # Prefer newer files on conflict
                prefer = newer

                # Auto-accept non-conflicting changes
                auto = true
                batch = true

                # Only sync specific folders (avoid system files)
                path = nix-home-manager
                path = desktop
              '';

              programs.bash = {
                enable = true;
                shellAliases = sharedAliases;
                profileExtra = ''
                  export PATH="$HOME/.nix-profile/bin:/run/current-system/sw/bin:$PATH"
                '';
              };

              programs.zsh = {
                enable = true;
                shellAliases = sharedAliases;
              };

              programs.fish = {
                enable = true;
                shellAliases = sharedAliases;
                interactiveShellInit = ''

                  # NOTE: sshd auto-start lives in modules/cloud-ide-sshd (`cloud-ide-sshd start`).
                  # The previous block here referenced ~/.ssh/sshd_config which is never
                  # created — it failed silently and hid real startup errors. Removed.

                  # Auto-start http-dev (web-server-md-eruda)
                  set -g __httpd_port 8000
                  if command -q http-dev
                    http-dev start >/dev/null 2>&1
                    set -g __httpd_pid (cat ~/.cache/web-server-md-eruda.pid 2>/dev/null)
                  end

                  # FZF configuration
                  set -gx FZF_DEFAULT_OPTS "--height 40% --layout=reverse --border"

                  # FZF key bindings for fish
                  function fzf_file
                    set -l result (fzf --preview 'head -100 {}')
                    if test -n "$result"
                      commandline -i "$result"
                    end
                    commandline -f repaint
                  end

                  function fzf_history
                    set -l result (history | fzf --no-sort)
                    if test -n "$result"
                      commandline -r "$result"
                    end
                    commandline -f repaint
                  end

                  function fzf_cd
                    set -l result (find . -type d 2>/dev/null | fzf)
                    if test -n "$result"
                      cd "$result"
                    end
                    commandline -f repaint
                  end

                  # Bind Ctrl+T for file, Ctrl+R for history, Alt+C for cd
                  bind \ct fzf_file
                  bind \cr fzf_history
                  bind \ec fzf_cd


                  # Greeting is fish_greeting in modules/programs/shells/fish/functions/fish_greeting.fish (wired via fish.nix)
                '';
              };
            };
          })
        ];
      };

      # ── termux-cache-image: LAYERED image of the nix-on-droid closure ──
      # One layer per store path (dockerTools.buildLayeredImage) → skopeo
      # (no Docker daemon needed on Android — see build.sh's
      # ghcr_pull_layered_skopeo) skips unchanged layers, so `build.sh pull`
      # fetches only the store paths that actually changed instead of
      # re-downloading the whole multi-GB nar. Pushed to GHCR by the CI
      # export step (GHCR_PUSH=1); consumed by `cmd_pull` (the nar.zst path
      # is kept as the fallback). Mirrors ba_flakes_desktop's hm-cache-image.
      packages.aarch64-linux.termux-cache-image = pkgsNew.dockerTools.buildLayeredImage {
        name = "unix-termux-cache";
        tag = "latest";
        maxLayers = 120;
        contents = [ self.nixOnDroidConfigurations.default.activationPackage ];
        config.Labels = {
          "org.opencontainers.image.description" = "Termux (nix-on-droid) activation closure as layered store paths (incremental GHCR cache).";
          "org.opencontainers.image.source" = "https://github.com/diegonmarcos/unix";
        };
      };
    };
}
