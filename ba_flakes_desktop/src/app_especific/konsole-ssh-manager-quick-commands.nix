{ config, pkgs, lib, ... }:

# Konsole SSH Manager + Quick Commands plugin configuration
# SSH Manager: connection bookmarks (opens new tab)
# Quick Commands: operation bookmarks (sends to active terminal)
# All commands delegate to konsole-commands.sh — zero escaping in nix

let
  # ── VM definitions ──────────────────────────────────────────────────────
  vms = [
    { alias = "gcp-proxy";     ip = "10.0.0.1"; user = "diego";  hasDropbear = true;  provider = "gcp"; gcInstance = "arch-1"; gcZone = "us-central1-a"; }
    { alias = "oci-mail";      ip = "10.0.0.3"; user = "ubuntu"; hasDropbear = true;  provider = "oci"; gcInstance = ""; gcZone = ""; }
    { alias = "oci-analytics"; ip = "10.0.0.4"; user = "ubuntu"; hasDropbear = true;  provider = "oci"; gcInstance = ""; gcZone = ""; }
    { alias = "oci-apps";      ip = "10.0.0.6"; user = "ubuntu"; hasDropbear = true;  provider = "oci"; gcInstance = ""; gcZone = ""; }
    { alias = "gcp-t4";        ip = "10.0.0.8"; user = "diego";  hasDropbear = false; provider = "gcp"; gcInstance = "ollama-spot-gpu"; gcZone = "us-central1-a"; }
  ];

  sshKey = "/home/diego/.ssh/id_rsa";
  cmd = "bash ~/.local/share/konsole/konsole-commands.sh";

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
    # Serial consoles are in Quick Commands (require proxy/script, not simple SSH)
    ;

  sshConfig = ''
    [Global plugin config]
    manageProfile=false
  ''
  + builtins.concatStringsSep "" (map mkSshVmEntries vms)
  + mkSshEntry "Git" "github.com" {
      hostname = "github.com"; user = "git";
    };

  # ── Quick Commands: konsolequickcommandsconfig ──────────────────────────

  mkQuickCmd = folder: id: cmdId: tooltip: ''

    [${folder}][${id}]
    command=${cmdId}
    name=${id}
    tooltip=${tooltip}
  '';

  mkQuickVmEntries = vm: let
    f = "VM - ${vm.alias}";
    c = "${cmd} vm";
    v = vm.alias;
  in
    (mkQuickCmd f "htop"                    "${c}-htop ${v}"              "Interactive process viewer")
    + (mkQuickCmd f "journalctl -f"         "${c}-journalctl-f ${v}"     "Follow system journal")
    + (mkQuickCmd f "journal-watch docker"  "${c}-journal-docker ${v}"   "Last 15 lines of Docker daemon journal")
    + (mkQuickCmd f "journal-watch sshd"    "${c}-journal-sshd ${v}"     "Last 15 lines of SSH daemon journal")
    + (mkQuickCmd f "journal-watch wg"      "${c}-journal-wg ${v}"       "Last 15 lines of WireGuard journal")
    + (mkQuickCmd f "journal-watch cinit"   "${c}-journal-cinit ${v}"    "Last 15 lines of container-init journal")
    + (mkQuickCmd f "journal-watch kernel"  "${c}-journal-kernel ${v}"   "Last 15 kernel messages")
    + (mkQuickCmd f "journal-watch errors"  "${c}-journal-errors ${v}"   "Last 15 error-level journal entries")
    + (mkQuickCmd f "systemctl status"      "${c}-systemctl-status ${v}" "Show systemd status overview")
    + (mkQuickCmd f "systemctl list-units"  "${c}-systemctl-list ${v}"   "List running systemd services")
    + (mkQuickCmd f "docker daemon start"   "${c}-docker-start ${v}"     "Start Docker daemon")
    + (mkQuickCmd f "docker daemon stop"    "${c}-docker-stop ${v}"      "Stop Docker daemon")
    + (mkQuickCmd f "docker ps"             "${c}-docker-ps ${v}"        "List running containers")
    + (mkQuickCmd f "docker stats"          "${c}-docker-stats ${v}"     "Live container resource usage")
    + (mkQuickCmd f "docker exec"           "${c}-docker-exec ${v}"      "Pick a container and exec into it")
    # Cloud control (per-VM)
    + (if vm.provider == "oci" then
      (mkQuickCmd f "oci start"   "${cmd} vm-oci-start ${v}"   "Start OCI instance")
      + (mkQuickCmd f "oci stop"   "${cmd} vm-oci-stop ${v}"    "Stop OCI instance")
      + (mkQuickCmd f "oci reset"  "${cmd} vm-oci-reset ${v}"   "Reset OCI instance")
      + (mkQuickCmd f "oci serial" "${cmd} vm-oci-serial ${v}"  "OCI serial console")
    else
      (mkQuickCmd f "gcloud start"  "${cmd} vm-gcloud-start ${vm.gcInstance}"  "Start GCP instance")
      + (mkQuickCmd f "gcloud stop"  "${cmd} vm-gcloud-stop ${vm.gcInstance}"   "Stop GCP instance")
      + (mkQuickCmd f "gcloud reset" "${cmd} vm-gcloud-reset ${vm.gcInstance}"  "Reset GCP instance")
      + (mkQuickCmd f "gcloud serial" "${cmd} vm-gcloud-serial ${vm.gcInstance}" "GCloud serial console")
    );

  desktopCommands =
    (mkQuickCmd "Desktop" "dtk.sh (interactive)"      "${cmd} dtk"            "Full interactive toolkit menu")
    + (mkQuickCmd "Desktop" "install dev toolchain"   "${cmd} dtk-install"    "Install full dev environment for detected OS")
    + (mkQuickCmd "Desktop" "docker-start (dev container)" "${cmd} dtk-docker" "Pull and run diego-user-env container")
    + (mkQuickCmd "Desktop" "git-clone (all repos)"   "${cmd} dtk-git-clone"  "Clone/pull all 5 repos to ~/git")
    + (mkQuickCmd "Desktop" "info (installed tools)"  "${cmd} dtk-info"       "Show installed tools and aliases")
    + (mkQuickCmd "Desktop" "commands (VM rescue)"    "${cmd} dtk-commands"   "Quick rescue commands menu")
    + (mkQuickCmd "Desktop" "ssh (gcloud serial)"     "${cmd} dtk-ssh"        "SSH via gcloud with serial/rescue modes")
    + (mkQuickCmd "Desktop" "htop"                    "${cmd} desktop-htop"   "Local interactive process viewer")
    + (mkQuickCmd "Desktop" "hm build switch"         "${cmd} hm-switch"      "Rebuild and switch home-manager desktop flake")
    + (mkQuickCmd "Desktop" "nixos rebuild switch"    "${cmd} nixos-switch"   "Rebuild and switch NixOS system flake")
    + (mkQuickCmd "Desktop" "git status (all repos)"  "${cmd} git-status-all" "Show git status across all repos")
    + (mkQuickCmd "Desktop" "wg status"               "${cmd} wg-status"      "Show WireGuard tunnel status")
    + (mkQuickCmd "Desktop" "docker ps (local)"       "${cmd} docker-ps-local" "List local running containers")
    + (mkQuickCmd "Desktop" "free memory"             "${cmd} free-mem"       "Show memory usage")
    + (mkQuickCmd "Desktop" "disk usage"              "${cmd} disk-usage"     "Show disk usage for key partitions");

  vpsCommands =
    # Cloud
    (mkQuickCmd "VPS - Cloud" "oci — list instances"      "${cmd} oci-list"       "List all OCI compute instances")
    + (mkQuickCmd "VPS - Cloud" "oci — instance details"  "${cmd} oci-details"    "Full JSON details for all OCI instances")
    + (mkQuickCmd "VPS - Cloud" "oci — vnic/IP list"      "${cmd} oci-vnics"      "List all OCI VNICs with public/private IPs")
    + (mkQuickCmd "VPS - Cloud" "gcloud — list instances"  "${cmd} gcloud-list"    "List all GCP compute instances")
    + (mkQuickCmd "VPS - Cloud" "gcloud — instance details" "${cmd} gcloud-details" "Full JSON details for all GCP instances")
    + (mkQuickCmd "VPS - Cloud" "gcloud — billing + costs" "${cmd} gcloud-billing" "GCP billing, instances, budgets, disks")
    # GH Actions
    + (mkQuickCmd "VPS - GH Actions" "runs — recent (cloud)"   "${cmd} gha-runs-cloud"   "Last 15 GitHub Actions runs for cloud repo")
    + (mkQuickCmd "VPS - GH Actions" "runs — failed (cloud)"   "${cmd} gha-failed-cloud"  "Recent failed GitHub Actions runs")
    + (mkQuickCmd "VPS - GH Actions" "runs — latest log"       "${cmd} gha-log-cloud"     "Last 50 lines of the most recent GHA run")
    + (mkQuickCmd "VPS - GH Actions" "workflows — list"        "${cmd} gha-workflows"     "List all GitHub Actions workflows")
    + (mkQuickCmd "VPS - GH Actions" "runs — recent (unix)"    "${cmd} gha-runs-unix"     "Last 10 GitHub Actions runs for unix repo")
    + (mkQuickCmd "VPS - GH Actions" "runs — recent (front)"   "${cmd} gha-runs-front"    "Last 10 GitHub Actions runs for front repo")
    # GH Repos
    + (mkQuickCmd "VPS - GH Repos" "status — all repos"       "${cmd} gh-repos-status"   "Push date and visibility for all repos")
    + (mkQuickCmd "VPS - GH Repos" "list — all repos"         "${cmd} gh-repos-list"     "List all GitHub repos with description")
    + (mkQuickCmd "VPS - GH Repos" "PRs — open (cloud)"       "${cmd} gh-prs"            "Open pull requests in cloud repo")
    + (mkQuickCmd "VPS - GH Repos" "issues — open (cloud)"    "${cmd} gh-issues"         "Open issues in cloud repo")
    + (mkQuickCmd "VPS - GH Repos" "recent commits"           "${cmd} gh-commits"        "Last 3 commits per repo")
    # GH Registry
    + (mkQuickCmd "VPS - GH Registry" "list — all packages"     "${cmd} ghcr-list"        "List all GHCR container packages")
    + (mkQuickCmd "VPS - GH Registry" "list — with versions"    "${cmd} ghcr-versions"    "GHCR packages with last update date")
    + (mkQuickCmd "VPS - GH Registry" "count — total"           "${cmd} ghcr-count"       "Count total GHCR packages")
    + (mkQuickCmd "VPS - GH Registry" "versions — inspect"      "${cmd} ghcr-inspect"     "List versions for a specific package")
    + (mkQuickCmd "VPS - GH Registry" "latest — all images"     "${cmd} ghcr-latest"      "All packages with latest version tag")
    + (mkQuickCmd "VPS - GH Registry" "visibility — all"        "${cmd} ghcr-visibility"  "Public vs private for all packages");

  quickCommandsConfig = builtins.concatStringsSep "" (map mkQuickVmEntries vms) + desktopCommands + vpsCommands;

in {
  # SSH Manager sidebar
  home.file.".config/konsolesshconfig".text = sshConfig;

  # Quick Commands sidebar
  home.file.".config/konsolequickcommandsconfig".text = quickCommandsConfig;

  # Commands script (referenced by Quick Commands)
  home.file.".local/share/konsole/konsole-commands.sh".source = ./konsole-commands.sh;
}
