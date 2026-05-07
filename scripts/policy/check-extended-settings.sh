#!/usr/bin/env bash
# scripts/policy/check-extended-settings.sh
#
# Policy gate: every key in extended-settings.properties must be a
# real Integration Server "Extended Settings" key, as advertised by
# the running MSR's settings catalog.
#
# Catalog source (one of):
#   --catalog FILE          local file: either JSON {"keys":[...]} OR
#                           one key per line. Bypasses wm-mcp, so
#                           tests run offline and CI can pre-fetch a
#                           snapshot if it doesn't want a live MSR
#                           dependency on every PR.
#   --container NAME        invoke `docker exec NAME wm-mcp
#                           list_settings_catalog --output json`
#                           against an already-running MSR sidecar.
#   --mcp-cmd PATH          run `<PATH> list_settings_catalog
#                           --output json` on the host (default
#                           wm-mcp). Honours WM_MCP_TARGET / USER /
#                           PASSWORD env vars per the project-wide
#                           wm-mcp invocation contract.
#
# Inputs:
#   --config-dir DIR        default <repo>/config; all
#                           extended-settings.properties under any
#                           top-level subdir are scanned.
#   --properties FILE       check a single file directly (test hook,
#                           also handy for ad-hoc validation).
#   --allow KEY             exempt a single key (repeatable). Use
#                           sparingly; intended for genuinely custom
#                           watt.* keys an in-house package introduces.
#                           Env var POLICY_SETTINGS_ALLOW (space-
#                           separated) is also honoured so CI can
#                           inject exemptions without YAML edits.
#
# Exit codes:
#   0  every declared key is in the catalog
#   1  setup error (missing tool, can't read catalog, no inputs, ...)
#   2  one or more keys are unknown (policy violation)

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

CONFIG_DIR="${REPO_ROOT}/config"
PROPS_FILE=""
CATALOG_FILE=""
CONTAINER=""
WM_MCP_CMD="${WM_MCP_CMD:-wm-mcp}"
declare -a ALLOWLIST=()
if [[ -n "${POLICY_SETTINGS_ALLOW:-}" ]]; then
    # shellcheck disable=SC2206
    ALLOWLIST+=( ${POLICY_SETTINGS_ALLOW} )
fi

usage() { sed -n 's/^# \{0,1\}//p' "$0" | sed -n '2,40p'; }

while (( $# > 0 )); do
    case "$1" in
        --config-dir)   CONFIG_DIR=$2; shift 2 ;;
        --properties)   PROPS_FILE=$2; shift 2 ;;
        --catalog)      CATALOG_FILE=$2; shift 2 ;;
        --container)    CONTAINER=$2; shift 2 ;;
        --mcp-cmd)      WM_MCP_CMD=$2; shift 2 ;;
        --allow)        ALLOWLIST+=("$2"); shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)
            policy_log_fail "unknown argument: $1"
            usage >&2
            exit 1 ;;
    esac
done

if ! command -v jq >/dev/null 2>&1; then
    policy_log_fail "jq is required"
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    policy_log_fail "python3 is required"
    exit 1
fi

# ---------------------------------------------------------------------
# Discover the property files to scan.
# ---------------------------------------------------------------------
declare -a PROPS_FILES=()
if [[ -n "$PROPS_FILE" ]]; then
    if [[ ! -f "$PROPS_FILE" ]]; then
        policy_log_fail "--properties file not found: $PROPS_FILE"
        exit 1
    fi
    PROPS_FILES+=("$PROPS_FILE")
else
    if [[ ! -d "$CONFIG_DIR" ]]; then
        policy_log_fail "config dir not found: $CONFIG_DIR"
        exit 1
    fi
    mapfile -t PROPS_FILES < <(
        find "$CONFIG_DIR" -mindepth 2 -maxdepth 2 -type f \
            -name 'extended-settings.properties' | sort
    )
fi

