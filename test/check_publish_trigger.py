#!/usr/bin/env python3
"""Assert the image-publish trigger covers every Dockerfile build input.

`.github/workflows/local_publish_images.yml` rebuilds the curated tool images on
a narrow `paths:` filter. A path that feeds an image but is missing from that
filter is a silent supply-chain failure: the image goes stale while CI stays
green. This derives the true input set from the workflow's own matrix — each
image's Dockerfile, every path it COPYs from the build context (the repo root),
expanded to files — and fails if any of them is not matched by the filter.

Over-triggering is safe, so the check is one-directional: the filter may match
more than the Dockerfiles read, never less.

--check-gate holds the release gate to the same set. Its stale-image diff-set
(PROVENANCE_DIFF_PATHS in tools/check_catalog_provenance_freshness.sh) must
cover every build input — or it calls an image fresh while its source moved —
and must stay within the trigger, or it reds the release with a staleness no
push to main can rebuild away.

Usage:
  check_publish_trigger.py [--workflow F] [--repo-root D]   coverage check
  check_publish_trigger.py --check-gate [--gate-script F]   gate/trigger agreement
  check_publish_trigger.py --list-inputs                    print the input set
  check_publish_trigger.py --match PATH...                  print MATCH/NO-MATCH

Exit: 0 covered, 1 uncovered input found, 2 tool/usage error (fail closed).
"""

import json
import os
import re
import shlex
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("check_publish_trigger: PyYAML not available for this python3.\n")
    raise SystemExit(2)

WORKFLOW = ".github/workflows/local_publish_images.yml"
DOCKERFILE_EXPR = "${{ matrix.path }}/Dockerfile"
BUILDER_WORKFLOW = "build_and_publish_container.yml"
GATE_SCRIPT = "tools/check_catalog_provenance_freshness.sh"
GATE_ARRAY = "PROVENANCE_DIFF_PATHS"
PRUNED_DIRS = {".git", ".claude", ".beads", ".wrangle"}


def fail(msg):
    sys.stderr.write("check_publish_trigger: %s\n" % msg)
    raise SystemExit(2)


def load_workflow(path):
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    if not isinstance(doc, dict):
        fail("%s is not a workflow mapping" % path)
    # PyYAML resolves the bare `on:` key to the boolean True (YAML 1.1).
    triggers = doc.get("on", doc.get(True))
    if not isinstance(triggers, dict):
        fail("%s has no `on:` mapping" % path)
    return doc, triggers


def trigger_patterns(triggers):
    push = triggers.get("push")
    if not isinstance(push, dict) or not isinstance(push.get("paths"), list):
        fail("%s has no on.push.paths list" % WORKFLOW)
    patterns = push["paths"]
    if not all(isinstance(p, str) for p in patterns):
        fail("on.push.paths must be a list of strings")
    return patterns


def image_dockerfiles(doc):
    """The Dockerfile of every image this workflow builds, from every job."""
    jobs = doc.get("jobs")
    if not isinstance(jobs, dict):
        fail("no jobs")
    paths = []
    for name, job in jobs.items():
        if not isinstance(job, dict) or BUILDER_WORKFLOW not in str(job.get("uses", "")):
            continue
        dockerfile = job.get("with", {}).get("dockerfile")
        if dockerfile != DOCKERFILE_EXPR:
            fail(
                "%s.with.dockerfile is %r, not %r — this check derives each "
                "image's Dockerfile from the matrix path and cannot follow "
                "another form" % (name, dockerfile, DOCKERFILE_EXPR)
            )
        include = job.get("strategy", {}).get("matrix", {}).get("include")
        if not isinstance(include, list) or not include:
            fail("%s builds images but has no matrix include list" % name)
        for entry in include:
            if not isinstance(entry, dict) or "path" not in entry:
                fail("matrix entry without a `path`: %r" % (entry,))
            paths.append("%s/Dockerfile" % entry["path"].rstrip("/"))
    if not paths:
        fail("no job builds an image via %s" % BUILDER_WORKFLOW)
    return paths


