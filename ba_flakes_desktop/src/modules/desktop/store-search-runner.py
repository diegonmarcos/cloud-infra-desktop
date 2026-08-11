#!/usr/bin/env python3
"""KRunner D-Bus runner backed by the CI-built /nix/store filename index.

Replaces plasma-runner-baloosearch, which is dead on this machine: baloo is
disabled (modules/programs/disable-baloo.nix) because it keyed documents by
(device, inode) and sustained ~50% CPU re-indexing an 8GB laptop.

The index this queries is built in GitHub Actions over the system closure and
downloaded whole at switch time (steps/60-fetch-search-index.sh). plocate's DB
is PATH-keyed and store paths are content-addressed, so a CI-built index is
byte-valid here — which is exactly what made baloo's inode-keyed DB untrans-
portable. Net result: KDE search covers the closure with zero local indexing.

D-Bus activated, so nothing runs until someone actually types in KRunner.
"""
import os
import subprocess

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

OBJPATH = "/runner"
IFACE = "org.kde.krunner1"
BUSNAME = "org.kde.runners.storesearch"

DB = os.path.join(
    os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")),
    "store-search",
    "store.db",
)

MAX_RESULTS = 25
# Plasma::QueryMatch::Type — CompletionMatch=10, PossibleMatch=30, ExactMatch=100.
POSSIBLE_MATCH = 30


def pkg_of(path):
    """/nix/store/<hash>-firefox-115/bin/firefox -> firefox-115

    The store path already encodes the package, so the index needs no metadata
    beyond the path itself — this is why filenames-only stays ~1.5MB.
    """
    parts = path.split("/")
    if len(parts) > 3 and parts[1] == "nix" and parts[2] == "store":
        name = parts[3]
        # Strip the 32-char base32 hash and its separating dash.
        return name[33:] if len(name) > 33 and name[32] == "-" else name
    return ""


class Runner(dbus.service.Object):
    @dbus.service.method(IFACE, in_signature="s", out_signature="a(sssida{sv})")
    def Match(self, query):
        query = query.strip()
        # Min-Letter-Count in the .desktop already gates this, but KRunner is
        # not the only possible caller of this interface.
        if len(query) < 3 or not os.path.exists(DB):
            return []
        try:
            out = subprocess.run(
                ["plocate", "-d", DB, "-i", "-l", str(MAX_RESULTS), "--", query],
                capture_output=True, text=True, timeout=2,
            ).stdout
        except (subprocess.SubprocessError, OSError):
            # A broken/absent index must degrade to "no results", never to a
            # KRunner error dialog on every keystroke.
            return []

        matches = []
        for i, path in enumerate(filter(None, out.splitlines())):
            base = os.path.basename(path)
            # Exact basename hits first, then by plocate's own ordering.
            relevance = 0.9 if base == query else max(0.1, 0.8 - i * 0.02)
            matches.append((
                path,                       # id, echoed back to Run()
                base,                       # text
                "text-x-generic",           # iconName
                POSSIBLE_MATCH,             # type
                relevance,                  # relevance
                {"subtext": dbus.String(pkg_of(path) or path)},
            ))
        return matches

    @dbus.service.method(IFACE, out_signature="a(sss)")
    def Actions(self):
        return [("open_dir", "Open containing folder", "folder-open")]

    @dbus.service.method(IFACE, in_signature="ss")
    def Run(self, matchId, actionId):
        target = os.path.dirname(matchId) if actionId == "open_dir" else matchId
        subprocess.Popen(
            ["xdg-open", target],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )


if __name__ == "__main__":
    DBusGMainLoop(set_as_default=True)
    Runner(dbus.service.BusName(BUSNAME, dbus.SessionBus()), OBJPATH)
    GLib.MainLoop().run()
