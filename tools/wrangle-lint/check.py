#!/usr/bin/env python3
"""wrangle-lint — adopter configuration footgun checks.

Audits an adopter repo's wrangle-relevant configuration for footguns that
silently defeat the protection wrangle sets up. This is a *config-correctness*
layer, distinct from the security scanning osv/zizmor/scorecard already do:
those check the adopter's code and workflows; this checks whether the
surrounding configuration is wired up to deliver what wrangle promises.

v1 covers Dependabot configuration correctness — the class behind the
"/**"-doesn't-recurse coverage gap:

  WL001  no .github/dependabot.yml — dependency update PRs never run, so
         action pins (including the `uses: TomHennen/wrangle/...` pin) and
         dependencies never get bumped.
  WL002  configuration lives at .github/dependabot.yaml — Dependabot reads
         only `.yml`, so a `.yaml` file is silently ignored.
  WL003  a github-actions entry globs `directory`/`directories` with `**` —
         github-actions does not recurse into nested action.yml, so composite
         actions go unbumped (and `/**` also provokes duplicate update PRs).
  WL004  a composite action.yml directory in the repo is not listed in the
         github-actions `directories` — that composite's third-party pins
         silently drift from the workflow copies.
  WL005  an updates entry has no `cooldown.default-days` >= 7 — bumps land
         before the community can surface a supply-chain attack.

Findings are suppressible with an inline comment carrying a justification:

  # wrangle-lint: ignore WL00X -- why this is safe here

on the flagged line, or in the contiguous comment block directly above it.
The justification is required (a bare ignore does not suppress). WL001
(missing file) has no line to anchor a comment to and is not suppressible.

Usage: check.py <src_dir> <out_sarif>
Exit: 0 SARIF written (with or without findings), 2 tool error (fail closed).
"""

import json
import os
import re
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write(
        "wrangle-lint: PyYAML not available for this python3.\n"
        "Install the pinned version in tools/wrangle-lint/requirements.txt "
        "into a venv (see test/Dockerfile).\n"
    )
    raise SystemExit(2)

COOLDOWN_MIN_DAYS = 7

# Directories that hold action.yml but are not the adopter's to bump (vendored
# or tooling state), so a missing Dependabot entry for them is not a footgun.
SKIP_DIRS = {".git", "node_modules", "vendor", ".beads", ".claude"}

# (level, security-severity, short description) per rule. level drives both the
# SARIF result level and the markdown severity (error=HIGH, warning=MED).
RULES = {
    "WL001": ("warning", "5.0", "No Dependabot configuration"),
    "WL002": ("error", "6.0", "Dependabot configuration uses an ignored .yaml extension"),
    "WL003": ("error", "7.0", "github-actions directory glob does not recurse into composites"),
    "WL004": ("error", "7.0", "Composite action directory not covered by Dependabot"),
    "WL005": ("warning", "4.0", "Dependabot cooldown missing or shorter than the adoption delay"),
}

# A suppression directive naming a specific rule. The trailing text after the
# rule id is the (required) justification.
SUPPRESS_RE = re.compile(r"wrangle-lint:\s*ignore[\s\[]+(WL\d{3})\]?\s*(.*)$")


class ToolError(Exception):
    """A condition that must fail the tool closed rather than pass clean."""


class Finding:
    __slots__ = ("rule", "uri", "abspath", "line", "message")

    def __init__(self, rule, uri, abspath, line, message):
        self.rule = rule
        self.uri = uri
        self.abspath = abspath
        self.line = line
        self.message = message


def mapping_items(node):
    """Yield (key_string, value_node) for a MappingNode, or nothing."""
    if isinstance(node, yaml.MappingNode):
        for key, value in node.value:
            if isinstance(key, yaml.ScalarNode):
                yield key.value, value


def m_get(node, key):
    for k, v in mapping_items(node):
        if k == key:
            return v
    return None


def norm_dir(value):
    """Normalize a Dependabot directory to a leading-slash, no-trailing-slash form."""
    value = value.strip()
    if not value.startswith("/"):
        value = "/" + value
    if len(value) > 1:
        value = value.rstrip("/")
    return value


def composite_dirs(src_dir):
    """Repo-relative dirs (leading-slash form) that contain a composite action.yml."""
    found = set()
    for root, dirs, files in os.walk(src_dir):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        if "action.yml" in files or "action.yaml" in files:
            rel = os.path.relpath(root, src_dir)
            found.add("/" if rel == "." else "/" + rel.replace(os.sep, "/"))
    return found


def entry_directories(entry):
    """List of (value, node) for an updates entry's directory/directories."""
    dirs = []
    single = m_get(entry, "directory")
    if isinstance(single, yaml.ScalarNode):
        dirs.append((single.value, single))
    plural = m_get(entry, "directories")
    if isinstance(plural, yaml.SequenceNode):
        for item in plural.value:
            if isinstance(item, yaml.ScalarNode):
                dirs.append((item.value, item))
    return dirs


def cooldown_days(entry):
    """default-days as an int, or None if absent/unparseable."""
    cooldown = m_get(entry, "cooldown")
    if not isinstance(cooldown, yaml.MappingNode):
        return None
    days = m_get(cooldown, "default-days")
    if not isinstance(days, yaml.ScalarNode):
        return None
    try:
        return int(days.value)
    except ValueError:
        return None


