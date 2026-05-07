# shellcheck shell=bash
# scripts/lib/wmreport-to-junit.sh
#
# Convert wm-mcp-server tool report JSON files into a single JUnit XML
# file consumable by the GitHub Actions test-reporter (dorny/test-reporter,
# mikepenz/action-junit-report, ...) and the IDE / IDE-extension test
# runners that follow the same convention.
#
# Source this file -- it does not run anything on its own.
#
#   . scripts/lib/wmreport-to-junit.sh
#   wmreport_to_junit reports/lint/results.xml \
#       reports/lint/package_dependency_check.json \
#       reports/lint/flow_validate.json
#
# Provides:
#   wmreport_to_junit OUT_XML JSON_REPORT [JSON_REPORT ...]
#
# Like manifest.sh, the heavy lifting is done in inline python3 rather
# than xmlstarlet/xmllint so the script runs unchanged on minimal dev
# boxes (WSL without libxml2-utils) and on the GitHub Actions ubuntu
# runners. python3 is on every supported platform; xmlstarlet is not.
#
# ---------------------------------------------------------------------
# Expected wm-mcp report JSON shape (one file per tool)
# ---------------------------------------------------------------------
#   {
#     "tool":   "<tool_name>",            # e.g. flow_validate
#     "ran_at": "<ISO-8601 UTC>",         # optional; emitted as
#                                         # testsuite[@timestamp]
#     "summary": {                         # optional, advisory only --
#         "total":    <int>,               # the converter recounts from
#         "passed":   <int>,               # the checks[] array so that
#         "failed":   <int>,               # totals always match what
#         "warnings": <int>                # ends up in the XML
#     },
#     "checks": [
#         {
#             "id":       "<stable id>",
#             "package":  "<package name>",
#             "service":  "<namespace:service>",  # optional
#             "severity": "error|warning|info|pass",
#             "message":  "<one-liner>",
#             "details":  "<multi-line, optional>"
#         },
#         ...
#     ]
#   }
#
# ---------------------------------------------------------------------
# Output XML (JUnit Surefire dialect)
# ---------------------------------------------------------------------
#   <testsuites tests="N" failures="F" errors="E">
#     <testsuite name="<tool>" tests="n" failures="f" errors="0"
#                skipped="0" timestamp="<ran_at>">
#       <testcase classname="<tool>.<package>" name="<id>"/>           pass
#       <testcase classname="<tool>.<package>" name="<id>">
#         <failure type="error|warning" message="...">
#           <details block as text>
#         </failure>
#       </testcase>
#       ...
#     </testsuite>
#     ...
#   </testsuites>
#
# Severity mapping:
#   error    -> <failure type="error">     (counts toward suite failures)
#   warning  -> <failure type="warning">   (counts toward suite failures)
#   info     -> empty <testcase/>          (passes; surfaces presence)
#   pass     -> empty <testcase/>          (passes)
#
# We deliberately treat warnings as failures rather than as a separate
# axis: the GitHub test-reporter does not render <system-out>/<warnings>
# blocks, and the whole point of running these checks in CI is to fail
# the PR until the warning is fixed or explicitly waived.
#
# A report file that is missing or unparseable is rendered as a single
# <error/> testcase named "(no output)" or "(parse error)" so the run
# is still visible in the GitHub UI rather than disappearing silently.

