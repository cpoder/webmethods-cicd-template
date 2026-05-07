#!/usr/bin/env bash
# scripts/test-unit.sh
#
# Headless unit-test runner for webMethods packages.
#
# Spins up the wm-msr-base-test image (the variant carrying the
# WmTestSuite package and Apache Ant), mounts the just-built service
# packages plus every tests/unit/<P>Test/ project into the container,
# renders the run-test-suites.properties file from its template, and
# invokes the WmTestSuite Composite Runner via Ant.
#
# Reports collected:
#   reports/unit/html/                  pretty HTML report
#   reports/unit/coverage/index.html    wmcodecoverage HTML report
#   reports/unit/raw/wmTestSuiteResult.xml*  raw runner output
#   reports/unit/junit.xml              JUnit XML for dorny/test-reporter
#
# Coverage gate: scripts/lib/wmtestsuite-to-junit.xsl converts raw to
# JUnit, then this script reads tests/unit/coverage-threshold.yaml and
# fails the build if any package falls below the configured percentage.
#
# Mocking: every test case lives in a .wmTestCase file and embeds its
# own mock definitions (JDBC adapter, pub.client:http, pub.jms:send,
# ...). Unit tests therefore run against an MSR with NO external
# infrastructure (no DB, no broker, no Kafka). Integration tests in
# tests/integration/ are the place for that stack -- see Task 4.2.
#
# Usage:
#   scripts/test-unit.sh [options]
#
# Options:
#   --packages-dir DIR         packages to mount   (default: <repo>/packages)
#   --tests-dir DIR            test projects root  (default: <repo>/tests/unit)
#   --reports-dir DIR          output reports dir  (default: <repo>/reports/unit)
#   --image IMAGE              test image          (default: wm-msr-base-test:${MSR_VERSION})
#   --port N                   host port           (default: 5555)
#   --user NAME                IS admin user       (default: Administrator)
#   --password PASS            IS admin password   (default: manage)
#   --wait-timeout SECONDS     readiness wait      (default: 240)
#   --use-https BOOL           true|false          (default: false)
#   --suites NAME[,NAME...]    suites to run       (default: all)
#   --no-coverage              run composite-runner-all-tests instead of the
#                              -with-coverage variant; faster on every push,
#                              the full one is for nightly
#   --coverage-threshold YAML  default: tests/unit/coverage-threshold.yaml
#   --coverage-include GLOB    default: */ns/**/* minus vendor packages
#   --coverage-exclude GLOB    default: Wm*,Default
#   --keep                     leave the container running on exit (debug)
#
# Exit codes:
#   0  all unit tests passed AND coverage met the configured threshold
#   1  setup error (missing host tool, image not pullable, container
#      never became healthy, properties template misrender, ...)
#   2  one or more test cases failed/errored
#   3  tests passed but coverage fell below the configured threshold

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)

# shellcheck source=lib/render-properties.sh
. "${SCRIPT_DIR}/lib/render-properties.sh"

# ---------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------
PACKAGES_DIR="${REPO_ROOT}/packages"
TESTS_DIR="${REPO_ROOT}/tests/unit"
REPORTS_DIR="${REPO_ROOT}/reports/unit"
TEST_IMAGE="${TEST_IMAGE:-}"
IS_PORT="${IS_PORT:-5555}"
IS_USERNAME="${IS_USERNAME:-Administrator}"
IS_PASSWORD="${IS_PASSWORD:-manage}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-240}"
IS_USE_HTTPS="${IS_USE_HTTPS:-false}"
TEST_SUITES="${TEST_SUITES:-all}"
WITH_COVERAGE=1
KEEP=0
COVERAGE_THRESHOLD_FILE="${REPO_ROOT}/tests/unit/coverage-threshold.yaml"
COVERAGE_INCLUDE="${COVERAGE_INCLUDE:-}"
COVERAGE_EXCLUDE="${COVERAGE_EXCLUDE:-Wm*,Default}"

usage() {
    sed -n 's/^# \{0,1\}//p' "$0" | sed -n '2,55p'
}

