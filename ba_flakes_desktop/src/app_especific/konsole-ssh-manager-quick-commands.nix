{ config, pkgs, lib, inputs, ... }:

# Konsole SSH Manager + Quick Commands plugin configuration
# SSH Manager: connection bookmarks (opens new tab)
# Quick Commands: operation bookmarks (sends to active terminal)
# All commands delegate to cloud-container-orchestrator.sh — zero escaping in nix

let
  # ── VM definitions ──────────────────────────────────────────────────────
  vms = [
    { alias = "gcp-proxy";     ip = "10.0.0.1"; user = "diego";  hasDropbear = true;  provider = "gcp"; gcInstance = "arch-1"; gcZone = "us-central1-a"; }
    { alias = "oci-mail";      ip = "10.0.0.3"; user = "ubuntu"; hasDropbear = true;  provider = "oci"; gcInstance = ""; gcZone = ""; }
    # publicIps: addresses on the wg-public mesh (10.1.0.0/24 + fd0c:1d01::/64),
    # a SEPARATE tunnel from wg0 with its OWN numbering -- oci-analytics is the
    # public hub at 10.1.0.1 while sitting at 10.0.0.4 on wg0. The last octet
    # does NOT carry across the two meshes, so these are declared, never derived.
    # Source: aa_desk-usr_x86_surface-linux_nixos/src/modules/wireguard-public-endpoints.json
    # Only peers with a verified public-mesh address get one; the rest are wg0-only
    # here because no file in the fleet enumerates their 10.1.0.x addresses.
    { alias = "oci-analytics"; ip = "10.0.0.4"; user = "ubuntu"; hasDropbear = true;  provider = "oci"; gcInstance = ""; gcZone = ""; publicIps = [ "10.1.0.1" "fd0c:1d01::1" ]; }
    { alias = "oci-apps";      ip = "10.0.0.6"; user = "ubuntu"; hasDropbear = true;  provider = "oci"; gcInstance = ""; gcZone = ""; }
    { alias = "gcp-t4";        ip = "10.0.0.8"; user = "diego";  hasDropbear = false; provider = "gcp"; gcInstance = "ollama-spot-gpu"; gcZone = "us-central1-a"; }
  ];

  # ── Non-VM SSH peers (mobile/edge) ──────────────────────────────────────
  # Termux: every mesh address + SSH port + user sourced from the termux flake
  # build.json via the `unix-repo` flake input (pinned github fetch of the unix
  # monorepo). ONE array feeds both ends: sshd binds defaults.wg_ips (see
  # bb_flakes_termux/src/modules/cloud-ide-sshd/default.nix) and the aliases
  # below dial them, so a profile switch can never leave the client pointing at
  # an address the daemon does not answer on.
  #
  # It used to read defaults.wg_ip -- ONE v4 address -- while sshd bound three.
  # Selecting a v6 WireGuard profile then broke `ssh phone` against a daemon
  # that was healthy and listening, because the alias could only ever dial
  # 10.0.0.9. Reading the same array is the whole fix.
  termuxBuildJson = builtins.fromJSON (builtins.readFile "${inputs.unix-repo}/bb_flakes_termux/build.json");
  termuxWgIp = termuxBuildJson.defaults.wg_ip or "10.0.0.9";
  termuxWgIps = termuxBuildJson.defaults.wg_ips or [ termuxWgIp ];
  termuxSshPort = termuxBuildJson.defaults.ssh_port or 8024;
  termuxUser = termuxBuildJson.defaults.user or "nix-on-droid";

  # Alias per address, named for the transport rather than an index, because
  # "phone-2" tells you nothing at 3am. Derived from the address itself so a
  # fourth entry in build.json needs no edit here:
  #   10.0.0.9      -> phone        (wg0 mesh, v4)
  #   10.1.0.9      -> phone-pub    (wg-public, v4)
  #   fd0c:1d01::9  -> phone-v6     (wg-public, v6)
  #
  # wg0 carries no IPv6 at all -- its MTU is 1200, under the RFC8200 floor of
  # 1280, so the kernel disables v6 on the interface. Any v6 alias is therefore
  # reachable over wg-public only; that is a property of the address, not a
  # thing to configure here.
  meshAliasSuffix = addr:
    if lib.hasInfix ":" addr then "-v6"
    else if lib.hasPrefix "10.1." addr then "-pub"
    else "";

  extraSshHosts = map (addr: {
    alias = "phone" + meshAliasSuffix addr;
    ip = addr;
    user = termuxUser;
    port = termuxSshPort;
  }) termuxWgIps;

  sshKey = "/home/diego/.ssh/id_rsa";
  cmd = "bash ~/git/cloud-mykonsole-dtk/5-infos/engines/cloud-container-orchestrator/cloud-container-orchestrator.sh";

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
    # Standard SSH: use alias as hostname so ~/.ssh/config Host block matches
    # (provides IdentitiesOnly + IdentityFile + ControlMaster)
    (mkSshEntry f "SSH (port 22)" {
      hostname = vm.alias; user = vm.user;
    })
    # Dropbear: use <alias>-dropbear SSH config host (has Port 2200 built in)
    + (lib.optionalString vm.hasDropbear
      (mkSshEntry f "SSH Dropbear (port 2200)" {
        hostname = "${vm.alias}-dropbear"; user = vm.user;
      }))
    # Serial consoles are in Quick Commands (require proxy/script, not simple SSH)
    ;

  mkSshExtraEntry = h:
    mkSshEntry h.alias "SSH (port ${toString h.port})" {
      hostname = h.alias; user = h.user;
    };

  sshConfig = ''
    [Global plugin config]
    manageProfile=false
  ''
  + builtins.concatStringsSep "" (map mkSshVmEntries vms)
  + builtins.concatStringsSep "" (map mkSshExtraEntry extraSshHosts)
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
    + (mkQuickCmd f "dashboard"             "${cmd} vm-dashboard ${v}"   "tmux: docker stats + htop split")
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

  orchCommands = let
    f = "VM - Orchestration";
    c = "${cmd} all";
  in
    # Mode switcher
    (mkQuickCmd f "⚡ mode: SSH (default)"         "${cmd} mode-ssh"        "Set connection mode to SSH (port 22)")
    + (mkQuickCmd f "⚡ mode: Dropbear"             "${cmd} mode-dropbear"   "Set connection mode to Dropbear (port 2200)")
    + (mkQuickCmd f "⚡ mode: Serial"               "${cmd} mode-serial"     "Set connection mode to serial console")
    + (mkQuickCmd f "⚡ mode: status"               "${cmd} mode-status"     "Show current connection mode")
    # Commands
    + (mkQuickCmd f "htop (all)"                    "${c}-htop"              "htop on all VMs sequentially")
    + (mkQuickCmd f "journalctl -f (all)"         "${c}-journalctl-f"     "Follow journal on all VMs")
    + (mkQuickCmd f "journal-watch docker (all)"  "${c}-journal-docker"   "Docker journal on all VMs")
    + (mkQuickCmd f "journal-watch sshd (all)"    "${c}-journal-sshd"     "SSH journal on all VMs")
    + (mkQuickCmd f "journal-watch wg (all)"      "${c}-journal-wg"       "WireGuard journal on all VMs")
    + (mkQuickCmd f "journal-watch cinit (all)"   "${c}-journal-cinit"    "container-init journal on all VMs")
    + (mkQuickCmd f "journal-watch kernel (all)"  "${c}-journal-kernel"   "Kernel messages on all VMs")
    + (mkQuickCmd f "journal-watch errors (all)"  "${c}-journal-errors"   "Error journal on all VMs")
    + (mkQuickCmd f "systemctl status (all)"      "${c}-systemctl-status" "systemd status on all VMs")
    + (mkQuickCmd f "systemctl list-units (all)"  "${c}-systemctl-list"   "Running services on all VMs")
    + (mkQuickCmd f "docker daemon start (all)"   "${c}-docker-start"     "Start Docker on all VMs")
    + (mkQuickCmd f "docker daemon stop (all)"    "${c}-docker-stop"      "Stop Docker on all VMs")
    + (mkQuickCmd f "docker ps (all)"             "${c}-docker-ps"        "List containers on all VMs")
    + (mkQuickCmd f "docker stats (all)"          "${c}-docker-stats"     "Container stats on all VMs")
    + (mkQuickCmd f "dashboard-stats (all)"         "${c}-dashboard-stats"   "tmux: docker stats + htop for all VMs (one tab per VM)")
    + (mkQuickCmd f "dashboard-journal (all)"       "${c}-dashboard-journal" "tmux: journalctl -f + htop for all VMs (one tab per VM)")
    + (mkQuickCmd f "konsole script push (all)"   "${c}-script-push"     "Push cloud-container-orchestrator.sh to all VMs");

  localCommands = let
    f = "Local";
    c = "${cmd} local";
  in
    (mkQuickCmd f "htop"                    "${c}-htop"              "Interactive process viewer")
    + (mkQuickCmd f "journalctl -f"         "${c}-journalctl-f"     "Follow system journal")
    + (mkQuickCmd f "journal-watch docker"  "${c}-journal-docker"   "Last 15 lines of Docker daemon journal")
    + (mkQuickCmd f "journal-watch sshd"    "${c}-journal-sshd"     "Last 15 lines of SSH daemon journal")
    + (mkQuickCmd f "journal-watch wg"      "${c}-journal-wg"       "Last 15 lines of WireGuard journal")
    + (mkQuickCmd f "journal-watch cinit"   "${c}-journal-cinit"    "Last 15 lines of container-init journal")
    + (mkQuickCmd f "journal-watch kernel"  "${c}-journal-kernel"   "Last 15 kernel messages")
    + (mkQuickCmd f "journal-watch errors"  "${c}-journal-errors"   "Last 15 error-level journal entries")
    + (mkQuickCmd f "systemctl status"      "${c}-systemctl-status" "Show systemd status overview")
    + (mkQuickCmd f "systemctl list-units"  "${c}-systemctl-list"   "List running systemd services")
    + (mkQuickCmd f "docker daemon start"   "${c}-docker-start"     "Start Docker daemon")
    + (mkQuickCmd f "docker daemon stop"    "${c}-docker-stop"      "Stop Docker daemon")
    + (mkQuickCmd f "docker ps"             "${c}-docker-ps"        "List running containers")
    + (mkQuickCmd f "docker stats"          "${c}-docker-stats"     "Live container resource usage")
    + (mkQuickCmd f "docker exec"           "${c}-docker-exec"      "Pick a container and exec into it");

  tuiCmd = "bash ~/git/cloud-mykonsole-dtk/5-infos/engines/cloud-container-orchestrator/cloud-container-orchestrator-tui.sh";

  desktopCommands =
    (mkQuickCmd "Desktop" "TUI (tmux + fzf)"          tuiCmd                  "Full TUI: fzf menu (left) + output (right) in tmux")
    + (mkQuickCmd "Desktop" "dtk.sh (interactive)"    "${cmd} dtk"            "Full interactive toolkit menu")
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
    + (mkQuickCmd "Desktop" "disk usage"              "${cmd} disk-usage"     "Show disk usage for key partitions")
    + (mkQuickCmd "Desktop" "konsole script push"     "if [ -d ~/git/cloud-mykonsole-dtk/.git ]; then git -C ~/git/cloud-mykonsole-dtk pull; else git clone https://github.com/diegonmarcos/cloud-mykonsole-dtk.git ~/git/cloud-mykonsole-dtk; fi && echo 'Done: ~/git/cloud-mykonsole-dtk'" "Clone/pull tools repo from GitHub");

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

  quickCommandsConfig = builtins.concatStringsSep "" (map mkQuickVmEntries vms) + orchCommands + localCommands + desktopCommands + vpsCommands;

  # ── SSH config (~/.ssh/config) — generated from VM definitions ─────────
  mkSshHostEntry = { host, hostname, user, identityFile ? sshKey, port ? 22, remoteCommand ? null }:
    "Host ${host}\n"
    + "    HostName ${hostname}\n"
    + "    User ${user}\n"
    + "    IdentityFile ${identityFile}\n"
    + "    IdentitiesOnly yes\n"
    + lib.optionalString (port != 22) "    Port ${toString port}\n"
    + lib.optionalString (remoteCommand != null)
        ("    RequestTTY yes\n    RemoteCommand ${remoteCommand}\n")
    + "\n";

  # oci-apps VM record (WG IP) — reused for the claude_oci-apps container alias.
  ociApps = builtins.head (builtins.filter (v: v.alias == "oci-apps") vms);

  desktopSshConfig = ''
    # Auto-generated by konsole-ssh-manager-quick-commands.nix — DO NOT EDIT
  '' + lib.concatMapStrings (vm:
    (mkSshHostEntry { host = vm.alias; hostname = vm.ip; user = vm.user; })
    + (lib.optionalString vm.hasDropbear
      (mkSshHostEntry { host = "${vm.alias}-dropbear"; hostname = vm.ip; user = vm.user; port = 2200; }))
    + lib.concatMapStrings (a:
        mkSshHostEntry { host = "${vm.alias}${meshAliasSuffix a}"; hostname = a; user = vm.user; })
      (vm.publicIps or [ ])
  ) vms + lib.concatMapStrings (h:
    (mkSshHostEntry { host = h.alias; hostname = h.ip; user = h.user; port = h.port; })
  ) extraSshHosts
  # Direct shell into the kg-bridge container on oci-apps (WG-only).
  # `ssh claude_oci-apps` → drops straight into Claude Code inside the container,
  # sharing the volume-persisted login the octocode GraphRAG bridge uses.
  + (mkSshHostEntry {
      host = "claude_oci-apps";
      hostname = ociApps.ip;
      user = ociApps.user;
      remoteCommand = "docker exec -it kg-bridge claude";
    })
  + ''
    Host github.com
        HostName github.com
        User git
        IdentityFile ${sshKey}
        IdentitiesOnly yes

    Host *
        StrictHostKeyChecking accept-new
        ServerAliveInterval 60
        ServerAliveCountMax 3
        # Multiplexing — ON BY DEFAULT for every host. First connection opens a
        # background master; later `ssh <host>` reuses the same TCP/auth, so
        # repeated commands skip the WG-handshake + key-exchange overhead
        # (which is ~3-10s on a flaky mobile WG).
        ControlMaster auto
        ControlPath ~/.ssh/sockets/%C
        ControlPersist 4h
        # Compress text streams over slow links.
        Compression yes
        # Longer connect timeout so a brief WG flap doesn't kill the master.
        ConnectTimeout 15
  '';

  # Asset files in tools repo (source of truth, also fetchable standalone)
  toolsRepo = "${config.home.homeDirectory}/git/cloud-mykonsole-dtk";
  quickCmdsAsset = "${toolsRepo}/2-cmds-cloud/konsolequickcommandsconfig";
  sshAsset = "${toolsRepo}/2-cmds-cloud/konsolesshconfig";

