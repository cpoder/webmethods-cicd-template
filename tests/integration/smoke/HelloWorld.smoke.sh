#!/usr/bin/env bash
# tests/integration/smoke/HelloWorld.smoke.sh
#
# Per-env smoke test for the HelloWorld package introduced in plan
# Task 8.3. The companion of tests/integration/smoke/run.sh, which
# exercises the canonical MSR `wm.server:ping` + `getServerVersion`
# endpoints; THIS script exercises the HelloWorld:greet flow service
# and asserts that the deployed instance returns the env tag matching
# the env it was promoted to.
#
# It deliberately stays dep-free (curl + python3) so it works as
# either:
#   * a CD post-deploy smoke step (cd.yml runs it after every deploy
#     against ${{ vars.<ENV>_URL }})
#   * a manual operator probe ("did the demo really go through to
#     prod?" -> point this at the prod URL)
#
# Inputs (env or args):
#   SMOKE_TARGET            Live base URL, e.g. https://wm-svc-dev.example.com.
#                           Required.
#   EXPECTED_ENV_NAME       The env tag we expect in the greeting
#                           ("dev" / "test" / "prod"). Required: this
#                           is THE assertion that proves promotion
#                           worked end-to-end.
#   MSR_ADMIN_USER          HTTP basic user (default: Administrator).
#                           hello.world:greet itself is anon-ACL but
#                           the same creds line up with the run.sh
#                           probe and avoid drift between the two
#                           smoke runners.
#   MSR_ADMIN_PASSWORD      HTTP basic password (default: manage).
#   SMOKE_TIMEOUT_SECONDS   Per-check timeout (default: 15).
#   SMOKE_REPORT            JUnit XML output path
#                           (default: reports/smoke/helloworld-junit.xml).
#
# Probes (run in order; first failure exits non-zero):
#   1. POST /invoke/hello.world:greet {"name": "smoke"}
#      - 200 OK
#      - body.greeting includes "smoke"
#      - body.greeting includes "(env: ${EXPECTED_ENV_NAME})"
#      - body.envName == ${EXPECTED_ENV_NAME}
#   2. POST /invoke/hello.world:greet {"name": ""}  (empty -> stranger)
#      - 200 OK
#      - body.greeting matches /Hello, stranger! \(env: <env>\)/
#
# Exit codes:
#   0  every probe passed
#   1  setup error (missing curl/python3, missing env var)
#   2  one or more probes failed
#
# Output:
#   * stdout                human-readable PASS/FAIL log
#   * SMOKE_REPORT          JUnit XML (one <testcase> per probe)

set -euo pipefail

SMOKE_TARGET="${SMOKE_TARGET:-}"
EXPECTED_ENV_NAME="${EXPECTED_ENV_NAME:-}"
MSR_ADMIN_USER="${MSR_ADMIN_USER:-Administrator}"
MSR_ADMIN_PASSWORD="${MSR_ADMIN_PASSWORD:-manage}"
SMOKE_TIMEOUT_SECONDS="${SMOKE_TIMEOUT_SECONDS:-15}"
SMOKE_REPORT="${SMOKE_REPORT:-reports/smoke/helloworld-junit.xml}"

usage() {
    sed -n 's/^# \{0,1\}//p' "$0" | sed -n '2,52p'
}

while (( $# > 0 )); do
    case "$1" in
        --target)   SMOKE_TARGET=$2; shift 2 ;;
        --env-name) EXPECTED_ENV_NAME=$2; shift 2 ;;
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
if [[ -z "${EXPECTED_ENV_NAME}" ]]; then
    echo "ERROR: EXPECTED_ENV_NAME (env or --env-name) is required" >&2
    echo "       This is the env tag the deployed greet service should return." >&2
    exit 1
fi
for tool in curl python3; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "ERROR: ${tool} is required" >&2
        exit 1
    fi
done

SMOKE_TARGET="${SMOKE_TARGET%/}"
mkdir -p "$(dirname -- "${SMOKE_REPORT}")"

declare -a TC_NAMES=()
declare -a TC_RESULTS=()       # ok | fail
declare -a TC_DURATIONS=()
declare -a TC_DETAILS=()

