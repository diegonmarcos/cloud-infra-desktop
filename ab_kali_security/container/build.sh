#!/usr/bin/env bash
# Universal engine for the Kali Linux container.
# Source of truth: ./install.json. NEVER hardcode values here.
#
# Usage: ./build.sh <command>
#   build         Build BOTH images (kali-os and kali-data — independent)
#   build-os      Build kali-os:latest from Dockerfile.os
#                 Full bootable image (OS + binaries + GUI ~28 GB),
#                 wordlists/seclists/exploitdb dirs deleted.
#   build-data    Build kali-data:latest from Dockerfile.data
#                 Pure-data sidecar (~6 GB) — wordlists + seclists + exploitdb.
#   rebuild       Force rebuild of both images
#
# Two-image MODULARITY split:
#   kali-os   ~28 GB  : single bootable image; everything except bulk data.
#   kali-data ~6 GB   : data-only sidecar; populates volumes at runtime so
#                       kali-os bind-mounts /usr/share/{wordlists,seclists,
#                       exploitdb} read-only.
# Pull both for full functionality; pull only kali-os for CI jobs that
# don't need wordlists. The two images are INDEPENDENT — neither FROMs the
# other; they share no layers.
#   up-cli     Start CLI profile  (host network)
#   up-gui     Start GUI profile  (host network, noVNC at :6901)
#   down       Stop + remove both profiles
#   shell      docker exec into the running CLI container
#   logs       Tail logs of all profiles
#   ps         Show container state
#   login      docker login ghcr.io with GHCR_TOKEN | gh auth token
#   push       Tag local image with every ghcr.tags entry and push to GHCR
#   pull       Pull every GHCR tag locally (and re-tag first as local_tag)
#   ship       build + push (full release)
#
#   scan local    [preset] [budget]    Audit this host (default: local-quick)
#   scan network <target> [preset] [budget]  Recon/scan target (default: network-quick)
#   scan all     <target> [budget]     local-full + network-full
#   scan list                          Print tools/categories/presets from scans.json
#   scan report  <ts>                  Render report.md from data/loot/<ts>/manifest.json
#   scan test                          Tester (schema valid + minimal dry-run)
#
#   test       Smoke test (JSON schema + image presence + GHCR reachability)
#   clean      Remove image + ./data persistence
#
# Environment knobs:
#   VERBOSE=1        enables full bash xtrace (set -x) — every command echoed
#   QUIET=1          suppresses the [hh:mm:ss] timestamps and step banners
#   BUILDKIT_PROGRESS overrides docker build progress (default: plain)
set -euo pipefail

# ─── verbose by default (timestamped logs, plain docker progress) ────────────
[[ "${VERBOSE:-0}" == "1" ]] && set -x
export DOCKER_BUILDKIT=1
export BUILDKIT_PROGRESS="${BUILDKIT_PROGRESS:-plain}"

if [[ "${QUIET:-0}" == "1" ]]; then
    _log()  { :; }
    _step() { :; }
