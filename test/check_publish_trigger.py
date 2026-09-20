#!/usr/bin/env python3
"""Assert the tool-image publish trigger covers every Dockerfile build input.

`.github/workflows/local_publish_images.yml` rebuilds the curated tool images on
a narrow `paths:` filter, and `tools/check_catalog_provenance_freshness.sh`
diffs the same set at release time to decide an image is stale. A path that
feeds an image but is missing from either one is a silent supply-chain failure:
the image goes stale while CI and the release gate stay green.

This derives the real input set from the workflow's own matrix — each image's
Dockerfile, plus every path it COPYs from the build context (the repo root),
expanded to files — and fails if one is not matched by the trigger. It then
holds the release gate's pathspecs to the trigger element by element, under the
only two pattern forms whose GitHub-glob and git-pathspec meanings coincide: an
exact path, and a whole directory (`X/**` here, `X` there).

Only this one workflow's trigger is checked, so it must be the only one that
builds images; a second one is refused rather than left unchecked.

Over-triggering is safe, under-triggering is not, so the Dockerfile direction is
one-way: the filter may match more than the Dockerfiles read, never less. The
gate must equal the trigger in both directions — a gap on one side calls a moved
image fresh, a gap on the other reds the release with a staleness no push can
rebuild away.

Usage:
  check_publish_trigger.py [--repo-root D] [--workflow F] [--gate-script F]
  check_publish_trigger.py --match PATH ...   print MATCH/NO-MATCH per path

Exit: 0 in agreement, 1 a disagreement, 2 tool/usage error (fail closed).
"""

import argparse
import glob
import json
import os
import re
import shlex
import subprocess
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("check_publish_trigger: PyYAML not available for this python3.\n")
    raise SystemExit(2)

WORKFLOW = ".github/workflows/local_publish_images.yml"
WORKFLOW_DIR = ".github/workflows"
GATE_SCRIPT = "tools/check_catalog_provenance_freshness.sh"
BUILDER_WORKFLOW = "build_and_publish_container.yml"
DOCKERFILE_EXPR = "${{ matrix.path }}/Dockerfile"
GATE_ARRAY = "PROVENANCE_DIFF_PATHS"


def fail(msg):
    sys.stderr.write("check_publish_trigger: %s\n" % msg)
    raise SystemExit(2)