def copy_sources(dockerfile, repo_root):
    """Build-context sources COPY/ADDed by dockerfile (stage sources excluded)."""
    with open(os.path.join(repo_root, dockerfile), encoding="utf-8") as fh:
        raw = fh.read()
    logical = re.sub(r"\\\n", " ", raw)
    sources = []
    for line in logical.splitlines():
        line = line.strip()
        for mount in re.findall(r"--mount=(\S+)", line):
            fields = dict(
                field.split("=", 1) for field in mount.split(",") if "=" in field
            )
            # A bind mount with no `from=` reads the build context — the whole of
            # it when it names no source — with no COPY to derive an input from.
            if fields.get("type", "bind") == "bind" and "from" not in fields:
                fail("%s bind-mounts the build context, which this check cannot "
                     "expand into an input set: %s" % (dockerfile, line))
        # An ONBUILD COPY runs in a child build, where the context is not this
        # repo — treat it as unmodellable rather than derive a set that ignores it.
        if re.match(r"(?i)^onbuild\s", line):
            fail("%s uses ONBUILD, whose build context this check cannot "
                 "derive: %s" % (dockerfile, line))
        if not re.match(r"(?i)^(copy|add)\s", line):
            continue
        body = line.split(None, 1)[1].strip()
        if body.startswith("["):
            try:
                tokens = json.loads(body)
            except ValueError:
                fail("cannot parse JSON-form instruction in %s: %s" % (dockerfile, line))
        else:
            tokens = shlex.split(body)
        if any(t.startswith("--from=") for t in tokens):
            continue  # copies from an earlier stage, not from the build context
        operands = [t for t in tokens if not t.startswith("--")]
        if len(operands) < 2:
            fail("cannot parse instruction in %s: %s" % (dockerfile, line))
        sources.extend(operands[:-1])
    return sources


def expand(source, dockerfile, repo_root):
    """A context source (file or directory) as the set of repo files it reads."""
    if re.search(r"[*?\[]", source):
        fail("wildcard context source %r in %s is not supported" % (source, dockerfile))
    rel = os.path.normpath(source)
    abs_path = os.path.join(repo_root, rel)
    if os.path.isfile(abs_path):
        return {rel}
    if os.path.isdir(abs_path):
        files = set()
        for dirpath, _, filenames in os.walk(abs_path):
            for name in filenames:
                files.add(os.path.relpath(os.path.join(dirpath, name), repo_root))
        return files
    fail("%s COPYs %r, which is not in the repo" % (dockerfile, source))


def pattern_to_regex(pattern):
    """A GitHub paths pattern as a regex: `*` stops at `/`, `**` does not."""
    out = []
    i = 0
    while i < len(pattern):
        char = pattern[i]
        if char == "*":
            if pattern.startswith("**", i):
                out.append(".*")
                i += 2
            else:
                out.append("[^/]*")
                i += 1
        elif char == "?":
            out.append("[^/]")
            i += 1
        elif char in "[]+!":
            fail("unsupported glob character %r in pattern %r" % (char, pattern))
        else:
            out.append(re.escape(char))
            i += 1
    return re.compile("^%s$" % "".join(out))


def matches(path, patterns):
    """GitHub paths semantics: `!` negates, and the last matching pattern wins."""
    included = False
    for pattern in patterns:
        negated = pattern.startswith("!")
        if pattern_to_regex(pattern.lstrip("!")).match(path):
            included = not negated
    return included


def gate_pathspecs(repo_root, gate_script):
    """The git pathspecs the release gate diffs to decide an image is stale."""
    with open(os.path.join(repo_root, gate_script), encoding="utf-8") as fh:
        body = fh.read()
    found = re.search(r"^%s=\((.*?)\)$" % GATE_ARRAY, body, re.MULTILINE | re.DOTALL)
    if not found:
        fail("no %s array in %s" % (GATE_ARRAY, gate_script))
    specs = shlex.split(found.group(1), comments=True)
    if not specs:
        fail("%s in %s is empty" % (GATE_ARRAY, gate_script))
    return specs


def git_pattern_to_regex(pattern):
    """A git `:(glob)` pathspec as a regex: unlike GitHub's, `**` matches zero
    path components, so `tools/**/*.go` covers `tools/x.go`."""
    out = []
    segments = pattern.split("/")
    for i, segment in enumerate(segments):
        last = i == len(segments) - 1
        if segment == "**":
            out.append(".*" if last else "(?:[^/]*/)*")
            continue
        if "**" in segment:
            fail("`**` must be its own path component in %r" % pattern)
        out.append(pattern_to_regex(segment).pattern[1:-1])
        if not last:
            out.append("/")
    return re.compile("^%s$" % "".join(out))


