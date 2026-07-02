#!/usr/bin/env bash
# gen-dashboard.sh — render the qutebrowser dashboard start page, DATA-DRIVEN.
#
# Inputs (all overridable via env for reproducible/CI builds):
#   BOOKMARKS_JSON   folder SoT (curated Services/Local + cloud:* source markers)
#   CLOUD_DESKTOP_JSON  cloud-data's build-flakes_desktop.json (per-service domain + proxy.primary.wg_only)
#   TEMPLATE         dashboard.template.html (has the __BOOKMARKS_JSON__ token)
#   OUT              output dashboard.html
#
# Cloud folders are NOT hardcoded: `source:"cloud:public"` → services whose
# proxy.primary.wg_only is not true; `source:"cloud:wg_only"` → the WG-only ones.
# Friendly label = last path segment for path-routes, else the first subdomain
# label (auth.diegonmarcos.com→auth, analytics…/matomo→matomo).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BOOKMARKS_JSON="${BOOKMARKS_JSON:-$HERE/../2_configs/qute-bookmarks.json}"
CLOUD_DESKTOP_JSON="${CLOUD_DESKTOP_JSON:-$HOME/git/cloud/2_configs/dist/build-flakes_desktop.json}"
TEMPLATE="${TEMPLATE:-$HERE/dashboard.template.html}"
OUT="${OUT:-$HERE/../../dist/dashboard.html}"

[ -r "$BOOKMARKS_JSON" ] || { echo "gen-dashboard: missing $BOOKMARKS_JSON" >&2; exit 1; }
[ -r "$TEMPLATE" ]       || { echo "gen-dashboard: missing $TEMPLATE" >&2; exit 1; }

# cloud services → { "label": "url", ... }. Two projections of the SAME service set:
#   mode=public : the public Caddy domain  (.domain → https://sub.diegonmarcos.com[/path])
#   mode=app    : the internal WG name      (.dns    → https://<name>.app)
# Empty {} if the cloud file is absent (page still builds without the cloud repo).
cloud_links() { # $1 = public|app
  local mode="$1"
  if [ -r "$CLOUD_DESKTOP_JSON" ]; then
    jq --arg mode "$mode" '
      [ .services // {} | to_entries[]
        | select(.value.enabled != false)
        | { name: .key, domain: .value.domain, dns: .value.dns }
        | if $mode == "app"
          then select(.dns) | { key: (.dns|sub("\\.app$";"")), url: ("https://" + .dns) }
          else select(.domain) | { key: ( if (.domain|contains("/")) then (.domain|split("/")|last)
                                           else (.domain|split(".")|first) end ),
                                   url: ("https://" + .domain) }
          end
      ] | sort_by(.key) | reduce .[] as $x ({}; .[$x.key] = $x.url)
    ' "$CLOUD_DESKTOP_JSON"
  else
    echo '{}'
  fi
}

PUBLIC="$(cloud_links public)"
WGONLY="$(cloud_links app)"

# Build the nested { folders: { Name: {_desc, links} } } the template expects,
# resolving cloud:* sources from the derived link maps.
DATA="$(jq -n \
  --slurpfile bm "$BOOKMARKS_JSON" \
  --argjson public "$PUBLIC" \
  --argjson wgonly "$WGONLY" '
  { folders: (
      $bm[0].folders
      | map({ (.name): {
          _desc: (.desc // ""),
          links: ( if   .source == "cloud:public" then $public
                   elif .source == "cloud:app"    then $wgonly
                   else (.links // {}) end )
        } })
      | add
    ) }
')"

mkdir -p "$(dirname "$OUT")"
# Inject via awk (safe with URLs/JSON; no sed backref hazards).
awk -v json="$DATA" '{ gsub(/__BOOKMARKS_JSON__/, json); print }' "$TEMPLATE" > "$OUT"
echo "gen-dashboard: wrote $OUT ($(jq -r '[.folders[].links|length]|add' <<<"$DATA") links across $(jq -r '.folders|length' <<<"$DATA") folders)"
