#!/usr/bin/env bash
# tests/integration/smoke/run.sh
#
# Tiny post-deploy smoke runner. Hit by .github/workflows/cd.yml
# after each deploy step. The intent is "did the live URL come back
# 2xx for the canary endpoints?" -- NOT "did every contract test
# pass" (that's tests/integration/, run pre-deploy by ci.yml).
#
# Inputs (env or args):
#   SMOKE_TARGET           Live base URL, e.g. https://wm-svc-dev.example.com
#                          (no trailing slash). Required.
#   MSR_ADMIN_USER         HTTP-basic user (default: Administrator)
#   MSR_ADMIN_PASSWORD     HTTP-basic password (default: manage)
#   SMOKE_TIMEOUT_SECONDS  Per-check timeout (default: 15)
#   SMOKE_REPORT           JUnit XML output path
#                          (default: reports/smoke/junit.xml)
#
# Checks:
#   1. /invoke/wm.server:ping             (anonymous; the canonical
#                                          MSR liveness endpoint, also
#                                          the base image's HEALTHCHECK)
#   2. /invoke/wm.server:getServerVersion (auth; proves the admin
#                                          credentials line up with
#                                          what apply-config thought
#                                          they were)
#
# Exit codes:
#   0  every check returned 2xx
#   1  setup error (missing curl, missing SMOKE_TARGET)
#   2  one or more checks failed -- workflow runs rollback.sh
#
# Output:
#   * stdout              human-readable PASS/FAIL log
#   * SMOKE_REPORT        JUnit XML (one <testcase> per check)
#
# Why a hand-rolled script and not k6/newman? The CD pipeline runs
# this against the live URL with corporate-PKI TLS terminating at an
# ingress; we want zero deps beyond curl. The pre-deploy integration
# suite (tests/integration/, run by ci.yml) already exercises k6 +
# newman + REST-assured against a sidecar-rich sandbox MSR.

set -euo pipefail

usage() {
    sed -n 's/^# \{0,1\}//p' "$0" | sed -n '2,40p'
}

SMOKE_TARGET="${SMOKE_TARGET:-}"
MSR_ADMIN_USER="${MSR_ADMIN_USER:-Administrator}"
MSR_ADMIN_PASSWORD="${MSR_ADMIN_PASSWORD:-manage}"
SMOKE_TIMEOUT_SECONDS="${SMOKE_TIMEOUT_SECONDS:-15}"
SMOKE_REPORT="${SMOKE_REPORT:-reports/smoke/junit.xml}"

while (( $# > 0 )); do
    case "$1" in
        --target)   SMOKE_TARGET=$2; shift 2 ;;
        --report)   SMOKE_REPORT=$2; shift 2 ;;
        --timeout)  SMOKE_TIMEOUT_SECONDS=$2; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ -z "${SMOKE_TARGET}" ]]; then
    echo "ERROR: SMOKE_TARGET (env or --target) is required" >&2
    exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required" >&2
    exit 1
fi

# Strip trailing slashes so URL concatenation below stays clean.
SMOKE_TARGET="${SMOKE_TARGET%/}"

mkdir -p "$(dirname -- "${SMOKE_REPORT}")"

# Each check is one line: NAME|PATH|AUTH
# AUTH is "anon" or "basic". Add a new check by appending a line.
CHECKS=(
    "ping|/invoke/wm.server:ping|anon"
    "getServerVersion|/invoke/wm.server:getServerVersion|basic"
)

# JUnit aggregation. We collect per-check results, then render at the
# end so a partial-fail run still produces a parseable XML for
# dorny/test-reporter.
declare -a TC_NAMES=()
declare -a TC_RESULTS=()       # ok | fail
declare -a TC_DURATIONS=()     # seconds
declare -a TC_DETAILS=()       # for failures: status code + body excerpt

