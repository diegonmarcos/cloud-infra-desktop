# Observability — producer-side verbosity so journald becomes a forensic source
#
# Reads from cloud-data-observability.json. All sinks funnel into journald.
# Answers questions journald cannot answer at default log levels:
#   - Who sent SIGTERM/SIGKILL to a process? → auditd kill/tkill/tgkill rules
#   - Who called StartUnit/StopUnit on user systemd? → systemd user LogLevel=debug
#   - Why did KWin/KSMServer exit? → QT_LOGGING_RULES debug categories
#   - When did MemoryHigh fire on which slice? → psi-recorder service
#   - Did the kernel deliver a fatal signal? → kernel.print-fatal-signals=1
#
# To activate: add `./configuration_observability.nix` to imports of
# configuration.nix (already done in this commit).
#
# Companion test runner: ./test-observability.sh (validates each producer
# actually emits to journald).
{ config, pkgs, lib, ... }:

let
  jsonPath = ./cloud-data-observability.json;
  cfg =
    if builtins.pathExists jsonPath
    then builtins.fromJSON (builtins.readFile jsonPath)
    else {
      _fallback = true;
      audit = { enable = false; rules = []; };
      psacct.enable = false;
      systemd_user = { log_level = "info"; log_target = "journal"; extra_config_lines = []; };
      kernel_sysctl = {};
      qt_logging.rules = [];
      psi_recorder = { enable = false; interval_seconds = 30; slices = []; fields = []; };
      ntfy = { topic = ""; url = ""; };
    };

  qtLoggingRulesValue = lib.concatStringsSep ";" (cfg.qt_logging.rules or []);

  systemdUserConfBody = lib.concatStringsSep "\n" (
    [ "[Manager]"
      "LogLevel=${cfg.systemd_user.log_level or "info"}"
      "LogTarget=${cfg.systemd_user.log_target or "journal"}"
    ]
    ++ (cfg.systemd_user.extra_config_lines or [])
  );

  psiRecorderScript = ''
    set -u
    INTERVAL=${toString (cfg.psi_recorder.interval_seconds or 10)}
    BASE=/sys/fs/cgroup
    while true; do
      ${lib.concatMapStringsSep "\n" (slice: ''
        SLICE_PATH="$BASE/${slice}"
        if [ -d "$SLICE_PATH" ]; then
          ${lib.concatMapStringsSep "\n          " (f: ''
            FILE="$SLICE_PATH/${f}"
            if [ -r "$FILE" ]; then
              CONTENT=$(tr '\n' '|' < "$FILE" 2>/dev/null | sed 's/|$//')
              echo "[psi-recorder] slice=${slice} field=${f} value=\"$CONTENT\""
            fi
          '') (cfg.psi_recorder.fields or [])}
        fi
      '') (cfg.psi_recorder.slices or [])}
      sleep "$INTERVAL"
    done
  '';

