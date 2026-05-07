#!/usr/bin/env bash
# scripts/apply-config.sh
#
# Apply the merged config/base/* + config/<env>/* configuration to a
# running webMethods Microservices Runtime by invoking wm-mcp-server
# tools in dependency order.
#
# Pipeline:
#   1. Deep-merge config/base + config/<env> per docs/config-merge.md
#      (scripts/lib/yaml-merge.sh).
#   2. Resolve ${SECRET:NAME} placeholders against env vars
#      (scripts/lib/secret-resolver.sh). CI is expected to populate the
#      env vars from GitHub Secrets / Vault / k8s Secret before
#      invoking this script. *_secret_ref URIs are passed through as
#      opaque pointers; wm-mcp resolves them on the runtime side.
#   3. For each section, call the spec-mandated wm-mcp verb per entry,
#      in this order:
#        a. set_global_variable      (variables[])
#        b. create_jdbc_pool         (pools[])
#        c. create_jms_alias         (aliases[])
#        d. create_kafka_connection  (connections[])
#        e. create_mqtt_connection   (connections[])
#        f. set_extended_setting     (k=v from properties)
#        g. create_port              (ports[])
#           set_port_ip_filter       (when allowed_ips/denied_ips set)
#        h. create_group, create_user, assign_acl
#
# Idempotency contract: the wm-mcp create_* / set_* verbs are upsert.
# Each response includes a "status" field
# ({created, updated, unchanged, failed}). The script does not attempt
# its own diff -- it relies on wm-mcp returning "unchanged" when the
# desired state already matches MSR's current state. That makes a
# second run a no-op and a single-field tweak patches only the
# affected resource (acceptance criterion).
#
# Usage:
#   scripts/apply-config.sh --env <ENV> [options]
#
# Options:
#   --env ENV               (required) one of dev|test|prod (or any
#                           directory under config/ that's not "base")
#   --config-dir DIR        default: <repo>/config
#   --reports-dir DIR       default: <repo>/reports/config
#   --container NAME        run wm-mcp inside this container via
#                           `docker exec`; default: invoke wm-mcp from PATH
#   --mcp-cmd PATH          wm-mcp binary name/path (default: wm-mcp)
#   --target URL            value of WM_MCP_TARGET env var passed to
#                           wm-mcp (default http://localhost:5555)
#   --user USER             default Administrator
#   --password PASS         default manage
#   --dry-run               compute the merged + resolved effective
#                           config, write the reports, but do NOT call
#                           wm-mcp. Each entry is logged with status
#                           "dry-run".
#   --keep-effective-only   skip wm-mcp calls AND skip writing apply.log
#                           / result.json. Useful for previewing what
#                           the merge produces.
#
# Outputs (under --reports-dir):
#   effective.<ENV>.json         merged + secret-resolved config (full)
#   effective.<ENV>.properties   merged + secret-resolved props body
#   apply.log                    human-readable per-call log
#   result.json                  machine-readable array of call results
#
# Exit codes:
#   0  every wm-mcp call succeeded (status created/updated/unchanged)
#   1  setup error (missing dep, missing config, unresolved secret)
#   2  one or more wm-mcp calls failed

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)

# shellcheck source=lib/yaml-merge.sh
. "${SCRIPT_DIR}/lib/yaml-merge.sh"
# shellcheck source=lib/secret-resolver.sh
. "${SCRIPT_DIR}/lib/secret-resolver.sh"

# ---------------------------------------------------------------------
# Defaults / CLI parsing
# ---------------------------------------------------------------------
ENV=""
CONFIG_DIR="${REPO_ROOT}/config"
REPORTS_DIR="${REPO_ROOT}/reports/config"
CONTAINER=""
WM_MCP_CMD="${WM_MCP_CMD:-wm-mcp}"
WM_MCP_TARGET="${WM_MCP_TARGET:-http://localhost:5555}"
WM_MCP_USER="${WM_MCP_USER:-Administrator}"
WM_MCP_PASSWORD="${WM_MCP_PASSWORD:-manage}"
DRY_RUN=0
KEEP_EFFECTIVE_ONLY=0

usage() {
    sed -n 's/^# \{0,1\}//p' "$0" | sed -n '2,80p'
}

