# konsole: systemd-oomd must not kill the whole terminal (2026-09-02)
#
# 11:33:02 incident: user.slice memory PSI held 33.23% > 30% for 10s and
# systemd-oomd killed app-org.kde.konsole@<hash>.service — 156 processes,
# every tab, shell and claude session at once. oomd's smallest possible kill
# is a CGROUP, and all of konsole is one unit, so "the worst cgroup" and
# "the whole terminal" are the same thing to it.
#
# ManagedOOMPreference=avoid demotes konsole to last in oomd's candidate
# ranking (systemd >= 252 honors the user.oomd_avoid xattr set by the
# unprivileged user manager on its own cgroups). Process-granular pressure
# relief INSIDE konsole is freeze-guard's job — its tree_victim picker kills
# the starving spawned workload first, then a tab, never the terminal.
#
# Template drop-in: matches every app-org.kde.konsole@<hash>.service instance.
{ ... }:

{
  xdg.configFile."systemd/user/app-org.kde.konsole@.service.d/10-oomd-avoid.conf".text = ''
    [Service]
    ManagedOOMPreference=avoid
  '';
}
