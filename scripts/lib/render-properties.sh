# shellcheck shell=bash
# scripts/lib/render-properties.sh
#
# Render a .properties template by substituting ${NAME} placeholders
# with the values of matching env vars. Source this file -- it does
# not run anything on its own.
#
#   . scripts/lib/render-properties.sh
#   render_properties tests/unit/run-test-suites.properties.tmpl \
#                     tests/unit/run-test-suites.properties
#
# Provides:
#   render_properties IN_FILE OUT_FILE
#       Read IN_FILE, replace every "${NAME}" with the value of env
#       var NAME, write OUT_FILE. Aborts with a non-zero exit if any
#       placeholder references an env var that is unset OR empty,
#       listing every missing name. Comment lines (the first
#       non-whitespace character is "#") are passed through verbatim
#       so meta-references like "${NAME} is the placeholder form" in
#       template documentation aren't accidentally replaced.
#
# Placeholder syntax: a literal ${NAME} where NAME matches
# [A-Za-z_][A-Za-z0-9_]*. The "${SECRET:NAME}" form (used elsewhere
# in this repo) is intentionally not understood here -- this helper
# is for plain env-var substitution into properties templates, not
# for the secret-resolution step of apply-config.sh.
#
# We forbid empty values rather than treating them as "use default":
# an unset IS_PASSWORD silently rendering to an empty password is the
# kind of failure that only shows up at the worst time (in CI on a
# Friday afternoon).

render_properties_require_tools() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "ERROR: python3 not found (required by render-properties)" >&2
        return 1
    fi
}

render_properties() {
    local in_file=$1
    local out_file=$2
    if [[ -z "${in_file}" || -z "${out_file}" ]]; then
        echo "ERROR: render_properties IN_FILE OUT_FILE" >&2
        return 2
    fi
    if [[ ! -f "${in_file}" ]]; then
        echo "ERROR: template not found: ${in_file}" >&2
        return 2
    fi
    render_properties_require_tools || return $?
    mkdir -p -- "$(dirname -- "${out_file}")"
    python3 - "${in_file}" "${out_file}" <<'PY'
import os
import re
import sys

placeholder = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
in_path = sys.argv[1]
out_path = sys.argv[2]

with open(in_path, "r", encoding="utf-8") as fh:
    lines = fh.readlines()

missing = set()
empty = set()


def repl(m):
    name = m.group(1)
    if name not in os.environ:
        missing.add(name)
        return m.group(0)
    val = os.environ[name]
    if val == "":
        empty.add(name)
        return m.group(0)
    return val


rendered_lines = []
for line in lines:
    if line.lstrip().startswith("#"):
        rendered_lines.append(line)
    else:
        rendered_lines.append(placeholder.sub(repl, line))
rendered = "".join(rendered_lines)

if missing or empty:
    print(
        "ERROR: render-properties: unresolved placeholders in template",
        file=sys.stderr,
    )
    print(f"  template: {in_path}", file=sys.stderr)
    if missing:
        print("  unset env vars:", file=sys.stderr)
        for n in sorted(missing):
            print(f"    - {n}", file=sys.stderr)
    if empty:
        print("  empty env vars (set but empty):", file=sys.stderr)
        for n in sorted(empty):
            print(f"    - {n}", file=sys.stderr)
    sys.exit(1)

with open(out_path, "w", encoding="utf-8") as fh:
    fh.write(rendered)
PY
}
