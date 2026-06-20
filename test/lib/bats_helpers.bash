# test/lib/bats_helpers.bash — shared bats helpers, pulled in with `load`.
# A sourced helper library: no shebang (it's loaded into a bats test, never
# executed on its own), so it carries no script preamble. Not a *.bats file, so
# the suite's glob doesn't run it as a test.

# in_ci: true under CI (CI/GITHUB_ACTIONS set). The single definition of
# "are we in CI" for test helpers — skip policy and preflight probes must
# agree on it.
in_ci() {
    [[ -n "${CI:-}${GITHUB_ACTIONS:-}" ]]
}

# skip_or_fail <reason>: under CI the real binary + network are present, so a
# skip means the test silently degraded — fail instead. Locally skip, so
# sandboxed dev isn't blocked.
skip_or_fail() {
    if in_ci; then
        printf 'FATAL: %s (skip not allowed in CI)\n' "$1" >&2
        exit 1
    fi
    skip "$1"
}

# bats_python: a python3 that can import yaml, for parsing action.yml in tests.
# Mirrors wrangle-workflow-lint's resolution: the image's PyYAML venv, else a
# system python3 with PyYAML for local dev.
bats_python() {
    local py
    for py in /opt/wrangle-workflow-lint/bin/python3 python3; do
        if command -v "$py" >/dev/null 2>&1 && "$py" -c 'import yaml' >/dev/null 2>&1; then
            printf '%s\n' "$py"
            return 0
        fi
    done
    return 1
}

# run_composite_step <action_yml> <step_name> <workspace> <action_path>:
# extract the named composite-action step's run: block and execute it with the
# step's declared env: — interpolating ${{ github.workspace }} and
# ${{ github.action_path }} — so a test drives the real action wiring, not a
# hand-copied facsimile that can drift. The step's `if:` is not evaluated here
# (callers set up the on-disk state the step gates on); shell ${...} env refs
# and the run-block body execute as written.
run_composite_step() {
    local action_yml="$1" step_name="$2" workspace="$3" action_path="$4" py
    py="$(bats_python)" || { printf 'PyYAML python3 unavailable\n' >&2; return 1; }
    local script
    script="$("$py" - "$action_yml" "$step_name" "$workspace" "$action_path" <<'PY'
import sys, yaml, shlex
action_yml, step_name, workspace, action_path = sys.argv[1:5]
doc = yaml.safe_load(open(action_yml))
steps = doc["runs"]["steps"]
step = next(s for s in steps if s.get("name") == step_name)
def interp(v):
    return (str(v)
            .replace("${{ github.workspace }}", workspace)
            .replace("${{ github.action_path }}", action_path))
lines = []
for k, v in (step.get("env") or {}).items():
    lines.append(f"export {k}={shlex.quote(interp(v))}")
lines.append(interp(step["run"]))
sys.stdout.write("\n".join(lines))
PY
)" || return 1
    bash -c "$script"
}
