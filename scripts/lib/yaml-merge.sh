# shellcheck shell=bash
# scripts/lib/yaml-merge.sh
#
# Helper functions for apply-config.sh. Source this file -- it does not
# run anything on its own.
#
#   . scripts/lib/yaml-merge.sh
#
# Provides:
#   yaml_merge_env CONFIG_DIR ENV OUT_JSON
#       Deep-merge config/base/*.yaml with config/<ENV>/*.yaml per the
#       rules documented in docs/config-merge.md, plus the
#       extended-settings.properties text merge. Writes a single JSON
#       document to OUT_JSON keyed by section name (file basename
#       without extension). The merged extended-settings text is stored
#       under the synthetic key "_extended-settings-text".
#
#   yaml_merge_require_tools
#       Abort if python3 / PyYAML / jq are missing.
#
# Why python3 inline rather than yq+jq:
#   * yq alone cannot do identity-keyed list merge (its built-in `*` /
#     `*+` merges concatenate or overwrite by index).
#   * The script must run on minimal dev boxes (WSL without yq) and on
#     stock GitHub Actions runners. python3+PyYAML is on every supported
#     platform; the same approach is used by manifest.sh and
#     wmreport-to-junit.sh in this repo.

yaml_merge_require_tools() {
    local missing=()
    for tool in python3 jq; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if (( ${#missing[@]} > 0 )); then
        printf 'ERROR: required tool(s) not found: %s\n' "${missing[*]}" >&2
        printf 'Install hint (Debian/Ubuntu): apt-get install -y python3 python3-yaml jq\n' >&2
        return 1
    fi
    if ! python3 -c 'import yaml' 2>/dev/null; then
        printf 'ERROR: PyYAML is not importable (pip install pyyaml)\n' >&2
        return 1
    fi
}

# ---------------------------------------------------------------------
# yaml_merge_env CONFIG_DIR ENV OUT_JSON
#
# Walks every *.yaml file under CONFIG_DIR/base/, and for each file
# loads the optional CONFIG_DIR/<ENV>/<basename>.yaml overlay and
# applies an identity-keyed deep merge per docs/config-merge.md.
#
# extended-settings.properties is merged textually as a flat key=value
# overlay (later assignments win) and embedded under the synthetic key
# "_extended-settings-text" so the apply driver gets one effective
# document for downstream secret resolution.
#
# Sections with no schema mapping (i.e. unexpected basenames under
# config/base/) are passed through verbatim under their basename so
# scripts/validate-config.sh remains the source of truth on what's
# allowed, not this merger.
# ---------------------------------------------------------------------
yaml_merge_env() {
    local config_dir=$1
    local env=$2
    local out_json=$3

    if [[ -z "$config_dir" || -z "$env" || -z "$out_json" ]]; then
        echo "ERROR: yaml_merge_env CONFIG_DIR ENV OUT_JSON" >&2
        return 2
    fi
    if [[ ! -d "$config_dir/base" ]]; then
        echo "ERROR: config base dir not found: $config_dir/base" >&2
        return 2
    fi

    mkdir -p -- "$(dirname -- "$out_json")"

    python3 - "$config_dir" "$env" "$out_json" <<'PY'
import json
import os
import pathlib
import sys

import yaml  # PyYAML

config_dir = pathlib.Path(sys.argv[1])
env = sys.argv[2]
out_json = pathlib.Path(sys.argv[3])

base_dir = config_dir / "base"
env_dir = config_dir / env

# Per-file identity rules: section name (basename sans extension) ->
# {top-level list key: identity field}. Mirrors docs/config-merge.md.
IDENTITY = {
    "global-variables":   {"variables":   "key"},
    "jdbc-pools":         {"pools":       "alias"},
    "jms-aliases":        {"aliases":     "alias"},
    "kafka-connections":  {"connections": "alias"},
    "mqtt-connections":   {"connections": "alias"},
    "ports":              {"ports":       "name"},
    "acls":               {"acls":        "name"},
    "users-and-groups":   {"users":       "username", "groups": "name"},
}


def deep_merge(base, overlay):
    """Recursive deep merge of dicts. Lists, scalars: overlay replaces."""
    if isinstance(base, dict) and isinstance(overlay, dict):
        out = dict(base)
        for k, v in overlay.items():
            if v is None:
                out.pop(k, None)
            elif k in out and isinstance(out[k], dict) and isinstance(v, dict):
                out[k] = deep_merge(out[k], v)
            else:
                out[k] = v
        return out
    return overlay


def merge_lists(base_list, overlay_list, identity):
    """Identity-keyed list merge: overlay entry whose identity matches
    a base entry replaces (deep-merge); otherwise appended."""
    out = list(base_list)
    base_index = {}
    for i, item in enumerate(out):
        if isinstance(item, dict) and identity in item:
            base_index[item[identity]] = i
    for ov in overlay_list:
        ov_id = ov.get(identity) if isinstance(ov, dict) else None
        if ov_id is not None and ov_id in base_index:
            i = base_index[ov_id]
            out[i] = deep_merge(out[i], ov)
        else:
            out.append(ov)
    return out


def merge_section(base_doc, overlay_doc, identity_rules):
    """Top-level merge: identity-keyed lists for designated keys, deep
    merge for nested objects, overlay-replaces-base otherwise."""
    if base_doc is None:
        base_doc = {}
    if overlay_doc is None:
        return base_doc
    if not isinstance(base_doc, dict) or not isinstance(overlay_doc, dict):
        return overlay_doc
    out = dict(base_doc)
    for k, v in overlay_doc.items():
        if v is None:
            out.pop(k, None)
        elif (
            k in identity_rules
            and isinstance(out.get(k), list)
            and isinstance(v, list)
        ):
            out[k] = merge_lists(out[k], v, identity_rules[k])
        elif k in out and isinstance(out[k], dict) and isinstance(v, dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def parse_props(text):
    """Return (ordered_keys, values_dict, raw_lines).

    Comments and blanks are kept in raw_lines so we can preserve them
    from base; overlay comments are dropped per docs/config-merge.md.
    """
    keys = []
    values = {}
    raw = []
    for line in (text or "").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped.startswith("!"):
            raw.append(("comment", line))
            continue
        if "=" not in line:
            raw.append(("comment", line))  # tolerate, treat as opaque
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if not key:
            raw.append(("comment", line))
            continue
        if key not in values:
            keys.append(key)
        values[key] = value
        raw.append(("kv", key))
    return keys, values, raw


def merge_props(base_text, overlay_text):
    """Java-Properties-chain semantics: later assignments win on key
    collision, new keys are appended, base comments preserved, overlay
    comments dropped."""
    base_keys, base_values, base_raw = parse_props(base_text)
    overlay_keys, overlay_values, _ = parse_props(overlay_text)

    effective = dict(base_values)
    effective.update(overlay_values)  # overlay wins

    out_lines = []
    seen = set()
    for kind, payload in base_raw:
        if kind == "comment":
            out_lines.append(payload)
        else:  # kv
            if payload in seen:
                continue
            out_lines.append(f"{payload}={effective[payload]}")
            seen.add(payload)
    for k in overlay_keys:
        if k not in seen:
            out_lines.append(f"{k}={effective[k]}")
            seen.add(k)
    text = "\n".join(out_lines)
    if text and not text.endswith("\n"):
        text += "\n"
    return text


def load_yaml(path):
    if not path.is_file():
        return None
    try:
        with path.open("r", encoding="utf-8") as fh:
            return yaml.safe_load(fh)
    except yaml.YAMLError as e:
        print(f"ERROR: malformed YAML in {path}: {e}", file=sys.stderr)
        sys.exit(2)


sections = {}

# YAML files under config/base/.
for base_path in sorted(base_dir.glob("*.yaml")) + sorted(base_dir.glob("*.yml")):
    section = base_path.stem
    base_doc = load_yaml(base_path) or {}
    overlay_path = env_dir / base_path.name
    if overlay_path.is_file():
        overlay_doc = load_yaml(overlay_path)
    else:
        overlay_doc = None
    rules = IDENTITY.get(section, {})
    sections[section] = merge_section(base_doc, overlay_doc, rules)

# extended-settings.properties (text merge).
base_props = base_dir / "extended-settings.properties"
overlay_props = env_dir / "extended-settings.properties"
if base_props.is_file() or overlay_props.is_file():
    base_text = base_props.read_text(encoding="utf-8") if base_props.is_file() else ""
    overlay_text = overlay_props.read_text(encoding="utf-8") if overlay_props.is_file() else ""
    sections["_extended-settings-text"] = merge_props(base_text, overlay_text)

out_json.parent.mkdir(parents=True, exist_ok=True)
out_json.write_text(json.dumps(sections, indent=2, sort_keys=False) + "\n",
                    encoding="utf-8")
PY
}