else
    _log()  { printf '\033[36m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*" >&2; }
    _step() { printf '\n\033[1;33m── %s ──\033[0m\n' "$*" >&2; }
fi

# Run + echo: always shows the command, runs it, returns its exit code.
_run() { _log "+ $*"; "$@"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

CFG="$HERE/install.json"
[[ -r "$CFG" ]] || { echo "missing $CFG"; exit 1; }
command -v jq      >/dev/null || { echo "need jq";      exit 1; }
command -v docker  >/dev/null || { echo "need docker";  exit 1; }

# --- read install.json into env (data-driven, no hardcoding) ----------------
BASE_IMAGE="$(jq -r '.image.registry+"/"+.image.repo+":"+.image.tag' "$CFG")"

# Two-image modularity split (kali-os + kali-data, independent).
KALI_IMAGE="$(jq -r '.images.os.local_tag'   "$CFG")"
DATA_IMAGE="$(jq -r '.images.data.local_tag' "$CFG")"
APT_DATA="$(jq -r  '.data_dirs.dirs | map(.) | join(" ") // "wordlists seclists exploitdb"' "$CFG")"

KALI_HOSTNAME="$(jq -r '.container.hostname'                         "$CFG")"
USER_NAME="$(jq -r '.user.name'                                     "$CFG")"
USER_UID="$(jq -r  '.user.uid'                                      "$CFG")"
USER_GID="$(jq -r  '.user.gid'                                      "$CFG")"
USER_SHELL="$(jq -r '.user.shell'                                   "$CFG")"
TZ_VAL="$(jq -r    '.env.TZ // "Etc/UTC"'                           "$CFG")"
LANG_VAL="$(jq -r  '.env.LANG // "en_US.UTF-8"'                     "$CFG")"

APT_BASE="$(jq -r  '.apt.base             | join(" ")'              "$CFG")"
APT_GUI="$(jq -r   '.apt.gui_stack        | join(" ")'              "$CFG")"
APT_META="$(jq -r  '.apt.metapackages     | join(" ")'              "$CFG")"
APT_RUNTIME="$(jq -r '.apt.runtime_helpers // [] | join(" ")'       "$CFG")"

GHCR_REG="$(jq -r   '.ghcr.registry'                                "$CFG")"
GHCR_OWNER="$(jq -r '.ghcr.owner'                                   "$CFG")"
OS_GHCR_REPO="${GHCR_REG}/${GHCR_OWNER}/$(jq -r '.images.os.ghcr_name'   "$CFG")"
DATA_GHCR_REPO="${GHCR_REG}/${GHCR_OWNER}/$(jq -r '.images.data.ghcr_name' "$CFG")"

export KALI_IMAGE KALI_HOSTNAME TZ="$TZ_VAL" LANG="$LANG_VAL"
export KALI_VNC_PASSWORD="${KALI_VNC_PASSWORD:-$(jq -r '.secrets.vnc_password_default' "$CFG")}"

DC=(docker compose -f "$HERE/compose.yml")

ensure_data_dirs() {
    while IFS= read -r d; do mkdir -p "$HERE/$d"; done < <(
        jq -r '.volumes | to_entries[].value.host' "$CFG"
    )
}

_netflag() {
    case "$(jq -r '.container.network_mode' "$CFG")" in
        host) printf -- "--network=host" ;;
    esac
}

_os_tag()   { echo "${KALI_IMAGE}"; }  # kali-os:latest
_data_tag() { echo "${DATA_IMAGE}"; }  # kali-data:latest

cmd_build_os() {
    _step "BUILD kali-os → $(_os_tag) (full toolkit, data dirs purged)"
    local net; net="$(_netflag)"
    # shellcheck disable=SC2086
    _run docker build --progress="$BUILDKIT_PROGRESS" $net \
        -f "$HERE/Dockerfile.os" \
        --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
        --build-arg "TZ=${TZ_VAL}" \
        --build-arg "LANG_=${LANG_VAL}" \
        --build-arg "APT_BASE=${APT_BASE}" \
        --build-arg "APT_GUI=${APT_GUI}" \
        --build-arg "APT_META=${APT_META}" \
        --build-arg "APT_RUNTIME=${APT_RUNTIME}" \
        --build-arg "USER_NAME=${USER_NAME}" \
        --build-arg "USER_UID=${USER_UID}" \
        --build-arg "USER_GID=${USER_GID}" \
        --build-arg "USER_SHELL=${USER_SHELL}" \
        -t "$(_os_tag)" "$HERE"
    _log "✔ done: $(_os_tag)"
}

cmd_build_data() {
    _step "BUILD kali-data → $(_data_tag) (data-only: ${APT_DATA})"
    local net; net="$(_netflag)"
    # shellcheck disable=SC2086
    _run docker build --progress="$BUILDKIT_PROGRESS" $net \
        -f "$HERE/Dockerfile.data" \
        --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
        --build-arg "APT_DATA=${APT_DATA}" \
        -t "$(_data_tag)" "$HERE"
    _log "✔ done: $(_data_tag)"
}

cmd_build()   { cmd_build_os && cmd_build_data; }
cmd_rebuild() { cmd_build_os && cmd_build_data; }

# Legacy aliases — pre-modularity-flatten naming.
cmd_build_base()    { cmd_build_data; }   # was: heavy stage
cmd_build_runtime() { cmd_build_os;   }   # was: thin overlay
cmd_build_lib()     { cmd_build_data; }   # was: separate lib image (now kali-data)

cmd_up_cli()  { ensure_data_dirs; "${DC[@]}" --profile cli up -d kali-cli; }
cmd_up_gui()  { ensure_data_dirs; "${DC[@]}" --profile gui up -d kali-gui; \
                local p; p=$(jq -r '.modes.gui.novnc_port' "$CFG"); \
                echo "→ open http://localhost:${p}/"; }
cmd_down()    { "${DC[@]}" --profile cli --profile gui down; }
cmd_shell()   { docker exec -it kali-linux-cli "${USER_SHELL}" -l; }
cmd_logs()    { "${DC[@]}" --profile cli --profile gui logs -f --tail=100; }
cmd_ps()      { "${DC[@]}" --profile cli --profile gui ps; }

cmd_test() {
    local fail=0
    echo -n "[1/8] install.json valid JSON ......... "
    jq empty "$CFG" && echo "OK"   || { echo "FAIL"; fail=1; }

    echo -n "[2/8] required keys present ........... "
    jq -e '.images.os.local_tag and .images.data.local_tag and (.container.network_mode=="host") and (.modes.cli and .modes.gui) and (.apt.metapackages | length > 0) and (.images.os.ghcr_tags | length > 0) and (.images.data.ghcr_tags | length > 0) and (.data_dirs.dirs | length > 0)' "$CFG" >/dev/null \
        && echo "OK" || { echo "FAIL"; fail=1; }

    echo -n "[3/8] kali-os built locally ........... "
    docker image inspect "${KALI_IMAGE}" >/dev/null 2>&1 \
        && echo "OK" || { echo "MISSING (run: $0 build-os)"; fail=1; }

    echo -n "[4/8] kali-data built locally ......... "
    docker image inspect "${DATA_IMAGE}" >/dev/null 2>&1 \
        && echo "OK" || { echo "MISSING (run: $0 build-data)"; fail=1; }

    echo -n "[5/8] kali-os has data dirs PURGED .... "
    if docker image inspect "${KALI_IMAGE}" >/dev/null 2>&1; then
        # /usr/share/{wordlists,seclists,exploitdb} should NOT exist in kali-os —
        # they were rm-ed in the same RUN that installed kali-linux-everything.
        # Tools that need them get them via the bind-mount from kali-data.
        if docker run --rm --entrypoint /bin/sh "${KALI_IMAGE}" -c \
              '! [ -d /usr/share/wordlists ] && ! [ -d /usr/share/seclists ] && ! [ -d /usr/share/exploitdb ]' >/dev/null 2>&1; then
            echo "OK"
        else
            echo "FAIL — bulk data dirs leaked into kali-os; rebuild Dockerfile.os"
            fail=1
        fi
    else echo "SKIP"; fi

    echo -n "[6/8] kali-data carries the data dirs . "
    if docker image inspect "${DATA_IMAGE}" >/dev/null 2>&1; then
        # All declared data_dirs must exist non-empty in kali-data.
        local needed; needed=$(jq -r '.data_dirs.dirs | join(" ")' "$CFG")
        if docker run --rm --entrypoint /bin/sh "${DATA_IMAGE}" -c \
              "for d in $needed; do test -d /usr/share/\$d && [ -n \"\$(ls -A /usr/share/\$d 2>/dev/null | head -1)\" ] || exit 1; done"; then
            echo "OK"
        else
            echo "FAIL — at least one of: $needed missing from kali-data"
            fail=1
        fi
    else echo "SKIP"; fi

    echo -n "[7/8] GHCR token reachable ............ "
    ghcr_token >/dev/null 2>&1 && echo "OK" || { echo "MISSING (set GHCR_TOKEN or 'gh auth login')"; fail=1; }

    echo -n "[8/8] GHCR repos (os + data) reachable ...... "
    if command -v curl >/dev/null 2>&1 && tok="$(ghcr_token 2>/dev/null)"; then
        bearer=$(printf '%s' "$tok" | base64 -w0)
        local os_name data_name
        os_name="$(jq -r   '.images.os.ghcr_name'   "$CFG")"
        data_name="$(jq -r '.images.data.ghcr_name' "$CFG")"
        local os_code data_code
        os_code=$(curl -s -o /dev/null -w '%{http_code}' \
                 -H "Authorization: Bearer ${bearer}" \
                 "https://${GHCR_REG}/v2/${GHCR_OWNER}/${os_name}/tags/list" || echo 000)
        data_code=$(curl -s -o /dev/null -w '%{http_code}' \
                 -H "Authorization: Bearer ${bearer}" \
                 "https://${GHCR_REG}/v2/${GHCR_OWNER}/${data_name}/tags/list" || echo 000)
        case "${os_code}/${data_code}" in
            2*/2*|2*/4*|4*/2*|4*/4*) echo "OK (os=$os_code, data=$data_code — both addressable)" ;;
            *) echo "FAIL (os=$os_code, data=$data_code)"; fail=1 ;;
        esac
    else echo "SKIP"; fi

    return "$fail"
}

