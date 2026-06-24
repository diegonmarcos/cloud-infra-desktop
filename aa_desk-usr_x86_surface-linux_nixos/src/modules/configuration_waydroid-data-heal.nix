# Self-heal for the mutable Waydroid /data (the non-deterministic half of the
# "container"). The Android system/vendor images are read-only + immutable, but
# /data (~/.local/share/waydroid, a rw btrfs subvol) drifts and corrupts. The
# most damaging mode: keystore ownership flips off AID_KEYSTORE(1017) ->
# keystore2 SQLITE_CANTOPEN -> system_server dies -> Waydroid forever-load.
#
# This oneshot asserts the ownership invariants (data-driven from
# waydroid.json::data_heal) BEFORE the container starts, every start. It is the
# self-healing layer: even if some future writer re-corrupts /data, the next
# container start repairs it automatically instead of crash-looping.
#
# Best-effort: it ALWAYS exits 0 and is `wantedBy` (not `requiredBy`) the
# container, so a heal failure logs but never blocks Waydroid from starting.
{ config, lib, pkgs, ... }:

let
  wd = builtins.fromJSON (builtins.readFile ./waydroid.json);
  heal = wd.data_heal or null;

  mkInvariant = root: inv:
    let
      target = "${root}/${inv.rel}";
      want = "${toString inv.uid}:${toString inv.gid}";
      recursive = inv.recursive or false;
    in if recursive then ''
      target="${target}"
      if [ -e "$target" ]; then
        # Detect a wrong owner ANYWHERE under the subtree (the keystore bug had
        # a correct 1017 dir but 1000-owned *.sqlite files inside it).
        bad="$(find "$target" \( ! -uid ${toString inv.uid} -o ! -gid ${toString inv.gid} \) -print -quit 2>/dev/null)"
        if [ -n "$bad" ]; then
          logger -t waydroid-data-heal -p user.warning "self-heal: wrong owner under $target (e.g. $bad) — chown -R ${want}"
          chown -R ${want} "$target" 2>/dev/null \
            || logger -t waydroid-data-heal -p user.err "self-heal: chown -R FAILED on $target"
        fi
      fi
    '' else ''
      target="${target}"
      if [ -e "$target" ]; then
        cur="$(stat -c '%u:%g' "$target" 2>/dev/null)"
        if [ "$cur" != "${want}" ]; then
          logger -t waydroid-data-heal -p user.warning "self-heal: $target owner $cur -> ${want}"
          chown ${want} "$target" 2>/dev/null \
            || logger -t waydroid-data-heal -p user.err "self-heal: chown FAILED on $target"
        fi
      fi
    '';

  healScript = lib.concatMapStringsSep "\n"
    (root: lib.concatMapStringsSep "\n" (inv: mkInvariant root inv) heal.invariants)
    heal.data_roots;

in lib.mkIf (heal != null) {
  systemd.services.waydroid-data-heal = {
    description = "Self-heal Waydroid /data ownership invariants (pre container-start)";
    before = [ "waydroid-container.service" ];
    wantedBy = [ "waydroid-container.service" ];
    path = [ pkgs.coreutils pkgs.findutils pkgs.util-linux ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
    };
    script = ''
      set +e
      ${healScript}
      exit 0
    '';
  };
}
