# Wrangle Workflows

Wrangle aims to provide _both_:

1. Reusable workflows that other projects can easily call to achieve their goals.
2. Minimal _example_ workflows that other projects can adopt themselves to use Wrangle workflows and actions.

Wrangle also has it's own workflows that it uses to mange itself.
Wrangle's own workflows all have filenames that start with `local_`.

## TODO:

- Provide example workflows.
- Provide reuable workflow for code change...

## build_and_publish_*.yml

`build_and_publish_container.yml`, `build_and_publish_python.yml`, `build_and_publish_npm.yml`, `build_and_publish_go.yml`, and `build_shell.yml` let callers build and publish with a minimum of fuss, following best practices: SLSA provenance, SBOMs, signing, and — as of this release — a source scan up front.

**Embedded source scan.** Each of these workflows runs a `scan` job (the `actions/scan` composite) before building, so adopters get scanning *and* build/publish from one workflow — no separate `check_source_change.yml` needed.

- **`scan-tools` input** — space-separated tools, default `"osv zizmor scorecard:info dependency-review"`. Suffix a tool with `:info` to make it non-blocking. Empty string disables scanning entirely.
- **Publish gating.** A load-bearing (`:fail`) finding blocks publishing. The point where it blocks differs by build type:
  - **container** — blocks the `build` job on *every* event; the docker push happens mid-composite and is not release-gated, so this is the documented exception.
  - **go** — blocks the `release` job on release events; PR snapshot builds still run.
  - **python / npm** — fails the run, so the caller's `needs:`-gated publish job is skipped.
  - **shell** — fails the run (no artifact to gate).
- **`security-events: write`.** Grant this in the *caller's* permissions to upload scan SARIF to the Security tab. Omitting it does NOT fail the run or disable gating — GitHub silently caps the called job's permission, so findings still appear in the step summary and the `wrangle-scan-results` artifact, and a `:fail` finding still blocks publish. Only Security-tab integration is lost.

## check_source_change.yml

This reusable workflow lets callers scan their source changes only — the entry point for repos with no wrangle build type (a `build_and_publish_*` workflow already scans for repos that have one).

It creates a summary of all the tool results in the GitHub Action.

![check_source_change_summary](/assets/images/check_source_change_summary.png)