#!/usr/bin/env bash
# scripts/test-integration.sh
#
# End-to-end integration test driver for the webMethods MSR pipeline.
#
# Lifecycle (every step is a hard gate -- the script bails on failure
# and tears the stack down on EXIT regardless):
#   1. Pull / build images named in tests/integration/compose.yml.
#   2. `docker compose up -d --wait`           -- start sidecars + MSR
#   3. Apply config/test/ via scripts/apply-config.sh
#      against the running MSR (over the published admin port).
#   4. Run the suites:
#        a. Newman               -> reports/integration/newman/
#        b. k6 smoke             -> reports/integration/k6/
#        c. REST-assured (mvn)   -> reports/integration/restassured/
#   5. Aggregate every JUnit XML under reports/integration/junit.xml
#      so dorny/test-reporter (Task 6.x) sees one canonical file.
#   6. `docker compose down -v` (always, via trap).
#
# Acceptance criteria for Task 4.2:
#   * exit 0 only when ALL suites pass
#   * exit non-zero on any failure (compose, apply, suites)
#   * reports/integration/ contains JUnit + HAR/HTML artifacts
#
# Usage:
#   scripts/test-integration.sh [options]
#
# Options:
#   --env ENV               profile under config/ (default: test)
#   --compose-file PATH     default: tests/integration/compose.yml
#   --reports-dir DIR       default: <repo>/reports/integration
#   --msr-image IMAGE       overrides MSR_IMAGE in compose
#   --msr-port N            host port for MSR (default: 15555)
#   --skip-up               assume the stack is already up
#   --skip-down             leave the stack running on exit
#   --skip-apply            don't call apply-config.sh
#   --skip-newman           don't run Newman
#   --skip-k6               don't run k6
#   --skip-restassured      don't run the Maven test project
#   --keep-failed           keep the stack up if any suite fails
#                           (overrides --skip-down for the pass case)
#
# Exit codes:
#   0  every enabled suite passed
#   1  setup error (missing tool, compose up failure, apply failure)
#   2  one or more suites failed
#
# Required tools: docker, docker compose, curl, jq, python3.
# Optional (per suite): newman, k6, mvn.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)

# ---------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------
ENV_NAME="${ENV_NAME:-test}"
COMPOSE_FILE="${REPO_ROOT}/tests/integration/compose.yml"
REPORTS_DIR="${REPO_ROOT}/reports/integration"
MSR_IMAGE_OVERRIDE=""
MSR_HOST_PORT="${MSR_HOST_PORT:-15555}"
SKIP_UP=0
SKIP_DOWN=0
SKIP_APPLY=0
SKIP_NEWMAN=0
SKIP_K6=0
SKIP_RESTASSURED=0
KEEP_FAILED=0

usage() { sed -n 's/^# \{0,1\}//p' "$0" | sed -n '2,55p'; }

while (( $# > 0 )); do
    case "$1" in
        --env)             ENV_NAME=$2; shift 2 ;;
        --compose-file)    COMPOSE_FILE=$2; shift 2 ;;
        --reports-dir)     REPORTS_DIR=$2; shift 2 ;;
        --msr-image)       MSR_IMAGE_OVERRIDE=$2; shift 2 ;;
        --msr-port)        MSR_HOST_PORT=$2; shift 2 ;;
        --skip-up)         SKIP_UP=1; shift ;;
        --skip-down)       SKIP_DOWN=1; shift ;;
        --skip-apply)      SKIP_APPLY=1; shift ;;
        --skip-newman)     SKIP_NEWMAN=1; shift ;;
        --skip-k6)         SKIP_K6=1; shift ;;
        --skip-restassured)SKIP_RESTASSURED=1; shift ;;
        --keep-failed)     KEEP_FAILED=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------
# Source versions.env so MSR_VERSION etc. are available to compose.
# ---------------------------------------------------------------------
if [[ -f "${REPO_ROOT}/versions.env" ]]; then
    # shellcheck source=/dev/null
    set -a; . "${REPO_ROOT}/versions.env"; set +a
fi

# Resolve the MSR image: explicit flag > env var > versions.env default.
if [[ -n "${MSR_IMAGE_OVERRIDE}" ]]; then
    export MSR_IMAGE="${MSR_IMAGE_OVERRIDE}"
