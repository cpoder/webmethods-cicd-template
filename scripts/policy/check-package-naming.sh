#!/usr/bin/env bash
# scripts/policy/check-package-naming.sh
#
# Policy gate: package directories under packages/ must not use
# reserved names. Per Task 5.3 the forbidden names are:
#
#   - Default
#   - Test
#   - Tmp
#   - any name starting with the Wm prefix (Wm*)  -- reserved by IBM
#     for built-in MSR / WmART packages.
#
# A "package" is a directory directly under --packages-dir that
# contains a manifest.v3 file (mirrors the discovery rule in
# scripts/build-packages.sh -- the .gitkeep marker and stray
# scratch dirs are silently ignored so the gate does not block on
# IDE/scratch droppings).
#
# Usage:
#   scripts/policy/check-package-naming.sh [--packages-dir DIR]
#                                          [--allow NAME ...]
#
# Options:
#   --packages-dir DIR   default: <repo>/packages
#   --allow NAME         exempt a specific name (repeatable). Use
#                        sparingly; intended for migrating a legacy
#                        package whose rename is scheduled separately.
#                        The env var POLICY_PKG_ALLOW (space-separated)
#                        is also honoured so CI can inject exemptions
#                        without editing the workflow YAML.
#   -h / --help
#
# Exit codes:
#   0  no reserved names in use
#   1  setup error
#   2  policy violation (one or more reserved names found)

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

PACKAGES_DIR="${REPO_ROOT}/packages"
declare -a ALLOWLIST=()

# Pull additional allow entries from the env var (space-separated).
if [[ -n "${POLICY_PKG_ALLOW:-}" ]]; then
    # shellcheck disable=SC2206 # intentional word-splitting on space
    ALLOWLIST+=( ${POLICY_PKG_ALLOW} )
fi

usage() { sed -n 's/^# \{0,1\}//p' "$0" | sed -n '2,40p'; }

while (( $# > 0 )); do
    case "$1" in
        --packages-dir)
            PACKAGES_DIR=$2; shift 2 ;;
        --allow)
            ALLOWLIST+=("$2"); shift 2 ;;
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

# ---------------------------------------------------------------------
# Reserved names. Wm is matched as a prefix (case-sensitive); the
# other three are matched as exact names. Case-sensitivity matches
# the IBM convention -- a package called "default" (lowercase) would
# be a different (and equally bad) problem that other gates flag.
# ---------------------------------------------------------------------
RESERVED_EXACT=(Default Test Tmp)
RESERVED_PREFIXES=(Wm)

is_allowed() {
    local n=$1
    local entry
    for entry in "${ALLOWLIST[@]}"; do
        [[ "$entry" == "$n" ]] && return 0
    done
    return 1
}

is_reserved() {
    local n=$1
    local r
    for r in "${RESERVED_EXACT[@]}"; do
        [[ "$n" == "$r" ]] && { echo "exact:$r"; return 0; }
    done
    for r in "${RESERVED_PREFIXES[@]}"; do
        [[ "$n" == "$r"* ]] && { echo "prefix:$r"; return 0; }
    done
    return 1
}

# ---------------------------------------------------------------------
# Walk packages/. Sort so the report is reproducible for CI logs.
# ---------------------------------------------------------------------
mapfile -t CANDIDATES < <(
    find "$PACKAGES_DIR" -mindepth 1 -maxdepth 1 -type d -print | sort
)

violations=0
checked=0
for pkg in "${CANDIDATES[@]}"; do
    name=$(basename -- "$pkg")
    # Skip directories without manifest.v3 -- they aren't recognised
    # as packages by build-packages.sh either.
    [[ -f "${pkg}/manifest.v3" ]] || continue
    checked=$((checked+1))

    if reason=$(is_reserved "$name"); then
        if is_allowed "$name"; then
            policy_log_warn "$name matches reserved rule [$reason] but is on the allowlist"
            continue
        fi
        policy_log_fail "$name is reserved [$reason] (forbidden by policy)"
        violations=$((violations+1))
    fi
done

if (( checked == 0 )); then
    policy_log_info "no packages found under $PACKAGES_DIR (nothing to check)"
fi

if (( violations > 0 )); then
    echo "::error::$violations package(s) use reserved names. Rename or add to the allowlist."
    exit 2
fi

policy_log_pass "no reserved package names in $PACKAGES_DIR ($checked package(s) checked)"
exit 0
