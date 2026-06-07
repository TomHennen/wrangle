# wrangle

Developers want to ship features.  They'd like to do it securely but it's hard.  We ask too much of them:

* Remember to scan for vulns
* Remember not to use pull_request_target
* Remember to run zizmor
* Remember to produce an SBOM
* Remember not to misconfiguring caching
* ...

What if... we could do this for developers, so they don't need to remember?

Wrangle is one-stop shop for GitHub Actions CI/CD.  Developers add **a single** job that
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

This is what it looks like for go.

```yaml
name: Go Build

on:
  push:
    tags: ["v*", "main"]
  pull_request:
    branches: ["**"]
  workflow_dispatch:

jobs:
  build:
    permissions:
      contents: write
      id-token: write
      attestations: write
    uses: TomHennen/wrangle/.github/workflows/build_and_publish_go.yml@...
    with:
      path: "."
```

Once they've done this they'll get tests run, scanning, attestations, etc.

## Pieces

- [Workflow examples](gh_workflow_examples/README.md) — copy-paste starting points
- [Reusable workflows](.github/workflows/) — what adopters call via `uses:`; `build_and_publish_*` scan + build + publish, `check_source_change.yml` scans only
- [Source scan action](actions/scan/README.md) — OSV, Zizmor, Scorecard, dependency-review orchestration
- [Build actions](build/) — npm, python, container, shell
- [Tools](tools/) — per-tool adapters and install scripts (OSV, Zizmor, Scorecard, Syft, dependency-review)
- [Spec](docs/SPEC.md) — architecture, contracts, threat model