if (( ${#PROPS_FILES[@]} == 0 )); then
    policy_log_info "no extended-settings.properties found under $CONFIG_DIR (nothing to check)"
    policy_log_pass "no unknown extended-settings keys (0 file(s) checked)"
    exit 0
fi

# ---------------------------------------------------------------------
# Resolve the catalog -> CATALOG_KEYS_FILE (one key per line, sorted).
# ---------------------------------------------------------------------
CATALOG_KEYS_FILE="${TMPDIR:-/tmp}/extended-settings-catalog.$$"
trap 'rm -f -- "$CATALOG_KEYS_FILE" "${CATALOG_RAW:-}"' EXIT

normalise_catalog() {
    # Accept either JSON {"keys": [...]} (or a bare array) OR plain
    # one-key-per-line text. Strip blanks and # comments.
    local src=$1
    if jq -e . < "$src" >/dev/null 2>&1; then
        jq -r '
            if type == "object" then
                (.keys // .settings // .data // [])
            elif type == "array" then
                .
            else
                empty
            end
            | .[]?
            | if type == "string" then . elif (.key|type)=="string" then .key else empty end
        ' < "$src"
    else
        sed -E 's/[[:space:]]*#.*$//' < "$src" \
            | sed -E '/^[[:space:]]*$/d'
    fi | sort -u
}

if [[ -n "$CATALOG_FILE" ]]; then
    if [[ ! -f "$CATALOG_FILE" ]]; then
        policy_log_fail "--catalog file not found: $CATALOG_FILE"
        exit 1
    fi
    normalise_catalog "$CATALOG_FILE" > "$CATALOG_KEYS_FILE"
else
    CATALOG_RAW="${TMPDIR:-/tmp}/extended-settings-catalog.raw.$$"
    if [[ -n "$CONTAINER" ]]; then
        if ! command -v docker >/dev/null 2>&1; then
            policy_log_fail "--container requires docker on PATH"
            exit 1
        fi
        docker exec \
            -e WM_MCP_TARGET="${WM_MCP_TARGET:-http://localhost:5555}" \
            -e WM_MCP_USER="${WM_MCP_USER:-Administrator}" \
            -e WM_MCP_PASSWORD="${WM_MCP_PASSWORD:-manage}" \
            "$CONTAINER" \
            "$WM_MCP_CMD" list_settings_catalog --output json \
            > "$CATALOG_RAW" 2>/dev/null \
            || { policy_log_fail "wm-mcp list_settings_catalog failed in container $CONTAINER"; exit 1; }
    else
        if ! command -v "$WM_MCP_CMD" >/dev/null 2>&1; then
            policy_log_fail "$WM_MCP_CMD not on PATH; pass --catalog or --container"
            exit 1
        fi
        "$WM_MCP_CMD" list_settings_catalog --output json \
            > "$CATALOG_RAW" 2>/dev/null \
            || { policy_log_fail "wm-mcp list_settings_catalog failed"; exit 1; }
    fi
    normalise_catalog "$CATALOG_RAW" > "$CATALOG_KEYS_FILE"
fi

if [[ ! -s "$CATALOG_KEYS_FILE" ]]; then
    policy_log_fail "settings catalog is empty -- refusing to greenlight every key"
    exit 1
fi

catalog_size=$(wc -l < "$CATALOG_KEYS_FILE")
policy_log_info "settings catalog loaded: $catalog_size key(s)"

# Fast lookup helper -- O(1) via associative array.
declare -A CATALOG=()
while IFS= read -r k; do
    CATALOG["$k"]=1
done < "$CATALOG_KEYS_FILE"
for k in "${ALLOWLIST[@]}"; do
    CATALOG["$k"]=1
done

# ---------------------------------------------------------------------
# Scan each properties file. Spec format: simple `key=value` lines,
# `#` for comments, blank lines ignored. We do NOT honour the JVM
# Properties spec's continuation-line / unicode-escape quirks --
# extended-settings.properties is a flat KV file in this project
# (see config/base/extended-settings.properties).
# ---------------------------------------------------------------------
violations=0
checked_files=0
for f in "${PROPS_FILES[@]}"; do
    rel=${f#"${REPO_ROOT}/"}
    checked_files=$((checked_files+1))
    # Strip any trailing \r (CRLF inputs), drop comments + blanks,
    # then take the LHS of the first '=' on each line.
    while IFS= read -r line; do
        line=${line%$'\r'}
        # Skip comments / blanks.
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        # Lines without '=' aren't legal extended-settings entries.
        if ! [[ "$line" == *"="* ]]; then
            policy_log_warn "$rel: skipping non-KV line: $line"
            continue
        fi
        key=${line%%=*}
        # Trim whitespace.
        key=${key#"${key%%[![:space:]]*}"}
        key=${key%"${key##*[![:space:]]}"}
        [[ -z "$key" ]] && continue
        if [[ -z "${CATALOG["$key"]+x}" ]]; then
            policy_log_fail "$rel: unknown key '$key' (not in MSR settings catalog)"
            violations=$((violations+1))
        fi
    done < "$f"
done

if (( violations > 0 )); then
    echo "::error::$violations extended-settings key(s) not in the MSR catalog. Either rename, drop, or pass --allow."
    exit 2
fi

policy_log_pass "all extended-settings keys are in the catalog ($checked_files file(s) checked)"
exit 0