def gate_matcher(spec):
    """A git pathspec as (excluded, regex). Only the magic the gate uses."""
    magic = []
    path = spec
    found = re.match(r"^:\(([^)]*)\)(.*)$", spec)
    if found:
        magic = found.group(1).split(",")
        path = found.group(2)
    elif spec.startswith(":"):
        fail("unsupported pathspec magic in %r" % spec)
    unknown = set(magic) - {"glob", "exclude"}
    if unknown:
        fail("unsupported pathspec magic %s in %r" % (sorted(unknown), spec))
    if "glob" in magic:
        regex = git_pattern_to_regex(path)
    else:
        # A literal pathspec matches the path itself and, for a directory,
        # everything beneath it.
        escaped = re.escape(path.rstrip("/"))
        regex = re.compile("^%s(/.*)?$" % escaped)
    return "exclude" in magic, regex


def gate_files(repo_root, gate_script, repo_files):
    """The repo files the release gate's diff-set covers."""
    matchers = [gate_matcher(spec) for spec in gate_pathspecs(repo_root, gate_script)]
    included = set()
    for path in repo_files:
        if any(regex.match(path) for excluded, regex in matchers if not excluded) and not any(
            regex.match(path) for excluded, regex in matchers if excluded
        ):
            included.add(path)
    return included


def repo_files(repo_root):
    files = set()
    for dirpath, dirnames, filenames in os.walk(repo_root):
        dirnames[:] = [d for d in dirnames if d not in PRUNED_DIRS]
        for name in filenames:
            files.add(os.path.relpath(os.path.join(dirpath, name), repo_root))
    return files


def build_inputs(doc, repo_root):
    """Every repo file every image's Dockerfile reads, keyed by Dockerfile."""
    inputs = {}
    for dockerfile in image_dockerfiles(doc):
        files = {dockerfile}
        for source in copy_sources(dockerfile, repo_root):
            files |= expand(source, dockerfile, repo_root)
        inputs[dockerfile] = files
    return inputs


def report(header, items):
    sys.stderr.write("check_publish_trigger: %s\n" % header)
    for item in items:
        sys.stderr.write("  %s\n" % item)
    return 1


def check_gate(doc, repo_root, gate_script, patterns):
    covered = gate_files(repo_root, gate_script, repo_files(repo_root))
    inputs = build_inputs(doc, repo_root)

    missing = sorted(
        "%s (read by %s)" % (path, dockerfile)
        for dockerfile, files in inputs.items()
        for path in files
        if path not in covered
    )
    if missing:
        return report(
            "these image build inputs are not in %s's %s — the release gate would "
            "call the image fresh with its source changed:" % (gate_script, GATE_ARRAY),
            missing,
        )

    stranded = sorted(path for path in covered if not matches(path, patterns))
    if stranded:
        return report(
            "%s's %s covers paths the publish trigger ignores — a change to one "
            "reds the release gate with no rebuild able to clear it:"
            % (gate_script, GATE_ARRAY),
            stranded,
        )
    print("release gate diff-set agrees with the trigger over %d paths" % len(covered))
    return 0


def main(argv):
    repo_root = os.getcwd()
    workflow = None
    gate_script = GATE_SCRIPT
    match_paths = []
    list_inputs = False
    gate = False
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--repo-root":
            repo_root = argv[i + 1]
            i += 2
        elif arg == "--workflow":
            workflow = argv[i + 1]
            i += 2
        elif arg == "--gate-script":
            gate_script = argv[i + 1]
            i += 2
        elif arg == "--check-gate":
            gate = True
            i += 1
        elif arg == "--list-inputs":
            list_inputs = True
            i += 1
        elif arg == "--match":
            match_paths = argv[i + 1:]
            break
        else:
            fail("unknown argument %r" % arg)
    doc, triggers = load_workflow(os.path.join(repo_root, workflow or WORKFLOW))
    patterns = trigger_patterns(triggers)

    if match_paths:
        for path in match_paths:
            print("%s %s" % ("MATCH" if matches(path, patterns) else "NO-MATCH", path))
        return 0

    if gate:
        return check_gate(doc, repo_root, gate_script, patterns)

    inputs = build_inputs(doc, repo_root)

    if list_inputs:
        for path in sorted(set().union(*inputs.values())):
            print(path)
        return 0

    uncovered = []
    checked = 0
    for dockerfile, files in sorted(inputs.items()):
        for path in sorted(files):
            checked += 1
            if not matches(path, patterns):
                uncovered.append("%s (read by %s)" % (path, dockerfile))

    if uncovered:
        return report(
            "these image build inputs are not matched by on.push.paths — a change "
            "to one would ship a stale image:",
            uncovered,
        )
    print("checked %d build inputs across %d images" % (checked, len(inputs)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
