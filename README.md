# wrangle

A composable CI/CD security framework for GitHub Actions. Adopters get source scanning, signed builds, SBOMs, and SLSA L3 provenance out of the box — by referencing wrangle's reusable workflows. Maintainers can update the tooling without adopters touching their repos.

## Quick Start

Add source scanning to any GitHub repo — create `.github/workflows/check_source_change.yml`:

```yaml
name: Check Source Change
on:
  push:
    branches: ["main"]
  pull_request:
    branches: ["**"]

jobs:
  check-change:
    permissions:
      actions: read
      contents: read
      security-events: write
    uses: TomHennen/wrangle/.github/workflows/check_source_change.yml@v0.1.0
```

Runs OSV-Scanner, Zizmor, OSSF Scorecard, and dependency-review on every PR. Findings appear in the Security tab and the Actions step summary.

For build/publish — npm, Python, container, shell — see the [workflow examples](gh_workflow_examples/README.md).

## Pieces

- [Workflow examples](gh_workflow_examples/README.md) — copy-paste starting points
- [Reusable workflows](.github/workflows/) — what adopters call via `uses:`
- [Source scan action](actions/scan/README.md) — OSV, Zizmor, Scorecard, dependency-review orchestration
- [Build actions](build/) — npm, python, container, shell
- [Tools](tools/) — per-tool adapters and install scripts (OSV, Zizmor, Scorecard, Syft, dependency-review)
- [Spec](docs/SPEC.md) — architecture, contracts, threat model
