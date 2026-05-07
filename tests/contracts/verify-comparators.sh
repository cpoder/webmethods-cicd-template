#!/usr/bin/env bash
# tests/contracts/verify-comparators.sh
#
# Smoke test for the contract-test machinery in scripts/lib/. Drives the
# OpenAPI and WSDL comparators against every fixture pair, then exercises
# scripts/test-contracts.sh in --offline mode to confirm:
#
#   * Adding a new required field to a request body fails the driver
#     with exit code 2 (acceptance criterion #1).
#   * The failure message names the field AND the endpoint
#     (acceptance criterion #2).
#   * --allow-breaking turns the failure into a warning and exit 0
#     (acceptance criterion #3 -- the `breaking-api` PR label override).
#
# Exits 0 iff every assertion passes.
#
# Usage:
#   tests/contracts/verify-comparators.sh

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)
FIX="${SCRIPT_DIR}/fixtures"
TMP=$(mktemp -d -t wm-contract-XXXX)
trap 'rm -rf -- "${TMP}"' EXIT

PASS=0
FAIL=0
fail() {
    echo "    FAIL: $*" >&2
    FAIL=$(( FAIL + 1 ))
}
ok() {
    echo "    ok:   $*"
    PASS=$(( PASS + 1 ))
}

run_openapi_pair() {
    local label="$1" base="$2" revised="$3" expect_rc="$4"; shift 4
    # Remaining args are substrings the stderr output must contain.
    echo ">>> openapi-diff: ${label}"
    set +e
    python3 "${REPO_ROOT}/scripts/lib/openapi-diff.py" \
        "${base}" "${revised}" \
        --json "${TMP}/${label}.json" \
        2> "${TMP}/${label}.err"
    local rc=$?
    set -e
    if [[ "${rc}" != "${expect_rc}" ]]; then
        fail "${label}: expected rc=${expect_rc}, got ${rc}"
        sed 's/^/        /' < "${TMP}/${label}.err" >&2 || true
        return
    fi
    ok "${label}: rc=${rc}"
    for needle in "$@"; do
        if grep -qF -- "${needle}" "${TMP}/${label}.err"; then
            ok "${label}: stderr contains \"${needle}\""
        else
            fail "${label}: stderr missing \"${needle}\""
            sed 's/^/        /' < "${TMP}/${label}.err" >&2 || true
        fi
    done
}

run_wsdl_pair() {
    local label="$1" base="$2" revised="$3" expect_rc="$4"; shift 4
    echo ">>> wsdl-diff: ${label}"
    set +e
    python3 "${REPO_ROOT}/scripts/lib/wsdl-diff.py" \
        "${base}" "${revised}" \
        --json "${TMP}/${label}.json" \
        2> "${TMP}/${label}.err"
    local rc=$?
    set -e
    if [[ "${rc}" != "${expect_rc}" ]]; then
        fail "${label}: expected rc=${expect_rc}, got ${rc}"
        sed 's/^/        /' < "${TMP}/${label}.err" >&2 || true
        return
    fi
    ok "${label}: rc=${rc}"
    for needle in "$@"; do
        if grep -qF -- "${needle}" "${TMP}/${label}.err"; then
            ok "${label}: stderr contains \"${needle}\""
        else
            fail "${label}: stderr missing \"${needle}\""
            sed 's/^/        /' < "${TMP}/${label}.err" >&2 || true
        fi
    done
}

# ---------------------------------------------------------------------------
# OpenAPI comparator: every breaking variant should exit 1 and print the
# right needle; the optional-only variant should exit 0.
# ---------------------------------------------------------------------------
run_openapi_pair "openapi-base-vs-base" \
    "${FIX}/openapi/base.yaml" "${FIX}/openapi/base.yaml" 0

run_openapi_pair "openapi-added-optional-field" \
    "${FIX}/openapi/base.yaml" \
    "${FIX}/openapi/added-optional-field.yaml" 0

run_openapi_pair "openapi-added-required-field" \
    "${FIX}/openapi/base.yaml" \
    "${FIX}/openapi/added-required-field.yaml" 1 \
    "required field 'email' added" "POST /greet"

run_openapi_pair "openapi-removed-endpoint" \
    "${FIX}/openapi/base.yaml" \
    "${FIX}/openapi/removed-endpoint.yaml" 1 \
    "endpoint removed: GET /health"

run_openapi_pair "openapi-added-required-param" \
    "${FIX}/openapi/base.yaml" \
    "${FIX}/openapi/added-required-param.yaml" 1 \
    "new required query parameter 'tenant'" "POST /greet"

