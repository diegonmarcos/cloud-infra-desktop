# NixOS module — OPTIONAL root-service runner for the Waydroid IIO sensors HAL.
# Import into the Surface host flake and set `services.waydroid-sensors.enable = true`
# ONLY if you want the daemon run as a root systemd service ordered after the Waydroid
# container.
#
# CURRENTLY UNUSED on the surface host: the daemon is run by the home-manager USER
# service (ba_flakes_desktop/src/modules/containers-cloud/waydroid-sensors.nix) from the
# pre-built dist/ artifact, and the SYSTEM side only puts `waydroid-sensord` on PATH via
# configuration_waydroid-sensors.nix. Do not enable both (double daemon on /dev/hwbinder).
#
# IMPORTANT — how the stub is actually disabled (verified from waydroid 1.4.3 source):
# `tools/helpers/images.py:make_prop` (run by the ROOT waydroid-container service) does
# `if which("waydroid-sensord") is None: props.append("waydroid.stub_sensors_hal=1")`.
# So the stub is gated PURELY by whether `waydroid-sensord` is on the system PATH — NOT
# by any waydroid_base.prop. waydroid IGNORES ~/.local/share/waydroid/waydroid_base.prop
# (it reads /var/lib/waydroid/waydroid_base.prop), and neither `waydroid prop set` nor
# `waydroid upgrade -o` make the stub flip. The fix is environment.systemPackages, not a
# prop. The runtime stub-stop ExecStartPre below is now redundant but harmless.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.waydroid-sensors;
in {
  options.services.waydroid-sensors = {
    enable = lib.mkEnableOption "Waydroid IIO-backed Android sensors HAL";
    package = lib.mkOption {
      type = lib.types.package;
      description = "waydroid-sensord package (this flake's packages.<system>.waydroid-sensord).";
    };
    confFile = lib.mkOption {
      type = lib.types.path;
      description = "KEY=VALUE daemon conf (IIO name, poll, mount matrix) — render from build.json.";
    };
    binderDevice = lib.mkOption { type = lib.types.str; default = "/dev/hwbinder"; };
    stubProp = lib.mkOption { type = lib.types.str; default = "waydroid.stub_sensors_hal"; };
    stubService = lib.mkOption { type = lib.types.str; default = "vendor.sensors-hal-1-0"; };
    stubProcess = lib.mkOption { type = lib.types.str; default = "android.hardware.sensors@1.0-service.waydroid"; };
    bootGateProp = lib.mkOption { type = lib.types.str; default = "sys.boot_completed";
      description = "Wait for this Android prop = 1 before starting the HAL (boot-safety gate)."; };
    bootGateTimeout = lib.mkOption { type = lib.types.int; default = 90;
      description = "Max seconds to wait for the boot-gate prop before failing."; };
    waydroidPackage = lib.mkOption { type = lib.types.package; default = pkgs.waydroid; };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.waydroid-sensors = {
      description = "Waydroid Android sensors HAL (IIO-backed accelerometer for auto-rotate)";
      after = [ "waydroid-container.service" ];
      partOf = [ "waydroid-container.service" ];
      wantedBy = [ "multi-user.target" ];
      environment.WAYDROID_SENSORS_CONF = toString cfg.confFile;
      serviceConfig = {
        Type = "simple";
        ExecStartPre = [
          # 0) BOOT-SAFETY GATE: wait until the framework is fully up. The HAL must NOT be
          #    present while SensorService initialises or it deadlocks the boot.
          ("${pkgs.bash}/bin/sh -c 'for i in $(seq 1 ${toString cfg.bootGateTimeout}); do "
            + "[ \"$(${cfg.waydroidPackage}/bin/waydroid shell -- getprop ${cfg.bootGateProp} 2>/dev/null | tr -d \"\\r\")\" = \"1\" ] "
            + "&& exit 0; sleep 1; done; echo boot-gate timeout >&2; exit 1'")
          # 1) stop any stub instance before we register (free the HIDL name).
          ("-${cfg.waydroidPackage}/bin/waydroid shell -- sh -c "
            + "'setprop ${cfg.stubProp} 0; setprop ctl.stop ${cfg.stubService}; "
            + "killall -9 ${cfg.stubProcess} 2>/dev/null; true'")
        ];
        ExecStart = "${cfg.package}/bin/waydroid-sensord ${cfg.binderDevice}";
        Restart = "on-failure";
        RestartSec = 2;
      };
    };
  };
}