ghcr_os_tags()   { jq -r '.images.os.ghcr_tags[]'   "$CFG"; }
ghcr_data_tags() { jq -r '.images.data.ghcr_tags[]' "$CFG"; }

ghcr_token() {
    local var cmd
    var="$(jq -r '.ghcr.auth.token_env'         "$CFG")"
    cmd="$(jq -r '.ghcr.auth.token_cmd // empty' "$CFG")"
    if [[ -n "${!var:-}" ]]; then printf '%s' "${!var}"; return 0; fi
    if [[ -n "$cmd" ]] && command -v "${cmd%% *}" >/dev/null 2>&1; then
        eval "$cmd" 2>/dev/null && return 0
    fi
    echo "no GHCR token: set ${var} or run 'gh auth login'" >&2
    return 1
}

cmd_login() {
    local user token
    user="$(jq -r '.ghcr.auth.username_env as $e | (env[$e] // .ghcr.auth.username_default)' "$CFG")"
    token="$(ghcr_token)" || return 1
    _step "LOGIN ${GHCR_REG} as ${user}"
    printf '%s' "$token" | docker login "$GHCR_REG" -u "$user" --password-stdin
}

cmd_push() {
    docker image inspect "$KALI_IMAGE" >/dev/null 2>&1 \
        || { echo "local image $KALI_IMAGE missing — run: $0 build-os"; return 1; }
    docker image inspect "$DATA_IMAGE" >/dev/null 2>&1 \
        || { echo "local image $DATA_IMAGE missing — run: $0 build-data"; return 1; }
    cmd_login || return 1

    _step "PUSH ${KALI_IMAGE} → ${OS_GHCR_REPO}"
    while IFS= read -r tag; do
        local full="${OS_GHCR_REPO}:${tag}"
        _log "tag  $KALI_IMAGE  →  $full"
        _run docker tag  "$KALI_IMAGE" "$full"
        _log "push $full"
        _run docker push "$full"
    done < <(ghcr_os_tags)

    _step "PUSH ${DATA_IMAGE} → ${DATA_GHCR_REPO}"
    while IFS= read -r tag; do
        local full="${DATA_GHCR_REPO}:${tag}"
        _log "tag  $DATA_IMAGE  →  $full"
        _run docker tag  "$DATA_IMAGE" "$full"
        _log "push $full"
        _run docker push "$full"
    done < <(ghcr_data_tags)

    _log "✔ push complete (os + data)"
}

