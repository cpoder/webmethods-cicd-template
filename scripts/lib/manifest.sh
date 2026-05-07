# shellcheck shell=bash
# scripts/lib/manifest.sh
#
# Helper functions for build-packages.sh. Source this file -- it does
# not run anything on its own.
#
#   . scripts/lib/manifest.sh
#
# Provides:
#   manifest_require_tools         -- abort if python3/jq/sha256sum missing
#   manifest_get_version FILE      -- print package version from manifest.v3
#   manifest_get_requires FILE     -- print required package names, one per line
#   manifest_is_builtin NAME       -- exit 0 if NAME is an MSR built-in
#   manifest_zip_package DIR OUT   -- write zip OUT containing pkg DIR
#   manifest_sha256 FILE           -- print sha256 hex
#
# We use python3 for XML parsing and zip creation rather than xmllint+zip
# so the script runs unchanged on minimal dev boxes (e.g. WSL without
# libxml2-utils) and on CI runners. python3 is on every supported
# platform; xmllint and the zip CLI are not.

# ---------------------------------------------------------------------
# MSR built-in package whitelist
# ---------------------------------------------------------------------
# Packages shipped by the Microservices Runtime itself. A `requires`
# entry that names one of these is satisfied by the running MSR even if
# nothing of the same name exists locally under packages/. Keep this
# list conservative: adding a name here lets a package depend on a
# runtime feature without a local copy, so an over-broad list will
# silently mask real missing-dependency errors.
#
# Sources: MSR 11.x package set + WmART adapter packages routinely
# present in corporate base images. Extend via the
# WM_BUILTIN_PACKAGES_EXTRA env var rather than editing this file in a
# microservice repo.
WM_BUILTIN_PACKAGES=(
    WmRoot
    WmPublic
    WmFlatFile
    WmJDBCAdapter
    WmART
    WmTaskClient
    WmTomcat
    WmXSLT
    WmTN
    WmEDI
    WmEDIINT
    WmEDIforTN
    WmISExtDC
    WmCloudStreams
    WmRESTConnector
    WmJSON
    WmXML
    WmJMS
    WmKafkaAdapter
    WmServer
    WmMonitor
    WmDeployer
    WmAssetPublisher
    WmISClient
    WmAdminCenter
    WmComposite
    WmMessaging
    WmSecurityInfra
    WmTestSuite
    WmDocViewer
    WmAgentCcs
    WmCDS
    WmSMTP
    WmDB
    WmEntireX
    WmWebService
    WmWin32
)

manifest_is_builtin() {
    local name=$1
    local extra
    for builtin in "${WM_BUILTIN_PACKAGES[@]}"; do
        [[ "$builtin" == "$name" ]] && return 0
    done
    # Allow projects to extend the whitelist via env without forking
    # this file. Format: WM_BUILTIN_PACKAGES_EXTRA="WmFoo WmBar".
    if [[ -n "${WM_BUILTIN_PACKAGES_EXTRA:-}" ]]; then
        for extra in ${WM_BUILTIN_PACKAGES_EXTRA}; do
            [[ "$extra" == "$name" ]] && return 0
        done
    fi
    return 1
}

