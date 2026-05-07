#!/usr/bin/env bash
# scripts/lint-packages.sh
#
# Lint every package zip under dist/ by booting a throwaway MSR
# container, installing the zips, and invoking wm-mcp-server static
# checks. Aggregate the per-tool reports into a single JUnit XML at
# reports/lint/results.xml so the GitHub Actions test-reporter can
# render the results.
#
# Tools invoked (one wm-mcp call per tool, in order):
#   package_dependency_check  - missing or circular requires
#   namespace_unused_services - dead code (services not referenced)
#   flow_validate             - syntax check on every flow service
#   acl_audit                 - services exposed to Anonymous ACL
#
# Usage:
#   scripts/lint-packages.sh [--dist-dir DIR] [--reports-dir DIR]
#                            [--image IMAGE] [--port N]
#                            [--user USER] [--password PASS]
#                            [--wait-timeout SECONDS]
#                            [--keep]
#
# Defaults:
#   --dist-dir      <repo>/dist
#   --reports-dir   <repo>/reports/lint
#   --image         wm-msr-base:${MSR_VERSION}   (from versions.env)
#   --port          5555
#   --user          Administrator
#   --password      manage
#   --wait-timeout  180  (3x the base image healthcheck start-period)
#
# Required tools on the host: docker, jq, python3, curl, base64.
#
# Required tools in the MSR image: wm-mcp (provided by the wm-msr-base
# image, see docker/base/Dockerfile). The wm-mcp CLI is invoked via
# `docker exec` rather than from the host so admin credentials never
# leave the container's loopback interface.
#
# Exit codes:
#   0  every check passed (or only info/pass severities found)
#   1  setup error: missing host tool, no zips, container won't start,
#                   image not pullable, ...
#   2  one or more checks reported error or warning severity, or a tool
#      crashed and produced no parseable output

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)

# shellcheck source=lib/wmreport-to-junit.sh
. "${SCRIPT_DIR}/lib/wmreport-to-junit.sh"

# ---------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------
DIST_DIR="${REPO_ROOT}/dist"
REPORTS_DIR="${REPO_ROOT}/reports/lint"
MSR_IMAGE="${MSR_IMAGE:-}"
MSR_PORT="${MSR_PORT:-5555}"
MSR_USER="${MSR_USER:-Administrator}"
MSR_PASSWORD="${MSR_PASSWORD:-manage}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"
KEEP=0

# wm-mcp tools to run, in dependency-friendly order. Keep
# package_dependency_check first so a broken requires graph is reported
# even if a later tool refuses to run against the resulting partial
# install.
TOOLS=(
    package_dependency_check
    namespace_unused_services
    flow_validate
    acl_audit
)

usage() {
    sed -n 's/^# \{0,1\}//p' "$0" | sed -n '2,44p'
}

while (( $# > 0 )); do
    case "$1" in
        --dist-dir)      DIST_DIR=$2; shift 2 ;;
        --reports-dir)   REPORTS_DIR=$2; shift 2 ;;
        --image)         MSR_IMAGE=$2; shift 2 ;;
        --port)          MSR_PORT=$2; shift 2 ;;
        --user)          MSR_USER=$2; shift 2 ;;
        --password)      MSR_PASSWORD=$2; shift 2 ;;
        --wait-timeout)  WAIT_TIMEOUT=$2; shift 2 ;;
        --keep)          KEEP=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------
# Resolve image default from versions.env if not passed in.
# Sourced with `set -a` so MSR_VERSION is exported into the environment.
# ---------------------------------------------------------------------
if [[ -z "${MSR_IMAGE}" ]]; then
    if [[ -f "${REPO_ROOT}/versions.env" ]]; then
        # shellcheck source=/dev/null
        set -a; . "${REPO_ROOT}/versions.env"; set +a
    fi
    MSR_IMAGE="wm-msr-base:${MSR_VERSION:-11.1.0}"
fi

