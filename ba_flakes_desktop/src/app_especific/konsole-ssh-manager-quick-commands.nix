{ config, pkgs, lib, ... }:

# Konsole SSH Manager + Quick Commands plugin configuration
# SSH Manager: connection bookmarks (opens new tab)
# Quick Commands: operation bookmarks (sends to active terminal)
# All Quick Commands are wrapped in bash -c to work from any shell (fish, zsh, etc.)

let
  # ── VM definitions ──────────────────────────────────────────────────────
  vms = [
    { alias = "gcp-proxy";     ip = "10.0.0.1"; user = "diego";  hasDropbear = true;  provider = "gcp"; }
    { alias = "oci-mail";      ip = "10.0.0.3"; user = "ubuntu"; hasDropbear = true;  provider = "oci"; }
    { alias = "oci-analytics"; ip = "10.0.0.4"; user = "ubuntu"; hasDropbear = true;  provider = "oci"; }
    { alias = "oci-apps";      ip = "10.0.0.6"; user = "ubuntu"; hasDropbear = true;  provider = "oci"; }
    { alias = "gcp-t4";        ip = "10.0.0.8"; user = "diego";  hasDropbear = false; provider = "gcp"; }
  ];

  sshKey = "/home/diego/.ssh/id_rsa";

  # ── SSH Manager: konsolesshconfig ───────────────────────────────────────

  mkSshEntry = folder: id: { hostname, port ? 22, user, useSshConfig ? true }: ''

    [${folder}][${id}]
    hostname=${hostname}
    identifier=${id}
    port=${toString port}
    profileName=Profile 1
    sshkey=${sshKey}
    useSshConfig=${if useSshConfig then "true" else "false"}
    username=${user}
  '';

  mkSshVmEntries = vm: let
    f = vm.alias;
  in
    (mkSshEntry f "SSH (port 22)" {
      hostname = vm.ip; user = vm.user;
    })
    + (lib.optionalString vm.hasDropbear
      (mkSshEntry f "SSH Dropbear (port 2200)" {
        hostname = vm.ip; port = 2200; user = vm.user; useSshConfig = false;
      }))
    + (lib.optionalString (vm.provider == "gcp")
      (mkSshEntry f "GCloud Serial Console" {
        hostname = vm.ip; user = vm.user;
      }))
    + (lib.optionalString (vm.provider == "oci")
      (mkSshEntry f "OCI Serial Console" {
        hostname = vm.ip; user = vm.user;
      }));

  sshConfig = ''
    [Global plugin config]
    manageProfile=false
  ''
  + builtins.concatStringsSep "" (map mkSshVmEntries vms)
  + mkSshEntry "Git" "github.com" {
      hostname = "github.com"; user = "git";
    };

  # ── Quick Commands: konsolequickcommandsconfig ──────────────────────────
  # All commands use POSIX bash syntax, wrapped in bash -c for shell independence

  # Escape single quotes for bash -c '...' wrapping: ' → '\''
  esc = builtins.replaceStrings ["'"] ["'\\''"];

  mkQuickCmd = folder: id: { command, tooltip ? "" }: ''

    [${folder}][${id}]
    command=bash -c '${esc command}'
    name=${id}
    tooltip=${tooltip}
  '';

  mkQuickVmEntries = vm: let
    f = "VM - ${vm.alias}";
    s = "ssh ${vm.alias} -t";
  in
    # System
    (mkQuickCmd f "htop" {
      command = "${s} htop";
      tooltip = "Interactive process viewer";
    })
    + (mkQuickCmd f "journalctl -f" {
      command = "${s} journalctl -f";
      tooltip = "Follow system journal";
    })
    + (mkQuickCmd f "journal-watch docker" {
      command = "${s} journalctl -u docker -n 15 --no-pager";
      tooltip = "Last 15 lines of Docker daemon journal";
    })
    + (mkQuickCmd f "journal-watch sshd" {
      command = "${s} journalctl -u sshd -u ssh -n 15 --no-pager";
      tooltip = "Last 15 lines of SSH daemon journal";
    })
    + (mkQuickCmd f "journal-watch wireguard" {
      command = "${s} journalctl -u wg-quick@wg0 -n 15 --no-pager";
      tooltip = "Last 15 lines of WireGuard journal";
    })
    + (mkQuickCmd f "journal-watch container-init" {
      command = "${s} journalctl -u container-init -n 15 --no-pager";
      tooltip = "Last 15 lines of container-init boot journal";
    })
    + (mkQuickCmd f "journal-watch kernel" {
      command = "${s} journalctl -k -n 15 --no-pager";
      tooltip = "Last 15 kernel messages";
    })
    + (mkQuickCmd f "journal-watch errors" {
      command = "${s} journalctl -p err -n 15 --no-pager";
      tooltip = "Last 15 error-level journal entries";
    })
    + (mkQuickCmd f "systemctl status" {
      command = "${s} systemctl status";
      tooltip = "Show systemd status overview";
    })
    + (mkQuickCmd f "systemctl list-units" {
      command = "${s} systemctl list-units --type=service --state=running";
      tooltip = "List running systemd services";
    })
    + (mkQuickCmd f "docker daemon start" {
      command = "${s} sudo systemctl start docker";
      tooltip = "Start Docker daemon";
    })
    + (mkQuickCmd f "docker daemon stop" {
      command = "${s} sudo systemctl stop docker";
      tooltip = "Stop Docker daemon";
    })
    # Docker
    + (mkQuickCmd f "docker ps" {
      command = ''${s} docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'';
      tooltip = "List running containers";
    })
    + (mkQuickCmd f "docker stats" {
      command = "${s} docker stats";
      tooltip = "Live container resource usage";
    })
    + (mkQuickCmd f "docker exec" {
      command = ''${s} "docker ps --format '{{.Names}}' && echo --- && read -p 'Container: ' c && docker exec -it \$c sh"'';
      tooltip = "Pick a container and exec into it";
    });

  # ── Desktop: local bootstrap commands ─────────────────────────────────

  aliasScript = "~/git/cloud-data/dtk.sh";

  desktopCommands =
    (mkQuickCmd "Desktop" "dtk.sh (interactive)" {
      command = "bash ${aliasScript}";
      tooltip = "Full interactive toolkit menu";
    })
    + (mkQuickCmd "Desktop" "install dev toolchain" {
      command = "bash ${aliasScript} install";
      tooltip = "Install full dev environment for detected OS";
    })
    + (mkQuickCmd "Desktop" "docker-start (dev container)" {
      command = "bash ${aliasScript} docker-start";
      tooltip = "Pull and run diego-user-env container";
    })
    + (mkQuickCmd "Desktop" "git-clone (all repos)" {
      command = "bash ${aliasScript} git-clone ~/git";
      tooltip = "Clone/pull all 5 repos to ~/git";
    })
    + (mkQuickCmd "Desktop" "info (installed tools)" {
      command = "bash ${aliasScript} info";
      tooltip = "Show installed tools and aliases";
    })
    + (mkQuickCmd "Desktop" "commands (VM rescue)" {
      command = "bash ${aliasScript} commands";
      tooltip = "Quick rescue commands menu";
    })
    + (mkQuickCmd "Desktop" "ssh (gcloud serial/rescue)" {
      command = "bash ${aliasScript} ssh";
      tooltip = "SSH via gcloud with serial/rescue modes";
    })
    # Direct useful commands
    + (mkQuickCmd "Desktop" "htop" {
      command = "htop";
      tooltip = "Local interactive process viewer";
    })
    + (mkQuickCmd "Desktop" "hm build switch" {
      command = "~/git/unix/ba_flakes_desktop/build.sh switch";
      tooltip = "Rebuild and switch home-manager desktop flake";
    })
    + (mkQuickCmd "Desktop" "nixos rebuild switch" {
      command = "~/git/unix/aa_nixos-surface_host/build.sh switch";
      tooltip = "Rebuild and switch NixOS system flake";
    })
    + (mkQuickCmd "Desktop" "git status (all repos)" {
      command = ''for d in ~/git/*/; do echo "=== $(basename "$d") ==="; git -C "$d" status -sb; echo; done'';
      tooltip = "Show git status across all repos";
    })
    + (mkQuickCmd "Desktop" "wg status" {
      command = "sudo wg show wg0";
      tooltip = "Show WireGuard tunnel status";
    })
    + (mkQuickCmd "Desktop" "docker ps (local)" {
      command = ''docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'';
      tooltip = "List local running containers";
    })
    + (mkQuickCmd "Desktop" "free memory" {
      command = "free -h";
      tooltip = "Show memory usage";
    })
    + (mkQuickCmd "Desktop" "disk usage" {
      command = "df -h / /home /nix /mnt/shared 2>/dev/null";
      tooltip = "Show disk usage for key partitions";
    });

  # ── VPS: cloud provider CLI commands ──────────────────────────────────

  vpsCommands =
    # OCI
    (mkQuickCmd "VPS - Cloud" "oci — list instances" {
      command = ''CID="$(oci iam compartment list --query "data[0].id" --raw-output)"; oci compute instance list --compartment-id "$CID" --output table --query "data[*].{Name:\"display-name\",State:\"lifecycle-state\",Shape:shape}"'';
      tooltip = "List all OCI compute instances";
    })
    + (mkQuickCmd "VPS - Cloud" "oci — instance details (all)" {
      command = ''CID="$(oci iam compartment list --query "data[0].id" --raw-output)"; oci compute instance list --compartment-id "$CID" --all --output json | jq ".data[] | {name: .\"display-name\", state: .\"lifecycle-state\", shape: .shape, ocpus: .\"shape-config\".ocpus, memory: .\"shape-config\".\"memory-in-gbs\", created: .\"time-created\"}"'';
      tooltip = "Full JSON details for all OCI instances";
    })
    + (mkQuickCmd "VPS - Cloud" "oci — vnic/IP list" {
      command = ''CID="$(oci iam compartment list --query "data[0].id" --raw-output)"; oci network vnic list --compartment-id "$CID" --all --output table --query "data[*].{Name:\"display-name\",PublicIP:\"public-ip\",PrivateIP:\"private-ip\",State:\"lifecycle-state\"}"'';
      tooltip = "List all OCI VNICs with public/private IPs";
    })
    # GCloud
    + (mkQuickCmd "VPS - Cloud" "gcloud — list instances" {
      command = "gcloud compute instances list --format=\"table(name,zone,machineType.basename(),status,networkInterfaces[0].accessConfigs[0].natIP)\"";
      tooltip = "List all GCP compute instances";
    })
    + (mkQuickCmd "VPS - Cloud" "gcloud — instance details" {
      command = ''gcloud compute instances list --format=json | jq ".[] | {name: .name, zone: .zone, machine: .machineType, status: .status, ip: .networkInterfaces[0].accessConfigs[0].natIP, disks: [.disks[].diskSizeGb]}"'';
      tooltip = "Full JSON details for all GCP instances";
    })
    + (mkQuickCmd "VPS - Cloud" "gcloud — billing + costs" {
      command = ''echo "=== Billing Account ==="; gcloud billing accounts list --format="table(name,displayName,open)"; echo; echo "=== Running Instances ==="; gcloud compute instances list --format="table(name,zone,machineType.basename(),status)"; echo; echo "=== Budgets ==="; ACCT="$(gcloud billing accounts list --format="value(name)" | head -1)"; gcloud billing budgets list --billing-account="$ACCT" --format="table(displayName,amount.specifiedAmount.currencyCode,amount.specifiedAmount.units,budgetFilter.calendarPeriod)" 2>/dev/null || echo "No budgets or alpha API not enabled"; echo; echo "=== Disks ==="; gcloud compute disks list --format="table(name,zone.basename(),sizeGb,type.basename(),status)"'';
      tooltip = "GCP billing account, running instances, budgets, disks";
    })
    # GitHub Actions
    + (mkQuickCmd "VPS - GH Actions" "runs — recent (cloud)" {
      command = "gh run list --repo diegonmarcos/cloud --limit 15";
      tooltip = "Last 15 GitHub Actions runs for cloud repo";
    })
    + (mkQuickCmd "VPS - GH Actions" "runs — failed (cloud)" {
      command = "gh run list --repo diegonmarcos/cloud --status failure --limit 10";
      tooltip = "Recent failed GitHub Actions runs";
    })
    + (mkQuickCmd "VPS - GH Actions" "runs — latest log (cloud)" {
      command = ''gh run view --repo diegonmarcos/cloud --log "$(gh run list --repo diegonmarcos/cloud --limit 1 --json databaseId --jq ".[0].databaseId")" 2>/dev/null | tail -50'';
      tooltip = "Last 50 lines of the most recent GHA run";
    })
    + (mkQuickCmd "VPS - GH Actions" "workflows — list (cloud)" {
      command = "gh workflow list --repo diegonmarcos/cloud";
      tooltip = "List all GitHub Actions workflows";
    })
    + (mkQuickCmd "VPS - GH Actions" "runs — recent (unix)" {
      command = "gh run list --repo diegonmarcos/unix --limit 10";
      tooltip = "Last 10 GitHub Actions runs for unix repo";
    })
    + (mkQuickCmd "VPS - GH Actions" "runs — recent (front)" {
      command = "gh run list --repo diegonmarcos/front --limit 10";
      tooltip = "Last 10 GitHub Actions runs for front repo";
    })
    # GitHub Repos
    + (mkQuickCmd "VPS - GH Repos" "status — all repos" {
      command = ''for r in cloud cloud-data unix vault; do echo "=== $r ==="; gh api "repos/diegonmarcos/$r" --jq "{pushed: .pushed_at, default: .default_branch, visibility: .visibility}" 2>/dev/null || echo "NOT FOUND"; echo; done'';
      tooltip = "Push date and visibility for all repos";
    })
    + (mkQuickCmd "VPS - GH Repos" "PRs — open (cloud)" {
      command = "gh pr list --repo diegonmarcos/cloud";
      tooltip = "Open pull requests in cloud repo";
    })
    + (mkQuickCmd "VPS - GH Repos" "issues — open (cloud)" {
      command = "gh issue list --repo diegonmarcos/cloud";
      tooltip = "Open issues in cloud repo";
    })
    + (mkQuickCmd "VPS - GH Repos" "packages — GHCR list" {
      command = ''gh api "user/packages?package_type=container" --jq ".[].name" | sort'';
      tooltip = "List all GHCR container packages";
    })
    + (mkQuickCmd "VPS - GH Repos" "recent commits — all repos" {
      command = ''for r in cloud cloud-data unix vault; do echo "=== $r ==="; gh api "repos/diegonmarcos/$r/commits?per_page=3" --jq ".[] | \"  \" + .commit.message[:60] + \" (\" + .commit.author.date[:10] + \")\"" 2>/dev/null || echo "  NOT FOUND"; echo; done'';
      tooltip = "Last 3 commits per repo";
    });

  quickCommandsConfig = builtins.concatStringsSep "" (map mkQuickVmEntries vms) + desktopCommands + vpsCommands;

in {
  # SSH Manager sidebar — connection bookmarks
  home.file.".config/konsolesshconfig".text = sshConfig;

  # Quick Commands sidebar — operation bookmarks
  home.file.".config/konsolequickcommandsconfig".text = quickCommandsConfig;
}