cmd_pull() {
    cmd_login || return 1
    local first=""

    _step "PULL ← ${OS_GHCR_REPO}"
    while IFS= read -r tag; do
        local full="${OS_GHCR_REPO}:${tag}"
        _log "pull $full"
        _run docker pull "$full"
        [[ -z "$first" ]] && first="$full"
    done < <(ghcr_os_tags)
    [[ -n "$first" ]] && _run docker tag "$first" "$KALI_IMAGE"

    first=""
    _step "PULL ← ${DATA_GHCR_REPO}"
    while IFS= read -r tag; do
        local full="${DATA_GHCR_REPO}:${tag}"
        _log "pull $full"
        _run docker pull "$full"
        [[ -z "$first" ]] && first="$full"
    done < <(ghcr_data_tags)
    [[ -n "$first" ]] && _run docker tag "$first" "$DATA_IMAGE"

    _log "✔ pull complete; local tags: os=$KALI_IMAGE, data=$DATA_IMAGE"
}

cmd_ship() { cmd_build && cmd_push; }

# ─── scan actions ─────────────────────────────────────────────────────────
SCANS_JSON="$HERE/scans.json"
TARGETS_JSON="$HERE/targets.json"

_default_budget() { echo "${1:-600}"; }

cmd_scan_local() {
    local preset="${1:-local-quick}" budget; budget="$(_default_budget "${2:-}")"
    [[ -r "$SCANS_JSON"   ]] || { echo "missing $SCANS_JSON";   return 1; }
    [[ -r "$TARGETS_JSON" ]] || { echo "missing $TARGETS_JSON"; return 1; }
    ensure_data_dirs
    "${DC[@]}" --profile scan-local run --rm scanner-local \
        --preset "$preset" --budget "$budget"
}

cmd_scan_network() {
    local target="${1:-}" preset="${2:-network-quick}" budget; budget="$(_default_budget "${3:-}")"
    [[ -n "$target" ]] || { echo "usage: scan network <target> [preset] [budget]"; return 2; }
    [[ -r "$SCANS_JSON"   ]] || { echo "missing $SCANS_JSON";   return 1; }
    [[ -r "$TARGETS_JSON" ]] || { echo "missing $TARGETS_JSON"; return 1; }
    ensure_data_dirs
    "${DC[@]}" --profile scan-network run --rm scanner-network \
        --preset "$preset" --target "$target" --budget "$budget"
}

