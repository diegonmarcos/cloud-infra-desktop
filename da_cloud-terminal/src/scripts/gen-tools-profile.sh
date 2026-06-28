#!/usr/bin/env bash
# gen-tools-profile.sh — generate src/data/profile-tools.json FROM the DTK
# registry (~/git/tools/registry.json), so the cloud-terminal Tools sidebar is
# the same single source of truth as `dtk` itself. Grouped by domain; each item
# runs `sh <tools>/dtk.sh <id>` in the active PTY tab.
#
# If the registry isn't present, the existing profile-tools.json is left as-is.
set -eu
HERE="$(cd "$(dirname "$0")/../.." && pwd)"          # da_cloud-terminal/
OUT="$HERE/src/data/profile-tools.json"
TOOLS="${CT_TOOLS_DIR:-$HOME/git/tools}"
REG="$TOOLS/registry.json"
JQ="$(command -v jq)"

if [ -z "$JQ" ] || [ ! -f "$REG" ]; then
  echo "   gen-tools-profile: registry not found ($REG) — keeping existing profile-tools.json"
  exit 0
fi

# Header (profile metadata) + sections derived from the registry. Each domain
# becomes a section; each command an item invoking its id through dtk.
"$JQ" -n --slurpfile reg "$REG" '
  ($reg[0]) as $r |
  {
    name: "tools",
    display_name: "Tools (DTK)",
    logo: "🛠️",
    tray_tooltip: "Tools — Diego ToolKit",
    flake: "/home/diego/git/tools",
    flakes: {
      system:  "/home/diego/git/unix/aa_desk-usr_x86_surface-linux_nixos",
      desktop: "/home/diego/git/unix/ba_flakes_desktop",
      cloud:   "/home/diego/git/cloud"
    },
    theme: { accent: "#fbbf24", accent2: "#f59e0b", bg: "#1a160e" },
    sections: (
      [ $r.domains | to_entries[] | .key as $d | {
          title: (.value.title + " (" + $d + ")"),
          items: [
            $r.commands[] | select(.domain == $d) | {
              label: (.name + (if .shortcode then "  [" + .shortcode + "]" else "" end)),
              type: "shell",
              arg: ("sh {FLAKE}/dtk.sh " + .id)
            }
          ]
        }
      ]
      # Maintenance section (desktop tools, not part of dtk) appended last.
      + [ {
          title: "Maintenance",
          items: [
            { label: "Mem Reclaim (dry-run)", type: "shell", arg: "bash {FLAKE_DESKTOP}/src/modules/desktop-session/mem-reclaim.sh --dry-run" },
            { label: "Mem Reclaim (kill)",    type: "shell", arg: "bash {FLAKE_DESKTOP}/src/modules/desktop-session/mem-reclaim.sh" },
            { label: "Mem Reclaim (restore)", type: "shell", arg: "bash {FLAKE_DESKTOP}/src/modules/desktop-session/mem-reclaim.sh restore" }
          ]
        } ]
      + [ {
          title: "DTK",
          items: [
            { label: "Open DTK Menu",   type: "shell", arg: "sh {FLAKE}/dtk.sh" },
            { label: "Open Tools Repo", type: "xdg",   arg: "{FLAKE}" }
          ]
        } ]
    )
  }
' > "$OUT"

echo "   gen-tools-profile: wrote $OUT ($("$JQ" '[.sections[].items[]] | length' "$OUT") items from registry)"
