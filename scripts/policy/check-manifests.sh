#!/usr/bin/env bash
# scripts/policy/check-manifests.sh
#
# Policy gate: every package's manifest.v3 must declare:
#   - <version>            non-empty
#   - <description>        non-empty
#   - <startup_service>    at least one entry, OR
#     a <no-startup-needed/> marker stating the omission is intentional
#
# The startup_service requirement exists so support engineers can wake
# up at 03:00, see "no startup ran", and know it was a deliberate
# choice -- not a forgotten config field.
#
# Discovery: same as scripts/build-packages.sh -- a package is a
# directory directly under --packages-dir that contains a manifest.v3
# file. The .gitkeep marker and scratch directories are silently
# skipped.
#
# Accepted manifest shapes (parsed via python's ElementTree):
#
#   Version:
#     <version>1.0.0</version>                     (canonical, per spec)
#     <package_version>1.0.0</package_version>     (legacy fallback)
#     <PackageInfo><Version>1.0.0</Version></...>  (legacy fallback)
#
#   Description:
#     <description>...</description>               (canonical)
#     <Description>...</Description>               (legacy)
#
#   Startup:
#     <startup_services><service>foo:bar</service></startup_services>
#     <startup_services><startup_service>foo:bar</startup_service>...
#     <startup_service>foo:bar</startup_service>   (top-level, IS export)
#     <Startup><Service>foo:bar</Service></Startup>
#     <no-startup-needed/>                         (explicit marker)
#     <no_startup_needed/>                         (snake_case alias)
#
# Usage:
#   scripts/policy/check-manifests.sh [--packages-dir DIR]
#
# Exit codes:
#   0  every manifest is well-formed and complete
#   1  setup error
#   2  one or more manifests fail the gate

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

PACKAGES_DIR="${REPO_ROOT}/packages"

usage() { sed -n 's/^# \{0,1\}//p' "$0" | sed -n '2,40p'; }

while (( $# > 0 )); do
    case "$1" in
        --packages-dir) PACKAGES_DIR=$2; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
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
# Walk packages/ deterministically.
# ---------------------------------------------------------------------
mapfile -t MANIFESTS < <(
    find "$PACKAGES_DIR" -mindepth 2 -maxdepth 2 -type f -name 'manifest.v3' | sort
)

if (( ${#MANIFESTS[@]} == 0 )); then
    policy_log_info "no packages found under $PACKAGES_DIR (nothing to check)"
    policy_log_pass "all manifests well-formed (0 checked)"
    exit 0
fi

violations=0
checked=0
for manifest in "${MANIFESTS[@]}"; do
    pkg=$(basename -- "$(dirname -- "$manifest")")
    checked=$((checked+1))

    # python returns one of:
    #   OK
    #   FAIL\t<msg>[ ; <msg>...]
    #   PARSE\t<msg>
    result=$(MANIFEST="$manifest" python3 - <<'PY'
import os, sys, xml.etree.ElementTree as ET

path = os.environ["MANIFEST"]
try:
    root = ET.parse(path).getroot()
except ET.ParseError as e:
    print(f"PARSE\tmalformed XML: {e}")
    sys.exit(0)

errs = []

# --- version --------------------------------------------------------
version = None
for xp in ("version", "package_version", "PackageInfo/Version"):
    el = root.find(xp)
    if el is not None and (el.text or "").strip():
        version = el.text.strip()
        break
if not version:
    errs.append("missing or empty <version>")

# --- description ----------------------------------------------------
description = None
for xp in ("description", "Description"):
    el = root.find(xp)
    if el is not None and (el.text or "").strip():
        description = el.text.strip()
        break
if not description:
    errs.append("missing or empty <description>")

# --- startup --------------------------------------------------------
def has_no_startup_marker(r):
    for tag in ("no-startup-needed", "no_startup_needed",
                "noStartupNeeded"):
        if r.find(tag) is not None:
            return True
    return False

def has_startup_service(r):
    # Accept several plural-container shapes...
    for parent_tag in ("startup_services", "startupServices", "Startup"):
        parent = r.find(parent_tag)
        if parent is None:
            continue
        for child_tag in ("service", "Service",
                          "startup_service", "startupService"):
            for el in parent.findall(child_tag):
                if (el.text or "").strip() or el.get("name", "").strip():
                    return True
    # ...or top-level <startup_service> elements directly under <Manifest>.
    for tag in ("startup_service", "startupService"):
        for el in r.findall(tag):
            if (el.text or "").strip() or el.get("name", "").strip():
                return True
    return False

if not (has_startup_service(root) or has_no_startup_marker(root)):
    errs.append("no <startup_service> entries and no <no-startup-needed/> marker")

if errs:
    print("FAIL\t" + " ; ".join(errs))
else:
    print("OK")
PY
    )

    case "$result" in
        OK)
            : ;;
        FAIL$'\t'*)
            msg=${result#FAIL$'\t'}
            policy_log_fail "$pkg: $msg"
            violations=$((violations+1)) ;;
        PARSE$'\t'*)
            msg=${result#PARSE$'\t'}
            policy_log_fail "$pkg: $msg"
            violations=$((violations+1)) ;;
        *)
            policy_log_warn "unexpected output for $pkg: $result"
            violations=$((violations+1)) ;;
    esac
done

if (( violations > 0 )); then
    echo "::error::$violations manifest(s) failed the policy gate."
    exit 2
fi

policy_log_pass "all manifests well-formed and complete ($checked checked)"
exit 0
