#!/usr/bin/env python3
"""wrangle-workflow-lint — YAML-level CLAUDE.md conventions for GitHub Actions.

Enforces the rules that operate on workflow / composite-action *structure*
(run-block line spans, step-sibling keys) rather than shell AST — those that
ast-grep cannot express and that actionlint / zizmor do not cover:

  WWL001 (R1)  a `run:` block is at most 10 physical lines (preamble, blanks,
               and comments included).
  WWL002 (R2)  no `${{ inputs.* }}` / `${{ github.event.* }}` interpolated
               literally inside a `run:` body (blanket ban — thread through
               `env:` first). Enforces the typed-input (`inputs.*`) and webhook
               (`github.event.*`, `github.head_ref`, `github.ref_name`)
               contexts; zizmor fails closed on its own overlapping subset.
  WWL003 (R4)  a verification-class step (name/id/uses matching
               verify|attestation|provenance|slsa|cosign|install) that sets
               `continue-on-error: true` must carry an adjacent justification
               comment — mirrors WSL005's documented-exception mechanism.

The sibling shell-AST rules live in wrangle-shell-lint: R3 (curl|sh) is WSL006
and R5 (`set +f` outside a subshell) is WSL007.

Inputs are file paths (workflows under .github/workflows and composite
action.yml files). Both `jobs.*.steps[]` and `runs.steps[]` are walked.

Exit: 0 clean, 1 violations found, 2 tool/usage error (fail closed).
"""

import re
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write(
        "wrangle-workflow-lint: PyYAML not available for this python3.\n"
        "Install it (the test image apt-installs python3-yaml; locally: "
        "`pip install pyyaml` or `apt-get install python3-yaml`).\n"
    )
    raise SystemExit(2)

MAX_RUN_LINES = 10

# R2: an interpolation of a typed input or the webhook event payload. These are
# attacker-influenced and must never be spliced into a shell command directly.
# `inputs` / `github` are matched only as expression roots (the lookbehind
# rejects a leading `.` or word char) so sibling contexts that merely end in
# `inputs` — `${{ matrix.inputs }}`, `${{ steps.x.outputs.inputs }}` — are not
# false-flagged. `inputs` must be followed by `.`/`[` (a typed-input access).
# `github.head_ref` / `github.ref_name` are attacker-influenced refs (the
# classic pull_request_target injection vector), so they are flagged too.
INJECTION_RE = re.compile(
    r"\$\{\{[^}]*?(?<![.\w])"
    r"(?:inputs\s*[.\[]|github\.(?:event\b|head_ref\b|ref_name\b))"
)

# R4: steps whose purpose is verifying provenance / attestations / signatures /
# installing toolchains — where silently swallowing a failure is a security
# regression, not a convenience. Best-effort keyword sets (not exhaustive).
#
# IDENTITY set scans name/id/uses: `install` is meaningful here ("Install
# Cosign", cosign-installer) — it names a tool-install step.
IDENTITY_KEYWORDS = re.compile(
    r"verify|attestation|provenance|slsa|cosign|sigstore|rekor|"
    r"notation|gitsign|in-?toto|gpg|install",
    re.IGNORECASE,
)
# RUN set scans the run: body — inline `run: cosign verify …` /
# `gh attestation verify …` is the repo's dominant style. Narrower than the
# identity set: `install` / `gpg` are dropped because a run body is dominated
# by routine package installs (`npm install`) that are not verification steps.
RUN_VERIFY_KEYWORDS = re.compile(
    r"verify|attestation|provenance|slsa|cosign|sigstore|rekor|"
    r"notation|gitsign|in-?toto",
    re.IGNORECASE,
)


def tolerates_failure(coe_node):
    """True if continue-on-error is set to anything that can evaluate true.

    Literal `true`, or any `${{ … }}` expression we cannot statically prove
    false. Literal `false` (the default) does not tolerate failure. This closes
    the `continue-on-error: ${{ true }}` bypass of a literal-only check.
    """
    if coe_node is None:
        return False
    val = scalar_text(coe_node).strip()
    low = val.lower()
    if low == "false":
        return False
    if low == "true":
        return True
    return val.startswith("${{")


class Finding:
    __slots__ = ("path", "line", "rule", "message")

    def __init__(self, path, line, rule, message):
        self.path = path
        self.line = line
        self.rule = rule
        self.message = message

    def __str__(self):
        return f"{self.path}:{self.line}: {self.rule}: {self.message}"


def mapping_items(node):
    """Yield (key_string, value_node) for a MappingNode, or nothing."""
    if isinstance(node, yaml.MappingNode):
        for key, value in node.value:
            if isinstance(key, yaml.ScalarNode):
                yield key.value, value


def find_steps(node):
    """Yield every step MappingNode reachable through any `steps:` sequence.

    Covers both `jobs.<id>.steps[]` (workflows) and `runs.steps[]` (composite
    actions) because both attach the step list under a `steps` key.
    """
    if isinstance(node, yaml.MappingNode):
        for key, value in mapping_items(node):
            if key == "steps" and isinstance(value, yaml.SequenceNode):
                for item in value.value:
                    if isinstance(item, yaml.MappingNode):
                        yield item
            yield from find_steps(value)
    elif isinstance(node, yaml.SequenceNode):
        for item in node.value:
            yield from find_steps(item)