while (( $# > 0 )); do
    case "$1" in
        --env)                  ENV=$2; shift 2 ;;
        --config-dir)           CONFIG_DIR=$2; shift 2 ;;
        --reports-dir)          REPORTS_DIR=$2; shift 2 ;;
        --container)            CONTAINER=$2; shift 2 ;;
        --mcp-cmd)              WM_MCP_CMD=$2; shift 2 ;;
        --target)               WM_MCP_TARGET=$2; shift 2 ;;
        --user)                 WM_MCP_USER=$2; shift 2 ;;
        --password)             WM_MCP_PASSWORD=$2; shift 2 ;;
        --dry-run)              DRY_RUN=1; shift ;;
        --keep-effective-only)  KEEP_EFFECTIVE_ONLY=1; DRY_RUN=1; shift ;;
        -h|--help)              usage; exit 0 ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 1 ;;
    esac
done

if [[ -z "$ENV" ]]; then
    echo "ERROR: --env <name> is required (e.g. --env dev)" >&2
    exit 1
fi
if [[ "$ENV" == "base" ]]; then
    echo "ERROR: --env cannot be 'base' (base is the ground-truth, not an overlay)" >&2
    exit 1
fi
if [[ ! -d "${CONFIG_DIR}/${ENV}" ]]; then
    # The overlay dir may legitimately be empty (or missing) and that
    # just means "use base verbatim". But if config/<env>/ does not
    # exist at all, the user has likely typo'd the name.
    echo "ERROR: env overlay directory not found: ${CONFIG_DIR}/${ENV}" >&2
    exit 1
fi

yaml_merge_require_tools || exit 1
secret_resolver_require_tools || exit 1

mkdir -p -- "${REPORTS_DIR}"

EFFECTIVE_RAW="${REPORTS_DIR}/effective.${ENV}.raw.json"
EFFECTIVE_JSON="${REPORTS_DIR}/effective.${ENV}.json"
EFFECTIVE_PROPS="${REPORTS_DIR}/effective.${ENV}.properties"
APPLY_LOG="${REPORTS_DIR}/apply.log"
RESULT_JSON="${REPORTS_DIR}/result.json"

# ---------------------------------------------------------------------
# Phase 1: merge
# ---------------------------------------------------------------------
echo "Merging config/base + config/${ENV} -> ${EFFECTIVE_RAW#${REPO_ROOT}/}"
yaml_merge_env "${CONFIG_DIR}" "${ENV}" "${EFFECTIVE_RAW}"

# ---------------------------------------------------------------------
# Phase 2: secret resolution
# ---------------------------------------------------------------------
echo "Resolving \${SECRET:NAME} placeholders -> ${EFFECTIVE_JSON#${REPO_ROOT}/}"
secret_resolve_json "${EFFECTIVE_RAW}" "${EFFECTIVE_JSON}"

# Extract the merged extended-settings text (already secret-resolved)
# into its own file. jq -r unwraps the JSON-encoded string.
if jq -e 'has("_extended-settings-text")' "${EFFECTIVE_JSON}" >/dev/null; then
    jq -r '."_extended-settings-text"' "${EFFECTIVE_JSON}" > "${EFFECTIVE_PROPS}"
else
    : > "${EFFECTIVE_PROPS}"
fi

if (( KEEP_EFFECTIVE_ONLY == 1 )); then
    echo "Effective config written; --keep-effective-only set, exiting."
    echo "  ${EFFECTIVE_JSON#${REPO_ROOT}/}"
    echo "  ${EFFECTIVE_PROPS#${REPO_ROOT}/}"
    exit 0
fi

# ---------------------------------------------------------------------
# Phase 3: wm-mcp orchestration
#
# Each call writes one line to apply.log and one entry to result.json.
# We intentionally do NOT abort on the first failure -- the goal is to
# surface every problem in one run so an operator gets a complete
# punch-list. Final exit code is 0 iff every entry's status is
# created/updated/unchanged.
# ---------------------------------------------------------------------
START_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
    printf '# apply-config.sh log\n'
    printf '# env=%s  target=%s  ts=%s\n' "${ENV}" "${WM_MCP_TARGET}" "${START_TS}"
    if (( DRY_RUN == 1 )); then
        printf '# DRY RUN: no wm-mcp calls were made\n'
    fi
    printf '\n'
} > "${APPLY_LOG}"
echo '[]' > "${RESULT_JSON}"

