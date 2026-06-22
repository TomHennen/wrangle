# Wrangle Build Shell

Wrangle checks your shell project: shellcheck over every script, your bats tests, and a source scan — all from one reusable workflow call. This build type validates; it produces no artifact, so no SBOM, provenance, or VSA applies (see [Build Track level](../../README.md#build-track-level)). It's the build type wrangle runs on itself.

## Quick start

Copy [`build_shell.yml`](../../../gh_workflow_examples/build_shell.yml) into `.github/workflows/` — no inputs are required:

```yaml
jobs:
  shell-build:
    permissions:
      contents: read
      actions: read           # source scan
      security-events: write  # scan findings -> Security tab
    uses: TomHennen/wrangle/.github/workflows/build_shell.yml@v0.3.0 # zizmor: ignore[unpinned-uses] - immutable
```

PRs, pushes, and manual dispatches all run the same checks — there's no release step to gate.

## What you get

- **shellcheck** over every `.sh` and `.bats` file under `scan-path` (default: the repo root), following `source`d helpers; `.bats` files exclude the few codes that misfire on core bats idioms.
- **bats tests**, auto-detected under `scan-path` — or run exactly the files you list in `bats-path`. No `.bats` files is fine; the step is skipped.
- **A setup hook** — point `setup-script` at a bash script that installs your test dependencies before the checks run; `PATH` additions via `GITHUB_PATH` reach the check steps.
- **Source scan** built in — vulnerable dependencies (OSV), unsafe workflow patterns (Zizmor), and more ([details](../../../actions/scan/README.md)); a load-bearing finding fails the run.

## Good to know

- **Monorepos**: set `scan-path` to confine the checks to a subtree.
- **`pull_request_target` can't trigger this workflow** — that trigger (and `workflow_run` chained from it) is a common exploit vector, so wrangle blocks both at startup.
- **Workflow inputs** are documented in [`build_shell.yml`](../../../.github/workflows/build_shell.yml) itself.
- **Enable Dependabot too** — copy [`dependabot.yml`](../../../gh_workflow_examples/dependabot.yml) to `.github/`; its `github-actions` entry keeps your `uses: TomHennen/wrangle/...` pin current.

## Further reading

- [`docs/SPEC.md`](../../../docs/SPEC.md) — the build-type contract and trigger model.
- [`actions/scan/README.md`](../../../actions/scan/README.md) — the source scan: tools, blocking semantics, configuration.
- [shellcheck](https://www.shellcheck.net/) and [bats](https://bats-core.readthedocs.io/) — the underlying tools.