# ----------------------------------------------------------------------
# probe NAME PAYLOAD ASSERT_PYTHON
#
# Runs a POST against /invoke/hello.world:greet, then evaluates an
# inline python snippet against the response body. The snippet has
# `body` (the JSON dict, or {} if parse failed), `status`, `text`,
# and `expected_env` in scope; it must call assert_eq()/assert_in()/
# fail() to raise an `AssertionError` on failure.
# ----------------------------------------------------------------------
probe() {
    local name=$1 payload=$2 assert_py=$3
    local started ended duration body_file http_status curl_rc
    started=$(date +%s)
    body_file=$(mktemp)
    set +e
    http_status=$(curl --silent --show-error \
        --max-time "${SMOKE_TIMEOUT_SECONDS}" \
        --user "${MSR_ADMIN_USER}:${MSR_ADMIN_PASSWORD}" \
        --header "Accept: application/json" \
        --header "Content-Type: application/json" \
        --data "${payload}" \
        --output "${body_file}" \
        --write-out "%{http_code}" \
        "${SMOKE_TARGET}/invoke/hello.world:greet" 2>"${body_file}.err")
    curl_rc=$?
    set -e
    ended=$(date +%s)
    duration=$(( ended - started ))

    TC_NAMES+=("${name}")
    TC_DURATIONS+=("${duration}")

    if (( curl_rc != 0 )); then
        local err
        err=$(head -c 400 "${body_file}.err" 2>/dev/null || true)
        TC_RESULTS+=("fail")
        TC_DETAILS+=("curl rc=${curl_rc} err=${err}")
        printf 'FAIL  %-40s curl rc=%s\n' "${name}" "${curl_rc}"
        rm -f -- "${body_file}" "${body_file}.err"
        return
    fi

    # Run the assertion snippet under python3. Non-zero exit means
    # assertion failure or parse error; capture stderr as the detail.
    local detail
    if detail=$(EXPECTED_ENV="${EXPECTED_ENV_NAME}" \
                STATUS="${http_status}" \
                ASSERT_PY="${assert_py}" \
                python3 - "${body_file}" <<'PY' 2>&1
import json, os, sys

path = sys.argv[1]
expected_env = os.environ["EXPECTED_ENV"]
status = int(os.environ["STATUS"])
assert_py = os.environ["ASSERT_PY"]

with open(path, "r", encoding="utf-8") as fh:
    text = fh.read()
try:
    body = json.loads(text) if text.strip() else {}
except json.JSONDecodeError as exc:
    body = {}
    sys.stderr.write(f"WARN: response was not JSON: {exc} (got {text[:200]!r})\n")

def assert_eq(actual, expected, label="value"):
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")

def assert_in(needle, haystack, label="value"):
    if needle not in (haystack or ""):
        raise AssertionError(f"{label}: expected to contain {needle!r}, got {haystack!r}")

def assert_match(pattern, value, label="value"):
    import re
    if not re.search(pattern, value or ""):
        raise AssertionError(f"{label}: did not match /{pattern}/, got {value!r}")

def fail(msg):
    raise AssertionError(msg)

try:
    exec(assert_py, {
        "body": body, "status": status, "text": text, "expected_env": expected_env,
        "assert_eq": assert_eq, "assert_in": assert_in,
        "assert_match": assert_match, "fail": fail,
    })
except AssertionError as exc:
    sys.stderr.write(f"AssertionError: {exc}\n")
    sys.exit(2)
PY
    )
    then
        TC_RESULTS+=("ok")
        TC_DETAILS+=("")
        printf 'PASS  %-40s HTTP %s in %ds\n' "${name}" "${http_status}" "${duration}"
    else
        TC_RESULTS+=("fail")
        TC_DETAILS+=("HTTP ${http_status}; ${detail}")
        printf 'FAIL  %-40s HTTP %s\n' "${name}" "${http_status}"
    fi
    rm -f -- "${body_file}" "${body_file}.err"
}

echo "Smoke target:        ${SMOKE_TARGET}"
echo "Expected env tag:    ${EXPECTED_ENV_NAME}"
echo "Report:              ${SMOKE_REPORT}"
echo

# ---- probe 1: happy path -----------------------------------------------
probe "greet name=smoke" \
    '{"name":"smoke"}' \
    '
assert_eq(status, 200, "http status")
assert_in("smoke", body.get("greeting"), "greeting includes name")
assert_in(f"(env: {expected_env})", body.get("greeting"), "greeting carries env tag")
assert_eq(body.get("envName"), expected_env, "envName field")
'

# ---- probe 2: empty name fallback --------------------------------------
probe "greet name=empty" \
    '{"name":""}' \
    '
assert_eq(status, 200, "http status")
assert_match(r"Hello, stranger! \(env: [a-z]+\)", body.get("greeting", ""), "stranger fallback")
assert_in(f"(env: {expected_env})", body.get("greeting"), "fallback env tag")
'

# ---- render JUnit XML --------------------------------------------------
py_args=("${SMOKE_REPORT}")
for (( i=0; i<${#TC_NAMES[@]}; i++ )); do
    py_args+=("${TC_NAMES[$i]}" "${TC_RESULTS[$i]}" "${TC_DURATIONS[$i]}" "${TC_DETAILS[$i]}")
done
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
    'name': 'cd-smoke-helloworld',
    'tests': str(len(items)),
    'failures': str(failures),
    'errors': '0',
    'skipped': '0',
})
for name, result, duration, detail in items:
    tc = ET.SubElement(suite, 'testcase', {
        'classname': 'cd.smoke.helloworld',
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

failures=$(printf '%s\n' "${TC_RESULTS[@]}" | grep -c '^fail$' || true)
echo
if (( failures > 0 )); then
    echo "HelloWorld smoke FAILED: ${failures}/${#TC_NAMES[@]} probe(s) failed."
    exit 2
fi
echo "HelloWorld smoke PASSED: ${#TC_NAMES[@]} probe(s) all green."
exit 0