# ---------------------------------------------------------------------
# Host tool checks
# ---------------------------------------------------------------------
missing=()
for tool in docker jq python3 curl base64; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if (( ${#missing[@]} > 0 )); then
    printf 'ERROR: required tool(s) not found on host: %s\n' "${missing[*]}" >&2
    printf 'Install hint (Debian/Ubuntu): apt-get install -y docker.io jq python3 curl coreutils\n' >&2
    exit 1
fi

# ---------------------------------------------------------------------
# Discover zips
# ---------------------------------------------------------------------
mapfile -t ZIPS < <(
    find "${DIST_DIR}" -maxdepth 1 -type f -name '*.zip' 2>/dev/null | sort
)
if (( ${#ZIPS[@]} == 0 )); then
    echo "ERROR: no package zips found under ${DIST_DIR}." >&2
    echo "       Run scripts/build-packages.sh first." >&2
    exit 1
fi

mkdir -p -- "${REPORTS_DIR}"

# ---------------------------------------------------------------------
# Boot MSR container with auto-cleanup.
#
# We use --rm so the container disappears on stop. The trap wraps stop
# in `|| true` and `return $rc` so the script's original exit status is
# preserved even if docker stop fails (e.g. container already gone).
# ---------------------------------------------------------------------
echo "Checking MSR image: ${MSR_IMAGE}"
if ! docker image inspect "${MSR_IMAGE}" >/dev/null 2>&1; then
    echo "Pulling ${MSR_IMAGE}..."
    docker pull "${MSR_IMAGE}" \
        || { echo "ERROR: failed to pull image ${MSR_IMAGE}" >&2; exit 1; }
fi

CONTAINER_NAME="wm-lint-$$-${RANDOM}"
echo "Starting MSR container ${CONTAINER_NAME} on port ${MSR_PORT}..."
CID=$(docker run --rm -d \
    --name "${CONTAINER_NAME}" \
    -p "${MSR_PORT}:5555" \
    "${MSR_IMAGE}")

cleanup() {
    local rc=$?
    if (( KEEP == 1 )); then
        echo "[keep] container left running: ${CONTAINER_NAME} (id ${CID:0:12})" >&2
    elif [[ -n "${CID:-}" ]]; then
        docker stop "${CID}" >/dev/null 2>&1 || true
    fi
    return $rc
}
trap cleanup EXIT

# ---------------------------------------------------------------------
# Wait for MSR to be healthy. The base image's healthcheck targets
# /invoke/wm.server:ping and starts after a 60s grace period; we poll
# the same endpoint from the host.
# ---------------------------------------------------------------------
echo "Waiting for MSR to become healthy (timeout ${WAIT_TIMEOUT}s)..."
auth_b64=$(printf '%s:%s' "${MSR_USER}" "${MSR_PASSWORD}" | base64 | tr -d '\n')
deadline=$(( SECONDS + WAIT_TIMEOUT ))
ready=0
while (( SECONDS < deadline )); do
    if curl -fsS \
        -H "Authorization: Basic ${auth_b64}" \
        "http://localhost:${MSR_PORT}/invoke/wm.server:ping" \
        >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 5
done
if (( ready == 0 )); then
    echo "ERROR: MSR did not become healthy within ${WAIT_TIMEOUT}s" >&2
    docker logs --tail 100 "${CID}" >&2 || true
    exit 1
fi
echo "MSR is ready."

# ---------------------------------------------------------------------
# Install zips. wm-mcp ships in the base image; running it inside the
# container lets it talk to localhost:5555 with admin creds without
# exposing them on the host network. The build-packages.sh output is
# alphabetically sorted, so wm-mcp sees the same install order on
# every run -- if a future package's <requires> needs ordering tweaks
# (e.g. WmFoo before WmBar), express it via package_install's own
# dependency resolver rather than reordering here.
# ---------------------------------------------------------------------
for zip_path in "${ZIPS[@]}"; do
    zip_name=$(basename -- "${zip_path}")
    echo "Installing ${zip_name}..."
    docker cp "${zip_path}" "${CID}:/tmp/${zip_name}"
    docker exec \
        -e WM_MCP_TARGET="http://localhost:5555" \
        -e WM_MCP_USER="${MSR_USER}" \
        -e WM_MCP_PASSWORD="${MSR_PASSWORD}" \
        "${CID}" \
        wm-mcp package_install --file "/tmp/${zip_name}"
done

# ---------------------------------------------------------------------
# Run lint tools, capturing each report to JSON.
#
# wm-mcp's convention is "exit 0 = no findings, exit 1 = findings,
# exit >=2 = tool error". We treat exit 1 with parseable JSON as a
# successful run that found problems (the JSON gets aggregated into
# JUnit). Exit >=2 or empty / unparseable JSON gets surfaced as an
# <error/> testcase by the converter and sets ERR_TOTAL>0 below.
# ---------------------------------------------------------------------
declare -a REPORT_FILES=()
for tool in "${TOOLS[@]}"; do
    out="${REPORTS_DIR}/${tool}.json"
    rm -f -- "${out}"
    echo "Running wm-mcp ${tool}..."
    set +e
    docker exec \
        -e WM_MCP_TARGET="http://localhost:5555" \
        -e WM_MCP_USER="${MSR_USER}" \
        -e WM_MCP_PASSWORD="${MSR_PASSWORD}" \
        "${CID}" \
        wm-mcp "${tool}" --output json \
        > "${out}" 2>/dev/null
    rc=$?
    set -e
    if [[ ! -s "${out}" ]] || ! jq -e . < "${out}" >/dev/null 2>&1; then
        echo "WARN: wm-mcp ${tool} exited ${rc} without parseable JSON" >&2
    fi
    REPORT_FILES+=("${out}")
done

# ---------------------------------------------------------------------
# Convert to JUnit XML.
# ---------------------------------------------------------------------
JUNIT_XML="${REPORTS_DIR}/results.xml"
echo "Converting reports -> ${JUNIT_XML}"
wmreport_to_junit "${JUNIT_XML}" "${REPORT_FILES[@]}"

# ---------------------------------------------------------------------
# Decide overall exit code.
#
# A check counts as a "failure" if its severity is error or warning;
# warnings are intentionally fatal in CI -- the whole point of running
# these tools at PR time is to fail until the warning is fixed or
# explicitly waived.
# ---------------------------------------------------------------------
fail_total=0
err_total=0
for f in "${REPORT_FILES[@]}"; do
    if [[ -s "${f}" ]] && jq -e . < "${f}" >/dev/null 2>&1; then
        n=$(jq -r '
            [ .checks[]?
              | (.severity // "info" | ascii_downcase)
              | select(. == "error" or . == "warning")
            ] | length
        ' "${f}")
        fail_total=$(( fail_total + n ))
    else
        err_total=$(( err_total + 1 ))
    fi
done

echo
echo "Lint summary:"
echo "  failures (error+warning): ${fail_total}"
echo "  tool errors (no output):  ${err_total}"
echo "  JUnit XML:                ${JUNIT_XML}"

if (( fail_total > 0 || err_total > 0 )); then
    exit 2
fi
echo "All lint checks passed."
exit 0
