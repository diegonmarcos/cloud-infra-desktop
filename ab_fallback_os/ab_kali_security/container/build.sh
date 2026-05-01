#!/usr/bin/env bash
# Universal engine for the Kali fallback container.
# Source of truth: ./install.json. NEVER hardcode values here.
#
# Usage: ./build.sh <command>
#   build         Build runtime overlay (auto-builds base if missing)
#   build-base    Build heavy stage1 image (Dockerfile.base) — kali-fallback:base
#   build-runtime Build thin stage2 overlay (Dockerfile.runtime) — kali-fallback:full
#   rebuild       Force rebuild of BOTH stages
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
#   test       Smoke test (JSON schema + image presence + GHCR reachability)
#   clean      Remove image + ./data persistence
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

CFG="$HERE/install.json"
[[ -r "$CFG" ]] || { echo "missing $CFG"; exit 1; }
command -v jq      >/dev/null || { echo "need jq";      exit 1; }
command -v docker  >/dev/null || { echo "need docker";  exit 1; }

# --- read install.json into env (data-driven, no hardcoding) ----------------
KALI_IMAGE="$(jq -r '.image.local_tag'                              "$CFG")"
BASE_IMAGE="$(jq -r '.image.registry+"/"+.image.repo+":"+.image.tag' "$CFG")"
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
GHCR_NAME="$(jq -r  '.ghcr.name'                                    "$CFG")"
GHCR_REPO="${GHCR_REG}/${GHCR_OWNER}/${GHCR_NAME}"

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

_base_tag()    { echo "${KALI_IMAGE%:*}:base"; }
_runtime_tag() { echo "${KALI_IMAGE}"; }

cmd_build_base() {
    local net; net="$(_netflag)"
    # shellcheck disable=SC2086
    docker build $net \
        -f "$HERE/Dockerfile.base" \
        --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
        --build-arg "TZ=${TZ_VAL}" \
        --build-arg "LANG_=${LANG_VAL}" \
        --build-arg "APT_BASE=${APT_BASE}" \
        --build-arg "APT_GUI=${APT_GUI}" \
        --build-arg "APT_META=${APT_META}" \
        -t "$(_base_tag)" "$HERE"
}

cmd_build_runtime() {
    docker image inspect "$(_base_tag)" >/dev/null 2>&1 \
        || { echo "base image $(_base_tag) missing — run: $0 build-base"; return 1; }
    local net; net="$(_netflag)"
    # shellcheck disable=SC2086
    docker build $net \
        -f "$HERE/Dockerfile.runtime" \
        --build-arg "BASE_TAG=$(_base_tag)" \
        --build-arg "USER_NAME=${USER_NAME}" \
        --build-arg "USER_UID=${USER_UID}" \
        --build-arg "USER_GID=${USER_GID}" \
        --build-arg "USER_SHELL=${USER_SHELL}" \
        --build-arg "APT_RUNTIME=${APT_RUNTIME}" \
        -t "$(_runtime_tag)" "$HERE"
}

cmd_build() {
    docker image inspect "$(_base_tag)" >/dev/null 2>&1 || cmd_build_base || return 1
    cmd_build_runtime
}

cmd_rebuild() { cmd_build_base && cmd_build_runtime; }

cmd_up_cli()  { ensure_data_dirs; "${DC[@]}" --profile cli up -d kali-cli; }
cmd_up_gui()  { ensure_data_dirs; "${DC[@]}" --profile gui up -d kali-gui; \
                local p; p=$(jq -r '.modes.gui.novnc_port' "$CFG"); \
                echo "→ open http://localhost:${p}/"; }
cmd_down()    { "${DC[@]}" --profile cli --profile gui down; }
cmd_shell()   { docker exec -it kali-fallback-cli "${USER_SHELL}" -l; }
cmd_logs()    { "${DC[@]}" --profile cli --profile gui logs -f --tail=100; }
cmd_ps()      { "${DC[@]}" --profile cli --profile gui ps; }