elif [[ -z "${MSR_IMAGE:-}" ]]; then
    export MSR_IMAGE="wm-msr-base:${MSR_VERSION:-11.1.0}"
fi
export MSR_HOST_PORT

# ---------------------------------------------------------------------
# Tool checks. Per-suite tools are checked just-in-time so a missing
# k6 doesn't block a Newman-only run.
# ---------------------------------------------------------------------
require_host_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: required tool not on PATH: $1" >&2
        exit 1
    fi
}

require_host_tool docker
require_host_tool curl
require_host_tool jq
require_host_tool python3

# `docker compose` v2 plugin (not legacy `docker-compose`).
if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: 'docker compose' (v2 plugin) is required." >&2
    exit 1
fi

# ---------------------------------------------------------------------
# Layout reports/integration/
# ---------------------------------------------------------------------
mkdir -p \
    "${REPORTS_DIR}" \
    "${REPORTS_DIR}/newman" \
    "${REPORTS_DIR}/k6" \
    "${REPORTS_DIR}/restassured" \
    "${REPORTS_DIR}/apply"

# ---------------------------------------------------------------------
# Compose lifecycle. The DOWN trap is registered before UP so a failure
# during UP also tears down whatever partially started.
# ---------------------------------------------------------------------
COMPOSE_DOWN_DONE=0
SUITES_OK=1

compose_down() {
    [[ "${COMPOSE_DOWN_DONE}" -eq 1 ]] && return
    COMPOSE_DOWN_DONE=1
    if [[ "${SKIP_DOWN}" -eq 1 ]] || { [[ "${KEEP_FAILED}" -eq 1 ]] && [[ "${SUITES_OK}" -eq 0 ]]; }; then
        echo ">>> Skipping 'docker compose down' (--skip-down or --keep-failed)."
        return
    fi
    echo ">>> docker compose down -v"
    docker compose -f "${COMPOSE_FILE}" -p wm-integration-tests down -v --remove-orphans \
        || echo "WARN: compose down reported a non-zero exit; continuing."
}
trap 'compose_down' EXIT

if [[ "${SKIP_UP}" -eq 0 ]]; then
    echo ">>> docker compose up -d --wait (this can take a couple of minutes on first run)"
    docker compose -f "${COMPOSE_FILE}" -p wm-integration-tests up -d --wait
else
    echo ">>> --skip-up set; assuming the stack is already healthy."
fi

# ---------------------------------------------------------------------
# Sanity ping against MSR before anyone runs a suite. compose --wait
# already gates on the per-service healthcheck, but a published-port
# check here gives us a clean "your stack is reachable" log line.
# ---------------------------------------------------------------------
MSR_BASE_URL="http://localhost:${MSR_HOST_PORT}"
MSR_ADMIN_USER="${MSR_ADMIN_USER:-Administrator}"
MSR_ADMIN_PASSWORD="${MSR_ADMIN_PASSWORD:-manage}"

ping_url="${MSR_BASE_URL}/invoke/wm.server:ping"
echo ">>> Verifying MSR is reachable at ${ping_url}"
deadline=$(( $(date +%s) + 60 ))
until curl -fsS -u "${MSR_ADMIN_USER}:${MSR_ADMIN_PASSWORD}" "${ping_url}" >/dev/null 2>&1; do
    if (( $(date +%s) >= deadline )); then
        echo "ERROR: MSR did not respond at ${ping_url} within 60s." >&2
        echo "       Check 'docker compose -p wm-integration-tests logs msr'." >&2
        exit 1
    fi
    sleep 2
done
echo "    MSR ping OK."

