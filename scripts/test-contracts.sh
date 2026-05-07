#!/usr/bin/env bash
# scripts/test-contracts.sh
#
# Contract tests for the public REST/SOAP surface of the running MSR.
#
# For every committed contract under api/:
#   *.openapi.yaml | openapi.yaml -- exported via wm-mcp generate_openapi,
#                                    diffed against the committed file via
#                                    scripts/lib/openapi-diff.py
#   *.wsdl                        -- exported via wm-mcp generate_wsdl,
#                                    diffed via scripts/lib/wsdl-diff.py
#
# An OpenAPI doc names its MSR-side source via the `info.x-msr-source`
# extension; a WSDL names it in a sidecar file `<basename>.wsdl.source`
# (single line, the source identifier passed verbatim to wm-mcp).
#
# Acceptance criteria for Task 4.3:
#   * Adding a new required field to a request body fails CI.
#   * The failure message names the field AND the endpoint.
#   * Adding the `breaking-api` label to the PR turns the failure into a
#     warning (the script is invoked with --allow-breaking by the
#     workflow when the label is present).
#
# Usage:
#   scripts/test-contracts.sh [options]
#
# Options:
#   --api-dir DIR           default: <repo>/api
#   --reports-dir DIR       default: <repo>/reports/contracts
#   --target URL            MSR base URL (default: http://localhost:5555)
#   --user NAME             IS admin user (default: Administrator)
#   --password PASS         IS admin password (default: manage)
#   --container NAME        docker exec into NAME instead of host wm-mcp
#   --allow-breaking        downgrade breaking changes to warnings
#   --skip-rest             don't process *.openapi.yaml
#   --skip-soap             don't process *.wsdl
#   --offline GENERATED_DIR don't call wm-mcp; treat GENERATED_DIR as the
#                           "exported" tree (used by the verify harness
#                           and for retro-fitting against archived runs)
#
# Exit codes:
#   0  every contract is non-breaking, or --allow-breaking and breaking
#      changes were detected (printed as WARNING)
#   1  setup error (no contracts, missing tool, MSR unreachable, ...)
#   2  one or more breaking changes detected (and --allow-breaking unset)

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
API_DIR="${REPO_ROOT}/api"
REPORTS_DIR="${REPO_ROOT}/reports/contracts"
MSR_TARGET="${MSR_TARGET:-http://localhost:5555}"
MSR_USER="${MSR_USER:-Administrator}"
MSR_PASSWORD="${MSR_PASSWORD:-manage}"
CONTAINER=""
ALLOW_BREAKING="${ALLOW_BREAKING_API:-0}"
SKIP_REST=0
SKIP_SOAP=0
OFFLINE_DIR=""

usage() { sed -n 's/^# \{0,1\}//p' "$0" | sed -n '2,46p'; }

while (( $# > 0 )); do
    case "$1" in
        --api-dir)         API_DIR=$2; shift 2 ;;
        --reports-dir)     REPORTS_DIR=$2; shift 2 ;;
        --target)          MSR_TARGET=$2; shift 2 ;;
        --user)            MSR_USER=$2; shift 2 ;;
        --password)        MSR_PASSWORD=$2; shift 2 ;;
        --container)       CONTAINER=$2; shift 2 ;;
        --allow-breaking)  ALLOW_BREAKING=1; shift ;;
        --skip-rest)       SKIP_REST=1; shift ;;
        --skip-soap)       SKIP_SOAP=1; shift ;;
        --offline)         OFFLINE_DIR=$2; shift 2 ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Tool checks
# ---------------------------------------------------------------------------
require_host_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: required tool not on PATH: $1" >&2
        exit 1
    fi
}
require_host_tool python3
require_host_tool find

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    echo "ERROR: PyYAML required (pip install pyyaml)" >&2
    exit 1
fi

if [[ -z "${OFFLINE_DIR}" ]]; then
    require_host_tool curl
    if [[ -n "${CONTAINER}" ]]; then
        require_host_tool docker
    fi
fi

if [[ ! -d "${API_DIR}" ]]; then
    echo "ERROR: api dir not found: ${API_DIR}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------
