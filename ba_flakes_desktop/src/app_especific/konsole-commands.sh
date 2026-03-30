#!/usr/bin/env bash
# Konsole Quick Commands — all commands live here, nix just calls: bash this.sh <id>
# No escaping hell. Pure bash.
# Every command prints itself (dimmed) so you can copy-paste and re-run.
set -euo pipefail

cmd="$1"; shift || true
vm="${1:-}"; shift || true

# Print the command being run (dimmed gray, copyable)
show() { printf '\033[0;90m$ %s\033[0m\n' "$*"; "$@"; }

case "$cmd" in

  # ── VM commands (require $vm) ───────────────────────────────────────
  vm-htop)              show ssh "$vm" -t htop ;;
  vm-journalctl-f)      show ssh "$vm" -t journalctl -f ;;
  vm-journal-docker)    show ssh "$vm" -t journalctl -u docker -n 15 --no-pager ;;
  vm-journal-sshd)      show ssh "$vm" -t journalctl -u sshd -u ssh -n 15 --no-pager ;;
  vm-journal-wg)        show ssh "$vm" -t journalctl -u wg-quick@wg0 -n 15 --no-pager ;;
  vm-journal-cinit)     show ssh "$vm" -t journalctl -u container-init -n 15 --no-pager ;;
  vm-journal-kernel)    show ssh "$vm" -t journalctl -k -n 15 --no-pager ;;
  vm-journal-errors)    show ssh "$vm" -t journalctl -p err -n 15 --no-pager ;;
  vm-systemctl-status)  show ssh "$vm" -t systemctl status ;;
  vm-systemctl-list)    show ssh "$vm" -t systemctl list-units --type=service --state=running ;;
  vm-docker-start)      show ssh "$vm" -t sudo systemctl start docker ;;
  vm-docker-stop)       show ssh "$vm" -t sudo systemctl stop docker ;;
  vm-docker-ps)
    printf '\033[0;90m$ ssh %s -t docker ps --format "table {{.Names}}\\t{{.Status}}\\t{{.Ports}}"\033[0m\n' "$vm"
    ssh "$vm" -t 'docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
    ;;
  vm-docker-stats)      show ssh "$vm" -t docker stats ;;
  vm-docker-exec)
    printf '\033[0;90m$ ssh %s -t '\''docker ps --format "{{.Names}}" && read -p "Container: " c && docker exec -it "$c" sh'\''\033[0m\n' "$vm"
    ssh "$vm" -t 'docker ps --format "{{.Names}}" && echo "---" && read -p "Container: " c && docker exec -it "$c" sh'
    ;;

  # ── VM cloud control (oci/gcloud per-VM) ─────────────────────────────
  # OCI VM map: ssh_alias → instance_id from cloud-data (no API calls for lookup)
  vm-oci-start|vm-oci-stop|vm-oci-reset)
    ACTION="${cmd#vm-oci-}"
    ACTION_UPPER="$(echo "$ACTION" | tr '[:lower:]' '[:upper:]')"
    printf '\033[0;90m$ oci compute instance action --action %s (%s)\033[0m\n' "$ACTION_UPPER" "$vm"
    CLOUD_DATA="${CLOUD_DATA:-$HOME/git/cloud/cloud-data/_cloud-data-consolidated.json}"
    OCID="$(jq -r ".vms | to_entries[] | select(.value.ssh_alias==\"$vm\") | .value.instance_id" "$CLOUD_DATA" 2>/dev/null)"
    [ -z "$OCID" ] && { echo "Instance not found in cloud-data for: $vm"; exit 1; }
    oci compute instance action --action "$ACTION_UPPER" --instance-id "$OCID" --output table
    ;;
  vm-oci-serial)
    printf '\033[0;90m$ oci serial console → %s\033[0m\n' "$vm"
    CLOUD_DATA="${CLOUD_DATA:-$HOME/git/cloud/cloud-data/_cloud-data-consolidated.json}"
    OCID="$(jq -r ".vms | to_entries[] | select(.value.ssh_alias==\"$vm\") | .value.instance_id" "$CLOUD_DATA" 2>/dev/null)"
    [ -z "$OCID" ] && { echo "Instance not found in cloud-data for: $vm"; exit 1; }
    CID="$(grep tenancy ~/.oci/config | head -1 | cut -d= -f2)"
    # Find or create console connection
    CONN="$(oci compute instance-console-connection list --compartment-id "$CID" --instance-id "$OCID" --output json \
      | jq -r '.data[] | select(."lifecycle-state"=="ACTIVE") | ."connection-string"' | head -1)"
    if [ -z "$CONN" ]; then
      echo "Creating console connection..."
      oci compute instance-console-connection create --instance-id "$OCID" --wait-for-state ACTIVE --output json >/dev/null
      CONN="$(oci compute instance-console-connection list --compartment-id "$CID" --instance-id "$OCID" --output json \
        | jq -r '.data[] | select(."lifecycle-state"=="ACTIVE") | ."connection-string"' | head -1)"
    fi
    [ -z "$CONN" ] && { echo "Failed to get console connection"; exit 1; }
    echo "Connecting to serial console for $vm..."
    # OCI serial needs: ssh-rsa (legacy key), no ControlPath (OCID paths > 108 chars)
    # Both inner (ProxyCommand) and outer SSH must have these flags
    SSH_OPTS="-o ControlPath=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa"
    # The connection string looks like: ssh -o ProxyCommand='ssh -W %h:%p -p 443 <connid>@instance-console...' <instanceid>
    # Replace ALL 'ssh ' with 'ssh <opts> ' to cover both inner and outer
    FIXED_CONN="$(echo "$CONN" | sed "s|ssh -o |ssh $SSH_OPTS -o |g; s|ssh -W |ssh $SSH_OPTS -W |g")"
    eval "$FIXED_CONN"
    ;;
  # GCloud VM control
  vm-gcloud-start)  show gcloud compute instances start "$vm" --zone=us-central1-a ;;
  vm-gcloud-stop)   show gcloud compute instances stop "$vm" --zone=us-central1-a ;;
  vm-gcloud-reset)  show gcloud compute instances reset "$vm" --zone=us-central1-a ;;
  vm-gcloud-serial) show gcloud compute connect-to-serial-port "$vm" --zone=us-central1-a ;;

  # ── Desktop commands ────────────────────────────────────────────────
  dtk)              show bash ~/git/cloud-data/dtk.sh ;;
  dtk-install)      show bash ~/git/cloud-data/dtk.sh install ;;
  dtk-docker)       show bash ~/git/cloud-data/dtk.sh docker-start ;;
  dtk-git-clone)    show bash ~/git/cloud-data/dtk.sh git-clone ~/git ;;
  dtk-info)         show bash ~/git/cloud-data/dtk.sh info ;;
  dtk-commands)     show bash ~/git/cloud-data/dtk.sh commands ;;
  dtk-ssh)          show bash ~/git/cloud-data/dtk.sh ssh ;;
  desktop-htop)     show htop ;;
  hm-switch)        show ~/git/unix/ba_flakes_desktop/build.sh switch ;;
  nixos-switch)     show ~/git/unix/aa_nixos-surface_host/build.sh switch ;;
  git-status-all)
    printf '\033[0;90m$ for d in ~/git/*/; do git -C "$d" status -sb; done\033[0m\n'
    for d in ~/git/*/; do
      echo "=== $(basename "$d") ==="
      git -C "$d" status -sb
      echo
    done
    ;;
  wg-status)        show sudo wg show wg0 ;;
  docker-ps-local)
    printf '\033[0;90m$ docker ps --format '\''table {{.Names}}\\t{{.Status}}\\t{{.Ports}}'\''\033[0m\n'
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    ;;
  free-mem)         show free -h ;;
  disk-usage)       show df -h / /home /nix /mnt/shared 2>/dev/null ;;

  # ── VPS - Cloud ─────────────────────────────────────────────────────
  oci-list)
    printf '\033[0;90m$ oci compute instance list --output table\033[0m\n'
    CID="$(grep tenancy ~/.oci/config | head -1 | cut -d= -f2)"
    oci compute instance list --compartment-id "$CID" --output table \
      --query 'data[*].{Name:"display-name",State:"lifecycle-state",Shape:shape}'
    ;;
  oci-details)
    printf '\033[0;90m$ oci compute instance list --output json | jq ...\033[0m\n'
    CID="$(grep tenancy ~/.oci/config | head -1 | cut -d= -f2)"
    oci compute instance list --compartment-id "$CID" --all --output json \
      | jq '.data[] | {name: ."display-name", state: ."lifecycle-state", shape: .shape, ocpus: ."shape-config".ocpus, memory: ."shape-config"."memory-in-gbs", created: ."time-created"}'
    ;;
  oci-vnics)
    printf '\033[0;90m$ oci compute vnic-attachment list\033[0m\n'
    CID="$(grep tenancy ~/.oci/config | head -1 | cut -d= -f2)"
    oci compute vnic-attachment list --compartment-id "$CID" --all --output json \
      | jq '.data[] | {instance: ."instance-id"[-12:], vnic: ."vnic-id"[-12:], state: ."lifecycle-state"}'
    ;;
  gcloud-list)
    printf '\033[0;90m$ gcloud compute instances list\033[0m\n'
    gcloud compute instances list \
      --format='table(name,zone,machineType.basename(),status,networkInterfaces[0].accessConfigs[0].natIP)'
    ;;
  gcloud-details)
    printf '\033[0;90m$ gcloud compute instances list --format=json | jq ...\033[0m\n'
    gcloud compute instances list --format=json \
      | jq '.[] | {name: .name, zone: .zone, machine: .machineType, status: .status, ip: .networkInterfaces[0].accessConfigs[0].natIP, disks: [.disks[].diskSizeGb]}'
    ;;
  gcloud-billing)
    printf '\033[0;90m$ gcloud billing accounts list + instances + budgets + disks\033[0m\n'
    echo "=== Billing Account ==="
    gcloud billing accounts list --format='table(name,displayName,open)'
    echo
    echo "=== Running Instances ==="
    gcloud compute instances list --format='table(name,zone,machineType.basename(),status)'
    echo
    echo "=== Budgets ==="
    ACCT="$(gcloud billing accounts list --format='value(name)' | head -1)"
    gcloud billing budgets list --billing-account="$ACCT" \
      --format='table(displayName,amount.specifiedAmount.currencyCode,amount.specifiedAmount.units,budgetFilter.calendarPeriod)' \
      2>/dev/null || echo "No budgets or alpha API not enabled"
    echo
    echo "=== Disks ==="
    gcloud compute disks list --format='table(name,zone.basename(),sizeGb,type.basename(),status)'
    ;;

  # ── VPS - GH Actions ───────────────────────────────────────────────
  gha-runs-cloud)     show gh run list --repo diegonmarcos/cloud --limit 15 ;;
  gha-failed-cloud)   show gh run list --repo diegonmarcos/cloud --status failure --limit 10 ;;
  gha-log-cloud)
    printf '\033[0;90m$ gh run view --repo diegonmarcos/cloud --log <latest> | tail -50\033[0m\n'
    RUN_ID="$(gh run list --repo diegonmarcos/cloud --limit 1 --json databaseId --jq '.[0].databaseId')"
    gh run view --repo diegonmarcos/cloud --log "$RUN_ID" 2>/dev/null | tail -50
    ;;
  gha-workflows)      show gh workflow list --repo diegonmarcos/cloud ;;
  gha-runs-unix)      show gh run list --repo diegonmarcos/unix --limit 10 ;;
  gha-runs-front)     show gh run list --repo diegonmarcos/front --limit 10 ;;

  # ── VPS - GH Repos ─────────────────────────────────────────────────
  gh-repos-status)
    printf '\033[0;90m$ gh repo list diegonmarcos --limit 50 | jq ... | column -t\033[0m\n'
    gh repo list diegonmarcos --limit 50 --json name,visibility,pushedAt \
      | jq -r '.[] | [.name, .visibility, .pushedAt[:10]] | @tsv' | sort | column -t
    ;;
  gh-repos-list)      show gh repo list diegonmarcos --limit 50 ;;
  gh-prs)             show gh pr list --repo diegonmarcos/cloud ;;
  gh-issues)          show gh issue list --repo diegonmarcos/cloud ;;
  gh-commits)
    printf '\033[0;90m$ gh api repos/diegonmarcos/{cloud,unix,...}/commits?per_page=3\033[0m\n'
    for r in cloud cloud-data unix vault front-data octocode; do
      echo "=== $r ==="
      gh api "repos/diegonmarcos/$r/commits?per_page=3" \
        --jq '.[] | "  " + .commit.message[:60] + " (" + .commit.author.date[:10] + ")"' \
        2>/dev/null || echo "  NOT FOUND"
      echo
    done
    ;;

  # ── VPS - GH Registry ──────────────────────────────────────────────
  ghcr-list)
    printf '\033[0;90m$ gh api user/packages?package_type=container --jq .[].name\033[0m\n'
    gh api 'user/packages?package_type=container' --jq '.[].name' | sort
    ;;
  ghcr-versions)
    printf '\033[0;90m$ gh api user/packages?package_type=container --jq ...\033[0m\n'
    gh api 'user/packages?package_type=container' \
      --jq '.[] | .name + " (" + .package_type + ") updated: " + .updated_at[:10]' | sort
    ;;
  ghcr-count)
    printf '\033[0;90m$ gh api user/packages?package_type=container --jq ". | length"\033[0m\n'
    echo "Total GHCR packages: $(gh api 'user/packages?package_type=container' --jq '. | length')"
    ;;
  ghcr-inspect)
    printf '\033[0;90m$ gh api user/packages/container/<name>/versions\033[0m\n'
    echo "Package name:"
    read -r pkg
    gh api "user/packages/container/$pkg/versions" \
      --jq '.[] | (.metadata.container.tags // ["untagged"])[0] + " (" + .updated_at[:10] + ")"' \
      2>/dev/null || echo "Not found: $pkg"
    ;;
  ghcr-latest)
    printf '\033[0;90m$ gh api user/packages?package_type=container → versions for each\033[0m\n'
    gh api 'user/packages?package_type=container' --jq '.[].name' | while read -r pkg; do
      latest="$(gh api "user/packages/container/$pkg/versions" --jq '.[0].name // "?"' 2>/dev/null)"
      echo "$pkg: $latest"
    done | sort
    ;;
  ghcr-visibility)
    printf '\033[0;90m$ gh api user/packages?package_type=container --jq ".[] | .name + .visibility"\033[0m\n'
    gh api 'user/packages?package_type=container' \
      --jq '.[] | .name + ": " + .visibility' | sort
    ;;

  *)
    echo "Unknown command: $cmd"
    echo "Usage: $0 <command-id> [vm-alias]"
    exit 1
    ;;
esac