fail_total=0
created_total=0
updated_total=0
unchanged_total=0

# wm_mcp_invoke VERB INPUT_JSON
# Pipe INPUT_JSON to wm-mcp <verb> --output json on stdin. Returns
# the captured stdout. Stderr is captured into the response too if
# the call fails so failures are debuggable from the log.
wm_mcp_invoke() {
    local verb=$1
    local input_json=$2
    if [[ -n "${CONTAINER}" ]]; then
        printf '%s' "${input_json}" | docker exec -i \
            -e WM_MCP_TARGET="${WM_MCP_TARGET}" \
            -e WM_MCP_USER="${WM_MCP_USER}" \
            -e WM_MCP_PASSWORD="${WM_MCP_PASSWORD}" \
            "${CONTAINER}" \
            ${WM_MCP_CMD} "${verb}" --output json
    else
        printf '%s' "${input_json}" | \
            WM_MCP_TARGET="${WM_MCP_TARGET}" \
            WM_MCP_USER="${WM_MCP_USER}" \
            WM_MCP_PASSWORD="${WM_MCP_PASSWORD}" \
            ${WM_MCP_CMD} "${verb}" --output json
    fi
}

# call_wm_mcp VERB IDENTITY INPUT_JSON
# The orchestration primitive. Every section's per-entry call goes
# through here so logging, dry-run, and failure handling are uniform.
call_wm_mcp() {
    local verb=$1
    local identity=$2
    local input_json=$3
    local response=""
    local status=""
    local rc=0

    if (( DRY_RUN == 1 )); then
        response=$(jq -n --arg tool "$verb" --arg id "$identity" \
            '{tool:$tool, status:"dry-run", id:$id}')
        status="dry-run"
    else
        local stderr_file
        stderr_file=$(mktemp)
        set +e
        response=$(wm_mcp_invoke "${verb}" "${input_json}" 2>"${stderr_file}")
        rc=$?
        set -e
        if (( rc != 0 )) || ! jq -e . <<<"${response}" >/dev/null 2>&1; then
            local stderr_text
            stderr_text=$(cat "${stderr_file}" 2>/dev/null || true)
            response=$(jq -n \
                --arg tool "$verb" \
                --arg id "$identity" \
                --argjson rc "$rc" \
                --arg stderr "$stderr_text" \
                --arg stdout "$response" \
                '{tool:$tool, status:"failed", id:$id,
                  exit_code:$rc, stderr:$stderr, stdout:$stdout}')
            status="failed"
        else
            status=$(jq -r '.status // "unknown"' <<<"${response}")
        fi
        rm -f "${stderr_file}"
    fi

    printf '%-26s %-40s -> %s\n' "${verb}" "${identity}" "${status}" \
        | tee -a "${APPLY_LOG}"

    # Append to result.json atomically.
    local tmp="${RESULT_JSON}.tmp"
    jq --arg verb "$verb" --arg identity "$identity" --argjson resp "$response" \
        '. + [{verb:$verb, identity:$identity, response:$resp}]' \
        "${RESULT_JSON}" > "${tmp}"
    mv -- "${tmp}" "${RESULT_JSON}"

    case "$status" in
        created)   created_total=$((created_total + 1)) ;;
        updated)   updated_total=$((updated_total + 1)) ;;
        unchanged) unchanged_total=$((unchanged_total + 1)) ;;
        dry-run)   : ;;
        *)         fail_total=$((fail_total + 1)) ;;
    esac
}

# Helper: pull a JSON path out of EFFECTIVE_JSON; on missing -> empty.
jget() {
    local path=$1
    jq -c "${path} // empty" "${EFFECTIVE_JSON}"
}

# ---- 3.a set_global_variable ----------------------------------------
echo
echo "== set_global_variable =="
while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    id=$(jq -r '.key // "?"' <<<"$entry")
    call_wm_mcp "set_global_variable" "$id" "$entry"
done < <(jget '."global-variables".variables[]?')

# ---- 3.b create_jdbc_pool -------------------------------------------
echo
echo "== create_jdbc_pool =="
while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    id=$(jq -r '.alias // "?"' <<<"$entry")
    call_wm_mcp "create_jdbc_pool" "$id" "$entry"
done < <(jget '."jdbc-pools".pools[]?')

