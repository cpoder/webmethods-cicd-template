#!/usr/bin/env python3
"""Validate one YAML/JSON config file against a $defs/<name> sub-schema.

Used by scripts/validate-config.sh. Kept self-contained so it can also be
invoked directly during development:

    scripts/lib/validate-config.py config/base/ports.yaml \\
        --schema schemas/config.schema.json --def Ports

Exit codes:
  0  valid
  1  one or more validation errors (printed to stderr)
  2  setup error (missing schema file, missing $defs key, missing dep)
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("instance", help="Path to YAML or JSON instance file")
    ap.add_argument("--schema", required=True, help="Path to JSON Schema file")
    ap.add_argument(
        "--def",
        dest="defname",
        required=True,
        help="$defs key in the schema to validate against",
    )
    args = ap.parse_args()

    try:
        import yaml  # PyYAML
    except ImportError:
        print("ERROR: PyYAML is not installed (pip install pyyaml)", file=sys.stderr)
        return 2
    try:
        import jsonschema
    except ImportError:
        print(
            "ERROR: jsonschema is not installed (pip install jsonschema)",
            file=sys.stderr,
        )
        return 2

    schema_path = pathlib.Path(args.schema)
    if not schema_path.is_file():
        print(f"ERROR: schema not found: {schema_path}", file=sys.stderr)
        return 2
    schema = json.loads(schema_path.read_text())
    defs = schema.get("$defs", {})
    if args.defname not in defs:
        print(
            f"ERROR: schema has no $defs/{args.defname} (available: "
            f"{', '.join(sorted(defs.keys())) or 'none'})",
            file=sys.stderr,
        )
        return 2

    sub = {"$ref": f"#/$defs/{args.defname}", "$defs": defs}

    inst_path = pathlib.Path(args.instance)
    if not inst_path.is_file():
        print(f"ERROR: instance not found: {inst_path}", file=sys.stderr)
        return 2
    with inst_path.open() as fh:
        instance = yaml.safe_load(fh)
    if instance is None:
        instance = {}

    validator = jsonschema.Draft202012Validator(sub)
    errors = sorted(
        validator.iter_errors(instance),
        key=lambda e: (list(e.absolute_path), e.message),
    )
    for err in errors:
        path = "/".join(str(p) for p in err.absolute_path) or "(root)"
        print(f"  {inst_path}:{path}: {err.message}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
