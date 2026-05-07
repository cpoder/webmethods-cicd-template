#!/usr/bin/env bash
# scripts/build-packages.sh
#
# Build a webMethods Microservices Runtime (MSR) install zip for every
# directory under packages/.
#
# For each packages/<P>/ that contains a manifest.v3:
#
#   1. read the package version from manifest.v3 (xpath /Manifest/version,
#      with fall-backs for <package_version> and <PackageInfo><Version>);
#   2. validate the <requires> block: every named package must either
#      exist as a sibling under packages/ or be on the MSR built-in
#      whitelist (see scripts/lib/manifest.sh);
#   3. emit dist/<P>-<version>.zip with the package directory at the
#      archive root and the IDE/cache droppings excluded.
#
# Finally a dist/manifest.json is written summarising every zip with
# its SHA-256 -- the file CI uploads as the build artifact alongside
# the zips.
#
# Usage:
#   ./scripts/build-packages.sh [--packages-dir DIR] [--dist-dir DIR] [--clean]
#
# Exit codes:
#   0  success
#   1  generic / missing required tool
#   2  manifest.v3 missing or malformed, or version missing
#   3  unsatisfied <requires> dependency

set -euo pipefail

# ---------------------------------------------------------------------
# Resolve repo root from the script's location so the script works no
# matter where the user invokes it from.
# ---------------------------------------------------------------------
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)

# shellcheck source=lib/manifest.sh
. "${SCRIPT_DIR}/lib/manifest.sh"

PACKAGES_DIR="${REPO_ROOT}/packages"
DIST_DIR="${REPO_ROOT}/dist"
CLEAN=0

usage() {
    sed -n 's/^# \{0,1\}//p' "$0" | sed -n '2,30p'
}

while (( $# > 0 )); do
    case "$1" in
        --packages-dir)
            PACKAGES_DIR=$(cd -- "$2" >/dev/null 2>&1 && pwd) || {
                echo "ERROR: --packages-dir '$2' does not exist" >&2; exit 1; }
            shift 2 ;;
        --dist-dir)
            DIST_DIR=$2
            shift 2 ;;
        --clean)
            CLEAN=1
            shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 1 ;;
    esac
done

manifest_require_tools

# ---------------------------------------------------------------------
# Discover packages
# ---------------------------------------------------------------------
# A "package" is a directory directly under packages/ that contains a
# manifest.v3 file. Anything else (the .gitkeep marker, stray scratch
# dirs from a developer's workspace) is silently ignored so the script
# stays useful as packages get added incrementally.
mapfile -t PACKAGE_DIRS < <(
    find "${PACKAGES_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
        | sort
)

PACKAGES=()
for d in "${PACKAGE_DIRS[@]}"; do
    if [[ -f "${d}/manifest.v3" ]]; then
        PACKAGES+=("$(basename -- "$d")")
    fi
done

if (( ${#PACKAGES[@]} == 0 )); then
    echo "No packages with a manifest.v3 found under ${PACKAGES_DIR}." >&2
    echo "Writing an empty dist/manifest.json and exiting cleanly." >&2
    mkdir -p "${DIST_DIR}"
    jq -n --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{schema: 1, generated_at: $generated_at, packages: []}' \
        > "${DIST_DIR}/manifest.json"
    exit 0
fi

# ---------------------------------------------------------------------
# Prepare dist/
# ---------------------------------------------------------------------
mkdir -p "${DIST_DIR}"
if (( CLEAN == 1 )); then
    # Only delete the artifacts this script owns. A developer may have
    # other work-in-progress files under dist/ (sboms, signed bundles,
    # etc. produced by later pipeline stages); we don't want a
    # surprise wipe.
    find "${DIST_DIR}" -maxdepth 1 -type f \
        \( -name '*.zip' -o -name 'manifest.json' \) -delete
fi

# ---------------------------------------------------------------------
# Phase 1 -- validate every package up-front before building anything.
#
# We collect all errors and only abort once at the end so a developer
# editing several packages at once sees every problem in a single run
# rather than fix-rerun-fix-rerun.
# ---------------------------------------------------------------------
declare -A PKG_VERSION
ERRORS=()

local_pkg_exists() {
    local name=$1
    [[ -f "${PACKAGES_DIR}/${name}/manifest.v3" ]]
}

for pkg in "${PACKAGES[@]}"; do
    manifest_path="${PACKAGES_DIR}/${pkg}/manifest.v3"
    version=$(manifest_get_version "${manifest_path}") || {
        ERRORS+=("${pkg}: failed to read package version from manifest.v3")
        continue
    }
    PKG_VERSION["$pkg"]="$version"

    while IFS= read -r req; do
        [[ -z "$req" ]] && continue
        if local_pkg_exists "$req"; then
            continue
        fi
        if manifest_is_builtin "$req"; then
            continue
        fi
        ERRORS+=("${pkg}: requires package '${req}' which is neither present under packages/ nor on the MSR built-in whitelist")
    done < <(manifest_get_requires "${manifest_path}")
done

if (( ${#ERRORS[@]} > 0 )); then
    {
        echo "ERROR: package validation failed:"
        printf '  - %s\n' "${ERRORS[@]}"
        echo
        echo "If a missing package really is an MSR built-in not on the default"
        echo "whitelist, set WM_BUILTIN_PACKAGES_EXTRA before re-running, e.g.:"
        echo "  WM_BUILTIN_PACKAGES_EXTRA='WmFoo WmBar' ./scripts/build-packages.sh"
    } >&2
    exit 3
fi

# ---------------------------------------------------------------------
# Phase 2 -- build zips and collect their SHA-256s.
# ---------------------------------------------------------------------
declare -a MANIFEST_ENTRIES=()

for pkg in "${PACKAGES[@]}"; do
    version="${PKG_VERSION[$pkg]}"
    zip_name="${pkg}-${version}.zip"
    zip_path="${DIST_DIR}/${zip_name}"

    # Remove any prior copy at this exact name to avoid `zip` appending.
    rm -f -- "${zip_path}"

    echo "Building ${zip_name}..."
    manifest_zip_package "${PACKAGES_DIR}/${pkg}" "${zip_path}"

    sha=$(manifest_sha256 "${zip_path}")
    size=$(stat -c '%s' "${zip_path}" 2>/dev/null || stat -f '%z' "${zip_path}")
    MANIFEST_ENTRIES+=(
        "$(jq -n \
            --arg name "$pkg" \
            --arg version "$version" \
            --arg zip "$zip_name" \
            --arg sha256 "$sha" \
            --argjson size_bytes "$size" \
            '{name: $name, version: $version, zip: $zip, sha256: $sha256, size_bytes: $size_bytes}')"
    )
done

# ---------------------------------------------------------------------
# Write dist/manifest.json
# ---------------------------------------------------------------------
generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n \
    --arg generated_at "$generated_at" \
    --argjson packages "$(printf '%s\n' "${MANIFEST_ENTRIES[@]}" | jq -s .)" \
    '{schema: 1, generated_at: $generated_at, packages: $packages}' \
    > "${DIST_DIR}/manifest.json"

echo
echo "Built ${#PACKAGES[@]} package(s):"
for pkg in "${PACKAGES[@]}"; do
    printf '  %s -> %s/%s-%s.zip\n' \
        "$pkg" "${DIST_DIR#"${REPO_ROOT}/"}" "$pkg" "${PKG_VERSION[$pkg]}"
done
echo "Manifest: ${DIST_DIR#"${REPO_ROOT}/"}/manifest.json"
