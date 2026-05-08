#!/usr/bin/env bash
# scripts/validate-config.sh
#
# Validates every YAML config file under config/<env>/ against
# schemas/config.schema.json. Files are mapped to a $defs/<name>
# sub-schema by basename; unknown basenames fail.
#
# Each sub-schema sets `additionalProperties: false`, so unknown
# top-level keys cause validation failure (acceptance criterion).
#
# Usage:
#   scripts/validate-config.sh                # validate all envs
#   scripts/validate-config.sh config/dev     # validate one env
#   scripts/validate-config.sh config/base/jdbc-pools.yaml  # validate one file
#
# yq (mikefarah) is used to pre-flight YAML parsing when available; the
# JSON-Schema check itself runs through scripts/lib/validate-config.py.
#
# Exit codes:
#   0  all files valid
#   1  one or more files failed validation
#   2  setup error (missing dependency, missing schema)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCHEMA_FILE="${SCHEMA_FILE:-${REPO_ROOT}/schemas/config.schema.json}"
PY_VALIDATOR="${SCRIPT_DIR}/lib/validate-config.py"
PYBIN="${PYTHON3:-python3}"

# Map config file basename -> $defs key.
file_to_def() {
    case "$1" in
        global-variables.yaml|global-variables.yml) echo "GlobalVariables" ;;
        jdbc-pools.yaml|jdbc-pools.yml) echo "JdbcPools" ;;
        jms-aliases.yaml|jms-aliases.yml) echo "JmsAliases" ;;
        kafka-connections.yaml|kafka-connections.yml) echo "KafkaConnections" ;;
        mqtt-connections.yaml|mqtt-connections.yml) echo "MqttConnections" ;;
        ports.yaml|ports.yml) echo "Ports" ;;
        acls.yaml|acls.yml) echo "Acls" ;;
        users-and-groups.yaml|users-and-groups.yml) echo "UsersAndGroups" ;;
        *) echo "" ;;
    esac
}

# Files we explicitly do NOT validate.
# - extended-settings.properties: raw .properties, see docs/config-merge.md
# - deploy.yaml: deploy-orchestration metadata read by scripts/deploy/*.sh,
#   not consumed by wm-mcp; intentionally has no entry in $defs (Task 7.1)
is_skipped_file() {
    case "$(basename "$1")" in
        .gitkeep|extended-settings.properties|README.md|README) return 0 ;;
        deploy.yaml|deploy.yml) return 0 ;;
        *) return 1 ;;
    esac
}

err()  { printf 'ERROR: %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }

# --- Pre-flight checks ---------------------------------------------------

if [[ ! -f "$SCHEMA_FILE" ]]; then
    err "schema file not found: $SCHEMA_FILE"
    exit 2
fi
if [[ ! -x "$PY_VALIDATOR" && ! -f "$PY_VALIDATOR" ]]; then
    err "python validator missing: $PY_VALIDATOR"
    exit 2
fi
if ! command -v "$PYBIN" >/dev/null 2>&1; then
    err "python3 not found in PATH"
    exit 2
fi

HAVE_YQ=0
if command -v yq >/dev/null 2>&1; then
    HAVE_YQ=1
fi

# --- Collect target files ------------------------------------------------

targets=()
if (( $# == 0 )); then
    while IFS= read -r -d '' f; do
        targets+=("$f")
    done < <(find "${REPO_ROOT}/config" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 2>/dev/null | sort -z)
else
    for arg in "$@"; do
        if [[ -d "$arg" ]]; then
            while IFS= read -r -d '' f; do
                targets+=("$f")
            done < <(find "$arg" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | sort -z)
        elif [[ -f "$arg" ]]; then
            targets+=("$arg")
        else
            err "not a file or directory: $arg"
            exit 2
        fi
    done
fi

if (( ${#targets[@]} == 0 )); then
    info "No YAML config files found - nothing to validate."
    exit 0
fi

# --- Validate each file --------------------------------------------------

errors=0
checked=0
unknown=0

for f in "${targets[@]}"; do
    rel="${f#${REPO_ROOT}/}"
    base="$(basename "$f")"

    if is_skipped_file "$f"; then
        continue
    fi

    def="$(file_to_def "$base")"
    if [[ -z "$def" ]]; then
        err "unknown config file (no schema mapping): $rel"
        unknown=$((unknown + 1))
        errors=$((errors + 1))
        continue
    fi

    # Optional: pre-flight YAML parse via yq for nicer error messages on
    # malformed YAML before invoking the python validator.
    if (( HAVE_YQ )); then
        if ! yq eval '.' "$f" >/dev/null 2>yq.err; then
            err "yq failed to parse $rel:"
            sed 's/^/    /' yq.err >&2 || true
            rm -f yq.err
            errors=$((errors + 1))
            continue
        fi
        rm -f yq.err
    fi

    info "Validating $rel  ->  #/\$defs/$def"
    if ! "$PYBIN" "$PY_VALIDATOR" "$f" --schema "$SCHEMA_FILE" --def "$def"; then
        errors=$((errors + 1))
    fi
    checked=$((checked + 1))
done

if (( errors > 0 )); then
    err "$errors file(s) failed validation (checked $checked${unknown:+, unknown $unknown})."
    exit 1
fi
info "OK: $checked file(s) valid against schemas/config.schema.json"
exit 0
