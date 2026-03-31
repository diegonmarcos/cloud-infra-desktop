#!/usr/bin/env bash
# Konsole Quick Commands — all commands live here, nix just calls: bash this.sh <id>
# No escaping hell. Pure bash.
# Every command prints itself (dimmed) so you can copy-paste and re-run.
set -euxo pipefail  # -x = verbose: print every command before execution
export BUILDSH_GUARDRAIL=1  # All commands here are intentional — bypass guardrail prompts

# Commands that need root use sudo inline — script runs as calling user

cmd="$1"; shift || true
vm="${1:-}"; shift || true

# Print the command being run (dimmed gray, copyable)
show() { printf '\033[0;90m$ %s\033[0m\n' "$*"; "$@"; }

case "$cmd" in

  # ── VM commands (require $vm) ───────────────────────────────────────
  vm-htop)              show ssh "$vm" -t htop ;;
  vm-journalctl-f)      show ssh "$vm" -t sudo journalctl -f ;;
  vm-journal-docker)    show ssh "$vm" -t sudo journalctl -u docker -n 15 --no-pager ;;
  vm-journal-sshd)      show ssh "$vm" -t sudo journalctl -u sshd -u ssh -n 15 --no-pager ;;
  vm-journal-wg)        show ssh "$vm" -t sudo journalctl -u wg-quick@wg0 -n 15 --no-pager ;;
  vm-journal-cinit)     show ssh "$vm" -t sudo journalctl -u container-init -n 15 --no-pager ;;
  vm-journal-kernel)    show ssh "$vm" -t sudo journalctl -k -n 15 --no-pager ;;
  vm-journal-errors)    show ssh "$vm" -t sudo journalctl -p err -n 15 --no-pager ;;
  vm-systemctl-status)  show ssh "$vm" -t sudo systemctl status ;;
  vm-systemctl-list)    show ssh "$vm" -t sudo systemctl list-units --type=service --state=running ;;
  vm-docker-start)
    show ssh "$vm" -t 'sudo systemctl start docker && systemctl status docker --no-pager -l'
    ;;
  vm-docker-stop)
    show ssh "$vm" -t 'sudo systemctl stop docker && echo "Docker stopped" && systemctl is-active docker || true'
    ;;
  vm-docker-ps)
    printf '\033[0;90m$ ssh %s -t sudo docker ps --format "table {{.Names}}\\t{{.Status}}\\t{{.Ports}}"\033[0m\n' "$vm"
    ssh "$vm" -t 'sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
    ;;
  vm-docker-stats)      show ssh "$vm" -t sudo docker stats ;;
  vm-docker-exec)
    printf '\033[0;90m$ ssh %s -t '\''sudo docker ps --format "{{.Names}}" && read -p "Container: " c && sudo docker exec -it "$c" sh'\''\033[0m\n' "$vm"
    ssh "$vm" -t 'sudo docker ps --format "{{.Names}}" && echo "---" && read -p "Container: " c && sudo docker exec -it "$c" sh'
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
      oci compute instance-console-connection create --instance-id "$OCID" --ssh-public-key-file ~/.ssh/id_rsa.pub --wait-for-state ACTIVE --output json >/dev/null
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

  # ── Orchestration commands (run on ALL VMs) ─────────────────────────
  all-script-push)
    ALL_VMS="gcp-proxy oci-mail oci-analytics oci-apps gcp-t4"
    RAW_URL="https://raw.githubusercontent.com/diegonmarcos/unix/main/ba_flakes_desktop/src/app_especific/konsole-commands.sh"
    for v in $ALL_VMS; do
      printf '\033[1;36m══ %s ══\033[0m\n' "$v"
      ssh "$v" "mkdir -p ~/.local/share/konsole && curl -fsSL '$RAW_URL' -o ~/.local/share/konsole/konsole-commands.sh && chmod +x ~/.local/share/konsole/konsole-commands.sh && echo 'Done'" 2>&1 || printf '\033[0;31m  [FAILED]\033[0m\n'
      echo
    done
    ;;
  all-*)
    SUB="${cmd#all-}"
    ALL_VMS="gcp-proxy oci-mail oci-analytics oci-apps gcp-t4"
    for v in $ALL_VMS; do
      printf '\033[1;36m══ %s ══\033[0m\n' "$v"
      bash "$0" "vm-${SUB}" "$v" 2>&1 || printf '\033[0;31m  [FAILED]\033[0m\n'
      echo
    done
    ;;

  # ── Local commands (same as VM but run directly) ────────────────────
  local-htop)              show htop ;;
  local-journalctl-f)      show sudo journalctl -f ;;
  local-journal-docker)    show sudo journalctl -u docker -n 15 --no-pager ;;
  local-journal-sshd)      show sudo journalctl -u sshd -u ssh -n 15 --no-pager ;;
  local-journal-wg)        show sudo journalctl -u wg-quick@wg0 -n 15 --no-pager ;;
  local-journal-cinit)     show sudo journalctl -u container-init -n 15 --no-pager ;;
  local-journal-kernel)    show sudo journalctl -k -n 15 --no-pager ;;
  local-journal-errors)    show sudo journalctl -p err -n 15 --no-pager ;;
  local-systemctl-status)  show sudo systemctl status ;;
  local-systemctl-list)    show sudo systemctl list-units --type=service --state=running ;;
  local-docker-start)
    show sudo systemctl start docker
    sudo systemctl status docker --no-pager -l
    ;;
  local-docker-stop)
    show sudo systemctl stop docker
    echo "Docker stopped"
    sudo systemctl is-active docker || true
    ;;
  local-docker-ps)
    printf '\033[0;90m$ sudo docker ps --format "table {{.Names}}\\t{{.Status}}\\t{{.Ports}}"\033[0m\n'
    sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    ;;
  local-docker-stats)      show sudo docker stats ;;
  local-docker-exec)
    printf '\033[0;90m$ sudo docker ps + exec\033[0m\n'
    sudo docker ps --format "{{.Names}}" && echo "---" && read -rp "Container: " c && sudo docker exec -it "$c" sh
    ;;

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
    printf '\033[0;90m$ sudo docker ps --format '\''table {{.Names}}\\t{{.Status}}\\t{{.Ports}}'\''\033[0m\n'
    sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
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