run_openapi_pair "openapi-removed-required-response-field" \
    "${FIX}/openapi/base.yaml" \
    "${FIX}/openapi/removed-required-response-field.yaml" 1 \
    "required field 'locale' removed from response body" "POST /greet"

# ---------------------------------------------------------------------------
# WSDL comparator: same shape -- breaking variants exit 1, optional 0.
# ---------------------------------------------------------------------------
run_wsdl_pair "wsdl-base-vs-base" \
    "${FIX}/wsdl/base.wsdl" "${FIX}/wsdl/base.wsdl" 0

run_wsdl_pair "wsdl-added-optional-element" \
    "${FIX}/wsdl/base.wsdl" \
    "${FIX}/wsdl/added-optional-element.wsdl" 0

run_wsdl_pair "wsdl-added-required-element" \
    "${FIX}/wsdl/base.wsdl" \
    "${FIX}/wsdl/added-required-element.wsdl" 1 \
    "new required element 'GreetRequest.email'"

run_wsdl_pair "wsdl-removed-operation" \
    "${FIX}/wsdl/base.wsdl" \
    "${FIX}/wsdl/removed-operation.wsdl" 1 \
    "SOAP operation 'greet' removed"

# ---------------------------------------------------------------------------
# scripts/test-contracts.sh end-to-end (offline mode)
# ---------------------------------------------------------------------------
echo ">>> driver: end-to-end offline run, expect rc=2 and acceptance message"
DRV_BASE="${FIX}/driver-base"
DRV_EXP="${FIX}/driver-exported"
DRV_REPORTS="${TMP}/driver-reports"

set +e
"${REPO_ROOT}/scripts/test-contracts.sh" \
    --api-dir "${DRV_BASE}/api" \
    --reports-dir "${DRV_REPORTS}" \
    --offline "${DRV_EXP}" \
    > "${TMP}/driver.out" 2> "${TMP}/driver.err"
DRV_RC=$?
set -e

if [[ "${DRV_RC}" == "2" ]]; then
    ok "driver: rc=2 without --allow-breaking"
else
    fail "driver: expected rc=2, got ${DRV_RC}"
    sed 's/^/        /' < "${TMP}/driver.out" >&2 || true
    sed 's/^/        /' < "${TMP}/driver.err" >&2 || true
fi

# Combined output (stdout + stderr) must mention the field and endpoint
# per the acceptance criteria. The driver prints findings to stdout and
# the FAIL summary to stderr.
DRV_ALL="${TMP}/driver.all"
cat "${TMP}/driver.out" "${TMP}/driver.err" > "${DRV_ALL}"

for needle in "required field 'email' added" "POST /greet"; do
    if grep -qF -- "${needle}" "${DRV_ALL}"; then
        ok "driver: output contains \"${needle}\""
    else
        fail "driver: output missing \"${needle}\""
        sed 's/^/        /' < "${DRV_ALL}" >&2
    fi
done

# JUnit XML must exist and carry a <failure> element.
if [[ -f "${DRV_REPORTS}/junit.xml" ]] \
   && grep -q '<failure ' "${DRV_REPORTS}/junit.xml"; then
    ok "driver: junit.xml contains <failure>"
else
    fail "driver: junit.xml missing or empty"
fi

echo ">>> driver: end-to-end offline run with --allow-breaking, expect rc=0 + WARNING"
set +e
"${REPO_ROOT}/scripts/test-contracts.sh" \
    --api-dir "${DRV_BASE}/api" \
    --reports-dir "${TMP}/driver-allow" \
    --offline "${DRV_EXP}" \
    --allow-breaking \
    > "${TMP}/driver-allow.out" 2> "${TMP}/driver-allow.err"
DRV_RC=$?
set -e

if [[ "${DRV_RC}" == "0" ]]; then
    ok "driver: rc=0 with --allow-breaking"
else
    fail "driver: expected rc=0 with --allow-breaking, got ${DRV_RC}"
    sed 's/^/        /' < "${TMP}/driver-allow.out" >&2 || true
    sed 's/^/        /' < "${TMP}/driver-allow.err" >&2 || true
fi

if grep -qF "WARNING:" "${TMP}/driver-allow.err"; then
    ok "driver: WARNING printed under --allow-breaking"
else
    fail "driver: WARNING not printed under --allow-breaking"
    sed 's/^/        /' < "${TMP}/driver-allow.err" >&2 || true
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
echo
echo "Summary: ${PASS} ok / ${FAIL} fail"
if (( FAIL > 0 )); then
    exit 1
fi
exit 0
