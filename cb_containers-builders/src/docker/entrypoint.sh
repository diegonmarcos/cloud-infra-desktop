#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ cloud-builder entrypoint — UNIVERSAL                            ║
# ║                                                                  ║
# ║ Works identically on GHA, Surface, Dagu, any Docker host.       ║
# ║                                                                  ║
# ║ Usage:                                                           ║
# ║   docker run <image> ship oci-apps                               ║
# ║   docker run <image> ship --all                                  ║
# ║   docker run <image> health                                      ║
# ║   docker run <image> bash        (interactive shell)             ║
# ║                                                                  ║
# ║ Secrets: auto-detected from env vars OR mounted files.           ║
# ║   ENV mode (GHA):    SSH_KEY, SOPS_AGE_KEY, GITHUB_TOKEN        ║
# ║   MOUNT mode (local): ~/.ssh, ~/.config/sops mounted into       ║
# ║                        container — script detects and uses them  ║
# ╚══════════════════════════════════════════════════════════════════╝
set -e

# ── 1. Nix/HM profile ─────────────────────────────────────────────
[ -f /root/.nix-profile/etc/profile.d/nix.sh ] && . /root/.nix-profile/etc/profile.d/nix.sh 2>/dev/null
[ -f /root/.nix-profile/etc/profile.d/hm-session-vars.sh ] && . /root/.nix-profile/etc/profile.d/hm-session-vars.sh 2>/dev/null
# HM home-path has the actual tool binaries (jq, node, sops, etc.)
HM_PROFILE="$HOME/.local/state/nix/profiles/home-manager"
HM_PATH=""
[ -d "$HM_PROFILE/home-path/bin" ] && HM_PATH="$HM_PROFILE/home-path/bin"
export PATH="$HM_PATH:$HOME/.nix-profile/bin:$HOME/.node_modules/node_modules/.bin:/usr/local/bin:$PATH"

# ── 2. Help / passthrough ─────────────────────────────────────────
case "${1:-}" in
  ""|--help|-h)
    IMAGE="ghcr.io/diegonmarcos/cloud-builder-x-deb-nixhm"
    echo "cloud-builder — universal CI/CD runner"
    echo ""
    echo "Usage:"
    echo "  docker run --rm $IMAGE cat /opt/cloud-builder/cloud-builder.sh | sh -s <command> [args]"
    echo ""
    echo "Commands:"
    echo "  ship <vm>           Ship services to a VM"
    echo "  ship --all          Ship all VMs"
    echo "  gen-configs         Generate configs (Caddy, DNS, etc.)"
    echo "  ship-hm             Ship home-manager to VMs"
    echo "  ship-reports        Build + push cloud-data-reports image"
    echo "  health              Run health checks"
    echo "  bash                Interactive shell"
    echo ""
    echo "Examples:"
    echo "  ... | sh -s ship oci-apps"
    echo "  ... | sh -s ship --all"
    echo "  ... | sh -s health"
    exit 0
    ;;
  bash|sh|fish)
    # Interactive shell — setup env but don't dispatch
    ;;
  ship|health|gen-configs|ship-hm|ship-reports)
    # Handled below after setup
    ;;
  *)
    # Raw passthrough (e.g. custom script)
    exec "$@"
    ;;
esac

# ── 3. SSH setup ──────────────────────────────────────────────────
# /root/.ssh may be mounted :ro from host. Everything uses || true — failures are non-fatal.
# Precedence:  env vars  >  /mnt/host-ssh copy  >  host-mounted .ssh  >  WARN.
SSH_DIR=/root/.ssh
mkdir -p "$SSH_DIR" 2>/dev/null || true
chmod 700 "$SSH_DIR" 2>/dev/null || true
ssh-keyscan github.com >> "$SSH_DIR/known_hosts" 2>/dev/null || true

# (a) CI-mode — env vars provided by GHA
if [ -n "${SSH_KEY:-}" ]; then
  echo "$SSH_KEY" > "$SSH_DIR/id_deploy" 2>/dev/null || true
  chmod 600 "$SSH_DIR/id_deploy" 2>/dev/null || true
  echo "[setup] SSH key from env var"
fi
if [ -n "${SSH_ALIAS:-}" ] && [ -n "${SSH_HOST:-}" ]; then
  cat >> "$SSH_DIR/config" 2>/dev/null <<EOF || true
Host ${SSH_ALIAS}
  HostName ${SSH_HOST}
  User ${SSH_USER:-ubuntu}
  IdentityFile $SSH_DIR/id_deploy
  StrictHostKeyChecking no
  ServerAliveInterval 30
  ServerAliveCountMax 10
EOF
  chmod 600 "$SSH_DIR/config" 2>/dev/null || true
  echo "[setup] SSH config for ${SSH_ALIAS}"