def load_workflow(path):
    try:
        with open(path, encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
    except (OSError, yaml.YAMLError) as err:
        fail("cannot read %s: %s" % (path, err))
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
        fail("the publish workflow has no on.push.paths list")
    patterns = push["paths"]
    if not all(isinstance(p, str) for p in patterns):
        fail("on.push.paths must be a list of strings")
    return patterns


def builds_images(doc):
    jobs = doc.get("jobs") if isinstance(doc, dict) else None
    if not isinstance(jobs, dict):
        return False
    return any(
        isinstance(job, dict) and BUILDER_WORKFLOW in str(job.get("uses", ""))
        for job in jobs.values()
    )


def publishing_workflows(repo_root):
    """Every workflow with a job that builds an image, repo-root-relative."""
    found = []
    for ext in ("yml", "yaml"):
        for path in glob.glob(os.path.join(repo_root, WORKFLOW_DIR, "*.%s" % ext)):
            try:
                with open(path, encoding="utf-8") as fh:
                    doc = yaml.safe_load(fh)
            except (OSError, yaml.YAMLError) as err:
                fail("cannot read %s: %s" % (path, err))
            if builds_images(doc):
                found.append(os.path.relpath(path, repo_root))
    return sorted(found)


def image_dockerfiles(doc):
    """The Dockerfile of every image this workflow builds, from every job."""
    jobs = doc.get("jobs")
    if not isinstance(jobs, dict):
        fail("the publish workflow has no jobs")
    paths = []
    for name, job in jobs.items():
        if not isinstance(job, dict) or BUILDER_WORKFLOW not in str(job.get("uses", "")):
            continue
        dockerfile = job.get("with", {}).get("dockerfile")
        if dockerfile != DOCKERFILE_EXPR:
            fail(
                "%s.with.dockerfile is %r, not %r — this check derives each image's "
                "Dockerfile from the matrix path and cannot follow another form"
                % (name, dockerfile, DOCKERFILE_EXPR)
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
    try:
        with open(os.path.join(repo_root, dockerfile), encoding="utf-8") as fh:
            raw = fh.read()
    except OSError as err:
        fail("cannot read %s: %s" % (dockerfile, err))
    logical = re.sub(r"\\\n", " ", raw)
    sources = []
    for line in logical.splitlines():
        line = line.strip()
        for mount in re.findall(r"--mount=(\S+)", line):
            fields = dict(field.split("=", 1) for field in mount.split(",") if "=" in field)
            # A bind mount with no `from=` reads the build context directly, with
            # no COPY to derive an input from.
            if fields.get("type", "bind") == "bind" and "from" not in fields:
                fail("%s bind-mounts the build context, which this check cannot "
                     "expand into an input set: %s" % (dockerfile, line))
        # An ONBUILD instruction runs in a child build whose context is not this repo.
        if re.match(r"(?i)^onbuild\s", line):
            fail("%s uses ONBUILD, whose build context this check cannot derive: %s"
                 % (dockerfile, line))
        if not re.match(r"(?i)^(copy|add)\s", line):
            continue
        body = line.split(None, 1)[1].strip()
        if body.startswith("<<"):
            fail("%s uses a here-document, which has no repo path to cover: %s"
                 % (dockerfile, line))
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
        if not files:
            fail("%s COPYs %r, which holds no files" % (dockerfile, source))
        return files
    fail("%s COPYs %r, which is not in the repo" % (dockerfile, source))


def build_inputs(doc, repo_root):
    """Every repo file every image's Dockerfile reads, keyed by Dockerfile."""
    inputs = {}
    for dockerfile in image_dockerfiles(doc):
        files = {dockerfile}
        for source in copy_sources(dockerfile, repo_root):
            files |= expand(source, dockerfile, repo_root)
        inputs[dockerfile] = files
    return inputs


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
        elif char in "?[]+!":
            fail("unsupported glob character %r in pattern %r" % (char, pattern))
        else:
            out.append(re.escape(char))
            i += 1
    return re.compile("^%s$" % "".join(out))


def matches(path, patterns):
    return any(pattern_to_regex(pattern).match(path) for pattern in patterns)


def gate_pathspecs(repo_root, gate_script):
    """The git pathspecs the release gate diffs, read from the script itself."""
    path = os.path.join(repo_root, gate_script)
    reader = 'source "$1"; printf "%%s\\n" "${%s[@]}"' % GATE_ARRAY
    proc = subprocess.run(
        ["bash", "-euc", reader, "bash", path],
        capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0:
        fail("cannot read %s from %s: %s" % (GATE_ARRAY, gate_script, proc.stderr.strip()))
    specs = [line for line in proc.stdout.splitlines() if line]
    if not specs:
        fail("%s in %s is empty" % (GATE_ARRAY, gate_script))
    return specs


def gate_equivalent(patterns, repo_root):
    """Each trigger pattern as the git pathspec that diffs the same files."""
    specs = set()
    for pattern in patterns:
        spec = pattern[:-3] if pattern.endswith("/**") else pattern
        # `X/**` and git's `X` select the same files only when X is a directory.
        if spec != pattern and not os.path.isdir(os.path.join(repo_root, spec)):
            fail("trigger pattern %r does not name a directory" % pattern)
        if re.search(r"[*?\[\]!]", spec):
            fail("trigger pattern %r has no git pathspec this check can prove "
                 "equivalent — use an exact path or a whole directory `X/**`" % pattern)
        specs.add(spec)
    return specs


def report(header, items):
    sys.stderr.write("check_publish_trigger: %s\n" % header)
    for item in items:
        sys.stderr.write("  %s\n" % item)
    return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo-root", default=os.getcwd())
    parser.add_argument("--workflow", default=WORKFLOW)
    parser.add_argument("--gate-script", default=GATE_SCRIPT)
    parser.add_argument("--match", nargs="+", metavar="PATH")
    args = parser.parse_args()

    doc, triggers = load_workflow(os.path.join(args.repo_root, args.workflow))
    patterns = trigger_patterns(triggers)

    if args.match:
        for path in args.match:
            print("%s %s" % ("MATCH" if matches(path, patterns) else "NO-MATCH", path))
        return 0

    # Images built from a workflow whose own paths: filter nobody checks would
    # go stale unseen, so this one must be the only one that builds them.
    checked = os.path.relpath(os.path.join(args.repo_root, args.workflow), args.repo_root)
    publishers = publishing_workflows(args.repo_root)
    if publishers != [checked]:
        fail("%s is checked here, but the workflows that build images are %s — "
             "every one needs its trigger checked against its Dockerfiles"
             % (checked, ", ".join(publishers)))

    inputs = build_inputs(doc, args.repo_root)
    uncovered = sorted(
        "%s (read by %s)" % (path, dockerfile)
        for dockerfile, files in inputs.items()
        for path in files
        if not matches(path, patterns)
    )
    if uncovered:
        return report(
            "these image build inputs are not matched by on.push.paths — a change "
            "to one would ship a stale image:",
            uncovered,
        )

    specs = set(gate_pathspecs(args.repo_root, args.gate_script))
    equivalent = gate_equivalent(patterns, args.repo_root)
    if specs != equivalent:
        rc = 0
        if equivalent - specs:
            rc = report(
                "the trigger rebuilds on these paths but %s's %s does not diff them — "
                "the release gate would call an image fresh with its source changed:"
                % (args.gate_script, GATE_ARRAY),
                sorted(equivalent - specs),
            )
        if specs - equivalent:
            rc = report(
                "%s's %s diffs these paths but the trigger does not rebuild on them — "
                "a change to one reds the release with no rebuild able to clear it:"
                % (args.gate_script, GATE_ARRAY),
                sorted(specs - equivalent),
            )
        return rc

    print("checked %d build inputs across %d images against the trigger and the "
          "release gate" % (len(set().union(*inputs.values())), len(inputs)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
