# shellcheck shell=bash
# scripts/policy/lib/common.sh
#
# Shared helpers for the policy gate scripts. Source-only; no
# top-level side effects so individual scripts can decide their own
# bash modes (set -e, etc.).
#
#   . scripts/policy/lib/common.sh
#
# Provides:
#   policy_log_pass MSG       -- print PASS line to stdout
#   policy_log_fail MSG       -- print FAIL line to stderr
#   policy_log_warn MSG       -- print WARN line to stderr
#   policy_log_info MSG       -- print INFO line to stderr
#   policy_human_bytes BYTES  -- pretty-print a byte count
#   policy_parse_size  STR    -- parse "2GB" / "512MiB" / "12345" -> bytes
#   policy_repo_root          -- echo the repository root directory
#
# Exit-code convention shared across check-*.sh scripts:
#   0  policy clean
#   1  setup error (missing tool, missing input, malformed CLI)
#   2  policy violation (the thing the gate exists to catch)

policy_log_pass() { printf 'PASS: %s\n' "$*"; }
policy_log_fail() { printf 'FAIL: %s\n' "$*" >&2; }
policy_log_warn() { printf 'WARN: %s\n' "$*" >&2; }
policy_log_info() { printf 'INFO: %s\n' "$*" >&2; }

# Pretty-print a byte count using powers of 1024 (GiB / MiB / KiB).
# Leaves the input untouched if it is not a positive integer.
policy_human_bytes() {
    local bytes=$1
    if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        printf '%s' "$bytes"
        return
    fi
    awk -v b="$bytes" '
        BEGIN {
            split("B KiB MiB GiB TiB", units, " ");
            i = 1;
            while (b >= 1024 && i < 5) { b /= 1024; i++ }
            if (i == 1) printf "%d %s", b, units[i];
            else        printf "%.2f %s", b, units[i];
        }'
}

# Parse a human-friendly size (case-insensitive) into a byte count.
# Accepts: 2147483648, 2GB, 2GiB, 512MB, 512MiB, 1024K, 12k, etc.
# Bare digits are interpreted as bytes. Decimal units (KB/MB/GB/TB)
# use powers of 1000 to match `du --si` and `docker inspect`'s "Size"
# field (which is reported in bytes); binary units (KiB/MiB/GiB) use
# powers of 1024. Prints the result on stdout; non-zero exit on a
# parse error (also writes a message to stderr).
policy_parse_size() {
    local raw=$1
    local upper
    upper=$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]')
    if [[ "$upper" =~ ^([0-9]+(\.[0-9]+)?)([KMGT]I?B?|B)?$ ]]; then
        local num=${BASH_REMATCH[1]}
        local unit=${BASH_REMATCH[3]:-B}
        local mult=1
        case "$unit" in
            B|"")        mult=1 ;;
            K|KB)        mult=1000 ;;
            KI|KIB)      mult=1024 ;;
            M|MB)        mult=$((1000*1000)) ;;
            MI|MIB)      mult=$((1024*1024)) ;;
            G|GB)        mult=$((1000*1000*1000)) ;;
            GI|GIB)      mult=$((1024*1024*1024)) ;;
            T|TB)        mult=$((1000*1000*1000*1000)) ;;
            TI|TIB)      mult=$((1024*1024*1024*1024)) ;;
            *)
                printf 'ERROR: unrecognised size unit %q in %q\n' "$unit" "$raw" >&2
                return 1 ;;
        esac
        # awk handles fractional inputs (e.g. "1.5GB") cleanly.
        awk -v n="$num" -v m="$mult" 'BEGIN { printf "%d", n * m }'
        return 0
    fi
    printf 'ERROR: cannot parse size %q (try 2GB, 512MiB, or a raw byte count)\n' "$raw" >&2
    return 1
}

policy_repo_root() {
    local script_dir
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[1]}")" >/dev/null 2>&1 && pwd)
    cd -- "${script_dir}/../.." >/dev/null 2>&1 && pwd
}
