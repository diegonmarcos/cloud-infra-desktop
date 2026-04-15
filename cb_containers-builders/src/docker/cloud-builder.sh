#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ cloud-builder.sh — Universal Launcher                           ║
# ║                                                                  ║
# ║ This script runs ON THE HOST after extraction from the image:    ║
# ║                                                                  ║
# ║   docker run --rm ghcr.io/diegonmarcos/cloud-builder-x-deb-nixhm \
# ║     cat /opt/cloud-builder/cloud-builder.sh | sh -s ship oci-apps║
# ║                                                                  ║
# ║ It has full host permissions: SSH keys, docker socket, network,  ║
# ║ SOPS keys, env vars — everything the user has.                   ║
# ║                                                                  ║
# ║ It then re-launches the container with all the right mounts.     ║
# ╚══════════════════════════════════════════════════════════════════╝
set -e

IMAGE="ghcr.io/diegonmarcos/cloud-builder-x-deb-nixhm:latest"

# ── Auto-detect what's available on this host ──────────────────────
DOCKER_ARGS="--rm --network=host"

# Docker socket
if [ -S /var/run/docker.sock ]; then
  DOCKER_ARGS="$DOCKER_ARGS -v /var/run/docker.sock:/var/run/docker.sock"
fi

# SSH keys (mount if dir exists)
if [ -d "$HOME/.ssh" ]; then
  DOCKER_ARGS="$DOCKER_ARGS -v $HOME/.ssh:/root/.ssh:ro"
fi

# SOPS age key (mount if dir exists)
if [ -d "$HOME/.config/sops" ]; then
  DOCKER_ARGS="$DOCKER_ARGS -v $HOME/.config/sops:/root/.config/sops:ro"
fi

# GitHub token (from env or gh CLI)
if [ -n "${GITHUB_TOKEN:-}" ]; then
  DOCKER_ARGS="$DOCKER_ARGS -e GITHUB_TOKEN=$GITHUB_TOKEN"
elif command -v gh >/dev/null 2>&1; then
  _token=$(gh auth token 2>/dev/null || true)
  [ -n "$_token" ] && DOCKER_ARGS="$DOCKER_ARGS -e GITHUB_TOKEN=$_token"
fi

# Pass through CI env vars if set
for _var in GITHUB_ACTOR GITHUB_ACTIONS GITHUB_EVENT_NAME GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_SHA SSH_KEY SSH_HOST SSH_USER SSH_ALIAS SOPS_AGE_KEY WG_PRIVATE_KEY CHANGED_DIRS OCI_SSH_KEY GCP_PROXY_SSH_KEY GCP_T4_SSH_KEY; do
  eval "_val=\${$_var:-}"
  [ -n "$_val" ] && DOCKER_ARGS="$DOCKER_ARGS -e $_var"
done

# ── Launch ─────────────────────────────────────────────────────────
exec docker run $DOCKER_ARGS "$IMAGE" "$@"