# ---------------------------------------------------------------------
# Apply config/test/. Uses the same wm-mcp invocation contract as the
# rest of the pipeline; secrets are exported here so the
# `${SECRET:NAME}` placeholders in the YAML get resolved at apply time
# without leaking onto disk.
# ---------------------------------------------------------------------
if [[ "${SKIP_APPLY}" -eq 0 ]]; then
    echo ">>> Applying config/${ENV_NAME}/ to MSR via scripts/apply-config.sh"
    # Sidecar credentials -- referenced as env: secret_refs from the
    # config/test/ YAMLs and resolved by wm-mcp at apply time.
    export DB_PASSWORD_TESTDB="${DB_PASSWORD_TESTDB:-testpass}"
    export JMS_PASSWORD_TESTQUEUE="${JMS_PASSWORD_TESTQUEUE:-testpass}"

    if [[ ! -x "${SCRIPT_DIR}/apply-config.sh" ]]; then
        echo "ERROR: ${SCRIPT_DIR}/apply-config.sh missing or not executable." >&2
        exit 1
    fi

    "${SCRIPT_DIR}/apply-config.sh" \
        --env "${ENV_NAME}" \
        --target "${MSR_BASE_URL}" \
        --user "${MSR_ADMIN_USER}" \
        --password "${MSR_ADMIN_PASSWORD}" \
        --reports-dir "${REPORTS_DIR}/apply" \
        || { echo "ERROR: apply-config.sh failed; aborting tests." >&2; exit 1; }
else
    echo ">>> --skip-apply set; not running apply-config.sh."
fi

# ---------------------------------------------------------------------
# Suite runners. Each one writes its own JUnit XML under
# reports/integration/<suite>/junit.xml; the aggregator at the bottom
# stitches them into reports/integration/junit.xml.
# ---------------------------------------------------------------------
SUITE_FAILURES=()

run_newman() {
    if [[ "${SKIP_NEWMAN}" -eq 1 ]]; then
        echo ">>> --skip-newman set."
        return 0
    fi
    if ! command -v newman >/dev/null 2>&1; then
        echo "WARN: newman not on PATH; skipping the Newman suite." >&2
        echo "      Install: npm i -g newman newman-reporter-htmlextra"
        SUITE_FAILURES+=("newman:not-installed")
        return 0
    fi

    echo ">>> Running Newman suite"
    local col="${REPO_ROOT}/tests/integration/postman/collection.json"
    local envf="${REPO_ROOT}/tests/integration/postman/dev.postman_environment.json"
    local reporters=cli,junit
    local html_args=()
    if newman run --help 2>/dev/null | grep -q htmlextra; then
        reporters=cli,junit,htmlextra
        html_args=(--reporter-htmlextra-export "${REPORTS_DIR}/newman/report.html")
    fi
    if newman run "${col}" \
        --environment "${envf}" \
        --env-var "msrBaseUrl=${MSR_BASE_URL}" \
        --env-var "adminUser=${MSR_ADMIN_USER}" \
        --env-var "adminPassword=${MSR_ADMIN_PASSWORD}" \
        --reporters "${reporters}" \
        --reporter-junit-export "${REPORTS_DIR}/newman/junit.xml" \
        "${html_args[@]}" \
        --insecure
    then
        echo "    Newman: OK"
    else
        echo "    Newman: FAIL"
        SUITE_FAILURES+=("newman")
    fi
}

run_k6() {
    if [[ "${SKIP_K6}" -eq 1 ]]; then
        echo ">>> --skip-k6 set."
        return 0
    fi
    if ! command -v k6 >/dev/null 2>&1; then
        echo "WARN: k6 not on PATH; skipping the k6 smoke suite." >&2
        echo "      Install: https://k6.io/docs/get-started/installation/"
        SUITE_FAILURES+=("k6:not-installed")
        return 0
    fi

    echo ">>> Running k6 smoke"
    if k6 run \
        -e "MSR_BASE_URL=${MSR_BASE_URL}" \
        -e "MSR_ADMIN_USER=${MSR_ADMIN_USER}" \
        -e "MSR_ADMIN_PASSWORD=${MSR_ADMIN_PASSWORD}" \
        --summary-export "${REPORTS_DIR}/k6/summary-export.json" \
        "${REPO_ROOT}/tests/integration/k6/smoke.js"
    then
        echo "    k6: OK"
    else
        echo "    k6: FAIL"
        SUITE_FAILURES+=("k6")
    fi
}

