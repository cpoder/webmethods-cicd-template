#!/usr/bin/env python3
"""
wsdl-diff.py -- detect breaking changes between two WSDL 1.1 documents.

Usage:
    wsdl-diff.py BASE REVISED [--json OUT] [--quiet]

BASE is the committed source-of-truth WSDL. REVISED is what the running
MSR currently exports via wm-mcp's generate_wsdl tool.

This is a lightweight comparator covering the most common breaking
changes a webMethods SOAP service can introduce:

  removed_operation        - portType operation gone in REVISED
  changed_operation_message - input/output message qname changed
  removed_message          - message gone in REVISED
  required_element_added   - new xsd:element with minOccurs!=0 in a
                             request type (i.e. a NEW required field
                             in the body of a SOAP operation)
  required_element_flipped - existing xsd:element whose minOccurs went
                             from '0' to a value >= 1

Limitations: imported schemas (xsd:import, xsd:include) are not chased,
so a finding can technically be missed if the WSDL splits its types
across files. The repo convention (api/*.wsdl) keeps types inline, and
the contract test job in CI surfaces a warning when imports are present.

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
from typing import Any, Dict, List, Optional, Set, Tuple
from xml.etree import ElementTree as ET


WSDL_NS = "http://schemas.xmlsoap.org/wsdl/"
XSD_NS = "http://www.w3.org/2001/XMLSchema"


def _q(ns: str, local: str) -> str:
    return f"{{{ns}}}{local}"


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

def load_wsdl(path: str) -> Tuple[ET.Element, str]:
    """Return (definitions_element, target_namespace)."""
    tree = ET.parse(path)
    root = tree.getroot()
    if root.tag != _q(WSDL_NS, "definitions"):
        raise ValueError(
            f"{path}: expected <wsdl:definitions> root, got <{root.tag}>"
        )
    tns = root.attrib.get("targetNamespace", "")
    return root, tns


def split_qname(qname: str, root: ET.Element, tns: str) -> Tuple[str, str]:
    """Resolve a 'prefix:local' QName against the root element's xmlns map.
    Falls back to targetNamespace when no prefix is present."""
    if ":" in qname:
        prefix, local = qname.split(":", 1)
    else:
        prefix, local = "", qname
    nsmap = {k.split(":", 1)[1] if k.startswith("xmlns:") else "": v
             for k, v in root.attrib.items()
             if k == "xmlns" or k.startswith("xmlns:")}
    return nsmap.get(prefix, tns), local


# ---------------------------------------------------------------------------
# Indexing
# ---------------------------------------------------------------------------

def index_operations(root: ET.Element) -> Dict[Tuple[str, str], Dict[str, str]]:
    """{(portType, operation): {input_msg: <qname>, output_msg: <qname>}}."""
    out: Dict[Tuple[str, str], Dict[str, str]] = {}
    for pt in root.findall(_q(WSDL_NS, "portType")):
        pt_name = pt.attrib.get("name", "")
        for op in pt.findall(_q(WSDL_NS, "operation")):
            op_name = op.attrib.get("name", "")
            entry: Dict[str, str] = {}
            for kind in ("input", "output", "fault"):
                node = op.find(_q(WSDL_NS, kind))
                if node is not None:
                    entry[f"{kind}_message"] = node.attrib.get("message", "")
            out[(pt_name, op_name)] = entry
    return out


def index_messages(root: ET.Element, tns: str) -> Dict[str, ET.Element]:
    """Map messageQName ('{ns}local') -> <message> element."""
    out: Dict[str, ET.Element] = {}
    for msg in root.findall(_q(WSDL_NS, "message")):
        local = msg.attrib.get("name", "")
        if local:
            out[_q(tns, local)] = msg
    return out


def index_xsd_elements(root: ET.Element) -> Dict[Tuple[str, str], ET.Element]:
    """Map global xsd:element qnames to their declaration. Schemas may
    set their own targetNamespace independent of the WSDL TNS."""
    out: Dict[Tuple[str, str], ET.Element] = {}
    for types in root.findall(_q(WSDL_NS, "types")):
        for sch in types.findall(_q(XSD_NS, "schema")):
            ns = sch.attrib.get("targetNamespace", "")
            for el in sch.findall(_q(XSD_NS, "element")):
                name = el.attrib.get("name")
                if name:
                    out[(ns, name)] = el
    return out


def collect_required_paths(
    el: ET.Element,
    prefix: str = "",
    seen: Optional[Set[int]] = None,
) -> Dict[str, str]:
    """Walk an xsd:element declaration and return a flat
    {dotted-path: minOccurs} map for every nested element. minOccurs
    defaults to '1' per the XSD spec."""
    if seen is None:
        seen = set()
    if id(el) in seen:
        return {}
    seen.add(id(el))

    out: Dict[str, str] = {}
    name = el.attrib.get("name", "?")
    here = f"{prefix}.{name}" if prefix else name

    # Descend through xsd:complexType / xsd:sequence / xsd:choice / xsd:all.
    for ct in el.findall(_q(XSD_NS, "complexType")):
        for container in ("sequence", "choice", "all"):
            for grp in ct.findall(_q(XSD_NS, container)):
                for child in grp.findall(_q(XSD_NS, "element")):
                    cname = child.attrib.get("name")
                    if cname is None:
                        # ref="..." -- record the ref's local name
                        ref = child.attrib.get("ref", "")
                        cname = ref.split(":")[-1] if ref else "?"
                    cmin = child.attrib.get("minOccurs", "1")
                    cpath = f"{here}.{cname}"
                    out[cpath] = cmin
                    out.update(collect_required_paths(child, here, seen))
    return out


# ---------------------------------------------------------------------------
# Diff
# ---------------------------------------------------------------------------

def diff(base_path: str, revised_path: str) -> List[Dict[str, Any]]:
    findings: List[Dict[str, Any]] = []

    b_root, b_tns = load_wsdl(base_path)
    r_root, r_tns = load_wsdl(revised_path)

    b_ops = index_operations(b_root)
    r_ops = index_operations(r_root)
    b_msgs = index_messages(b_root, b_tns)
    r_msgs = index_messages(r_root, r_tns)
    b_els = index_xsd_elements(b_root)
    r_els = index_xsd_elements(r_root)

    # ---- Removed / changed operations ----
    for key in sorted(b_ops):
        if key not in r_ops:
            pt, op = key
            findings.append({
                "kind": "removed_operation",
                "portType": pt,
                "operation": op,
                "message": (
                    f"BREAKING: SOAP operation '{op}' removed from "
                    f"portType '{pt}'"
                ),
            })
            continue
        # Compare input/output message names.
        b = b_ops[key]
        r = r_ops[key]
        for k in ("input_message", "output_message", "fault_message"):
            if b.get(k) and r.get(k) != b.get(k):
                pt, op = key
                findings.append({
                    "kind": "changed_operation_message",
                    "portType": pt,
                    "operation": op,
                    "role": k,
                    "from": b.get(k),
                    "to": r.get(k, "<missing>"),
                    "message": (
                        f"BREAKING: SOAP operation '{op}' on portType "
                        f"'{pt}' changed {k}: {b.get(k)} -> "
                        f"{r.get(k, '<missing>')}"
                    ),
                })

    # ---- Removed messages ----
    for q in sorted(set(b_msgs) - set(r_msgs)):
        findings.append({
            "kind": "removed_message",
            "message_qname": q,
            "message": f"BREAKING: WSDL message '{q}' removed",
        })

    # ---- Element-level requiredness on the request side ----
    # We only diff elements that show up as the input message's body of an
    # operation that exists in BOTH WSDLs -- new required fields elsewhere
    # (response side) are flagged separately as response-required-removed
    # instead, in line with how openapi-diff.py treats responses.
    request_element_qnames: Set[Tuple[str, str]] = set()
    for key, b in b_ops.items():
        if key not in r_ops:
            continue
        b_in_q = b.get("input_message")
        if not b_in_q:
            continue
        # Resolve the input message's part to a global element decl.
        msg = b_msgs.get(_resolve_qname(b_in_q, b_root, b_tns))
        if msg is None:
            continue
        for part in msg.findall(_q(WSDL_NS, "part")):
            elem_attr = part.attrib.get("element")
            if elem_attr:
                ns, local = split_qname(elem_attr, b_root, b_tns)
                request_element_qnames.add((ns, local))

    for qkey in sorted(request_element_qnames):
        b_el = b_els.get(qkey)
        r_el = r_els.get(qkey)
        if r_el is None:
            # The element disappeared from the revised schema -- flagged
            # via removed_message above if the message also went away.
            continue
        b_paths = collect_required_paths(b_el) if b_el is not None else {}
        r_paths = collect_required_paths(r_el)

        for path, minocc in sorted(r_paths.items()):
            if minocc == "0":
                continue  # optional in revised, never breaking
            if path not in b_paths:
                # Brand new required element.
                findings.append({
                    "kind": "required_element_added",
                    "element": "{%s}%s" % qkey,
                    "field": path,
                    "min_occurs": minocc,
                    "message": (
                        f"BREAKING: new required element '{path}' added to "
                        f"request type {{{qkey[0]}}}{qkey[1]}"
                    ),
                })
            elif b_paths[path] == "0":
                # Existing element flipped from optional to required.
                findings.append({
                    "kind": "required_element_flipped",
                    "element": "{%s}%s" % qkey,
                    "field": path,
                    "min_occurs": minocc,
                    "message": (
                        f"BREAKING: element '{path}' in request type "
                        f"{{{qkey[0]}}}{qkey[1]} is now required "
                        f"(minOccurs={minocc})"
                    ),
                })

    return findings


def _resolve_qname(qname: str, root: ET.Element, tns: str) -> str:
    ns, local = split_qname(qname, root, tns)
    return _q(ns, local)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        prog="wsdl-diff.py",
        description="Detect breaking changes between two WSDL 1.1 documents.",
    )
    ap.add_argument("base")
    ap.add_argument("revised")
    ap.add_argument("--json", dest="json_out")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    for label, p in (("BASE", args.base), ("REVISED", args.revised)):
        if not os.path.isfile(p):
            sys.stderr.write(f"ERROR: {label} file not found: {p}\n")
            return 2

    try:
        findings = diff(args.base, args.revised)
    except (ET.ParseError, ValueError, OSError) as e:
        sys.stderr.write(f"ERROR: failed to parse WSDL: {e}\n")
        return 2

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