in {
  # SSH config — declarative, with dropbear aliases
  home.file.".ssh/config" = {
    text = desktopSshConfig;
    target = ".ssh/config";
  };

  # Sockets directory for ControlMaster multiplexing. ssh silently disables
  # multiplex if the directory doesn't exist, so make sure it's there before
  # any session opens. 700 perms — sockets are auth handles, not for sharing.
  home.activation.sshSocketsDir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    $DRY_RUN_CMD mkdir -p $VERBOSE_ARG "$HOME/.ssh/sockets"
    $DRY_RUN_CMD chmod 700 "$HOME/.ssh/sockets"
  '';

  # SSH Manager + Quick Commands sidebars — seeded, NOT symlinked.
  #
  # 2026-08-12: both were `home.file`, i.e. /nix/store symlinks. Konsole's
  # SSH-manager and quick-commands plugins are KConfig writers: adding or
  # editing an entry in the sidebar rewrites the file, which against a
  # read-only store target makes Konsole print
  #   Configuration file "/nix/store/…-hm_.configkonsolesshconfig" not writable.
  # and silently DROP the edit. Exactly the konsolerc failure (see konsole.nix),
  # and the same failure baloofilerc had: a store symlink under a program that
  # insists on writing its own config.
  #
  # Seeded rather than repaired-key-by-key (the konsole.nix Profile 1 approach):
  # these files are lists of user-owned entries, not a fixed key set, so there
  # is no single key that is safe to force. The declaration is the STARTING
  # point; once the file is real, the sidebar owns it.
  #
  # Consequence, deliberately accepted: editing sshConfig/quickCommandsConfig in
  # this repo no longer rewrites an existing local file. To re-seed from the
  # repo, delete the file and re-activate.
  home.activation.seedKonsoleSidebars = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    (
    ${lib.concatMapStringsSep "\n" (f: ''
      DST="$HOME/.config/${f.name}"
      if [ -L "$DST" ] || [ ! -e "$DST" ]; then
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$HOME/.config"
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -f "$DST"
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -m 0644 ${f.src} "$DST"
        echo "[konsole] seeded writable ${f.name}"
      fi
    '') [
      { name = "konsolesshconfig";           src = pkgs.writeText "konsolesshconfig" sshConfig; }
      { name = "konsolequickcommandsconfig"; src = pkgs.writeText "konsolequickcommandsconfig" quickCommandsConfig; }
    ]}
    )
  '';

  # Asset paths exported for reference (used by dtk.sh 42c installer)
  # Source files: ~/git/cloud-mykonsole-dtk/2-cmds-cloud/konsolequickcommandsconfig
  #               ~/git/cloud-mykonsole-dtk/2-cmds-cloud/konsolesshconfig
}