fi

# (b) Local/Dagu mode — host keys mounted at /mnt/host-ssh:ro
if [ -d /mnt/host-ssh ]; then
  for f in /mnt/host-ssh/id_* /mnt/host-ssh/config /mnt/host-ssh/known_hosts; do
    [ -f "$f" ] || continue
    bn=$(basename "$f")
    [ -f "$SSH_DIR/$bn" ] && continue
    cp "$f" "$SSH_DIR/$bn" 2>/dev/null || true
    chown root:root "$SSH_DIR/$bn" 2>/dev/null || true
    case "$bn" in
      config|id_*) chmod 600 "$SSH_DIR/$bn" 2>/dev/null || true ;;
      *)           chmod 644 "$SSH_DIR/$bn" 2>/dev/null || true ;;
    esac
  done
  echo "[setup] SSH from /mnt/host-ssh"
fi

if [ ! -f "$SSH_DIR/config" ] && [ ! -f "$SSH_DIR/id_deploy" ]; then
  echo "[setup] WARNING: no SSH keys found"
fi

# ── 4. SOPS setup ─────────────────────────────────────────────────
# Precedence: env var (CI) > /mnt/host-sops (local).
mkdir -p /root/.config/sops/age 2>/dev/null || true
if [ -n "${SOPS_AGE_KEY:-}" ]; then
  echo "$SOPS_AGE_KEY" > /root/.config/sops/age/keys.txt 2>/dev/null || true
  chmod 600 /root/.config/sops/age/keys.txt 2>/dev/null || true
  export SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt
  echo "[setup] SOPS age key from env var"
elif [ -f /mnt/host-sops/age/keys.txt ]; then
  cp /mnt/host-sops/age/keys.txt /root/.config/sops/age/keys.txt 2>/dev/null || true
  chown root:root /root/.config/sops/age/keys.txt 2>/dev/null || true
  chmod 600 /root/.config/sops/age/keys.txt 2>/dev/null || true
  export SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt
  echo "[setup] SOPS age key from /mnt/host-sops"
else
  echo "[setup] WARNING: no SOPS age key found"
fi

# ── 4b. gh CLI config (optional, local-dev) ───────────────────────
if [ -d /mnt/host-gh ] && [ ! -d /root/.config/gh ]; then
  mkdir -p /root/.config/gh 2>/dev/null || true
  cp -r /mnt/host-gh/. /root/.config/gh/ 2>/dev/null || true
  chown -R root:root /root/.config/gh 2>/dev/null || true
  echo "[setup] gh CLI config from /mnt/host-gh"
fi

# ── 5. GHCR login ─────────────────────────────────────────────────
# In CI, the host runner already runs `docker login ghcr.io` before
# `docker compose run`, and the resulting ~/.docker/config.json is
# RO-mounted into the container per compose.yaml. A fresh `docker login`
# inside the container tries to write back to that RO mount and fails.
# Combined with `set -e` and silenced stderr, it killed the entrypoint
# silently right after the gh CLI step (the original gen-configs/Ship
# crash). Detect the RO-mount or pre-existing auth and skip; otherwise
# attempt login but treat failure as non-fatal — GHCR login is best
# effort, downstream consumers (docker pull, compose) surface the real
# error if the registry is genuinely unreachable.
if [ -f /root/.docker/config.json ] && grep -q '"ghcr.io"' /root/.docker/config.json 2>/dev/null; then
  echo "[setup] GHCR auth already present (host-mounted ~/.docker/config.json)"
elif [ -n "${GITHUB_TOKEN:-}" ]; then
  if echo "$GITHUB_TOKEN" | docker login ghcr.io -u "${GITHUB_ACTOR:-diegonmarcos}" --password-stdin 2>&1; then
    echo "[setup] GHCR authenticated"
  else
    echo "[setup] GHCR login failed (non-fatal — downstream docker pull will fail loud if needed)"
  fi
elif command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
  if gh auth token 2>/dev/null | docker login ghcr.io -u "$(gh api user --jq .login 2>/dev/null || echo diegonmarcos)" --password-stdin 2>&1; then
    echo "[setup] GHCR authenticated via gh CLI"
  else
    echo "[setup] GHCR login via gh failed (non-fatal)"
  fi
fi