def check_dependabot(yml_path, uri, findings):
    """Append WL003/WL004/WL005 findings for a parsed .github/dependabot.yml."""
    with open(yml_path, "r", encoding="utf-8") as fh:
        content = fh.read()
    try:
        root = yaml.compose(content)
    except yaml.YAMLError as exc:
        raise ToolError(f"{uri}: YAML parse error: {exc}") from exc
    if root is None:
        return

    src_dir = os.path.dirname(os.path.dirname(yml_path))  # strip /.github/dependabot.yml
    composites = composite_dirs(src_dir)

    updates = m_get(root, "updates")
    entries = updates.value if isinstance(updates, yaml.SequenceNode) else []
    for entry in entries:
        if not isinstance(entry, yaml.MappingNode):
            continue
        eco_node = m_get(entry, "package-ecosystem")
        ecosystem = eco_node.value if isinstance(eco_node, yaml.ScalarNode) else ""
        anchor_line = (eco_node or entry).start_mark.line + 1

        if cooldown_days(entry) is None or cooldown_days(entry) < COOLDOWN_MIN_DAYS:
            findings.append(Finding(
                "WL005", uri, yml_path, anchor_line,
                f"The '{ecosystem}' update entry has no cooldown.default-days >= "
                f"{COOLDOWN_MIN_DAYS}. Without it, dependency bumps land immediately, "
                "before the community can surface a supply-chain attack. Add "
                f"cooldown.default-days: {COOLDOWN_MIN_DAYS}.",
            ))

        if ecosystem != "github-actions":
            continue

        dirs = entry_directories(entry)
        has_glob = False
        for value, node in dirs:
            if "**" in value:
                has_glob = True
                findings.append(Finding(
                    "WL003", uri, yml_path, node.start_mark.line + 1,
                    f"The github-actions entry uses a '{value}' glob. github-actions "
                    "does not recurse into nested action.yml, so composite actions are "
                    "never bumped (and '/**' provokes duplicate update PRs). List each "
                    "directory holding an action.yml explicitly.",
                ))

        # A glob is already flagged (WL003); enumerating coverage on top would
        # double-report. Only check coverage when explicit directories are used.
        if has_glob:
            continue
        listed = {norm_dir(value) for value, _ in dirs}
        anchor = dirs[-1][1].start_mark.line + 1 if dirs else anchor_line
        for cdir in sorted(composites):
            if cdir not in listed:
                findings.append(Finding(
                    "WL004", uri, yml_path, anchor,
                    f"Composite action '{cdir}/action.yml' is not listed in the "
                    "github-actions directories. Its third-party pins will drift "
                    "from the workflow copies. Add a directory entry for it.",
                ))


def run_checks(src_dir):
    yml_path = os.path.join(src_dir, ".github", "dependabot.yml")
    yaml_path = os.path.join(src_dir, ".github", "dependabot.yaml")
    findings = []

    if os.path.isfile(yml_path):
        check_dependabot(yml_path, ".github/dependabot.yml", findings)
    elif os.path.isfile(yaml_path):
        findings.append(Finding(
            "WL002", ".github/dependabot.yaml", yaml_path, 1,
            "Dependabot reads only .github/dependabot.yml; this .yaml file is "
            "silently ignored, so no update PRs run. Rename it to dependabot.yml.",
        ))
    else:
        findings.append(Finding(
            "WL001", ".github/dependabot.yml", None, 1,
            "No .github/dependabot.yml found. Dependency and action-pin updates "
            "(including your wrangle pin) never run. Copy "
            "gh_workflow_examples/dependabot.yml to .github/dependabot.yml.",
        ))
    return findings


def is_suppressed(raw_lines, line, rule):
    """True if a justified `wrangle-lint: ignore <rule>` directive is bound to the line."""
    if line < 1 or line > len(raw_lines):
        return False

    def justified(text):
        m = SUPPRESS_RE.search(text)
        if not m or m.group(1) != rule:
            return False
        return bool(m.group(2).lstrip(" \t:-").strip())

    if justified(raw_lines[line - 1]):
        return True
    i = line - 2
    while i >= 0 and raw_lines[i].lstrip().startswith("#"):
        if justified(raw_lines[i]):
            return True
        i -= 1
    return False


def filter_suppressed(findings):
    cache = {}
    kept = []
    for f in findings:
        if f.abspath is None:
            kept.append(f)
            continue
        if f.abspath not in cache:
            with open(f.abspath, "r", encoding="utf-8") as fh:
                cache[f.abspath] = fh.read().splitlines()
        if not is_suppressed(cache[f.abspath], f.line, f.rule):
            kept.append(f)
    return kept


def build_sarif(findings):
    used = sorted({f.rule for f in findings})
    rules = [{
        "id": rid,
        "name": rid,
        "shortDescription": {"text": RULES[rid][2]},
        "defaultConfiguration": {"level": RULES[rid][0]},
        "properties": {"security-severity": RULES[rid][1]},
    } for rid in used]
    results = [{
        "ruleId": f.rule,
        "level": RULES[f.rule][0],
        "message": {"text": f.message},
        "locations": [{"physicalLocation": {
            "artifactLocation": {"uri": f.uri},
            "region": {"startLine": f.line},
        }}],
    } for f in findings]
    return {
        "version": "2.1.0",
        "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
        "runs": [{
            "tool": {"driver": {
                "name": "wrangle-lint",
                "informationUri": "https://github.com/TomHennen/wrangle",
                "rules": rules,
            }},
            "results": results,
        }],
    }


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("Usage: check.py <src_dir> <out_sarif>\n")
        return 2
    src_dir, out_sarif = argv[1], argv[2]
    try:
        findings = filter_suppressed(run_checks(src_dir))
    except (OSError, ToolError) as exc:
        sys.stderr.write(f"wrangle-lint: {exc}\n")
        sys.stderr.write("wrangle-lint: failing closed.\n")
        return 2
    findings.sort(key=lambda f: (f.uri, f.line, f.rule))
    with open(out_sarif, "w", encoding="utf-8") as fh:
        json.dump(build_sarif(findings), fh, indent=2)
        fh.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
