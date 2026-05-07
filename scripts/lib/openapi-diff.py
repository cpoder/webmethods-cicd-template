#!/usr/bin/env python3
"""
openapi-diff.py -- detect breaking changes between two OpenAPI 3.x docs.

Usage:
    openapi-diff.py BASE REVISED [--json OUT] [--quiet]

BASE is the committed source-of-truth (typically api/openapi.yaml on the
PR branch). REVISED is the OpenAPI document the running MSR currently
exports via wm-mcp's generate_openapi tool. A finding is reported when
REVISED is incompatible with clients that were written against BASE.

Detected breaking-change classes:

  removed_endpoint         - path or method present in BASE, gone in REVISED
  required_parameter_added - new path/query/header/cookie param marked
                             required (or an existing one flipped to required)
  request_body_now_required - body went from optional to required
  required_field_added     - request body schema gained a `required` entry
  required_field_removed   - response body schema lost a `required` entry
                             (clients break when they expect the field)
  removed_response_content - request/response content type removed
  removed_response_status  - response status code removed

The `required_field_added` finding is the one called out in the Task 4.3
acceptance criterion -- the `message` field in the JSON output and the
human-readable line both name the field AND the endpoint.

Exit codes:
    0   no breaking changes
    1   one or more breaking changes
    2   argument / parse error
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, Dict, Iterable, List, Optional, Set, Tuple

try:
    import yaml  # type: ignore
except ImportError:
    sys.stderr.write(
        "ERROR: PyYAML is required for openapi-diff.py.\n"
        "       Install: pip install pyyaml\n"
    )
    sys.exit(2)


METHODS = {"get", "post", "put", "patch", "delete", "head", "options", "trace"}


# ---------------------------------------------------------------------------
# Loading + $ref resolution
# ---------------------------------------------------------------------------

def load_doc(path: str) -> Dict[str, Any]:
    """Load YAML or JSON OpenAPI document."""
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    # yaml.safe_load handles both YAML and JSON.
    doc = yaml.safe_load(text)
    if not isinstance(doc, dict):
        raise ValueError(f"{path}: top-level must be a mapping, got {type(doc).__name__}")
    return doc


def resolve_ref(doc: Dict[str, Any], ref: Any) -> Optional[Any]:
    """Resolve a local $ref like '#/components/schemas/Foo'. Returns None
    on miss, including for external $refs (we don't follow those)."""
    if not isinstance(ref, str) or not ref.startswith("#/"):
        return None
    cur: Any = doc
    for part in ref[2:].split("/"):
        # JSON Pointer escape: ~1 -> /, ~0 -> ~ (RFC 6901).
        part = part.replace("~1", "/").replace("~0", "~")
        if isinstance(cur, list):
            try:
                cur = cur[int(part)]
            except (ValueError, IndexError):
                return None
        elif isinstance(cur, dict):
            if part not in cur:
                return None
            cur = cur[part]
        else:
            return None
    return cur


def deref(doc: Dict[str, Any], obj: Any, _seen: Optional[Set[str]] = None) -> Any:
    """Resolve $ref one level (chases chains, but bails on cycles)."""
    if not isinstance(obj, dict) or "$ref" not in obj:
        return obj
    if _seen is None:
        _seen = set()
    ref = obj["$ref"]
    if ref in _seen:
        return obj
    _seen.add(ref)
    target = resolve_ref(doc, ref)
    if target is None:
        return obj
    return deref(doc, target, _seen)


# ---------------------------------------------------------------------------
# Schema introspection (with allOf composition)
# ---------------------------------------------------------------------------

def _schema_required_set(doc: Dict[str, Any], schema: Any, _seen: Optional[Set[int]] = None) -> Set[str]:
    if not isinstance(schema, dict):
        return set()
    if _seen is None:
        _seen = set()
    schema = deref(doc, schema)
    sid = id(schema)
    if sid in _seen:
        return set()
    _seen.add(sid)
    out: Set[str] = set(schema.get("required") or [])
    for sub in schema.get("allOf") or []:
        out |= _schema_required_set(doc, sub, _seen)
    # oneOf/anyOf are intentionally NOT composed: a field required in one
    # branch but not another is not unconditionally required.
    return out


# ---------------------------------------------------------------------------
# Operation walking
# ---------------------------------------------------------------------------

def operations(doc: Dict[str, Any]) -> Iterable[Tuple[str, str, Dict[str, Any], Dict[str, Any]]]:
    """Yield (method_lower, path, op, path_item) tuples."""
    for path, item in (doc.get("paths") or {}).items():
        if not isinstance(item, dict):
            continue
        # PathItem may itself be a $ref.
        item = deref(doc, item)
        if not isinstance(item, dict):
            continue
        for method, op in item.items():
            if method.lower() in METHODS and isinstance(op, dict):
                yield method.lower(), path, op, item


def merged_parameters(
    doc: Dict[str, Any],
    op: Dict[str, Any],
    path_item: Dict[str, Any],
) -> Dict[Tuple[str, str], Dict[str, Any]]:
    """Index parameters by (in, name). Operation-level params override
    path-level params with the same (in, name) per the OpenAPI spec."""
    out: Dict[Tuple[str, str], Dict[str, Any]] = {}
    for src in (path_item.get("parameters") or [], op.get("parameters") or []):
        for raw in src:
            p = deref(doc, raw)
            if not isinstance(p, dict):
                continue
            loc = p.get("in")
            name = p.get("name")
            if loc is None or name is None:
                continue
            out[(loc, name)] = p
    return out


# ---------------------------------------------------------------------------
# Diff logic
# ---------------------------------------------------------------------------

def diff(base: Dict[str, Any], revised: Dict[str, Any]) -> List[Dict[str, Any]]:
    findings: List[Dict[str, Any]] = []

    base_ops = {(m, p): (op, item) for m, p, op, item in operations(base)}
    rev_ops = {(m, p): (op, item) for m, p, op, item in operations(revised)}

    # ---- Removed endpoints ----
    for key in sorted(base_ops):
        if key not in rev_ops:
            method, path = key
            findings.append({
                "kind": "removed_endpoint",
                "method": method.upper(),
                "path": path,
                "message": (
                    f"BREAKING: endpoint removed: {method.upper()} {path}"
                ),
            })

    # ---- Per-endpoint comparisons ----
    for key in sorted(base_ops):
        if key not in rev_ops:
            continue
        method, path = key
        b_op, b_item = base_ops[key]
        r_op, r_item = rev_ops[key]
        ep = f"{method.upper()} {path}"

        # ----- Parameters -----
        b_params = merged_parameters(base, b_op, b_item)
        r_params = merged_parameters(revised, r_op, r_item)
        for k, p in r_params.items():
            if not p.get("required"):
                continue
            b = b_params.get(k)
            if b is None:
                loc, name = k
                findings.append({
                    "kind": "required_parameter_added",
                    "method": method.upper(),
                    "path": path,
                    "in": loc,
                    "name": name,
                    "message": (
                        f"BREAKING: new required {loc} parameter '{name}' "
                        f"added to {ep}"
                    ),
                })
            elif not b.get("required"):
                loc, name = k
                findings.append({
                    "kind": "required_parameter_added",
                    "method": method.upper(),
                    "path": path,
                    "in": loc,
                    "name": name,
                    "message": (
                        f"BREAKING: existing {loc} parameter '{name}' on {ep} "
                        f"is now required"
                    ),
                })

        # ----- Request body -----
        b_body = b_op.get("requestBody")
        r_body = r_op.get("requestBody")
        if isinstance(b_body, dict):
            b_body = deref(base, b_body)
        if isinstance(r_body, dict):
            r_body = deref(revised, r_body)
        b_content = (b_body or {}).get("content") or {}
        r_content = (r_body or {}).get("content") or {}

        # Body went from optional to required.
        if (
            isinstance(r_body, dict) and r_body.get("required")
            and not (isinstance(b_body, dict) and b_body.get("required"))
        ):
            findings.append({
                "kind": "request_body_now_required",
                "method": method.upper(),
                "path": path,
                "message": (
                    f"BREAKING: request body became required for {ep}"
                ),
            })

        # Removed content types on request body.
        for ct in sorted(set(b_content) - set(r_content)):
            findings.append({
                "kind": "removed_request_content",
                "method": method.upper(),
                "path": path,
                "content_type": ct,
                "message": (
                    f"BREAKING: request content type '{ct}' removed from {ep}"
                ),
            })

        # Per-content-type required-field comparisons.
        for ct, r_media in r_content.items():
            r_schema = (r_media or {}).get("schema") or {}
            b_media = b_content.get(ct) or {}
            b_schema = (b_media or {}).get("schema") or {}
            r_req = _schema_required_set(revised, r_schema)
            b_req = _schema_required_set(base, b_schema)
            for field in sorted(r_req - b_req):
                # THE acceptance-criterion case for Task 4.3: name the field
                # AND the endpoint, plus the content type for disambiguation.
                findings.append({
                    "kind": "required_field_added",
                    "method": method.upper(),
                    "path": path,
                    "field": field,
                    "content_type": ct,
                    "message": (
                        f"BREAKING: required field '{field}' added to "
                        f"request body ({ct}) of {ep}"
                    ),
                })

        # ----- Responses -----
        b_resp = b_op.get("responses") or {}
        r_resp = r_op.get("responses") or {}
        for code in sorted(b_resp):
            if code not in r_resp:
                # 'default' is special; also tolerate codes that moved to a
                # different position. We still flag it: removing a documented
                # response is a contract change.
                findings.append({
                    "kind": "removed_response_status",
                    "method": method.upper(),
                    "path": path,
                    "status": code,
                    "message": (
                        f"BREAKING: response status '{code}' removed from {ep}"
                    ),
                })
        for code in sorted(set(b_resp) & set(r_resp)):
            b_r = deref(base, b_resp[code])
            r_r = deref(revised, r_resp[code])
            b_rc = (b_r or {}).get("content") or {}
            r_rc = (r_r or {}).get("content") or {}
            for ct in sorted(set(b_rc) - set(r_rc)):
                findings.append({
                    "kind": "removed_response_content",
                    "method": method.upper(),
                    "path": path,
                    "status": code,
                    "content_type": ct,
                    "message": (
                        f"BREAKING: response content type '{ct}' removed "
                        f"from {ep} status {code}"
                    ),
                })
            for ct, r_media in r_rc.items():
                r_schema = (r_media or {}).get("schema") or {}
                b_media = b_rc.get(ct) or {}
                b_schema = (b_media or {}).get("schema") or {}
                r_req = _schema_required_set(revised, r_schema)
                b_req = _schema_required_set(base, b_schema)
                for field in sorted(b_req - r_req):
                    # Removed required response field: clients that
                    # destructure on it will break.
                    findings.append({
                        "kind": "required_field_removed",
                        "method": method.upper(),
                        "path": path,
                        "status": code,
                        "field": field,
                        "content_type": ct,
                        "message": (
                            f"BREAKING: required field '{field}' removed "
                            f"from response body ({ct}) of {ep} status {code}"
                        ),
                    })

    return findings


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        prog="openapi-diff.py",
        description="Detect breaking changes between two OpenAPI 3.x documents.",
    )
    ap.add_argument("base", help="Path to the BASE (committed) OpenAPI doc.")
    ap.add_argument("revised", help="Path to the REVISED (exported) OpenAPI doc.")
    ap.add_argument("--json", dest="json_out",
                    help="Write the findings to this JSON file.")
    ap.add_argument("--quiet", action="store_true",
                    help="Don't print findings to stderr; rely on --json + exit code.")
    args = ap.parse_args(argv)

    for label, p in (("BASE", args.base), ("REVISED", args.revised)):
        if not os.path.isfile(p):
            sys.stderr.write(f"ERROR: {label} file not found: {p}\n")
            return 2

    try:
        base = load_doc(args.base)
        revised = load_doc(args.revised)
    except (yaml.YAMLError, ValueError, OSError) as e:
        sys.stderr.write(f"ERROR: failed to parse OpenAPI doc: {e}\n")
        return 2

    findings = diff(base, revised)

    if args.json_out:
        try:
            with open(args.json_out, "w", encoding="utf-8") as fh:
                json.dump({
                    "base": args.base,
                    "revised": args.revised,
                    "breaking": findings,
                    "count": len(findings),
                }, fh, indent=2, sort_keys=True)
        except OSError as e:
            sys.stderr.write(f"ERROR: failed to write {args.json_out}: {e}\n")
            return 2

    if not args.quiet:
        for f in findings:
            sys.stderr.write(f["message"] + "\n")

    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