# ── 6. WireGuard (if key provided) ────────────────────────────────
if [ -n "${WG_PRIVATE_KEY:-}" ]; then
  # Smart privilege escalation: try sudo, fall back to direct (root in container)
  _run() {
    if [ "$(id -u)" = "0" ]; then
      "$@"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo "$@"
    else
      "$@"  # last resort — may fail if not root, but won't hang
    fi
  }
  # Subshell scopes umask — otherwise 077 persists for the whole entrypoint
  # and every subsequent file (including /traces/*.json mounted from the GHA
  # runner) becomes 600 root, which makes actions/upload-artifact fail with
  # EACCES when it tries to read the trace as the non-root runner user.
  ( umask 077
    cat > /tmp/wg0.conf << WGEOF
[Interface]
PrivateKey = ${WG_PRIVATE_KEY}
Address = 10.0.0.200/24

[Peer]
PublicKey = vV/phXUwnCjxACQ5Df11Uw47BzJaK4r85jPYMu2HmDc=
Endpoint = 35.226.147.64:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
WGEOF
  )
  _run mkdir -p /etc/wireguard 2>/dev/null || true
  _run cp /tmp/wg0.conf /etc/wireguard/wg0.conf 2>/dev/null || true
  rm /tmp/wg0.conf 2>/dev/null || true
  # Do NOT silence errors — a silent "non-fatal" WG failure masks the
  # single most common cause of downstream ssh timeouts to WG-only VMs
  # (oci-mail 10.0.0.3, oci-apps 10.0.0.6). If wg-quick fails, print the
  # actual kernel/ip/permission error so it's visible in the job log.
  # "non-fatal" is kept only because some invocations genuinely don't need
  # WG (local dev, health checks against public endpoints) — callers that
  # need WG must check reachability afterwards, not trust this line.
  if _run wg-quick up wg0; then
    echo "[setup] WireGuard up"
  else
    _wg_rc=$?
    echo "[setup] WireGuard FAILED (rc=$_wg_rc) — ssh to WG-only VMs will time out"
    echo "[setup]   Common causes: missing cap_add: NET_ADMIN in compose OR --cap-add NET_ADMIN on docker run"
    [ -z "${WG_PRIVATE_KEY:-}" ] && echo "[setup]   WG_PRIVATE_KEY was empty"
  fi
  unset -f _run
fi

# ── 7. Re-sync all repos (baked at build time under ~/git/) ──────
# Each repo's 1_workflows framework provides a `git nuke` alias —
# bulletproof reset-from-origin (fetch + reset --hard + clean -fdx +
# submodule update --remote --rebase --force). Survives force-pushed
# origin, dirty work, untracked files, divergent history.
# See ~/git/cloud/1_workflows/src/scripts/cloud-git-nuke.sh.
#
# Falls back to hand-rolled fetch+reset for repos without the framework
# (cloud-data, front) or images that pre-date the alias.
GIT_ROOT="$HOME/git"
git config --global --add safe.directory "*"

echo "[setup] Syncing all repos via git nuke..."
for repo in cloud cloud-data unix front tools; do
  dir="$GIT_ROOT/$repo"
  [ -d "$dir/.git" ] || continue
  _synced=0
  if git -C "$dir" config --get alias.nuke >/dev/null 2>&1; then
    if (cd "$dir" && git nuke --quiet 2>/dev/null); then
      echo "[setup] Synced $repo (via git nuke)"
      _synced=1
    else
      # nuke can die on broken submodule state WITHOUT moving HEAD —
      # 2026-07-02: baked cloud repo stuck at Jun-14, every ship skipped
      # all services as "unchanged" (false-green). Fall through to the
      # legacy path instead of leaving the repo stale.
      echo "[setup] git nuke failed for $repo — falling back to fetch+reset"
    fi
  fi
  if [ "$_synced" -eq 0 ]; then
    # fetch+reset moves HEAD even when submodule checkout is broken;
    # submodule update is best-effort and must never mask a moved HEAD.
    # No 2>/dev/null on fetch/reset — sync errors must be visible.
    #
    # Retried: github.com is reachable-but-slow often enough that a single
    # attempt is a coin flip. 2026-08-02 run 30753108019 — cloud-cgc-mcp died
    # on "Failed to connect to github.com port 443 after 136060 ms", the one
    # attempt was spent, and the run limped on with a stale workspace until
    # the staleness gate below aborted it with an unrelated-looking error.
    _n=0
    while :; do
      # --no-recurse-submodules: fetch's job here is to move the SUPERPROJECT's
      # HEAD. Recursing (git's "on-demand" default) makes the exit code depend on
      # every submodule being reachable — and cloud-data is a PRIVATE repo the
      # builder has no HTTPS credentials for, so fetch returned non-zero, the
      # && chain skipped the reset, all 3 attempts burned, and the workspace went
      # stale (2026-08-09: every cloud ship failed on "could not read Username").
      # Submodules are updated separately below, best-effort, where a private
      # repo we don't need cannot poison the payload sync.
      if git -C "$dir" fetch --no-recurse-submodules origin main \
         && git -C "$dir" reset --hard origin/main; then
        git -C "$dir" submodule update --init --recursive 2>/dev/null \
          || echo "[setup] WARN: submodule update failed for $repo (continuing)"
        echo "[setup] Synced $repo (legacy fetch+reset)"
        _synced=1
        break
      fi
      _n=$((_n + 1))
      if [ "$_n" -ge 3 ]; then
        break
      fi
      echo "[setup] WARN: sync attempt $_n failed for $repo — retrying in $((_n * 10))s"
      sleep $((_n * 10))
    done
  fi
  if [ "$_synced" -eq 0 ]; then
    # The payload repo is not optional: continuing leaves the workspace stale
    # and the failure resurfaces below as a confusing HEAD-mismatch abort.
    # Fail here, where the real reason (the git error) is on screen.
    if [ "$repo" = "cloud" ]; then
      echo "[setup] FATAL: sync failed for payload repo '$repo' after 3 attempts — see the git error above"
      exit 1
    fi
    echo "[setup] Sync failed for $repo (non-fatal)"
  fi