# ---------------------------------------------------------------------
# Tool checks
# ---------------------------------------------------------------------
manifest_require_tools() {
    local missing=()
    for tool in python3 jq sha256sum; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if (( ${#missing[@]} > 0 )); then
        printf 'ERROR: required tool(s) not found: %s\n' "${missing[*]}" >&2
        printf 'Install hint (Debian/Ubuntu): apt-get install -y python3 jq coreutils\n' >&2
        return 1
    fi
}

# ---------------------------------------------------------------------
# Version extraction
# ---------------------------------------------------------------------
# Reads the package version from manifest.v3.
#
# Per task spec the canonical xpath is /Manifest/version (an element
# directly under the root). Real-world webMethods exports also use
# <package_version> or a <PackageInfo><Version> nested element -- we
# accept either as a fallback so the script works against packages
# extracted from existing repositories without a manual rewrite.
#
# Returns the version on stdout, exits non-zero if no version found.
manifest_get_version() {
    local manifest=$1
    python3 - "$manifest" <<'PY'
import sys, xml.etree.ElementTree as ET

path = sys.argv[1]
try:
    root = ET.parse(path).getroot()
except ET.ParseError as e:
    print(f"ERROR: malformed XML in {path}: {e}", file=sys.stderr)
    sys.exit(2)

# Probe candidate locations in priority order.
for xpath in ("version", "package_version", "PackageInfo/Version"):
    el = root.find(xpath)
    if el is not None and (el.text or "").strip():
        print(el.text.strip())
        sys.exit(0)

print(f"ERROR: no <version>, <package_version>, or <PackageInfo><Version> "
      f"element under <Manifest> in {path}", file=sys.stderr)
sys.exit(3)
PY
}

# ---------------------------------------------------------------------
# Requires extraction
# ---------------------------------------------------------------------
# Prints the names of every <package> child of <requires> (one per line).
# Accepts both the canonical lowercase form and the capitalised
# <Requires>/<Package> variant. Each entry's name is taken from element
# text content first, then a `name` attribute as a fallback.
manifest_get_requires() {
    local manifest=$1
    python3 - "$manifest" <<'PY'
import sys, xml.etree.ElementTree as ET

path = sys.argv[1]
try:
    root = ET.parse(path).getroot()
except ET.ParseError as e:
    print(f"ERROR: malformed XML in {path}: {e}", file=sys.stderr)
    sys.exit(2)

names = []
for req_tag in ("requires", "Requires"):
    req = root.find(req_tag)
    if req is None:
        continue
    for pkg_tag in ("package", "Package"):
        for el in req.findall(pkg_tag):
            name = (el.text or "").strip() or el.get("name", "").strip()
            if name:
                names.append(name)

# Stable, de-duplicated output.
seen = set()
for n in names:
    if n not in seen:
        seen.add(n)
        print(n)
PY
}

# ---------------------------------------------------------------------
# Zip creation
# ---------------------------------------------------------------------
# Writes a zip archive whose contents, when extracted, produce the
# package directory at the root -- the layout MSR's package_install
# expects.
#
# Excludes:
#   - <pkg>/code/classes/.cache/   (per task spec)
#   - .idea/, .vscode/, .settings/, .git/ anywhere under the package
#   - file patterns: *.lck *.iml *.swp *.swo *.bak *.tmp *~ .DS_Store Thumbs.db
manifest_zip_package() {
    local pkg_dir=$1
    local out_zip=$2
    python3 - "$pkg_dir" "$out_zip" <<'PY'
import os, sys, zipfile, fnmatch

src = os.path.normpath(sys.argv[1])
out = sys.argv[2]
pkg_name = os.path.basename(src)
if not pkg_name:
    print(f"ERROR: cannot derive package name from path '{sys.argv[1]}'", file=sys.stderr)
    sys.exit(2)

# Anywhere directories named these are stripped from the archive.
EXCLUDE_DIR_NAMES = {".idea", ".vscode", ".settings", ".git", "__pycache__"}
EXCLUDE_FILE_PATTERNS = (
    "*.lck", "*.iml", "*.swp", "*.swo", "*.bak", "*.tmp", "*~",
    ".DS_Store", "Thumbs.db",
)

def excluded_file(name):
    return any(fnmatch.fnmatch(name, p) for p in EXCLUDE_FILE_PATTERNS)

with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for dirpath, dirs, files in os.walk(src):
        rel_dir = os.path.relpath(dirpath, src).replace(os.sep, "/")
        if rel_dir == ".":
            rel_dir = ""

        # Spec: exclude code/classes/.cache and everything under it.
        if rel_dir == "code/classes/.cache" or rel_dir.startswith("code/classes/.cache/"):
            dirs[:] = []
            continue

        # Generic excludes for IDE/version-control droppings.
        dirs[:] = sorted(d for d in dirs if d not in EXCLUDE_DIR_NAMES)

        for fname in sorted(files):
            if excluded_file(fname):
                continue
            full = os.path.join(dirpath, fname)
            arc = pkg_name + "/" + (f"{rel_dir}/{fname}" if rel_dir else fname)
            zf.write(full, arc)
PY
}

# ---------------------------------------------------------------------
# SHA-256
# ---------------------------------------------------------------------
manifest_sha256() {
    local file=$1
    sha256sum "$file" | awk '{print $1}'
}