while (( $# > 0 )); do
    case "$1" in
        --packages-dir)        PACKAGES_DIR=$2; shift 2 ;;
        --tests-dir)           TESTS_DIR=$2; shift 2 ;;
        --reports-dir)         REPORTS_DIR=$2; shift 2 ;;
        --image)               TEST_IMAGE=$2; shift 2 ;;
        --port)                IS_PORT=$2; shift 2 ;;
        --user)                IS_USERNAME=$2; shift 2 ;;
        --password)            IS_PASSWORD=$2; shift 2 ;;
        --wait-timeout)        WAIT_TIMEOUT=$2; shift 2 ;;
        --use-https)           IS_USE_HTTPS=$2; shift 2 ;;
        --suites)              TEST_SUITES=$2; shift 2 ;;
        --no-coverage)         WITH_COVERAGE=0; shift ;;
        --coverage-threshold)  COVERAGE_THRESHOLD_FILE=$2; shift 2 ;;
        --coverage-include)    COVERAGE_INCLUDE=$2; shift 2 ;;
        --coverage-exclude)    COVERAGE_EXCLUDE=$2; shift 2 ;;
        --keep)                KEEP=1; shift ;;
        -h|--help)             usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------
# Resolve test image default from versions.env when not passed in.
# ---------------------------------------------------------------------
if [[ -z "${TEST_IMAGE}" ]]; then
    if [[ -f "${REPO_ROOT}/versions.env" ]]; then
        # shellcheck source=/dev/null
        set -a; . "${REPO_ROOT}/versions.env"; set +a
    fi
    TEST_IMAGE="wm-msr-base-test:${MSR_VERSION:-11.1.0}"
fi

# Default coverage-include glob: every service file under
# packages/*/ns/<your-org>/... -- vendor packages and the synthetic
# "Default" package are excluded via --coverage-exclude.
if [[ -z "${COVERAGE_INCLUDE}" ]]; then
    COVERAGE_INCLUDE="packages/*/ns/**/*"
fi

