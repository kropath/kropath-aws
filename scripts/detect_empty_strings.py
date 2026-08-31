#!/usr/bin/env python3
"""
Stage 1 detector for KRO-925.

Finds empty-string fallbacks inside ACK resource templates in RGDs,
excluding s3bucket, snstopic, sqsqueue (handled by KRO-918).

Each resource node has: id, [includeWhen], template
template has: apiVersion, kind, metadata, spec

Output: TSV with columns: file, line, resource_id, api_version, kind, field_path, expression
"""

import os
import re
import sys
import yaml

RGDS_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "rgds")

EXCLUDE_PREFIXES = ("s3bucket", "snstopic", "sqsqueue")

ACK_API_RE = re.compile(r".*\.services\.k8s\.aws/")

# Patterns that indicate an empty-string fallback in a CEL expression.
# Only match when "" is the FINAL output of an expression, not an intermediate guard.
EMPTY_STR_PATTERNS = [
    # : ""} or : "")} — final ternary fallback (the : must be part of a ternary, not inside a string)
    re.compile(r':\s*""\s*\)?\}'),
    # orValue("") NOT followed by a comparison operator — i.e. final output, not a guard
    re.compile(r'orValue\(""\)(?!\s*(?:!=|==)\s*"")'),
    # : "false" — boolean-as-string fallback (indicates a string field with a false default)
    re.compile(r':\s*"false"'),
]

# Patterns that indicate the match is a FALSE POSITIVE (guard usage, not final output)
FALSE_POSITIVE_INDICATORS = [
    # The ONLY orValue("") instances in the expression are guard patterns
    # (will be checked per-hit below)
]


def is_real_hit(expression: str) -> bool:
    """Return True only if the expression can emit "" as a final output value."""
    # Check the `: ""}` / `: "")}` pattern — these are terminal ternary fallbacks
    if re.search(r':\s*""\s*\)?\}', expression):
        return True

    # Check for orValue("") that is NOT a guard
    # A guard looks like: .orValue("") != "" or .orValue("") == ""
    # A final output looks like: .orValue("")}  or  .orValue("") : ...  or end-of-expression
    for m in re.finditer(r'orValue\(""\)', expression):
        # Look at what follows
        tail = expression[m.end():]
        # Remove leading whitespace
        tail_stripped = tail.lstrip()
        # If followed by a comparison, it's a guard — skip
        if tail_stripped.startswith('!=') or tail_stripped.startswith('=='):
            continue
        # It's a final output usage
        return True

    # Check for "false" as a final string
    if re.search(r':\s*"false"', expression):
        return True

    return False


def is_ack_template(template: dict) -> bool:
    api_version = template.get("apiVersion", "")
    return bool(ACK_API_RE.match(api_version))


def walk_for_empty_strings(obj, path: str = "") -> list:
    """Recursively walk, collecting string values where "" can be the final output."""
    hits = []
    if isinstance(obj, dict):
        for key, value in obj.items():
            sub_path = f"{path}.{key}" if path else key
            if isinstance(value, str):
                if is_real_hit(value):
                    hits.append((sub_path, value))
            elif isinstance(value, (dict, list)):
                hits.extend(walk_for_empty_strings(value, sub_path))
    elif isinstance(obj, list):
        for i, item in enumerate(obj):
            hits.extend(walk_for_empty_strings(item, f"{path}[{i}]"))
    return hits


def process_rgd(filepath: str) -> list:
    """Process one RGD file and return hits."""
    hits = []
    filename = os.path.basename(filepath)

    # Extract family slug (first component before first dot)
    slug = filename.split(".")[0]
    if any(slug.startswith(excl) for excl in EXCLUDE_PREFIXES):
        return hits

    with open(filepath, "r") as f:
        content = f.read()

    try:
        doc = yaml.safe_load(content)
    except yaml.YAMLError as e:
        print(f"# YAML parse error in {filename}: {e}", file=sys.stderr)
        return hits

    if not isinstance(doc, dict):
        return hits

    spec = doc.get("spec", {})
    resources = spec.get("resources", [])
    if not isinstance(resources, list):
        return hits

    lines = content.splitlines()

    for resource in resources:
        if not isinstance(resource, dict):
            continue

        resource_id = resource.get("id", "?")
        template = resource.get("template")
        if not template or not isinstance(template, dict):
            continue

        # Skip non-ACK resources (ConfigMaps, etc.)
        if not is_ack_template(template):
            continue

        api_version = template.get("apiVersion", "?")
        kind = template.get("kind", "?")

        # Walk template.spec for empty string patterns
        template_spec = template.get("spec", {})
        if not template_spec:
            continue

        field_hits = walk_for_empty_strings(template_spec, "spec")

        for field_path, expression in field_hits:
            # Find line number by searching for a distinctive part of the expression
            line_num = 0
            search_val = expression.strip()[:60]
            for i, line in enumerate(lines, 1):
                if search_val and search_val[:40] in line:
                    line_num = i
                    break

            hits.append({
                "file": filename,
                "line": line_num,
                "resource_id": resource_id,
                "api_version": api_version,
                "kind": kind,
                "field_path": field_path,
                "expression": expression[:300],
            })

    return hits


def main():
    print("file\tline\tresource_id\tapi_version\tkind\tfield_path\texpression")

    all_hits = []
    for fname in sorted(os.listdir(RGDS_DIR)):
        if not fname.endswith(".yaml"):
            continue
        filepath = os.path.join(RGDS_DIR, fname)
        hits = process_rgd(filepath)
        all_hits.extend(hits)

    for h in all_hits:
        expr = h["expression"].replace("\t", " ").replace("\n", " ")
        print(f"{h['file']}\t{h['line']}\t{h['resource_id']}\t{h['api_version']}\t{h['kind']}\t{h['field_path']}\t{expr}")

    print(f"\n# Total hits: {len(all_hits)}", file=sys.stderr)


if __name__ == "__main__":
    main()
