# NixOS module — permanent declarative home for the Waydroid IIO sensors HAL.
# Import into the Surface host flake and set `services.waydroid-sensors.enable = true`.
# This replaces the imperative `build.sh install`/`enable` (which only exist because
# /etc is read-only on NixOS): the daemon runs as a root systemd service ordered after
# the Waydroid container.
#
# NOTE: the boot-time prop override (waydroid.stub_sensors_hal=0) lives in the user's
# ~/.local/share/waydroid/waydroid_base.prop and is written by `build.sh bootprops`
# (it is per-user Waydroid data, not system config). The framework reads it at container
# start; without it SensorService reports no sensors regardless of this service.
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
        # Belt-and-suspenders: stop any stub instance before we register.
        ExecStartPre = "-${cfg.waydroidPackage}/bin/waydroid shell -- sh -c "
          + "'setprop ${cfg.stubProp} 0; setprop ctl.stop ${cfg.stubService}; "
          + "killall -9 ${cfg.stubProcess} 2>/dev/null; true'";
        ExecStart = "${cfg.package}/bin/waydroid-sensord ${cfg.binderDevice}";
        Restart = "on-failure";
        RestartSec = 2;
      };
    };
  };
}