run_check() {
    local name=$1 path=$2 auth=$3
    local url="${SMOKE_TARGET}${path}"
    local started ended duration
    local body_file http_status curl_rc
    started=$(date +%s)
    body_file=$(mktemp)
    set +e
    if [[ "${auth}" == "basic" ]]; then
        http_status=$(curl --silent --show-error \
            --max-time "${SMOKE_TIMEOUT_SECONDS}" \
            --user "${MSR_ADMIN_USER}:${MSR_ADMIN_PASSWORD}" \
            --output "${body_file}" \
            --write-out "%{http_code}" \
            "${url}" 2>"${body_file}.err")
        curl_rc=$?
    else
        http_status=$(curl --silent --show-error \
            --max-time "${SMOKE_TIMEOUT_SECONDS}" \
            --output "${body_file}" \
            --write-out "%{http_code}" \
            "${url}" 2>"${body_file}.err")
        curl_rc=$?
    fi
    set -e
    ended=$(date +%s)
    duration=$(( ended - started ))

    TC_NAMES+=("${name}")
    TC_DURATIONS+=("${duration}")

    if (( curl_rc != 0 )); then
        local err
        err=$(head -c 400 "${body_file}.err" 2>/dev/null || true)
        TC_RESULTS+=("fail")
        TC_DETAILS+=("curl rc=${curl_rc} url=${url} err=${err}")
        printf 'FAIL  %-30s curl rc=%s\n' "${name}" "${curl_rc}"
    elif [[ "${http_status}" =~ ^2[0-9][0-9]$ ]]; then
        TC_RESULTS+=("ok")
        TC_DETAILS+=("")
        printf 'PASS  %-30s HTTP %s in %ds\n' "${name}" "${http_status}" "${duration}"
    else
        local body
        body=$(head -c 400 "${body_file}" 2>/dev/null || true)
        TC_RESULTS+=("fail")
        TC_DETAILS+=("HTTP ${http_status} url=${url} body=${body}")
        printf 'FAIL  %-30s HTTP %s\n' "${name}" "${http_status}"
    fi
    rm -f -- "${body_file}" "${body_file}.err"
}

echo "Smoke target: ${SMOKE_TARGET}"
echo "Report:       ${SMOKE_REPORT}"
echo

failures=0
for check in "${CHECKS[@]}"; do
    IFS='|' read -r name path auth <<<"${check}"
    run_check "${name}" "${path}" "${auth}"
done

# Render JUnit XML. We use python3 if available so escape rules are
# right; fall back to a bash printf if it isn't (CI runners always
# have python3, this is just defensive).
#
# The python branch reads its inputs from argv: argv[1] is the report
# path, then four-word groups of (name, result, duration, detail).
py_args=("${SMOKE_REPORT}")
for (( i=0; i<${#TC_NAMES[@]}; i++ )); do
    py_args+=("${TC_NAMES[$i]}" "${TC_RESULTS[$i]}" "${TC_DURATIONS[$i]}" "${TC_DETAILS[$i]}")
done

if command -v python3 >/dev/null 2>&1; then
    python3 - "${py_args[@]}" <<'PY'
import sys
from xml.etree import ElementTree as ET

report_path = sys.argv[1]
items = []
i = 2
while i < len(sys.argv):
    items.append(sys.argv[i:i+4])
    i += 4

failures = sum(1 for it in items if it[1] == 'fail')
suite = ET.Element('testsuite', {
    'name': 'cd-smoke',
    'tests': str(len(items)),
    'failures': str(failures),
    'errors': '0',
    'skipped': '0',
})
for name, result, duration, detail in items:
    tc = ET.SubElement(suite, 'testcase', {
        'classname': 'cd.smoke',
        'name': name,
        'time': str(duration),
    })
    if result == 'fail':
        f = ET.SubElement(tc, 'failure', {
            'type': 'SmokeFailure',
            'message': (detail or 'failed').splitlines()[0][:200],
        })
        f.text = detail
suites = ET.Element('testsuites')
suites.append(suite)
ET.ElementTree(suites).write(report_path, encoding='utf-8', xml_declaration=True)
PY
else
    # Tiny fallback. XML-escape &<> in detail; smoke detail is short
    # and curl-rendered so this is enough.
    failures_count=$(printf '%s\n' "${TC_RESULTS[@]}" | grep -c '^fail$' || true)
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<testsuites>\n'
        printf '  <testsuite name="cd-smoke" tests="%d" failures="%d">\n' \
            "${#TC_NAMES[@]}" "${failures_count}"
        for (( i=0; i<${#TC_NAMES[@]}; i++ )); do
            n="${TC_NAMES[$i]}"; r="${TC_RESULTS[$i]}"; d="${TC_DURATIONS[$i]}"
            detail="${TC_DETAILS[$i]}"
            detail="${detail//&/&amp;}"
            detail="${detail//</&lt;}"
            detail="${detail//>/&gt;}"
            printf '    <testcase classname="cd.smoke" name="%s" time="%s">' "${n}" "${d}"
            if [[ "${r}" == "fail" ]]; then
                printf '<failure type="SmokeFailure" message="%s">%s</failure>' "${detail:0:200}" "${detail}"
            fi
            printf '</testcase>\n'
        done
        printf '  </testsuite>\n</testsuites>\n'
    } > "${SMOKE_REPORT}"
fi

failures=$(printf '%s\n' "${TC_RESULTS[@]}" | grep -c '^fail$' || true)
echo
if (( failures > 0 )); then
    echo "Smoke FAILED: ${failures}/${#TC_NAMES[@]} check(s) failed."
    exit 2
fi
echo "Smoke PASSED: ${#TC_NAMES[@]} check(s) all green."
exit 0
