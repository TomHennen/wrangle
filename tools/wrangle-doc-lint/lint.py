#!/usr/bin/env python3
"""wrangle-doc-lint — validate `→ enforced by:` pointers in spec docs.

A contract invariant in docs/SPEC.md cites the check that enforces it:

    → enforced by: `tools/osv/test.bats::osv adapter: requires 2 arguments`

Backtick-quoted references after the marker (through the end of the
paragraph or list item) are validated against the repo:

    <path>.bats::<test name>   the bats file exists AND contains
                               @test "<test name>" verbatim
    WSL### / WWL### / WDL###   the rule ID exists in the owning linter
    <path containing '/'>      the file exists (recognized by extension:
                               .sh .bats .py .yml .yaml .md .hjson)

Other backticked spans (env vars, regexes, plain code) are ignored.

Rules:
    WDL001  referenced file does not exist
    WDL002  bats file exists but has no @test with that exact name
    WDL003  unknown lint rule ID
    WDL004  `→ enforced by:` with no recognizable reference

Usage: lint.py [--root DIR] <doc.md> [...]
Exit: 0 clean, 1 violations found, 2 tool error.
"""

import argparse
import re
import sys
from pathlib import Path

MARKER = "→ enforced by:"

BATS_REF = re.compile(r"^([\w./-]+\.bats)::(.+)$")
RULE_REF = re.compile(r"^(WSL|WWL|WDL)\d{3}$")
PATH_REF = re.compile(r"^[\w./-]+\.(sh|bats|py|yml|yaml|md|hjson)$")
BACKTICKED = re.compile(r"`([^`]+)`")

# Where each rule-ID family is defined. A cited ID must appear in one of
# the owning linter's definition files.
RULE_SOURCES = {
    "WSL": ["tools/wrangle-shell-lint/rules", "tools/wrangle-shell-lint/lint.sh"],
    "WWL": ["tools/wrangle-workflow-lint/lint.py"],
    "WDL": ["tools/wrangle-doc-lint/lint.py"],
}


def text_after_marker(lines, start, col):
    """Text from just past the marker through the end of its list item/paragraph."""
    chunk = [lines[start][col + len(MARKER) :]]
    for line in lines[start + 1 :]:
        stripped = line.strip()
        if not stripped or stripped.startswith(("-", "*", "#", "|", ">")):
            break
        chunk.append(line)
    return "\n".join(chunk)


def load_rule_ids(root, family):
    ids = set()
    for rel in RULE_SOURCES[family]:
        path = root / rel
        files = sorted(path.rglob("*")) if path.is_dir() else [path]
        for f in files:
            if f.is_file():
                ids.update(re.findall(rf"\b{family}\d{{3}}\b", f.read_text(errors="replace")))
    return ids


def check_doc(doc, root, rule_ids, bats_cache):
    problems = []
    try:
        lines = doc.read_text().splitlines()
    except OSError as e:
        print(f"wrangle-doc-lint: cannot read {doc}: {e}", file=sys.stderr)
        sys.exit(2)

    for i, line in enumerate(lines):
        col = line.find(MARKER)
        if col == -1:
            continue
        text = text_after_marker(lines, i, col)
        loc = f"{doc}:{i + 1}"
        recognized = 0

        for ref in BACKTICKED.findall(text):
            if m := BATS_REF.match(ref):
                recognized += 1
                bats_path = root / m.group(1)
                if not bats_path.is_file():
                    problems.append(f"{loc}: WDL001 referenced file does not exist: {m.group(1)}")
                    continue
                if bats_path not in bats_cache:
                    bats_cache[bats_path] = bats_path.read_text(errors="replace")
                if f'@test "{m.group(2)}"' not in bats_cache[bats_path]:
                    problems.append(f'{loc}: WDL002 no @test "{m.group(2)}" in {m.group(1)}')
            elif RULE_REF.match(ref):
                recognized += 1
                family = ref[:3]
                if family not in rule_ids:
                    rule_ids[family] = load_rule_ids(root, family)
                if ref not in rule_ids[family]:
                    problems.append(f"{loc}: WDL003 unknown lint rule ID: {ref}")
            elif "/" in ref and PATH_REF.match(ref):
                recognized += 1
                if not (root / ref).is_file():
                    problems.append(f"{loc}: WDL001 referenced file does not exist: {ref}")

        if recognized == 0:
            problems.append(f"{loc}: WDL004 '{MARKER}' cites no recognizable check")

    return problems


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("docs", nargs="+", type=Path)
    args = parser.parse_args()

    if not args.root.is_dir():
        print(f"wrangle-doc-lint: root is not a directory: {args.root}", file=sys.stderr)
        return 2

    rule_ids, bats_cache, problems = {}, {}, []
    for doc in args.docs:
        problems.extend(check_doc(doc, args.root, rule_ids, bats_cache))

    for p in problems:
        print(p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