# ---------------------------------------------------------------------
# Host tool checks. xsltproc OR python3+lxml is enough -- test-unit.sh
# picks whichever is available when converting raw -> JUnit.
# ---------------------------------------------------------------------
missing=()
for tool in docker python3 curl base64; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if (( ${#missing[@]} > 0 )); then
    printf 'ERROR: required tool(s) not found on host: %s\n' "${missing[*]}" >&2
    exit 1
fi

XSLT_RUNNER=""
if command -v xsltproc >/dev/null 2>&1; then
    XSLT_RUNNER=xsltproc
elif python3 -c 'import lxml.etree' >/dev/null 2>&1; then
    XSLT_RUNNER=python-lxml
else
    echo "ERROR: need xsltproc OR python3-lxml for the JUnit conversion." >&2
    echo "       Install hint (Debian/Ubuntu): apt-get install -y xsltproc" >&2
    echo "                  or:                pip install lxml" >&2
    exit 1
fi

# ---------------------------------------------------------------------
# Discover test projects. Each tests/unit/<P>Test/ directory that has a
# .project file counts as a project. We mount the whole tests-dir into
# the container at /tests, so the runner sees the full tree.
# ---------------------------------------------------------------------
mapfile -t TEST_PROJECTS < <(
    find "${TESTS_DIR}" -mindepth 2 -maxdepth 2 -name '.project' -printf '%h\n' 2>/dev/null | sort
)
if (( ${#TEST_PROJECTS[@]} == 0 )); then
    echo "ERROR: no test projects found under ${TESTS_DIR}." >&2
    echo "       Each tests/unit/<P>Test/ directory needs a .project file." >&2
    exit 1
fi
echo "Discovered ${#TEST_PROJECTS[@]} test project(s):"
for p in "${TEST_PROJECTS[@]}"; do
    echo "  - $(basename -- "$p")"
done

# ---------------------------------------------------------------------
# Render the properties file from the template. The committed template
# at tests/unit/run-test-suites.properties.tmpl holds NO secrets; this
# step substitutes env vars (admin creds + container paths).
# ---------------------------------------------------------------------
TEMPLATE="${TESTS_DIR}/run-test-suites.properties.tmpl"
if [[ ! -f "${TEMPLATE}" ]]; then
    echo "ERROR: properties template not found: ${TEMPLATE}" >&2
    exit 1
fi
RENDERED_PROPS_HOST="${REPORTS_DIR}/run-test-suites.properties"
mkdir -p -- "${REPORTS_DIR}"

# Container-side paths for the rendered properties file -- these are
# what the IS Composite Runner sees once we bind-mount things.
export IS_HOST=localhost
export IS_PORT="${IS_PORT}"
export IS_USERNAME IS_PASSWORD IS_USE_HTTPS
export TESTS_DIR=/tests
export TEST_SUITES
export REPORT_HTML_DIR=/reports/html
export REPORT_RAW_DIR=/reports/raw
export REPORT_COVERAGE_DIR=/reports/coverage
export COVERAGE_INCLUDE COVERAGE_EXCLUDE

echo "Rendering ${TEMPLATE} -> ${RENDERED_PROPS_HOST}..."
render_properties "${TEMPLATE}" "${RENDERED_PROPS_HOST}"

# ---------------------------------------------------------------------
# Pull the test image if missing.
# ---------------------------------------------------------------------
echo "Checking test image: ${TEST_IMAGE}"
if ! docker image inspect "${TEST_IMAGE}" >/dev/null 2>&1; then
    echo "Pulling ${TEST_IMAGE}..."
    docker pull "${TEST_IMAGE}" \
        || { echo "ERROR: failed to pull ${TEST_IMAGE}" >&2; exit 1; }
fi

# ---------------------------------------------------------------------
# Boot the test container.
#
# Mounts:
#   <packages-dir>  -> /opt/.../instances/default/packages/   (services)
#   <tests-dir>     -> /tests                                 (suites)
#   <reports-dir>   -> /reports                               (output)
#
# Packages are mounted read-only so the runner cannot mutate the
# committed source tree by accident; reports is read-write because
# Ant writes the output there.
# ---------------------------------------------------------------------
CONTAINER_NAME="wm-utf-$$-${RANDOM}"
CID=""

cleanup() {
    local rc=$?
    if (( KEEP == 1 )); then
        echo "[keep] container left running: ${CONTAINER_NAME} (id ${CID:0:12})" >&2
    elif [[ -n "${CID}" ]]; then
        docker stop "${CID}" >/dev/null 2>&1 || true
    fi
    return $rc
}
trap cleanup EXIT

echo "Starting ${CONTAINER_NAME} on port ${IS_PORT}..."
PACKAGES_MOUNT="/opt/softwareag/IntegrationServer/instances/default/packages"
CID=$(docker run --rm -d \
    --name "${CONTAINER_NAME}" \
    -p "${IS_PORT}:5555" \
    -v "${PACKAGES_DIR}:${PACKAGES_MOUNT}/_user:ro" \
    -v "${TESTS_DIR}:/tests:ro" \
    -v "${REPORTS_DIR}:/reports" \
    -v "${RENDERED_PROPS_HOST}:/tests/run-test-suites.properties:ro" \
    "${TEST_IMAGE}")

# ---------------------------------------------------------------------
# Wait for IS to become healthy. The base image's /invoke/wm.server:ping
# endpoint requires HTTP Basic auth; we use the same creds the test
# runner is configured with.
# ---------------------------------------------------------------------
echo "Waiting for IS to become healthy (timeout ${WAIT_TIMEOUT}s)..."
auth_b64=$(printf '%s:%s' "${IS_USERNAME}" "${IS_PASSWORD}" | base64 | tr -d '\n')
deadline=$(( SECONDS + WAIT_TIMEOUT ))
ready=0
while (( SECONDS < deadline )); do
    if curl -fsS \
        -H "Authorization: Basic ${auth_b64}" \
        "http://localhost:${IS_PORT}/invoke/wm.server:ping" \
        >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 5
done
if (( ready == 0 )); then
    echo "ERROR: IS did not become healthy within ${WAIT_TIMEOUT}s" >&2
    docker logs --tail 100 "${CID}" >&2 || true
    exit 1
fi
echo "IS is ready."

# ---------------------------------------------------------------------
# Move the user packages into the IS instance packages dir. We mount
# them under /packages/_user/ so we don't shadow IBM-provided packages
# (WmRoot, WmTestSuite, WmJDBCAdapter, ...); the runner expects them
# alongside, so symlink them in.
# ---------------------------------------------------------------------
docker exec -u root "${CID}" sh -c '
    set -e
    for pkg in /opt/softwareag/IntegrationServer/instances/default/packages/_user/*/; do
        [ -d "$pkg" ] || continue
        name=$(basename "$pkg")
        ln -sfn "$pkg" \
            "/opt/softwareag/IntegrationServer/instances/default/packages/$name"
    done
    chown -R sagadmin:sagadmin \
        /opt/softwareag/IntegrationServer/instances/default/packages 2>/dev/null || true
' || true

# ---------------------------------------------------------------------
# Reload the package list inside IS so the freshly mounted packages
# come online without restarting the container.
# ---------------------------------------------------------------------
echo "Reloading IS packages..."
docker exec \
    -e WM_MCP_TARGET="http://localhost:5555" \
    -e WM_MCP_USER="${IS_USERNAME}" \
    -e WM_MCP_PASSWORD="${IS_PASSWORD}" \
    "${CID}" \
    wm-mcp packages_reload --output json >/dev/null 2>&1 || true

# ---------------------------------------------------------------------
# Run Ant. WmTestSuite ships its driver build file at
# $WM_HOME/IntegrationServer/instances/default/packages/WmTestSuite/code/ant/run-composite-runner.xml.
# Targets:
#   composite-runner-all-tests                 - fast no-coverage run
#   composite-runner-all-tests-with-coverage   - with wmcodecoverage
# We pick the latter by default; --no-coverage drops to the former.
# ---------------------------------------------------------------------
TARGET="composite-runner-all-tests-with-coverage"
if (( WITH_COVERAGE == 0 )); then
    TARGET="composite-runner-all-tests"
fi

echo "Running Ant target: ${TARGET}"
ANT_BUILD="/opt/softwareag/IntegrationServer/instances/default/packages/WmTestSuite/code/ant/run-composite-runner.xml"
set +e
docker exec "${CID}" \
    ant -f "${ANT_BUILD}" \
        -propertyfile /tests/run-test-suites.properties \
        "${TARGET}"
ANT_RC=$?
set -e
echo "Ant exited with status ${ANT_RC}"

# ---------------------------------------------------------------------
# Convert raw runner output to JUnit. There is one wmTestSuiteResult.xml
# per test suite; we transform each independently and concatenate. The
# JUnit reporter accepts either a single file or a glob, but a single
# file is simpler for the GitHub Actions workflow definition.
# ---------------------------------------------------------------------
RAW_DIR="${REPORTS_DIR}/raw"
JUNIT_XML="${REPORTS_DIR}/junit.xml"
HTML_DIR="${REPORTS_DIR}/html"
COVERAGE_DIR="${REPORTS_DIR}/coverage"

mkdir -p -- "${RAW_DIR}" "${HTML_DIR}" "${COVERAGE_DIR}"

mapfile -t RAW_FILES < <(
    find "${RAW_DIR}" -type f -name '*.xml' 2>/dev/null | sort
)

XSL="${SCRIPT_DIR}/lib/wmtestsuite-to-junit.xsl"

if (( ${#RAW_FILES[@]} == 0 )); then
    echo "WARN: no raw wmTestSuiteResult XML files under ${RAW_DIR}" >&2
    # Emit an empty-but-valid testsuites doc so dorny/test-reporter has
    # something to render rather than 404'ing.
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
        '<testsuites tests="0" failures="0" errors="1">' \
        '  <testsuite name="(no output)" tests="1" failures="0" errors="1">' \
        '    <testcase classname="WmTestSuite" name="(no raw results)">' \
        '      <error type="NoOutput" message="WmTestSuite produced no XML"/>' \
        '    </testcase>' \
        '  </testsuite>' \
        '</testsuites>' > "${JUNIT_XML}"
    JUNIT_FAIL=1
    JUNIT_ERR=1
else
    echo "Converting ${#RAW_FILES[@]} raw result file(s) -> ${JUNIT_XML} (via ${XSLT_RUNNER})"
    # Merge raw into a single in-memory doc, transform, write.
    python3 - "${JUNIT_XML}" "${XSL}" "${XSLT_RUNNER}" "${RAW_FILES[@]}" <<'PY'
import sys
import os
from xml.etree import ElementTree as ET

out_xml, xsl_path, runner = sys.argv[1], sys.argv[2], sys.argv[3]
raw_files = sys.argv[4:]

# Concatenate every <testSuiteResult> from the raw files into a single
# synthetic <wmTestSuiteResult>. The XSLT walks //testSuiteResult so a
# wrapper root is enough; we don't need to merge attribute-level data.
merged = ET.Element("wmTestSuiteResult")
for path in raw_files:
    try:
        doc = ET.parse(path).getroot()
    except ET.ParseError as e:
        # Surface the parse error as a synthetic suite so the GitHub
        # UI shows the bad file rather than just a smaller test count.
        ts = ET.SubElement(merged, "testSuiteResult", name=os.path.basename(path))
        tc = ET.SubElement(ts, "testCaseResult", name="(parse error)", status="error")
        det = ET.SubElement(tc, "errorDetails")
        msg = ET.SubElement(det, "message")
        msg.text = str(e)
        continue
    # The raw root is itself <wmTestSuiteResult> on most runs but a
    # single-suite run may produce <testSuiteResult> directly. Handle
    # both.
    if doc.tag == "testSuiteResult":
        merged.append(doc)
    else:
        for ts in doc.findall(".//testSuiteResult"):
            merged.append(ts)

merged_path = out_xml + ".merged-raw.xml"
ET.ElementTree(merged).write(merged_path, encoding="utf-8", xml_declaration=True)

if runner == "xsltproc":
    import subprocess
    rc = subprocess.call(["xsltproc", "-o", out_xml, xsl_path, merged_path])
    if rc != 0:
        sys.exit(rc)
else:
    from lxml import etree
    xslt = etree.parse(xsl_path)
    src = etree.parse(merged_path)
    transformer = etree.XSLT(xslt)
    result = transformer(src)
    with open(out_xml, "wb") as fh:
        fh.write(etree.tostring(
            result,
            pretty_print=True,
            xml_declaration=True,
            encoding="UTF-8",
        ))

os.unlink(merged_path)
PY

    # Tally counts from the converted JUnit so we can decide exit code.
    JUNIT_FAIL=$(python3 -c "
from xml.etree import ElementTree as ET
r = ET.parse('${JUNIT_XML}').getroot()
print(int(r.get('failures', '0')))
")
    JUNIT_ERR=$(python3 -c "
from xml.etree import ElementTree as ET
r = ET.parse('${JUNIT_XML}').getroot()
print(int(r.get('errors', '0')))
")
fi

echo "JUnit summary: failures=${JUNIT_FAIL} errors=${JUNIT_ERR}"

# ---------------------------------------------------------------------
# Coverage gate. The wmcodecoverage tool emits a coverage.xml in
# Cobertura-ish format under reports/unit/coverage/. We parse that and
# compare against the per-package thresholds in coverage-threshold.yaml.
#
# Thresholds file shape:
#   defaults:
#     min_line_coverage: 70
#   packages:
#     HelloWorld:
#       min_line_coverage: 80
# ---------------------------------------------------------------------
COVERAGE_XML=""
for candidate in \
    "${COVERAGE_DIR}/coverage.xml" \
    "${COVERAGE_DIR}/cobertura.xml"; do
    if [[ -f "${candidate}" ]]; then
        COVERAGE_XML="${candidate}"
        break
    fi
done

COVERAGE_RC=0
if (( WITH_COVERAGE == 1 )); then
    if [[ -z "${COVERAGE_XML}" ]]; then
        echo "WARN: coverage report not found under ${COVERAGE_DIR}" >&2
        echo "      (expected coverage.xml or cobertura.xml)" >&2
        COVERAGE_RC=3
    else
        echo "Checking coverage against ${COVERAGE_THRESHOLD_FILE}..."
        set +e
        python3 - "${COVERAGE_XML}" "${COVERAGE_THRESHOLD_FILE}" "${COVERAGE_EXCLUDE}" <<'PY'
import sys
import os
import fnmatch
from xml.etree import ElementTree as ET

cov_xml, thresholds_path, exclude_globs_csv = sys.argv[1], sys.argv[2], sys.argv[3]
exclude_globs = [g.strip() for g in exclude_globs_csv.split(",") if g.strip()]


def parse_thresholds(path):
    """Tiny YAML parser limited to the documented thresholds shape.

    Avoids pulling PyYAML in. Format we accept:
        defaults:
          min_line_coverage: 70
        packages:
          HelloWorld:
            min_line_coverage: 80
    """
    if not os.path.isfile(path):
        return {"default": 70, "packages": {}}

    default = 70
    packages = {}
    section = None
    current_pkg = None
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            if not line.startswith(" "):
                section = stripped.rstrip(":")
                current_pkg = None
                continue
            indent = len(line) - len(line.lstrip(" "))
            if section == "defaults" and ":" in stripped:
                k, v = [x.strip() for x in stripped.split(":", 1)]
                if k == "min_line_coverage":
                    default = float(v)
            elif section == "packages":
                if indent == 2 and stripped.endswith(":"):
                    current_pkg = stripped.rstrip(":")
                    packages.setdefault(current_pkg, {"min_line_coverage": default})
                elif indent >= 4 and current_pkg and ":" in stripped:
                    k, v = [x.strip() for x in stripped.split(":", 1)]
                    if k == "min_line_coverage":
                        packages[current_pkg]["min_line_coverage"] = float(v)
    return {"default": default, "packages": packages}


thresholds = parse_thresholds(thresholds_path)

# Cobertura-style: <coverage line-rate="0.83">
#                    <packages>
#                      <package name="..." line-rate="...">...</package>
#                    </packages>
#                  </coverage>
root = ET.parse(cov_xml).getroot()

failed = []
overall_rate = root.get("line-rate")
if overall_rate is not None:
    overall_pct = float(overall_rate) * 100
    print(f"  overall: {overall_pct:.1f}% (threshold {thresholds['default']}%)")
    if overall_pct < thresholds["default"]:
        failed.append((
            "(overall)",
            overall_pct,
            thresholds["default"],
        ))

for pkg in root.iter("package"):
    name = pkg.get("name", "(unknown)")
    rate = pkg.get("line-rate")
    if rate is None:
        continue
    if any(fnmatch.fnmatchcase(name, g) for g in exclude_globs):
        # Vendor packages (Wm*, Default) are filtered by the runner's
        # coverage-exclude glob and may legitimately appear in
        # coverage.xml with low rates -- don't gate on them.
        print(f"  {name}: skipped (matches exclude glob)")
        continue
    pct = float(rate) * 100
    pkg_threshold = thresholds["packages"].get(name, {}).get(
        "min_line_coverage", thresholds["default"]
    )
    print(f"  {name}: {pct:.1f}% (threshold {pkg_threshold}%)")
    if pct < pkg_threshold:
        failed.append((name, pct, pkg_threshold))

if failed:
    print()
    print("ERROR: coverage below threshold:", file=sys.stderr)
    for name, pct, t in failed:
        print(f"  - {name}: {pct:.1f}% < {t}%", file=sys.stderr)
    sys.exit(3)
PY
        COVERAGE_RC=$?
        set -e
    fi
fi

# ---------------------------------------------------------------------
# Exit code precedence:
#   1. setup error -> already exited above
#   2. test failures/errors -> 2
#   3. coverage below threshold -> 3
#   4. all good -> 0
# ---------------------------------------------------------------------
echo
echo "Reports:"
echo "  HTML:     ${HTML_DIR}/"
echo "  Coverage: ${COVERAGE_DIR}/index.html"
echo "  Raw:      ${RAW_DIR}/"
echo "  JUnit:    ${JUNIT_XML}"

if (( JUNIT_FAIL > 0 || JUNIT_ERR > 0 )); then
    echo "Result: FAIL (${JUNIT_FAIL} failures, ${JUNIT_ERR} errors)"
    exit 2
fi
if (( COVERAGE_RC != 0 )); then
    echo "Result: COVERAGE BELOW THRESHOLD"
    exit 3
fi
echo "Result: PASS"
exit 0