in
{
  # ════════════════════════════════════════════════════════════════════════════
  # KERNEL: print fatal signals to dmesg → journal (kmsg transport)
  # ════════════════════════════════════════════════════════════════════════════
  boot.kernel.sysctl = lib.mkMerge [
    (cfg.kernel_sysctl or {})
  ];

  # ════════════════════════════════════════════════════════════════════════════
  # AUDITD: kernel audit subsystem + userspace bridge to journald
  #   - security.audit.enable starts the kernel audit machinery
  #   - security.auditd.enable starts the daemon that bridges to journald
  #     (events appear with _TRANSPORT=audit and _AUDIT_* fields)
  # ════════════════════════════════════════════════════════════════════════════
  security.audit = lib.mkIf (cfg.audit.enable or false) {
    enable = true;
    backlogLimit = cfg.audit.backlog_limit or 8192;
    rules = cfg.audit.rules or [];
  };

  security.auditd.enable = lib.mkIf (cfg.audit.enable or false) true;

  # auditd's default log_file is /var/log/audit/audit.log — that lives on the
  # tmpfs root and fills it within hours (claude/esbuild syscalls).
  # Move the on-disk log to the persistent btrfs @shared subvolume and cap
  # rotation at 5 × 8 MiB = 40 MiB max. Events also stream to journald via the
  # kernel _TRANSPORT=audit bridge (verified by T2 in test-observability.sh).
  environment.etc."audit/auditd.conf".text = lib.mkIf (cfg.audit.enable or false) ''
    local_events = yes
    write_logs = yes
    log_file = /mnt/shared/log/audit/audit.log
    log_group = root
    log_format = ENRICHED
    flush = INCREMENTAL_ASYNC
    freq = 50
    max_log_file = 8
    num_logs = 5
    priority_boost = 4
    name_format = NONE
    max_log_file_action = ROTATE
    space_left = 75
    space_left_action = SYSLOG
    admin_space_left = 50
    admin_space_left_action = SUSPEND
    disk_full_action = SUSPEND
    disk_error_action = SUSPEND
    use_libwrap = yes
    tcp_listen_queue = 5
    tcp_max_per_addr = 1
    tcp_client_max_idle = 0
    transport = TCP
    distribute_network = no
    q_depth = 2000
    overflow_action = SYSLOG
    max_restarts = 10
    plugin_dir = /etc/audit/plugins.d
    end_of_event_timeout = 2
  '';

  # NOTE: persistent audit log dir creation, 3-day age cleanup, and the
  # `R! /var/log/audit` reset rule live in cloud-data-disk-protection.json
  # (single source of truth for tmpfiles, consumed by
  # configuration_system-protection-disk.nix).

  # ════════════════════════════════════════════════════════════════════════════
  # PSACCT: process accounting binary log
  #   Permanent forensics service — log MUST live on btrfs, not tmpfs root.
  #   Path: /mnt/shared/log/account/pacct (@shared subvol). Cleanup is the
  #   `logrotate.entries.pacct` rule in cloud-data-disk-protection.json — NOT
  #   the tmpfiles `e /mnt/shared/log/account ... 14d` rule that used to be
  #   cited here. tmpfiles ages a DIRECTORY by mtime and pacct is ONE file the
  #   kernel appends to on every exec, so its mtime is always now and that rule
  #   could never fire. It didn't: the file reached 17GB and took the 80G pool
  #   to 98% on 2026-09-03. Rotation has to stop accton, roll, restart it.
  #   Read with `lastcomm`, `sa` — covers exec history that journald can't see
  #   when a process exits before logging anything itself.
  #   NixOS 24.11 has no services.psacct module, so we wrap accton ourselves.
  #   Requires local-fs.target so /mnt/shared is mounted before we touch it.
  # ════════════════════════════════════════════════════════════════════════════
  systemd.services.psacct = lib.mkIf (cfg.psacct.enable or false) {
    description = "BSD-style process accounting (accton)";
    after = [ "local-fs.target" "mnt-shared.mount" ];
    requires = [ "local-fs.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStartPre = pkgs.writeShellScript "psacct-prep" ''
        set -e
        ${pkgs.coreutils}/bin/mkdir -p /mnt/shared/log/account
        ${pkgs.coreutils}/bin/chmod 0750 /mnt/shared/log/account
        # accton requires the log file to EXIST (not just the directory):
        # without this it fails with "accton: No such file or directory" (status 2).
        if [ ! -e /mnt/shared/log/account/pacct ]; then
          ${pkgs.coreutils}/bin/touch /mnt/shared/log/account/pacct
          ${pkgs.coreutils}/bin/chmod 600 /mnt/shared/log/account/pacct
        fi
      '';
      ExecStart = "${pkgs.acct}/bin/accton /mnt/shared/log/account/pacct";
      ExecStop = "${pkgs.acct}/bin/accton off";
    };
  };

  # ════════════════════════════════════════════════════════════════════════════
  # SYSTEMD USER MANAGER: debug-level logging
  #   At debug level, target activations include the requesting client.
  #   Written via /etc/systemd/user.conf.d (NixOS-allowed override path).
  # ════════════════════════════════════════════════════════════════════════════
  environment.etc."systemd/user.conf.d/90-observability.conf".text = systemdUserConfBody;

  # ════════════════════════════════════════════════════════════════════════════
  # QT_LOGGING_RULES: KWin/KSMServer/dbus debug categories (system-wide env)
  #   Sent via Qt's logging framework → stderr → systemd unit → journald
  # ════════════════════════════════════════════════════════════════════════════
  environment.variables.QT_LOGGING_RULES =
    lib.mkIf (qtLoggingRulesValue != "") qtLoggingRulesValue;

  # ════════════════════════════════════════════════════════════════════════════
  # PSI-RECORDER: periodic snapshot of cgroup pressure & memory.events
  #   Without this, memory.events.high is a counter (we see "25389" cumulative
  #   but not WHEN it happened). This emits one journal line per slice per
  #   interval, giving a time-series.
  # ════════════════════════════════════════════════════════════════════════════
  systemd.services.psi-recorder = lib.mkIf (cfg.psi_recorder.enable or false) {
    description = "PSI + memory.events recorder → journald";
    after = [ "multi-user.target" ];
    wantedBy = [ "multi-user.target" ];
    path = with pkgs; [ coreutils gnused ];
    serviceConfig = {
      Type = "simple";
      Slice = "os-essentials.slice";
      Restart = "always";
      RestartSec = 5;
      OOMScoreAdjust = -800;
      MemoryMax = "30M";
      MemoryHigh = "20M";
      Nice = 10;
      StandardOutput = "journal";
      StandardError = "journal";
    };
    script = psiRecorderScript;
  };

  # ════════════════════════════════════════════════════════════════════════════
  # PACKAGES: tools needed to query the producers
  # ════════════════════════════════════════════════════════════════════════════
  environment.systemPackages = with pkgs; [
    audit       # auditctl, ausearch, aureport
    acct        # lastcomm, sa, ac (psacct toolkit)
  ];
}