done

WORKSPACE="$GIT_ROOT/cloud"
cd "$WORKSPACE"

# ── Fail-loud staleness gate ──────────────────────────────────────
# Shipping from a stale payload repo produces false-green runs: every
# service reports "skipped (unchanged)" because stale dir names never
# match CHANGED_DIRS (proven 2026-07-02, run 28603693386). The payload
# repo MUST be at origin/main, and when GHA provides the triggering
# commit (GITHUB_SHA) it must exist in the synced history. Anything
# else aborts the run — a no-op ship reported as success is worse
# than a failed one.
_HEAD=$(git rev-parse HEAD 2>/dev/null || echo unknown)
_ORIGIN_MAIN=$(git rev-parse origin/main 2>/dev/null || echo unavailable)
if [ "$_HEAD" != "$_ORIGIN_MAIN" ]; then
  echo "[setup] FATAL: cloud repo HEAD ($_HEAD) != origin/main ($_ORIGIN_MAIN) — stale workspace, aborting"
  exit 1
fi
if [ -n "${GITHUB_SHA:-}" ] && ! git cat-file -e "${GITHUB_SHA}^{commit}" 2>/dev/null; then
  echo "[setup] FATAL: triggering commit $GITHUB_SHA not present in synced cloud repo — aborting"
  exit 1
fi
echo "[setup] Ready: $(pwd) @ $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

# ── 7b. Docker daemon health-check ────────────────────────────────
# The container mounts /var/run/docker.sock and every common payload
# (docker login, docker build, docker push) needs the daemon
# reachable. If the socket mount has wrong perms or the daemon is
# down, the next docker call fails, `set -e` aborts the user payload
# silently mid-pipeline → ssh closes → outer engine sees exit 255 with
# zero diagnostic output. Surfacing the actual daemon error here means
# future failures arrive with their cause attached.
if ! docker info >/dev/null 2>&1; then
  echo "[setup] FATAL: docker daemon unreachable from inside cloud-builder-x"
  echo "[setup] docker info stderr:"
  docker info 2>&1 | sed 's/^/[setup]   /' | head -10
  exit 1
fi
echo "[setup] docker daemon ok ($(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'))"

# ── 8. Dispatch ────────────────────────────────────────────────────
SCRIPTS=".github/workflows/scripts"
CMD="$1"; shift
echo "[setup] Dispatching: CMD=$CMD args=$*"

case "$CMD" in
  ship)
    VM="${1:-}"
    if [ "$VM" = "--all" ] || [ -z "$VM" ]; then
      exec bash "$SCRIPTS/cloud-ship-orchestrate-portable.sh" "$@"
    else
      export SSH_ALIAS="${SSH_ALIAS:-$VM}"
      export CHANGED_DIRS="${CHANGED_DIRS:-}"
      exec bash "$SCRIPTS/cloud-ship-ci-builder-dispatch.sh" "$VM" "$@"
    fi
    ;;
  health)
    exec bash "$SCRIPTS/cloud-health-full.sh" "$@"
    ;;
  gen-configs)
    exec bash "$SCRIPTS/cloud-ship-orchestrate-gen-configs.sh" "$@"
    ;;
  ship-hm)
    exec bash "$SCRIPTS/cloud-ship-ci-builder-dispatch.sh" ship-hm "$@"
    ;;
  ship-reports)
    CLOUD_DATA_SCRIPTS="$HOME/git/cloud-data/.github/workflows/scripts"
    exec bash "$CLOUD_DATA_SCRIPTS/ship-reports.sh" "$@"
    ;;
  bash|sh)
    exec bash "$@"
    ;;
  fish)
    exec fish "$@"
    ;;
esac
