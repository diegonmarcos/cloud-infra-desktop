#!/bin/sh
# Cloud-builder entrypoint
# Sources HM profile, refreshes repos, then routes commands

# Home Manager profile (manages PATH, env vars, shell config)
[ -f /root/.nix-profile/etc/profile.d/nix.sh ] && . /root/.nix-profile/etc/profile.d/nix.sh 2>/dev/null
[ -f /root/.nix-profile/etc/profile.d/hm-session-vars.sh ] && . /root/.nix-profile/etc/profile.d/hm-session-vars.sh 2>/dev/null
export PATH="$HOME/.nix-profile/bin:$HOME/.node_modules/node_modules/.bin:$PATH"

# Refresh repos (remote always wins)
for repo in cloud unix front cloud-data; do
  dir="$HOME/git/$repo"
  [ -d "$dir/.git" ] && git -C "$dir" fetch origin main 2>/dev/null && git -C "$dir" reset --hard origin/main 2>/dev/null
done
# Update submodules in cloud
[ -d "$HOME/git/cloud/.git" ] && git -C "$HOME/git/cloud" submodule update --remote 2>/dev/null

case "${1:-}" in
  docker-up)
    cat /opt/cloud-builder/docker-up.sh
    ;;
  ""|--help|-h)
    echo "cloud-builder — Debian flat + nix + home-manager"
    echo "Repos at ~/git/{cloud,unix,front,cloud-data}"
    echo "Usage: docker compose -f compose.yaml run cloud-builder bash"
    echo "       docker run --rm <image> bash -c 'cd ~/git/cloud && bash build.sh config'"
    ;;
  *)
    exec "$@"
    ;;
esac
