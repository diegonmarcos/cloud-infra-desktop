#!/usr/bin/env bash
# gen-dashboard.sh — render the qutebrowser dashboard start page, DATA-DRIVEN.
#
# Inputs (all overridable via env for reproducible/CI builds):
#   BOOKMARKS_JSON      section SoT (curated links/folders + source markers)
#   CLOUD_DESKTOP_JSON  cloud-data's build-flakes_desktop.json (per-service domain + proxy.primary.wg_only)
#   FRONT_TOPOLOGY_JSON front's I_front-data/front-topology.json (projects[] with category + path)
#   FRONT_ROOT          front repo root for file:// links (default ~/git/front)
#   HISTORY_SQLITE      qutebrowser history db for the "Last Sessions" section
#   TEMPLATE            dashboard.template.html (has the __BOOKMARKS_JSON__ token)
#   OUT                 output dashboard.html
#
# Section model: sections[] → each has direct `links` and/or `folders[]`.
# DATA-DRIVEN sources (never hardcoded):
#   section source:"history" → last 5 distinct URLs from history.sqlite (empty if absent)
#   section source:"front"   → one folder per front category (^[abc]-) from front-topology.json
#   folder  source:"cloud:public" → services whose proxy.primary.wg_only is not true
#   folder  source:"cloud:app"    → the WG-only services (internal *.app names)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BOOKMARKS_JSON="${BOOKMARKS_JSON:-$HERE/../2_configs/qute-bookmarks.json}"
CLOUD_DESKTOP_JSON="${CLOUD_DESKTOP_JSON:-$HOME/git/cloud/2_configs/dist/build-flakes_desktop.json}"
FRONT_TOPOLOGY_JSON="${FRONT_TOPOLOGY_JSON:-$HOME/git/front/I_front-data/front-topology.json}"
FRONT_ROOT="${FRONT_ROOT:-$HOME/git/front}"
HISTORY_SQLITE="${HISTORY_SQLITE:-$HOME/.local/share/qutebrowser/history.sqlite}"
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

# front categories → [ { name, links:{proj:file://…} } ], one folder per ^[abc]- category.
# file:// links point at each project's index.html under FRONT_ROOT/<path>.
front_folders() {
  if [ -r "$FRONT_TOPOLOGY_JSON" ]; then
    jq --arg root "$FRONT_ROOT" '
      [ .projects // [] | .[]
        | select(.category | test("^[abc]-"))
        | { cat: .category, name: .name,
            url: ("file://" + $root + "/" + .path
                  + (if .has_dist then "/dist/index.html" else "/index.html" end)) } ]
      | group_by(.cat)
      | map({ name: (.[0].cat),
              links: (reduce .[] as $p ({}; .[$p.name] = $p.url)) })
    ' "$FRONT_TOPOLOGY_JSON"
  else
    echo '[]'
  fi
}

# last 5 distinct URLs from qutebrowser history → { label: url }.
# Skips the dashboard itself; label = page title (fallback host). Empty if no db/sqlite3.
history_links() {
  if command -v sqlite3 >/dev/null 2>&1 && [ -r "$HISTORY_SQLITE" ]; then
    # TSV: url \t title  (newest first, distinct url, real navigations only)
    sqlite3 -separator $'\t' "$HISTORY_SQLITE" \
      "SELECT url, COALESCE(NULLIF(title,''), url) FROM History
         WHERE redirect=0 AND url NOT LIKE 'file://%dashboard.html'
         GROUP BY url ORDER BY max(atime) DESC LIMIT 5;" 2>/dev/null \
    | jq -R -s '
        split("\n") | map(select(length>0) | split("\t"))
        | reduce .[] as $r ({}; .[($r[1] // $r[0])] = $r[0])'
  else
    echo '{}'
  fi
}

PUBLIC="$(cloud_links public)"
WGONLY="$(cloud_links app)"
FRONT="$(front_folders)"
HISTORY="$(history_links)"

# Normalise every section to { name, desc, links, folders:[{name,desc,links}] },
# resolving all data-driven sources. Direct section links (QuickMarks) stay in
# .links; folder-bearing sections resolve each folder's source.
DATA="$(jq -n \
  --slurpfile bm "$BOOKMARKS_JSON" \
  --argjson public "$PUBLIC" \
  --argjson wgonly "$WGONLY" \
  --argjson front  "$FRONT" \
  --argjson history "$HISTORY" '
  { sections: (
      $bm[0].sections
      | map({
          name: .name,
          desc: (.desc // ""),
          recent: (.source == "history"),
          links: ( if   .source == "history" then $history
                   else (.links // {}) end ),
          folders: ( if .source == "front" then $front
                     else ( .folders // []
                            | map({ name: .name, desc: (.desc // ""),
                                    links: ( if   .source == "cloud:public" then $public
                                             elif .source == "cloud:app"    then $wgonly
                                             else (.links // {}) end ) }) )
                     end )
        })
    ) }
')"

mkdir -p "$(dirname "$OUT")"
# Inject via awk (safe with URLs/JSON; no sed backref hazards).
awk -v json="$DATA" '{ gsub(/__BOOKMARKS_JSON__/, json); print }' "$TEMPLATE" > "$OUT"
nsec=$(jq -r '.sections|length' <<<"$DATA")
nlink=$(jq -r '[.sections[] | (.links|length) + ([.folders[].links|length]|add // 0)]|add' <<<"$DATA")
echo "gen-dashboard: wrote $OUT ($nlink links across $nsec sections)"

# Also emit qutebrowser's native bookmarks file (one "url  Section/[Folder/]name"
# per line) from the SAME fully-resolved link set — so the built-in Bookmarks page
# carries the identical list (curated + cloud + front). "Last Sessions" is skipped
# (transient history, not a bookmark). Deployed by home-module.nix.
BOOKMARKS_URLS="${BOOKMARKS_URLS:-$HERE/../../dist/qute-bookmarks-urls}"
jq -r '.sections[] | select(.name != "Last Sessions") as $s
       | ( ($s.links // {}) | to_entries[] | "\(.value)  \($s.name)/\(.key)" ),
         ( ($s.folders // [])[] as $f | $f.links | to_entries[]
           | "\(.value)  \($s.name)/\($f.name)/\(.key)" )' <<<"$DATA" > "$BOOKMARKS_URLS"
echo "gen-dashboard: wrote $BOOKMARKS_URLS ($(wc -l < "$BOOKMARKS_URLS") bookmarks)"
