# shellcheck shell=bash
# scripts/lib/secret-resolver.sh
#
# Helper functions for apply-config.sh. Source this file -- it does not
# run anything on its own.
#
#   . scripts/lib/secret-resolver.sh
#
# Provides:
#   secret_resolve_json IN_JSON OUT_JSON
#       Walk the JSON tree at IN_JSON; in every string value, replace
#       every "${SECRET:NAME}" placeholder with the value of the env
#       var NAME. Aborts with a non-zero exit if any placeholder
#       references an env var that is unset or empty, listing every
#       missing name.
#
#   secret_resolve_text IN_FILE OUT_FILE
#       Same substitution rule, but on a flat text file (used for
#       the merged extended-settings.properties body so that
#       set_extended_setting can be called with already-resolved
#       values).
#
# Why the "${SECRET:NAME}" form rather than plain ${NAME}:
#   * MSR's Global Variable / URL-template mechanism already uses
#     ${VAR} for runtime substitution; conflating the two would mean
#     the apply step accidentally resolves placeholders intended for
#     wm-mcp / IS to handle later.
#   * The "SECRET:" prefix is a hard, greppable signal for reviewers
#     that a string is going to leak a real credential at apply time.
#
# *_secret_ref fields (password_secret_ref, sasl_password_secret_ref,
# ssl_truststore_secret_ref, etc.) are deliberately NOT touched here:
# docs/config-merge.md states that merge tools should treat
# *_secret_ref strings as opaque pointers, and apply-config.sh follows
# the same convention -- the wm-mcp tool calls receive the URI and the
# wm-mcp daemon is responsible for fetching the credential through its
# active backend (Vault, k8s Secret, ...).

secret_resolver_require_tools() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "ERROR: python3 not found (required by secret-resolver)" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------
# secret_resolve_json IN_JSON OUT_JSON
#
# Reads IN_JSON, replaces all ${SECRET:NAME} placeholders inside
# string values, writes OUT_JSON. Exits non-zero if any placeholder
# refers to an unset env var.
# ---------------------------------------------------------------------
secret_resolve_json() {
    local in_json=$1
    local out_json=$2
    if [[ -z "$in_json" || -z "$out_json" ]]; then
        echo "ERROR: secret_resolve_json IN_JSON OUT_JSON" >&2
        return 2
    fi
    if [[ ! -f "$in_json" ]]; then
        echo "ERROR: input JSON not found: $in_json" >&2
        return 2
    fi
    mkdir -p -- "$(dirname -- "$out_json")"
    python3 - "$in_json" "$out_json" <<'PY'
import json
import os
import re
import sys

placeholder = re.compile(r"\$\{SECRET:([A-Za-z_][A-Za-z0-9_]*)\}")
in_path = sys.argv[1]
out_path = sys.argv[2]

with open(in_path, "r", encoding="utf-8") as fh:
    doc = json.load(fh)

missing = set()


def resolve_string(s, where):
    def repl(m):
        name = m.group(1)
        val = os.environ.get(name)
        if val is None or val == "":
            missing.add(f"{name} (referenced at {where})")
            return m.group(0)
        return val
    return placeholder.sub(repl, s)


def walk(node, where="$"):
    if isinstance(node, dict):
        return {k: walk(v, f"{where}.{k}") for k, v in node.items()}
    if isinstance(node, list):
        return [walk(v, f"{where}[{i}]") for i, v in enumerate(node)]
    if isinstance(node, str):
        return resolve_string(node, where)
    return node


resolved = walk(doc)

if missing:
    print(
        "ERROR: unresolved ${SECRET:NAME} placeholders -- env vars are not set:",
        file=sys.stderr,
    )
    for m in sorted(missing):
        print(f"  - {m}", file=sys.stderr)
    sys.exit(1)

with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(resolved, fh, indent=2, sort_keys=False)
    fh.write("\n")
PY
}

# ---------------------------------------------------------------------
# secret_resolve_text IN_FILE OUT_FILE
#
# Same substitution as secret_resolve_json, but treats the input as a
# flat text file (no JSON parse). Used for the merged
# extended-settings.properties before set_extended_setting calls.
# ---------------------------------------------------------------------
secret_resolve_text() {
    local in_file=$1
    local out_file=$2
    if [[ -z "$in_file" || -z "$out_file" ]]; then
        echo "ERROR: secret_resolve_text IN_FILE OUT_FILE" >&2
        return 2
    fi
    if [[ ! -f "$in_file" ]]; then
        echo "ERROR: input file not found: $in_file" >&2
        return 2
    fi
    mkdir -p -- "$(dirname -- "$out_file")"
    python3 - "$in_file" "$out_file" <<'PY'
import os
import re
import sys

placeholder = re.compile(r"\$\{SECRET:([A-Za-z_][A-Za-z0-9_]*)\}")
in_path = sys.argv[1]
out_path = sys.argv[2]

with open(in_path, "r", encoding="utf-8") as fh:
    text = fh.read()

missing = set()


def repl(m):
    name = m.group(1)
    val = os.environ.get(name)
    if val is None or val == "":
        missing.add(name)
        return m.group(0)
    return val


resolved = placeholder.sub(repl, text)

if missing:
    print(
        "ERROR: unresolved ${SECRET:NAME} placeholders -- env vars are not set:",
        file=sys.stderr,
    )
    for n in sorted(missing):
        print(f"  - {n}", file=sys.stderr)
    sys.exit(1)

with open(out_path, "w", encoding="utf-8") as fh:
    fh.write(resolved)
PY
}
