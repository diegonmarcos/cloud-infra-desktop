#!/usr/bin/env bash
# Konsole Quick Commands — all commands live here, nix just calls: bash this.sh <id>
# No escaping hell. Pure bash.
set -euo pipefail

cmd="$1"; shift || true
vm="${1:-}"; shift || true

case "$cmd" in

  # ── VM commands (require $vm) ───────────────────────────────────────
  vm-htop)              ssh "$vm" -t htop ;;
  vm-journalctl-f)      ssh "$vm" -t journalctl -f ;;
  vm-journal-docker)    ssh "$vm" -t journalctl -u docker -n 15 --no-pager ;;
  vm-journal-sshd)      ssh "$vm" -t journalctl -u sshd -u ssh -n 15 --no-pager ;;
  vm-journal-wg)        ssh "$vm" -t journalctl -u wg-quick@wg0 -n 15 --no-pager ;;
  vm-journal-cinit)     ssh "$vm" -t journalctl -u container-init -n 15 --no-pager ;;
  vm-journal-kernel)    ssh "$vm" -t journalctl -k -n 15 --no-pager ;;
  vm-journal-errors)    ssh "$vm" -t journalctl -p err -n 15 --no-pager ;;
  vm-systemctl-status)  ssh "$vm" -t systemctl status ;;
  vm-systemctl-list)    ssh "$vm" -t systemctl list-units --type=service --state=running ;;
  vm-docker-start)      ssh "$vm" -t sudo systemctl start docker ;;
  vm-docker-stop)       ssh "$vm" -t sudo systemctl stop docker ;;
  vm-docker-ps)         ssh "$vm" -t 'docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"' ;;
  vm-docker-stats)      ssh "$vm" -t docker stats ;;
  vm-docker-exec)       ssh "$vm" -t 'docker ps --format "{{.Names}}" && echo "---" && read -p "Container: " c && docker exec -it "$c" sh' ;;

  # ── Desktop commands ────────────────────────────────────────────────
  dtk)              bash ~/git/cloud-data/dtk.sh ;;
  dtk-install)      bash ~/git/cloud-data/dtk.sh install ;;
  dtk-docker)       bash ~/git/cloud-data/dtk.sh docker-start ;;
  dtk-git-clone)    bash ~/git/cloud-data/dtk.sh git-clone ~/git ;;
  dtk-info)         bash ~/git/cloud-data/dtk.sh info ;;
  dtk-commands)     bash ~/git/cloud-data/dtk.sh commands ;;
  dtk-ssh)          bash ~/git/cloud-data/dtk.sh ssh ;;
  desktop-htop)     htop ;;
  hm-switch)        ~/git/unix/ba_flakes_desktop/build.sh switch ;;
  nixos-switch)     ~/git/unix/aa_nixos-surface_host/build.sh switch ;;
  git-status-all)
    for d in ~/git/*/; do
      echo "=== $(basename "$d") ==="
      git -C "$d" status -sb
      echo
    done
    ;;
  wg-status)        sudo wg show wg0 ;;
  docker-ps-local)  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' ;;
  free-mem)         free -h ;;
  disk-usage)       df -h / /home /nix /mnt/shared 2>/dev/null ;;

  # ── VPS - Cloud ─────────────────────────────────────────────────────
  oci-list)
    CID="$(oci iam compartment list --query 'data[0].id' --raw-output)"
    oci compute instance list --compartment-id "$CID" --output table \
      --query 'data[*].{Name:"display-name",State:"lifecycle-state",Shape:shape}'
    ;;
  oci-details)
    CID="$(oci iam compartment list --query 'data[0].id' --raw-output)"
    oci compute instance list --compartment-id "$CID" --all --output json \
      | jq '.data[] | {name: ."display-name", state: ."lifecycle-state", shape: .shape, ocpus: ."shape-config".ocpus, memory: ."shape-config"."memory-in-gbs", created: ."time-created"}'
    ;;
  oci-vnics)
    CID="$(oci iam compartment list --query 'data[0].id' --raw-output)"
    oci network vnic list --compartment-id "$CID" --all --output table \
      --query 'data[*].{Name:"display-name",PublicIP:"public-ip",PrivateIP:"private-ip",State:"lifecycle-state"}'
    ;;
  gcloud-list)
    gcloud compute instances list \
      --format='table(name,zone,machineType.basename(),status,networkInterfaces[0].accessConfigs[0].natIP)'
    ;;
  gcloud-details)
    gcloud compute instances list --format=json \
      | jq '.[] | {name: .name, zone: .zone, machine: .machineType, status: .status, ip: .networkInterfaces[0].accessConfigs[0].natIP, disks: [.disks[].diskSizeGb]}'
    ;;
  gcloud-billing)
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
  gha-runs-cloud)     gh run list --repo diegonmarcos/cloud --limit 15 ;;
  gha-failed-cloud)   gh run list --repo diegonmarcos/cloud --status failure --limit 10 ;;
  gha-log-cloud)
    RUN_ID="$(gh run list --repo diegonmarcos/cloud --limit 1 --json databaseId --jq '.[0].databaseId')"
    gh run view --repo diegonmarcos/cloud --log "$RUN_ID" 2>/dev/null | tail -50
    ;;
  gha-workflows)      gh workflow list --repo diegonmarcos/cloud ;;
  gha-runs-unix)      gh run list --repo diegonmarcos/unix --limit 10 ;;
  gha-runs-front)     gh run list --repo diegonmarcos/front --limit 10 ;;

  # ── VPS - GH Repos ─────────────────────────────────────────────────
  gh-repos-status)
    gh repo list diegonmarcos --limit 50 --json name,visibility,pushedAt \
      | jq -r '.[] | [.name, .visibility, .pushedAt[:10]] | @tsv' | sort | column -t
    ;;
  gh-repos-list)      gh repo list diegonmarcos --limit 50 ;;
  gh-prs)             gh pr list --repo diegonmarcos/cloud ;;
  gh-issues)          gh issue list --repo diegonmarcos/cloud ;;
  gh-commits)
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
    gh api 'user/packages?package_type=container' --jq '.[].name' | sort
    ;;
  ghcr-versions)
    gh api 'user/packages?package_type=container' \
      --jq '.[] | .name + " (" + .package_type + ") updated: " + .updated_at[:10]' | sort
    ;;
  ghcr-count)
    echo "Total GHCR packages: $(gh api 'user/packages?package_type=container' --jq '. | length')"
    ;;
  ghcr-inspect)
    echo "Package name:"
    read -r pkg
    gh api "user/packages/container/$pkg/versions" \
      --jq '.[] | (.metadata.container.tags // ["untagged"])[0] + " (" + .updated_at[:10] + ")"' \
      2>/dev/null || echo "Not found: $pkg"
    ;;
  ghcr-latest)
    gh api 'user/packages?package_type=container' --jq '.[].name' | while read -r pkg; do
      latest="$(gh api "user/packages/container/$pkg/versions" --jq '.[0].name // "?"' 2>/dev/null)"
      echo "$pkg: $latest"
    done | sort
    ;;
  ghcr-visibility)
    gh api 'user/packages?package_type=container' \
      --jq '.[] | .name + ": " + .visibility' | sort
    ;;

  *)
    echo "Unknown command: $cmd"
    echo "Usage: $0 <command-id> [vm-alias]"
    exit 1
    ;;
esac
