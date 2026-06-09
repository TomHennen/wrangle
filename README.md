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

* Vulnerability scanning with [osv](https://github.com/google/osv-scanner)
* GitHub Action safety checks with [Zizmor](https://github.com/zizmorcore/zizmor)
* Automatic execution of unit tests
* Automatic builds with safe defaults
* [SBOMs](https://spdx.dev)
* [SLSA Build Level 3 provenance](https://slsa.dev/spec/v1.2/levels)
* Build provenance verified against SLSA policy (fail-closed) with [Ampel](https://github.com/carabiner-dev/ampel)
* A [SLSA VSA](https://slsa.dev/verification_summary/v1) letting downstream users easily verify the artifacts you distribute.
* and more

The promise is that if developers use wrangle, wrangle will take care of drudgery, safely,
and let developers focus on the features they want to ship.

## Quick Start

Developers can copy & adapt one of the ecosystem specific examples from [./gh_workflow_examples](gh_workflow_examples),
putting it in their .github/workflows directory.

This is what it looks like for go (which also needs a `.goreleaser.yml` — see the table below).

```yaml
name: Go Build

on:
  push:
    branches: ["main"]  # source scan + snapshot build on main (no publish); drop to skip per-merge builds
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

## How Wrangle Works

You add **one workflow file** to your repo that calls a wrangle reusable workflow. From there,
wrangle runs your code through a pipeline of well-known security and supply-chain tools so you
don't have to wire them up, configure them, or keep them current yourself.

### The pipeline

Depending on the ecosystem you pick, a run moves through these stages:

1. **Scan the source** — checks your dependencies for known vulnerabilities (OSV) and lints your
   GitHub Actions workflows for unsafe patterns (Zizmor).
2. **Run your tests** — wrangle runs your existing test suite; it orchestrates your tests, it
   doesn't replace them.
3. **Build the artifact** — compiles/packages your project using safe defaults for your
   ecosystem (Go, Python, npm, or a container image).
4. **Describe what's inside** — generates an [SBOM](https://spdx.dev) (a bill of materials of
   every dependency) and scans it for vulnerabilities.
5. **Sign and attest** — signs the artifact and produces
   [SLSA Build Level 3 provenance](https://slsa.dev/spec/v1.2/levels): tamper-evident proof of
   exactly how and where it was built.
6. **Verify before shipping** — checks that provenance against a policy and emits a
   [VSA](https://slsa.dev/verification_summary/v1) so the people who consume your artifact can
   verify it with a single command.

Source-only and shell projects run the checks without producing a published artifact; the other
ecosystems run the whole pipeline.

### Maintained for you

Because you reference wrangle's reusable workflows (rather than copying tool config into your
repo), tool updates, new security checks, and fixes flow to you automatically. A security
engineer can improve the defaults for everyone without every project having to change anything.

### Security is the point, not a feature

Wrangle is a supply-chain security tool, so its defaults lean toward safety:

- **Fail-closed on security guarantees.** If signing or provenance generation fails, the release
  is *blocked* — wrangle never ships an unsigned or unattested artifact, because a missing
  guarantee is indistinguishable from an attack.
- **Keyless signing.** Artifacts are signed with [Sigstore](https://www.sigstore.dev/) using
  your GitHub Actions identity — there are no signing keys for you to manage or leak.
- **Verifiable provenance.** The provenance ties each artifact back to the exact workflow that
  built it, and the VSA lets downstream users confirm that without trusting you blindly.
- **Least privilege.** Workflows request only the permissions they actually need — never
  blanket write access.

You don't have to be a security expert to get these properties; adopting wrangle is how you get
them.

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