# ---- 3.c create_jms_alias -------------------------------------------
echo
echo "== create_jms_alias =="
while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    id=$(jq -r '.alias // "?"' <<<"$entry")
    call_wm_mcp "create_jms_alias" "$id" "$entry"
done < <(jget '."jms-aliases".aliases[]?')

# ---- 3.d create_kafka_connection ------------------------------------
echo
echo "== create_kafka_connection =="
while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    id=$(jq -r '.alias // "?"' <<<"$entry")
    call_wm_mcp "create_kafka_connection" "$id" "$entry"
done < <(jget '."kafka-connections".connections[]?')

# ---- 3.e create_mqtt_connection -------------------------------------
echo
echo "== create_mqtt_connection =="
while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    id=$(jq -r '.alias // "?"' <<<"$entry")
    call_wm_mcp "create_mqtt_connection" "$id" "$entry"
done < <(jget '."mqtt-connections".connections[]?')

# ---- 3.f set_extended_setting ---------------------------------------
echo
echo "== set_extended_setting =="
if [[ -s "${EFFECTIVE_PROPS}" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip blanks, comments.
        [[ -z "$line" ]] && continue
        case "$line" in
            \#*|!*) continue ;;
        esac
        # Split on first '='.
        if [[ "$line" != *"="* ]]; then
            continue
        fi
        key="${line%%=*}"
        value="${line#*=}"
        # Trim leading whitespace on key.
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        [[ -z "$key" ]] && continue
        entry=$(jq -n --arg k "$key" --arg v "$value" '{key:$k, value:$v}')
        call_wm_mcp "set_extended_setting" "$key" "$entry"
    done < "${EFFECTIVE_PROPS}"
else
    echo "(no extended-settings.properties content)"
fi

# ---- 3.g create_port + set_port_ip_filter ---------------------------
echo
echo "== create_port (+ set_port_ip_filter) =="
while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    id=$(jq -r '.name // "?"' <<<"$entry")
    # Strip the IP filter fields from the create_port payload; they
    # are applied separately via set_port_ip_filter so the lifecycle
    # of the port and its filter is independent.
    port_payload=$(jq 'del(.allowed_ips, .denied_ips)' <<<"$entry")
    call_wm_mcp "create_port" "$id" "$port_payload"
    has_filter=$(jq -r 'select((.allowed_ips // [] | length) + (.denied_ips // [] | length) > 0) | "yes"' <<<"$entry")
    if [[ "$has_filter" == "yes" ]]; then
        filter_payload=$(jq '{port_name: .name, allowed_ips: (.allowed_ips // []), denied_ips: (.denied_ips // [])}' <<<"$entry")
        call_wm_mcp "set_port_ip_filter" "$id" "$filter_payload"
    fi
done < <(jget '.ports.ports[]?')

# ---- 3.h create_group, create_user, assign_acl ----------------------
echo
echo "== create_group =="
while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    id=$(jq -r '.name // "?"' <<<"$entry")
    call_wm_mcp "create_group" "$id" "$entry"
done < <(jget '."users-and-groups".groups[]?')

echo
echo "== create_user =="
while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    id=$(jq -r '.username // "?"' <<<"$entry")
    call_wm_mcp "create_user" "$id" "$entry"
done < <(jget '."users-and-groups".users[]?')

echo
echo "== assign_acl =="
while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    id=$(jq -r '.name // "?"' <<<"$entry")
    call_wm_mcp "assign_acl" "$id" "$entry"
done < <(jget '.acls.acls[]?')

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------
END_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
    printf '\n# Summary  (start=%s end=%s)\n' "${START_TS}" "${END_TS}"
    printf '# created=%d updated=%d unchanged=%d failed=%d\n' \
        "${created_total}" "${updated_total}" "${unchanged_total}" "${fail_total}"
} >> "${APPLY_LOG}"

echo
echo "Apply summary for env=${ENV}:"
printf '  created=%d  updated=%d  unchanged=%d  failed=%d\n' \
    "${created_total}" "${updated_total}" "${unchanged_total}" "${fail_total}"
echo "  log:    ${APPLY_LOG#${REPO_ROOT}/}"
echo "  result: ${RESULT_JSON#${REPO_ROOT}/}"

if (( fail_total > 0 )); then
    exit 2
fi
exit 0