cmd_test() {
    local fail=0
    echo -n "[1/6] install.json valid JSON ......... "
    jq empty "$CFG" && echo "OK"   || { echo "FAIL"; fail=1; }

    echo -n "[2/6] required keys present ........... "
    jq -e '.image.local_tag and (.container.network_mode=="host") and (.modes.cli and .modes.gui) and (.apt.metapackages | length > 0) and (.ghcr.tags | length > 0)' "$CFG" >/dev/null \
        && echo "OK" || { echo "FAIL"; fail=1; }

    echo -n "[3/6] image built locally ............. "
    docker image inspect "${KALI_IMAGE}" >/dev/null 2>&1 \
        && echo "OK" || { echo "MISSING (run: $0 build)"; fail=1; }

    echo -n "[4/6] image has jq + entrypoint ....... "
    if docker image inspect "${KALI_IMAGE}" >/dev/null 2>&1; then
        docker run --rm --entrypoint /bin/bash "${KALI_IMAGE}" -c \
            'command -v jq >/dev/null && test -x /usr/local/bin/entrypoint.sh' \
            && echo "OK" || { echo "FAIL"; fail=1; }
    else echo "SKIP"; fi

    echo -n "[5/6] GHCR token reachable ............ "
    ghcr_token >/dev/null 2>&1 && echo "OK" || { echo "MISSING (set GHCR_TOKEN or 'gh auth login')"; fail=1; }

    echo -n "[6/6] GHCR repo reachable (HEAD) ...... "
    if command -v curl >/dev/null 2>&1 && tok="$(ghcr_token 2>/dev/null)"; then
        bearer=$(printf '%s' "$tok" | base64 -w0)
        code=$(curl -s -o /dev/null -w '%{http_code}' \
                 -H "Authorization: Bearer ${bearer}" \
                 "https://${GHCR_REG}/v2/${GHCR_OWNER}/${GHCR_NAME}/tags/list" || echo 000)
        case "$code" in
            200|401|404) echo "OK ($code — repo addressable)" ;;
            *) echo "FAIL ($code)"; fail=1 ;;
        esac
    else echo "SKIP"; fi

    return "$fail"
}

ghcr_tags() { jq -r '.ghcr.tags[]' "$CFG"; }

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
    printf '%s' "$token" | docker login "$GHCR_REG" -u "$user" --password-stdin
}

cmd_push() {
    docker image inspect "$KALI_IMAGE" >/dev/null 2>&1 \
        || { echo "local image $KALI_IMAGE missing — run: $0 build"; return 1; }
    cmd_login || return 1
    while IFS= read -r tag; do
        local full="${GHCR_REPO}:${tag}"
        echo "→ tag  $KALI_IMAGE  →  $full"
        docker tag  "$KALI_IMAGE" "$full"
        echo "→ push $full"
        docker push "$full"
    done < <(ghcr_tags)
}

cmd_pull() {
    cmd_login || return 1
    local first=""
    while IFS= read -r tag; do
        local full="${GHCR_REPO}:${tag}"
        echo "→ pull $full"
        docker pull "$full"
        [[ -z "$first" ]] && first="$full"
    done < <(ghcr_tags)
    [[ -n "$first" ]] && docker tag "$first" "$KALI_IMAGE"
}

cmd_ship() { cmd_build && cmd_push; }

cmd_clean() {
    "${DC[@]}" --profile cli --profile gui down -v 2>/dev/null || true
    docker image rm "${KALI_IMAGE}" 2>/dev/null || true
    rm -rf "$HERE/data"
}

case "${1:-}" in
    build)         cmd_build         ;;
    build-base)    cmd_build_base    ;;
    build-runtime) cmd_build_runtime ;;
    rebuild)       cmd_rebuild       ;;
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
    test)    cmd_test    ;;
    clean)   cmd_clean   ;;
    ""|help|-h|--help)
        awk '/^# Usage:/{p=1} p && !/^#/{exit} p{sub(/^# ?/,""); print}' "$0" ;;
    *) echo "unknown: $1"; exit 2 ;;
esac
