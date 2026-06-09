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

Add one more file to keep wrangle current: copy
[`gh_workflow_examples/dependabot.yml`](gh_workflow_examples/dependabot.yml) to
`.github/dependabot.yml`. It raises a PR whenever a newer wrangle release is available so your
pin (and the security tooling behind it) doesn't go stale — review and merge those yourself, and
don't enable auto-merge (see [Staying up to date](#staying-up-to-date)).

## How Wrangle Works

Behind that one workflow call, wrangle runs your code through a pipeline of well-known security
and supply-chain tools so you don't have to wire them up, configure them, or keep them current
yourself.

### The pipeline

Depending on the ecosystem you pick, a run moves through these stages:

1. **Scan the source** — checks your dependencies for known vulnerabilities (OSV) and lints your
   GitHub Actions workflows for unsafe patterns (Zizmor).
2. **Run your tests** — wrangle runs your existing test suite; it orchestrates your tests, it
   doesn't replace them.
3. **Build the artifact** — compiles/packages your project using safe defaults for your
   ecosystem (Go, Python, npm, or a container image).
4. **Describe what's inside** — generates an SBOM (a bill of materials of every dependency) and
   scans it for vulnerabilities.
5. **Sign and attest** — signs the artifact and produces SLSA Build Level 3 provenance:
   tamper-evident proof of exactly how and where it was built.
6. **Verify before shipping** — checks that provenance against a policy and emits a VSA so the
   people who consume your artifact can verify it with a single command.

Source-only and shell projects run the checks without producing a published artifact; the other
ecosystems run the whole pipeline. (The intro bullets above link out to each of these terms.)

### Staying up to date

Because you reference wrangle's reusable workflows (rather than copying tool config into your
repo), every new wrangle release ships freshly-pinned tool versions, new security checks, and
fixes — and you adopt the whole bundle by bumping a single pin, not by re-plumbing anything. A
security engineer can improve the defaults for everyone centrally.

These updates do **not** apply themselves. You pin wrangle at a release tag (e.g.
`@v0.2.0`), and you pick up new releases when that pin is bumped — so wrangle adoption is really
**two files**: the workflow above, plus a [Dependabot config](gh_workflow_examples/dependabot.yml)
(copy it to `.github/dependabot.yml`) that raises a PR whenever a newer wrangle tag is available.
Without it your pin — and the security tooling behind it — silently goes stale. Review and merge
those PRs yourself; **do not** enable auto-merge, so wrangle's ~7-day cooldown can let
supply-chain attacks surface before you pull a new version in.

### Security is the point, not a feature

Wrangle is a supply-chain security tool, so its defaults lean toward safety:

- **Fail-closed on security guarantees.** If signing or provenance generation fails, the release
  is *blocked* — wrangle never ships an unsigned or unattested artifact, because a missing
  guarantee is indistinguishable from an attack.
- **Keyless signing.** Artifacts are signed with [Sigstore](https://www.sigstore.dev/) using
  your GitHub Actions identity — there are no signing keys for you to manage or leak.
- **Verifiable provenance.** The provenance ties each artifact back to the exact workflow that
  built it, and the VSA lets downstream users confirm that without trusting you blindly.
- **Least privilege, job by job.** There is no workflow-wide permission grant. Each job inside a
  reusable workflow declares its own minimal `permissions:` block, so the scan and test jobs run
  read-only while only the publish, sign, and attest jobs hold write or token scopes
  (`contents: write`, `packages: write`, `id-token: write`, `attestations: write`) — and only for
  the length of that one job. GitHub enforces the ceiling too: a called job can narrow the
  caller's grant but never widen it.

You don't have to be a security expert to get these properties; adopting wrangle is how you get
them.

## Ecosystems

Go, Python, npm, and Container each run the full pipeline and produce a signed, verifiable artifact; Shell and source-only run the checks only. Pick the row matching your project:

| Ecosystem | README | Example |
|-----------|--------|---------|
| Go — uses your `.goreleaser.yml` | [README](build/actions/go/README.md) | [build_go.yml](gh_workflow_examples/build_go.yml) with example goreleaser configs in [pure-Go](gh_workflow_examples/build_go.goreleaser.yml) or [cgo cross-compile](gh_workflow_examples/build_go_cgo.goreleaser.yml) |
| Python — uv or pip, auto-detected | [README](build/actions/python/README.md) | [build_python.yml](gh_workflow_examples/build_python.yml) |
| npm — npm or pnpm, auto-detected | [README](build/actions/npm/README.md) | [build_npm.yml](gh_workflow_examples/build_npm.yml) |
| Container | [README](build/actions/container/README.md) | [build_and_publish_containers.yml](gh_workflow_examples/build_and_publish_containers.yml) |
| Shell | — | [build_shell.yml](gh_workflow_examples/build_shell.yml) |
| Source-only — no build, scan only | [README](actions/scan/README.md) | [check_source_change.yml](gh_workflow_examples/check_source_change.yml) |