def run_body_physical_lines(node, raw_lines):
    """Physical source-line count of a `run:` scalar body.

    Counts the lines the shell occupies as written — preamble, blank lines,
    and comments all count (a 10-line cap on the *body*, per CLAUDE.md). Uses
    raw source lines rather than the parsed value so folded (`>`) scalars,
    whose newlines collapse to spaces in the value, are still measured by
    physical extent.
    """
    start = node.start_mark.line  # 0-indexed line of the value indicator
    end = node.end_mark.line
    if node.style in ("|", ">"):
        body = raw_lines[start + 1 : end]
        # Trailing blank lines are chomped from the value and are YAML
        # formatting, not shell — don't count them against the cap.
        while body and body[-1].strip() == "":
            body.pop()
        return len(body)
    # Plain or quoted scalar: physical span (single line in the common case).
    return (end - start) + 1


def step_sub(step):
    """Return {key_string: value_node} for a step's immediate keys."""
    return {k: v for k, v in mapping_items(step)}


def scalar_text(node):
    return node.value if isinstance(node, yaml.ScalarNode) else ""


def check_run_rules(path, run_node, raw_lines, findings):
    # R1 — run-block length.
    n = run_body_physical_lines(run_node, raw_lines)
    if n > MAX_RUN_LINES:
        findings.append(
            Finding(
                path,
                run_node.start_mark.line + 1,
                "WWL001",
                f"run: block is {n} physical lines (max {MAX_RUN_LINES}). "
                "Extract the logic to a script under tools/<name>/ or "
                "build/actions/ and call it. See CLAUDE.md 'GitHub Actions'.",
            )
        )

    # R2 — expression injection inside a run body. node.value holds the
    # literal shell text for block scalars; search it line by line so the
    # report points at the offending line, not the run: indicator.
    body = scalar_text(run_node)
    base = run_node.start_mark.line + (1 if run_node.style in ("|", ">") else 0)
    for offset, text in enumerate(body.splitlines()):
        if INJECTION_RE.search(text):
            findings.append(
                Finding(
                    path,
                    base + offset + 1,
                    "WWL002",
                    "`${{ inputs.* }}` / `${{ github.event.* }}` interpolated "
                    "into a run: body. Thread the value through `env:` and "
                    "reference it as a shell variable. See CLAUDE.md "
                    "'No expression injection'.",
                )
            )


def has_adjacent_justification(coe_node, raw_lines):
    """True if a justification comment is bound to the continue-on-error key.

    Like WSL005, the justification must sit ON the directive: either a trailing
    inline comment on the `continue-on-error:` line, or the contiguous block of
    comment lines immediately above it. An incidental comment elsewhere in the
    step does not count. Whitespace after `#` is not a justification.
    """
    coe_line = coe_node.start_mark.line
    # Trailing inline comment on the continue-on-error line itself. The value is
    # `true`/`false`/`${{ … }}` (no literal `#`), so a `#` here starts a comment.
    if coe_line < len(raw_lines):
        hash_idx = raw_lines[coe_line].find("#")
        if hash_idx != -1 and raw_lines[coe_line][hash_idx + 1:].strip():
            return True
    # Contiguous comment block directly above the continue-on-error line.
    i = coe_line - 1
    while i >= 0:
        stripped = raw_lines[i].lstrip()
        if not stripped.startswith("#"):
            break
        if stripped[1:].strip():
            return True
        i -= 1
    return False


def check_step_rules(path, step, raw_lines, findings):
    sub = step_sub(step)
    if "run" in sub and isinstance(sub["run"], yaml.ScalarNode):
        check_run_rules(path, sub["run"], raw_lines, findings)

    # R4 — failure-tolerating continue-on-error on a verification-class step
    # needs a justification. `tolerates_failure` covers the `${{ true }}`
    # expression form, not only the literal.
    coe = sub.get("continue-on-error")
    if not tolerates_failure(coe):
        return
    identity = " ".join(
        scalar_text(sub[k]) for k in ("name", "id", "uses") if k in sub
    )
    run_body = (
        scalar_text(sub["run"])
        if "run" in sub and isinstance(sub["run"], yaml.ScalarNode)
        else ""
    )
    if not (
        IDENTITY_KEYWORDS.search(identity) or RUN_VERIFY_KEYWORDS.search(run_body)
    ):
        return
    if not has_adjacent_justification(coe, raw_lines):
        findings.append(
            Finding(
                path,
                coe.start_mark.line + 1,
                "WWL003",
                "continue-on-error tolerates failure on a verification-class "
                "step (name/id/uses/run matches verify|attestation|provenance|"
                "slsa|cosign|sigstore|... or install) without a justification "
                "comment on the continue-on-error line. Swallowing a "
                "verification failure can mask a supply-chain attack; document "
                "why it is safe here.",
            )
        )


def lint_file(path):
    """Return a list of Findings for one YAML file (may be empty)."""
    with open(path, "r", encoding="utf-8") as fh:
        content = fh.read()
    raw_lines = content.splitlines()
    try:
        root = yaml.compose(content)
    except yaml.YAMLError as exc:
        # A file we cannot parse is a tool error, not a pass — fail closed.
        raise RuntimeError(f"{path}: YAML parse error: {exc}") from exc
    findings = []
    if root is not None:
        for step in find_steps(root):
            check_step_rules(path, step, raw_lines, findings)
    return findings


def main(argv):
    paths = argv[1:]
    if not paths:
        return 0
    findings = []
    try:
        for path in paths:
            findings.extend(lint_file(path))
    except (OSError, RuntimeError) as exc:
        sys.stderr.write(f"wrangle-workflow-lint: {exc}\n")
        sys.stderr.write("wrangle-workflow-lint: failing closed.\n")
        return 2
    if findings:
        findings.sort(key=lambda f: (f.path, f.line, f.rule))
        for finding in findings:
            print(finding)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
