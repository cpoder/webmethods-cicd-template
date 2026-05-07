#!/usr/bin/env bash
# scripts/policy/check-image-size.sh
#
# Policy gate: a service image must be no larger than --max-bytes
# (default 2 GiB, per Task 5.3 spec "service image <= 2 GB").
#
# Inputs (one is required):
#   --image REF              docker image ref to inspect
#                            (uses `docker image inspect`)
#   --tarball PATH           file produced by `docker save -o ...` --
#                            its on-disk byte count is used
#   --size-bytes N           skip resolution; use N directly (test hook,
#                            also useful right after a buildx export
#                            where CI already knows the size)
#
# Options:
#   --max-bytes N            override the default ceiling (raw bytes)
#   --max-size  STR          human-friendly alternative: 2GB, 1.5GiB, ...
#                            (see scripts/policy/lib/common.sh for the
#                            accepted unit grammar)
#   -h / --help
#
# Exit codes:
#   0  size <= max
#   1  setup error (missing tool, missing input, parse error)
#   2  size >  max  (policy violation)

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

DEFAULT_MAX=$((2 * 1024 * 1024 * 1024))   # 2 GiB
IMAGE=""
TARBALL=""
SIZE_BYTES=""
MAX_BYTES=""
MAX_SIZE=""

usage() { sed -n 's/^# \{0,1\}//p' "$0" | sed -n '2,30p'; }

while (( $# > 0 )); do
    case "$1" in
        --image)        IMAGE=$2; shift 2 ;;
        --tarball)      TARBALL=$2; shift 2 ;;
        --size-bytes)   SIZE_BYTES=$2; shift 2 ;;
        --max-bytes)    MAX_BYTES=$2; shift 2 ;;
        --max-size)     MAX_SIZE=$2; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)
            policy_log_fail "unknown argument: $1"
            usage >&2
            exit 1 ;;
    esac
done

# ---------------------------------------------------------------------
# Resolve the ceiling
# ---------------------------------------------------------------------
if [[ -n "$MAX_BYTES" && -n "$MAX_SIZE" ]]; then
    policy_log_fail "use --max-bytes OR --max-size, not both"
    exit 1
fi
if [[ -n "$MAX_SIZE" ]]; then
    MAX_BYTES=$(policy_parse_size "$MAX_SIZE") || exit 1
fi
if [[ -z "$MAX_BYTES" ]]; then
    MAX_BYTES=$DEFAULT_MAX
fi
if ! [[ "$MAX_BYTES" =~ ^[0-9]+$ ]]; then
    policy_log_fail "--max-bytes must be a positive integer (got: $MAX_BYTES)"
    exit 1
fi

# ---------------------------------------------------------------------
# Resolve the actual image size
# ---------------------------------------------------------------------
inputs=0
[[ -n "$IMAGE" ]]      && inputs=$((inputs+1))
[[ -n "$TARBALL" ]]    && inputs=$((inputs+1))
[[ -n "$SIZE_BYTES" ]] && inputs=$((inputs+1))
if (( inputs == 0 )); then
    policy_log_fail "one of --image, --tarball, --size-bytes is required"
    usage >&2
    exit 1
fi
if (( inputs > 1 )); then
    policy_log_fail "--image, --tarball, --size-bytes are mutually exclusive"
    exit 1
fi

actual=""
source_label=""
if [[ -n "$SIZE_BYTES" ]]; then
    if ! [[ "$SIZE_BYTES" =~ ^[0-9]+$ ]]; then
        policy_log_fail "--size-bytes must be a positive integer (got: $SIZE_BYTES)"
        exit 1
    fi
    actual=$SIZE_BYTES
    source_label="size-bytes"
elif [[ -n "$TARBALL" ]]; then
    if [[ ! -f "$TARBALL" ]]; then
        policy_log_fail "--tarball file not found: $TARBALL"
        exit 1
    fi
    actual=$(stat -c '%s' -- "$TARBALL" 2>/dev/null \
          || stat -f '%z' -- "$TARBALL")
    source_label="tarball:$TARBALL"
else
    if ! command -v docker >/dev/null 2>&1; then
        policy_log_fail "--image requires docker on PATH"
        exit 1
    fi
    # docker image inspect returns the "uncompressed on-disk" size,
    # which is what `docker pull` will materialise on the node.
    actual=$(docker image inspect --format '{{.Size}}' "$IMAGE" 2>/dev/null) || {
        policy_log_fail "docker image inspect failed for: $IMAGE"
        exit 1
    }
    source_label="image:$IMAGE"
fi

# ---------------------------------------------------------------------
# Compare
# ---------------------------------------------------------------------
human_actual=$(policy_human_bytes "$actual")
human_max=$(policy_human_bytes "$MAX_BYTES")

if (( actual > MAX_BYTES )); then
    policy_log_fail "$source_label is $human_actual (> ceiling $human_max)"
    echo "::error::Image size ${human_actual} exceeds policy ceiling ${human_max}."
    exit 2
fi

policy_log_pass "$source_label is $human_actual (<= ceiling $human_max)"
exit 0
