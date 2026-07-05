# Wrangle Workflows

Wrangle aims to provide _both_:

1. Reusable workflows that other projects can easily call to achieve their goals.
2. Minimal _example_ workflows that other projects can adopt themselves to use Wrangle workflows and actions.

Wrangle also has its own workflows that it uses to manage itself. Its dogfooding
callers are prefixed `local_` (e.g. `local_build_shell.yml`,
`local_publish_images.yml`); other internal workflows (`test.yml`,
`integration-test.yml`, `release-showcase.yml`, the catalog-freshness checks) are
not. Adopter-facing example workflows live in [`../../gh_workflow_examples/`](../../gh_workflow_examples/).

## build_and_publish_*.yml

`build_and_publish_container.yml`, `build_and_publish_python.yml`, `build_and_publish_npm.yml`, and `build_and_publish_go.yml` let callers build and publish with a minimum of fuss, following best practices: signed SLSA provenance, SBOMs, a signed VSA, and a source scan up front. `build_shell.yml` runs the same scan/build/test flow for shell projects but produces no artifact.

`build_shell.yml` also takes a `setup-script` input — a repo-relative script that installs test dependencies before the checks run — and a space-separated `bats-path`. Wrangle itself uses both: `local_build_shell.yml` is the dogfooding caller, with `test/setup_integration.sh` installing the integration toolchain.

**Embedded source scan.** Each of these workflows runs a `scan` job (the `actions/scan` composite) before building, so adopters get scanning *and* build/publish from one workflow — no separate `check_source_change.yml` needed.

- **`scan-tools` input** — space-separated tools, default `"osv zizmor scorecard:info dependency-review wrangle-lint"`. Suffix a tool with `:info` to make it non-blocking. Empty string disables scanning entirely.
- **Publish gating.** A load-bearing (`:fail`) finding blocks publishing. The point where it blocks differs by build type:
  - **container** — blocks the `build` job on *every* event; the docker push happens mid-composite and is not release-gated, so this is the documented exception.
  - **go** — blocks the `release` job on release events; PR snapshot builds still run.
  - **python / npm** — fails the run, so the caller's `needs:`-gated publish job is skipped.
  - **shell** — fails the run (no artifact to gate).
- **`actions: read` + `security-events: write`.** The caller MUST grant both — the embedded `scan` job requests them, and GitHub fails the run at startup if a called job requests a permission the caller didn't grant. Omitting either is a startup failure, not a silent downgrade.

## check_source_change.yml

This reusable workflow lets callers scan their source changes only — the entry point for repos with no wrangle build type (a `build_and_publish_*` workflow already scans for repos that have one).

It creates a summary of all the tool results in the GitHub Action.

![check_source_change_summary](/assets/images/check_source_change_summary.png)