run_restassured() {
    if [[ "${SKIP_RESTASSURED}" -eq 1 ]]; then
        echo ">>> --skip-restassured set."
        return 0
    fi
    if ! command -v mvn >/dev/null 2>&1; then
        echo "WARN: mvn not on PATH; skipping the REST-assured suite." >&2
        echo "      Install: https://maven.apache.org/install.html"
        SUITE_FAILURES+=("restassured:not-installed")
        return 0
    fi

    echo ">>> Running REST-assured Maven suite"
    local pom="${REPO_ROOT}/tests/integration/restassured/pom.xml"
    if mvn -B -ntp -f "${pom}" \
        -Dmsr.base.url="${MSR_BASE_URL}" \
        -Dmsr.admin.user="${MSR_ADMIN_USER}" \
        -Dmsr.admin.password="${MSR_ADMIN_PASSWORD}" \
        -Dpostgres.jdbc.url="jdbc:postgresql://localhost:${POSTGRES_HOST_PORT:-15432}/wm_test" \
        -Dartemis.url="tcp://localhost:${ARTEMIS_CORE_HOST_PORT:-61616}" \
        -Dmqtt.url="tcp://localhost:${MQTT_HOST_PORT:-11883}" \
        -Dkafka.bootstrap="localhost:${REDPANDA_HOST_PORT:-19092}" \
        verify
    then
        echo "    REST-assured: OK"
    else
        echo "    REST-assured: FAIL"
        SUITE_FAILURES+=("restassured")
    fi

    # Copy Surefire's JUnit XML into reports/integration/restassured/.
    local sf_dir="${REPO_ROOT}/tests/integration/restassured/target/surefire-reports"
    if [[ -d "${sf_dir}" ]]; then
        find "${sf_dir}" -maxdepth 1 -name 'TEST-*.xml' -print0 \
            | xargs -0 -I {} cp -f {} "${REPORTS_DIR}/restassured/" 2>/dev/null \
            || true
    fi
}

run_newman
run_k6
run_restassured

# ---------------------------------------------------------------------
# Aggregate every per-suite junit.xml into one canonical file the CI
# test reporter can consume. Tiny inline python so we don't require
# yet another tool on the host.
# ---------------------------------------------------------------------
echo ">>> Aggregating JUnit XML"
python3 - "${REPORTS_DIR}" <<'PY'
import os, sys, glob, xml.etree.ElementTree as ET

base = sys.argv[1]
out  = os.path.join(base, "junit.xml")

root = ET.Element("testsuites", {"name": "wm-integration"})
total = 0
failures = 0
errors = 0
duration = 0.0

for pat in (
    os.path.join(base, "newman",      "*.xml"),
    os.path.join(base, "k6",          "*.xml"),
    os.path.join(base, "restassured", "*.xml"),
):
    for f in sorted(glob.glob(pat)):
        try:
            tree = ET.parse(f)
        except ET.ParseError as e:
            ts = ET.SubElement(root, "testsuite",
                               {"name": os.path.basename(f), "tests": "1", "failures": "0", "errors": "1", "time": "0"})
            tc = ET.SubElement(ts, "testcase", {"classname": "junit-aggregate", "name": os.path.basename(f)})
            err = ET.SubElement(tc, "error", {"type": "ParseError"})
            err.text = str(e)
            total += 1
            errors += 1
            continue

        node = tree.getroot()
        suites = [node] if node.tag == "testsuite" else list(node.findall("testsuite"))
        for ts in suites:
            root.append(ts)
            try:
                total    += int(ts.attrib.get("tests",    0))
                failures += int(ts.attrib.get("failures", 0))
                errors   += int(ts.attrib.get("errors",   0))
                duration += float(ts.attrib.get("time",   0))
            except ValueError:
                pass

root.set("tests",    str(total))
root.set("failures", str(failures))
root.set("errors",   str(errors))
root.set("time",     f"{duration:.3f}")

ET.ElementTree(root).write(out, encoding="UTF-8", xml_declaration=True)
print(f"  -> {out}: tests={total} failures={failures} errors={errors} time={duration:.3f}s")
PY

# ---------------------------------------------------------------------
# Final verdict
# ---------------------------------------------------------------------
if (( ${#SUITE_FAILURES[@]} > 0 )); then
    SUITES_OK=0
    echo "FAIL: ${#SUITE_FAILURES[@]} suite failure(s): ${SUITE_FAILURES[*]}" >&2
    exit 2
fi

echo "PASS: all integration suites green."
exit 0