wmreport_to_junit() {
    local out_xml=$1
    shift
    local reports=("$@")
    if (( ${#reports[@]} == 0 )); then
        echo "ERROR: wmreport_to_junit needs OUT_XML and at least one report file" >&2
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "ERROR: python3 not found (required by wmreport_to_junit)" >&2
        return 1
    fi
    mkdir -p -- "$(dirname -- "${out_xml}")"
    python3 - "${out_xml}" "${reports[@]}" <<'PY'
import json
import os
import sys
from xml.etree import ElementTree as ET

out_xml = sys.argv[1]
report_paths = sys.argv[2:]

testsuites = ET.Element("testsuites")
total_tests = 0
total_failures = 0
total_errors = 0


def _suite_name_from_path(path):
    return os.path.splitext(os.path.basename(path))[0]


def _tool_error_suite(parent, suite_name, kind, message, body):
    """Render a missing/unparseable report as a single error testcase."""
    ts = ET.SubElement(
        parent, "testsuite",
        name=suite_name, tests="1", failures="0",
        errors="1", skipped="0",
    )
    tc = ET.SubElement(
        ts, "testcase", classname=suite_name, name="(no output)",
    )
    err = ET.SubElement(tc, "error", type=kind, message=message)
    err.text = body
    return ts


for path in report_paths:
    suite_name = _suite_name_from_path(path)

    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        _tool_error_suite(
            testsuites, suite_name,
            kind="ToolError",
            message="wm-mcp produced no output",
            body=f"Report file empty or missing: {path}",
        )
        total_tests += 1
        total_errors += 1
        continue

    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError) as e:
        _tool_error_suite(
            testsuites, suite_name,
            kind=type(e).__name__,
            message=str(e),
            body=f"File: {path}",
        )
        total_tests += 1
        total_errors += 1
        continue

    tool = (data.get("tool") or suite_name).strip()
    checks = data.get("checks") or []
    timestamp = (data.get("ran_at") or "").strip()

    n_total = len(checks)
    n_failed = 0
    for c in checks:
        sev = (c.get("severity") or "info").lower()
        if sev in ("error", "warning"):
            n_failed += 1

    suite_attrs = {
        "name": tool,
        "tests": str(n_total),
        "failures": str(n_failed),
        "errors": "0",
        "skipped": "0",
    }
    if timestamp:
        suite_attrs["timestamp"] = timestamp
    ts = ET.SubElement(testsuites, "testsuite", **suite_attrs)

    # Track names within this suite so a tool that emits two findings
    # for the same id/service still produces two distinct testcases
    # (the GitHub reporter dedupes on classname+name).
    seen = {}
    for c in checks:
        sev = (c.get("severity") or "info").lower()
        pkg = (c.get("package") or "package").strip() or "package"
        cid_raw = (
            c.get("id")
            or c.get("service")
            or c.get("message")
            or "check"
        )
        cid = str(cid_raw).strip() or "check"
        service = (c.get("service") or "").strip()
        base_name = f"{service} :: {cid}" if service else cid

        # Disambiguate duplicates within the suite.
        key = (pkg, base_name)
        seen[key] = seen.get(key, 0) + 1
        suffix = f" #{seen[key]}" if seen[key] > 1 else ""
        name = f"{base_name}{suffix}"

        tc = ET.SubElement(
            ts, "testcase",
            classname=f"{tool}.{pkg}",
            name=name,
        )
        if sev in ("error", "warning"):
            failure = ET.SubElement(
                tc, "failure",
                type=sev,
                message=str(c.get("message", "")).strip(),
            )
            details = c.get("details")
            failure.text = (
                str(details).strip()
                if details
                else str(c.get("message", "")).strip()
            )

    total_tests += n_total
    total_failures += n_failed

testsuites.set("tests", str(total_tests))
testsuites.set("failures", str(total_failures))
testsuites.set("errors", str(total_errors))

# Pretty-print so the generated file is human-diffable in PR review.
# ET.indent landed in Python 3.9 -- the GitHub ubuntu-latest runner
# ships >=3.10, and our Dockerfiles install python3 >= 3.9.
ET.indent(testsuites, space="  ")
xml_bytes = ET.tostring(testsuites, encoding="utf-8", xml_declaration=True)

os.makedirs(os.path.dirname(out_xml) or ".", exist_ok=True)
with open(out_xml, "wb") as fh:
    fh.write(xml_bytes)
    fh.write(b"\n")
PY
}