cmd_scan_all() {
    local target="${1:-}" budget; budget="$(_default_budget "${2:-}")"
    [[ -n "$target" ]] || { echo "usage: scan all <target> [budget]"; return 2; }
    cmd_scan_local   "local-full"   "$budget" || return $?
    cmd_scan_network "$target" "network-full" "$budget"
}

cmd_scan_list() {
    jq -r '
      "── Tools ──",        (.tools      | keys[]            | "  " + .),
      "", "── Categories ──", (.categories | to_entries[]      | "  [\(.value.domain)] \(.key)  →  \(.value.tools|join(", "))"),
      "", "── Presets ──",    (.presets    | to_entries[]      | "  \(.key)  →  \(.value|join(", "))")
    ' "$SCANS_JSON"
}

cmd_scan_report() {
    local ts="${1:-}"
    [[ -n "$ts" ]] || { echo "usage: scan report <timestamp-dir>"; return 2; }
    local m="$HERE/data/loot/$ts/manifest.json"
    [[ -r "$m" ]] || { echo "no manifest at $m"; return 1; }
    "$HERE/scripts/reporter.sh" "$m"
}

cmd_scan_test() {
    local fail=0
    echo -n "[scan-test 1/4] scans.json valid JSON ............ "
    jq empty "$SCANS_JSON" 2>/dev/null && echo OK || { echo FAIL; fail=1; }

    echo -n "[scan-test 2/4] every preset references valid cats . "
    if jq -e '
        [.presets | to_entries[].value[]] | unique
        | map(. as $c | if (.|type=="string") and ($c | IN($c) ) then . else . end)
      ' "$SCANS_JSON" >/dev/null 2>&1 && \
       jq -e '
         . as $root |
         all(.presets[][];     . as $c | $root.categories | has($c))    and
         all(.categories[].tools[]; . as $t | $root.tools | has($t))
       ' "$SCANS_JSON" >/dev/null; then
        echo OK
    else echo FAIL; fail=1; fi

    echo -n "[scan-test 3/4] targets.json valid JSON .......... "
    jq empty "$TARGETS_JSON" 2>/dev/null && echo OK || { echo FAIL; fail=1; }

    echo -n "[scan-test 4/4] dry run preset 'test' locally ..... "
    if cmd_scan_local test 60 >/tmp/.scan-test.log 2>&1 && \
       ls "$HERE"/data/loot/*/manifest.json >/dev/null 2>&1; then
        echo OK
    else
        echo "FAIL (see /tmp/.scan-test.log)"; fail=1
    fi
    return "$fail"
}

cmd_scan() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        local)    cmd_scan_local    "$@" ;;
        network)  cmd_scan_network  "$@" ;;
        all)      cmd_scan_all      "$@" ;;
        list)     cmd_scan_list          ;;
        report)   cmd_scan_report   "$@" ;;
        test)     cmd_scan_test          ;;
        ""|help)  echo "scan: local|network|all|list|report|test" ;;
        *)        echo "unknown scan sub: $sub"; return 2 ;;
    esac
}

cmd_clean() {
    "${DC[@]}" --profile cli --profile gui down -v 2>/dev/null || true
    docker image rm "${KALI_IMAGE}" 2>/dev/null || true
    docker image rm "${DATA_IMAGE}" 2>/dev/null || true
    rm -rf "$HERE/data"
}

case "${1:-}" in
    build)                  cmd_build         ;;
    build-os|build-runtime) cmd_build_os      ;;  # build-runtime = legacy alias
    build-data)             cmd_build_data    ;;
    build-lib|build-base)   cmd_build_data    ;;  # legacy aliases (lib/base both refer to data now)
    rebuild)                cmd_rebuild       ;;
    up-cli)  cmd_up_cli  ;;
    up-gui)  cmd_up_gui  ;;
    down)    cmd_down    ;;
    shell)   cmd_shell   ;;
    logs)    cmd_logs    ;;
    ps)      cmd_ps      ;;
    login)   cmd_login   ;;
    push)    cmd_push    ;;
    pull)    cmd_pull    ;;
    ship)    cmd_ship    ;;
    scan)    shift; cmd_scan "$@" ;;
    test)    cmd_test    ;;
    clean)   cmd_clean   ;;
    ""|help|-h|--help)
        awk '/^# Usage:/{p=1} p && !/^#/{exit} p{sub(/^# ?/,""); print}' "$0" ;;
    *) echo "unknown: $1"; exit 2 ;;
esac
