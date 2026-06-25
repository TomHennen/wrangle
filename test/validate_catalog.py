#!/usr/bin/env python3
"""test/validate_catalog.py — CI/dev-time guard that lib/read_catalog.sh's
hand-rolled scanner stays faithful to real YAML.

The orchestrator reads tools/catalog.yaml with a dependency-free shell scanner
(no YAML parser in the security-critical path). This DEV-ONLY checker, run from
test_read_catalog.bats under a pinned PyYAML, keeps that scanner honest:

  shape <catalog>           the catalog conforms to the strict grammar the
                            scanner assumes (flat `tools:` map, each entry a
                            block map of scalar fields; no nested maps,
                            sequences, anchors, or flow style). Exit 1 if not.
  diff  <catalog> <reader>  for every (tool, field) PyYAML sees, the scanner's
                            output equals the parsed scalar. Exit 1 on any
                            mismatch.

Exit: 0 ok, 1 violation, 2 tool/usage error (fail closed).
"""

import subprocess
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("validate_catalog: PyYAML not available for this python3.\n")
    raise SystemExit(2)


def load(path):
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f.read())


def check_shape(catalog):
    doc = load(catalog)
    if not isinstance(doc, dict) or set(doc) != {"tools"}:
        return "top level must be a single `tools:` map"
    tools = doc["tools"]
    if not isinstance(tools, dict):
        return "`tools:` must be a map of entries"
    for name, entry in tools.items():
        if not isinstance(name, str):
            return f"tool name {name!r} is not a string"
        if not isinstance(entry, dict):
            return f"tool {name!r} must be a map of scalar fields"
        for field, value in entry.items():
            if not isinstance(field, str):
                return f"{name}.{field!r}: field name is not a string"
            if isinstance(value, (dict, list)):
                return f"{name}.{field}: value must be a scalar, not a nested map/sequence"
    return None


def check_diff(catalog, reader):
    doc = load(catalog)
    tools = doc["tools"]
    for name, entry in tools.items():
        for field, value in entry.items():
            expected = "" if value is None else str(value)
            got = subprocess.run(
                [reader, catalog, name, field],
                capture_output=True, text=True, check=True,
            ).stdout
            if got != expected:
                return f"{name}.{field}: scanner={got!r} parser={expected!r}"
    return None


def main(argv):
    if len(argv) == 3 and argv[1] == "shape":
        err = check_shape(argv[2])
    elif len(argv) == 4 and argv[1] == "diff":
        err = check_diff(argv[2], argv[3])
    else:
        sys.stderr.write(
            "Usage: validate_catalog.py shape <catalog>\n"
            "       validate_catalog.py diff <catalog> <reader>\n"
        )
        return 2
    if err:
        sys.stderr.write(f"validate_catalog: {err}\n")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