GEN_DIR="${REPORTS_DIR}/generated"
DIFF_DIR="${REPORTS_DIR}/diff"
mkdir -p -- "${GEN_DIR}" "${DIFF_DIR}"

JUNIT_XML="${REPORTS_DIR}/junit.xml"

# ---------------------------------------------------------------------------
# Contract discovery
# ---------------------------------------------------------------------------
mapfile -t REST_CONTRACTS < <(
    find "${API_DIR}" -maxdepth 2 -type f \
        \( -name '*.openapi.yaml' -o -name '*.openapi.yml' \
           -o -name 'openapi.yaml' -o -name 'openapi.yml' \) \
        2>/dev/null | sort
)
mapfile -t SOAP_CONTRACTS < <(
    find "${API_DIR}" -maxdepth 2 -type f -name '*.wsdl' 2>/dev/null | sort
)

if (( SKIP_REST == 1 )); then REST_CONTRACTS=(); fi
if (( SKIP_SOAP == 1 )); then SOAP_CONTRACTS=(); fi

if (( ${#REST_CONTRACTS[@]} == 0 )) && (( ${#SOAP_CONTRACTS[@]} == 0 )); then
    echo "ERROR: no contracts found under ${API_DIR}" >&2
    echo "       Expected *.openapi.yaml or *.wsdl files." >&2
    exit 1
fi

echo ">>> Contracts to verify:"
for c in "${REST_CONTRACTS[@]}"; do echo "    REST  ${c#${REPO_ROOT}/}"; done
for c in "${SOAP_CONTRACTS[@]}"; do echo "    SOAP  ${c#${REPO_ROOT}/}"; done
echo

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Read info.x-msr-source from an OpenAPI doc.
read_x_msr_source() {
    local file="$1"
    python3 - "$file" <<'PY'
import sys, yaml
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    doc = yaml.safe_load(fh) or {}
src = (doc.get("info") or {}).get("x-msr-source")
if not src:
    sys.exit(2)
sys.stdout.write(str(src))
PY
}

# Read the sidecar source file for a WSDL (<basename>.wsdl.source).
read_wsdl_source() {
    local wsdl="$1"
    local sidecar="${wsdl}.source"
    if [[ -f "${sidecar}" ]]; then
        # Trim whitespace and ignore comment lines.
        grep -v '^[[:space:]]*#' "${sidecar}" \
            | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
            | grep -v '^$' \
            | head -n1
    fi
}

# Invoke wm-mcp either on the host or via docker exec.
wm_mcp() {
    local args=("$@")
    if [[ -n "${CONTAINER}" ]]; then
        docker exec \
            -e WM_MCP_TARGET="${MSR_TARGET}" \
            -e WM_MCP_USER="${MSR_USER}" \
            -e WM_MCP_PASSWORD="${MSR_PASSWORD}" \
            "${CONTAINER}" \
            wm-mcp "${args[@]}"
    else
        WM_MCP_TARGET="${MSR_TARGET}" \
        WM_MCP_USER="${MSR_USER}" \
        WM_MCP_PASSWORD="${MSR_PASSWORD}" \
            wm-mcp "${args[@]}"
    fi
}

# ---------------------------------------------------------------------------
# Per-contract processing
# ---------------------------------------------------------------------------
TOTAL=0
BREAKING_TOTAL=0
PER_CONTRACT_RESULTS=()  # "<rel>|<status>|<count>"

process_rest() {
    local contract="$1"
    local rel="${contract#${REPO_ROOT}/}"
    local base
    base=$(basename -- "${contract}")
    local source
    if ! source=$(read_x_msr_source "${contract}" 2>/dev/null); then
        echo "ERROR: ${rel}: missing required info.x-msr-source extension" >&2
        PER_CONTRACT_RESULTS+=("${rel}|setup_error|0")
        return 1
    fi
    echo ">>> [REST] ${rel}  (source: ${source})"

    local generated="${GEN_DIR}/${base}"
    if [[ -n "${OFFLINE_DIR}" ]]; then
        if [[ -f "${OFFLINE_DIR}/${base}" ]]; then
            cp -f "${OFFLINE_DIR}/${base}" "${generated}"
        else
            echo "ERROR: --offline ${OFFLINE_DIR}/${base} not found" >&2
            PER_CONTRACT_RESULTS+=("${rel}|setup_error|0")
            return 1
        fi
    else
        if ! wm_mcp generate_openapi --source "${source}" --output yaml \
                > "${generated}" 2> "${generated}.err"; then
            echo "ERROR: wm-mcp generate_openapi --source ${source} failed" >&2
            sed 's/^/        /' < "${generated}.err" >&2 || true
            PER_CONTRACT_RESULTS+=("${rel}|setup_error|0")
            return 1
        fi
    fi

    local diff_json="${DIFF_DIR}/${base%.yaml}.json"
    diff_json="${diff_json%.yml}.json"
    set +e
    python3 "${SCRIPT_DIR}/lib/openapi-diff.py" \
        "${contract}" \
        "${generated}" \
        --json "${diff_json}" \
        --quiet
    local rc=$?
    set -e

    local count
    count=$(python3 -c "import json; print(json.load(open('${diff_json}'))['count'])")

    if (( rc == 2 )); then
        echo "ERROR: openapi-diff.py crashed for ${rel}" >&2
        PER_CONTRACT_RESULTS+=("${rel}|setup_error|0")
        return 1
    fi

    if (( count > 0 )); then
        echo "    -> ${count} breaking change(s):"
        python3 -c "
import json
for f in json.load(open('${diff_json}'))['breaking']:
    print('       - ' + f['message'])
"
        BREAKING_TOTAL=$(( BREAKING_TOTAL + count ))
        PER_CONTRACT_RESULTS+=("${rel}|breaking|${count}")
    else
        echo "    -> OK"
        PER_CONTRACT_RESULTS+=("${rel}|ok|0")
    fi
    TOTAL=$(( TOTAL + 1 ))
}

process_soap() {
    local contract="$1"
    local rel="${contract#${REPO_ROOT}/}"
    local base
    base=$(basename -- "${contract}")
    local source
    source=$(read_wsdl_source "${contract}")
    if [[ -z "${source}" ]]; then
        echo "ERROR: ${rel}: missing sidecar ${base}.source naming the wm-mcp source" >&2
        PER_CONTRACT_RESULTS+=("${rel}|setup_error|0")
        return 1
    fi
    echo ">>> [SOAP] ${rel}  (source: ${source})"

    local generated="${GEN_DIR}/${base}"
    if [[ -n "${OFFLINE_DIR}" ]]; then
        if [[ -f "${OFFLINE_DIR}/${base}" ]]; then
            cp -f "${OFFLINE_DIR}/${base}" "${generated}"
        else
            echo "ERROR: --offline ${OFFLINE_DIR}/${base} not found" >&2
            PER_CONTRACT_RESULTS+=("${rel}|setup_error|0")
            return 1
        fi
    else
        if ! wm_mcp generate_wsdl --source "${source}" --output xml \
                > "${generated}" 2> "${generated}.err"; then
            echo "ERROR: wm-mcp generate_wsdl --source ${source} failed" >&2
            sed 's/^/        /' < "${generated}.err" >&2 || true
            PER_CONTRACT_RESULTS+=("${rel}|setup_error|0")
            return 1
        fi
    fi

    local diff_json="${DIFF_DIR}/${base%.wsdl}.json"
    set +e
    python3 "${SCRIPT_DIR}/lib/wsdl-diff.py" \
        "${contract}" \
        "${generated}" \
        --json "${diff_json}" \
        --quiet
    local rc=$?
    set -e

    local count
    count=$(python3 -c "import json; print(json.load(open('${diff_json}'))['count'])")

    if (( rc == 2 )); then
        echo "ERROR: wsdl-diff.py crashed for ${rel}" >&2
        PER_CONTRACT_RESULTS+=("${rel}|setup_error|0")
        return 1
    fi

    if (( count > 0 )); then
        echo "    -> ${count} breaking change(s):"
        python3 -c "
import json
for f in json.load(open('${diff_json}'))['breaking']:
    print('       - ' + f['message'])
"
        BREAKING_TOTAL=$(( BREAKING_TOTAL + count ))
        PER_CONTRACT_RESULTS+=("${rel}|breaking|${count}")
    else
        echo "    -> OK"
        PER_CONTRACT_RESULTS+=("${rel}|ok|0")
    fi
    TOTAL=$(( TOTAL + 1 ))
}

SETUP_FAIL=0
for c in "${REST_CONTRACTS[@]}"; do
    if ! process_rest "${c}"; then SETUP_FAIL=1; fi
done
for c in "${SOAP_CONTRACTS[@]}"; do
    if ! process_soap "${c}"; then SETUP_FAIL=1; fi
done

# ---------------------------------------------------------------------------
# JUnit XML aggregation
# ---------------------------------------------------------------------------
echo
echo ">>> Writing JUnit XML to ${JUNIT_XML}"
python3 - "${JUNIT_XML}" "${DIFF_DIR}" "${PER_CONTRACT_RESULTS[@]}" <<'PY'
import sys, os, json, glob
from xml.etree import ElementTree as ET

junit_path, diff_dir = sys.argv[1], sys.argv[2]
results = sys.argv[3:]

ts = ET.Element("testsuites", {"name": "wm-contracts"})
suite = ET.SubElement(ts, "testsuite", {
    "name": "contract-tests",
    "tests": str(len(results)),
})

failures = 0
errors = 0
for line in results:
    parts = line.split("|")
    rel, status, count = parts[0], parts[1], parts[2] if len(parts) > 2 else "0"
    case = ET.SubElement(suite, "testcase", {
        "classname": "wm.contract",
        "name": rel,
    })
    if status == "ok":
        continue
    if status == "setup_error":
        errors += 1
        ET.SubElement(case, "error", {
            "type": "SetupError",
            "message": f"contract test could not run for {rel}",
        })
        continue
    # status == "breaking"
    failures += 1
    # Attach the per-message text to the failure body so the GitHub UI
    # surfaces "required field 'X' added to <method> <path>" verbatim.
    diff_files = glob.glob(os.path.join(diff_dir, "*.json"))
    msgs = []
    for df in diff_files:
        try:
            with open(df, "r", encoding="utf-8") as fh:
                payload = json.load(fh)
        except (OSError, ValueError):
            continue
        # Match by base path (strip extension to allow .yaml/.yml/.wsdl).
        if os.path.basename(payload.get("base", "")) == os.path.basename(rel):
            for f in payload.get("breaking", []):
                msgs.append(f.get("message", ""))
    fail = ET.SubElement(case, "failure", {
        "type": "BreakingChange",
        "message": f"{count} breaking change(s) detected",
    })
    fail.text = "\n".join(msgs) if msgs else ""

suite.set("failures", str(failures))
suite.set("errors",   str(errors))
ts.set("tests",    str(len(results)))
ts.set("failures", str(failures))
ts.set("errors",   str(errors))
ET.ElementTree(ts).write(junit_path, encoding="UTF-8", xml_declaration=True)
print(f"  -> {junit_path}: tests={len(results)} failures={failures} errors={errors}")
PY

# ---------------------------------------------------------------------------
# Final verdict
# ---------------------------------------------------------------------------
echo
echo "Contract test summary:"
echo "  contracts processed:  ${TOTAL}"
echo "  breaking findings:    ${BREAKING_TOTAL}"
echo "  setup errors:         $(( SETUP_FAIL == 1 ? 1 : 0 ))"
echo "  reports:              ${REPORTS_DIR}"

if (( SETUP_FAIL == 1 )); then
    echo "FAIL: one or more contracts could not be processed (see errors above)" >&2
    exit 1
fi

if (( BREAKING_TOTAL > 0 )); then
    if (( ALLOW_BREAKING == 1 )); then
        # The PR carries the breaking-api label (or the equivalent env var
        # was set). Still print every breaking finding so the maintainer
        # SEES what they're shipping, but don't fail the build.
        cat >&2 <<EOF
WARNING: ${BREAKING_TOTAL} breaking change(s) detected, but --allow-breaking
         is set (PR carries 'breaking-api' label). Treating as a warning.
         See ${DIFF_DIR}/ for per-contract JSON.
EOF
        exit 0
    fi
    echo "FAIL: ${BREAKING_TOTAL} breaking change(s) detected (PR not labelled 'breaking-api')" >&2
    exit 2
fi

echo "PASS: every contract is compatible."
exit 0
