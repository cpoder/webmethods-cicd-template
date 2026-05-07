#!/usr/bin/env bash
# scripts/policy/check-acl-hygiene.sh
#
# Policy gate: a flow service must NOT run as the Anonymous ACL
# unless its comment block carries the explicit
# `// public-by-design` marker.
#
# Discovery: any directory under packages/<P>/ns/.../ that contains
# both a flow.xml and a node.ndf is treated as a flow service node.
# We do not walk node.ndf alone -- a non-service node (folder,
# trigger, document type) is irrelevant to this gate.
#
# Parsing: node.ndf is a Values-XML file emitted by IS. We accept
# two shapes for forward-compat with toolchain quirks:
#
#   1. canonical:   <value name="acl_runtime">Anonymous</value>
#   2. legacy KV:   acl_runtime=Anonymous   (one per line)
#
# Comment lookup order (first non-empty wins):
#   a. <value name="node_comment"> in node.ndf
#   b. <COMMENT> element in flow.xml
#   c. node_comment=... legacy KV in node.ndf
#
# The marker is matched literally as the substring "// public-by-design"
# (case-sensitive). A trailing rationale ("// public-by-design - ping
# endpoint for k8s probe") is fine.
#
# Usage:
#   scripts/policy/check-acl-hygiene.sh [--packages-dir DIR]
#                                       [--marker STRING]
#
# Exit codes:
#   0  no Anonymous flow services without the marker
#   1  setup error
#   2  one or more violations

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

PACKAGES_DIR="${REPO_ROOT}/packages"
MARKER="// public-by-design"

usage() { sed -n 's/^# \{0,1\}//p' "$0" | sed -n '2,40p'; }

while (( $# > 0 )); do
    case "$1" in
        --packages-dir)
            PACKAGES_DIR=$2; shift 2 ;;
        --marker)
            MARKER=$2; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            policy_log_fail "unknown argument: $1"
            usage >&2
            exit 1 ;;
    esac
done

if [[ ! -d "$PACKAGES_DIR" ]]; then
    policy_log_fail "packages dir not found: $PACKAGES_DIR"
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    policy_log_fail "python3 is required (XML parsing)"
    exit 1
fi

# ---------------------------------------------------------------------
# Find candidate flow services (flow.xml + node.ndf in the same dir).
# A package without ns/ is fine -- not every package owns flow services.
# ---------------------------------------------------------------------
mapfile -t NODES < <(
    find "$PACKAGES_DIR" -mindepth 3 -type f -name 'flow.xml' -print | sort
)

if (( ${#NODES[@]} == 0 )); then
    policy_log_info "no flow services found under $PACKAGES_DIR (nothing to check)"
    policy_log_pass "no Anonymous-ACL violations (0 flow services checked)"
    exit 0
fi

# ---------------------------------------------------------------------
# Per-node check delegated to python so we get real XML parsing
# instead of grep+sed games.
# ---------------------------------------------------------------------
violations=0
checked=0
for flow_xml in "${NODES[@]}"; do
    node_dir=$(dirname -- "$flow_xml")
    node_ndf="${node_dir}/node.ndf"
    [[ -f "$node_ndf" ]] || continue
    checked=$((checked+1))

    result=$(
        FLOW_XML="$flow_xml" \
        NODE_NDF="$node_ndf" \
        MARKER="$MARKER" \
        PACKAGES_DIR="$PACKAGES_DIR" \
        python3 - <<'PY'
import os, sys, re, xml.etree.ElementTree as ET

flow_xml    = os.environ["FLOW_XML"]
node_ndf    = os.environ["NODE_NDF"]
marker      = os.environ["MARKER"]
packages_dir = os.environ["PACKAGES_DIR"]

def values_xml_get(path, name):
    """Return the first <value name=...>X</value> text, or None."""
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError):
        return None
    for el in root.iter("value"):
        if el.get("name") == name:
            return (el.text or "").strip()
    return None

def kv_get(path, key):
    """Return the value of `key=...` (legacy format), or None."""
    pat = re.compile(rf"^\s*{re.escape(key)}\s*=\s*(.*?)\s*$")
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = pat.match(line)
                if m:
                    return m.group(1)
    except OSError:
        return None
    return None

def flow_xml_comment(path):
    """Return text of a top-level <COMMENT> element, or None."""
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError):
        return None
    el = root.find("COMMENT")
    if el is not None and (el.text or "").strip():
        return el.text.strip()
    # Some IS exports nest as <FLOW><COMMENT>...</COMMENT></FLOW>
    el = root.find(".//COMMENT")
    if el is not None and (el.text or "").strip():
        return el.text.strip()
    return None

acl = values_xml_get(node_ndf, "acl_runtime") or kv_get(node_ndf, "acl_runtime")
if not acl:
    # No declared ACL means the IS default applies -- which is NOT
    # Anonymous. Out of scope for this gate.
    sys.exit(0)

if acl != "Anonymous":
    sys.exit(0)

comment = (
    values_xml_get(node_ndf, "node_comment")
    or flow_xml_comment(flow_xml)
    or kv_get(node_ndf, "node_comment")
    or ""
)

# Print the relative path so the CI log is short and clickable.
try:
    rel = os.path.relpath(os.path.dirname(flow_xml), packages_dir)
except ValueError:
    rel = os.path.dirname(flow_xml)

if marker in comment:
    print(f"WAIVED\t{rel}")
else:
    print(f"VIOLATION\t{rel}")
PY
    )

    case "$result" in
        VIOLATION$'\t'*)
            rel=${result#VIOLATION$'\t'}
            policy_log_fail "$rel runs as Anonymous ACL without the $MARKER marker"
            violations=$((violations+1)) ;;
        WAIVED$'\t'*)
            rel=${result#WAIVED$'\t'}
            policy_log_info "$rel: Anonymous ACL waived ($MARKER)" ;;
        "" )
            : ;;  # quiet pass
        * )
            policy_log_warn "unexpected result for $flow_xml: $result" ;;
    esac
done

if (( violations > 0 )); then
    echo "::error::$violations flow service(s) expose Anonymous ACL without the '$MARKER' marker."
    exit 2
fi

policy_log_pass "no Anonymous-ACL violations ($checked flow service(s) checked)"
exit 0
