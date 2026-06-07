# wrangle

Developers want to ship features.  They'd like to do it securely but it's hard.  We ask too much of them:

* Remember to scan for vulns
* Remember not to use pull_request_target
* Remember to run zizmor
* Remember to produce an SBOM
* Remember not to misconfigure caching
* ...

What if... we could do this for developers, so they don't need to remember?

Wrangle is a one-stop shop for GitHub Actions CI/CD.  Developers add **a single** job that
uses one of wrangle's reusable workflows.  With that single job developers get:

* Vulnerability scanning with osv
* GitHub Action safety checks with Zizmor
* Automatic execution of unit tests
* Automatic builds with safe defaults
* SBOMs
* SLSA Build Level 3 provenance
* A SLSA VSA letting downstream users easily verify the artifacts you distribute.
* and more

The promise is that if developers use wrangle, wrangle will take care of drudgery, and let
developers focus on the features they want to ship.

## Quick Start

Developers can copy & adapt one of the ecosystem specific examples from [./gh_workflow_examples](gh_workflow_examples),
putting it in their .github/workflows directory.

This is what it looks like for go (which also needs a `.goreleaser.yml` — see the table below).

```yaml
name: Go Build

on:
  push:
    tags: ["v*"]       # publish on version tags
  pull_request:
    branches: ["**"]   # build + test on PRs (no provenance, no publish)
  workflow_dispatch:

jobs:
  build:
    permissions:
      contents: write         # goreleaser creates the Release; verify job attaches the VSA
      id-token: write         # OIDC for Sigstore signing
      attestations: write     # GitHub-issued SLSA provenance
      actions: read           # source scan: Scorecard reads the Actions API
      security-events: write  # source-scan SARIF -> Security tab
    uses: TomHennen/wrangle/.github/workflows/build_and_publish_go.yml@v0.2.0
    with:
      path: "."
```

Once they've done this they'll get tests run, scanning, attestations, etc.

## Ecosystems

Go, Python, npm, and Container each produce a signed artifact — source scan, tests, SBOM, SLSA Build L3 provenance, and a VSA. Shell and source-only run checks without producing an artifact.

| Ecosystem | README | Example |
|-----------|--------|---------|
| Go — uses your `.goreleaser.yml` | [README](build/actions/go/README.md) | [build_go.yml](gh_workflow_examples/build_go.yml) with example goreleaser configs in [pure-Go](gh_workflow_examples/build_go.goreleaser.yml) or [cgo cross-compile](gh_workflow_examples/build_go_cgo.goreleaser.yml) |
| Python — uv or pip, auto-detected | [README](build/actions/python/README.md) | [build_python.yml](gh_workflow_examples/build_python.yml) |
| npm — npm or pnpm, auto-detected | [README](build/actions/npm/README.md) | [build_npm.yml](gh_workflow_examples/build_npm.yml) |
| Container | [README](build/actions/container/README.md) | [build_and_publish_containers.yml](gh_workflow_examples/build_and_publish_containers.yml) |
| Shell | — | [build_shell.yml](gh_workflow_examples/build_shell.yml) |
| Source-only — no build, scan only | [README](actions/scan/README.md) | [check_source_change.yml](gh_workflow_examples/check_source_change.yml) |
