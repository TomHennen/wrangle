# wrangle

> [!WARNING]
> Wrangle is **experimental**. Interfaces, policies, and security guarantees are still settling, and the code hasn't had independent security review — don't rely on it to protect anything important yet. Kick the tires, file issues, but keep your existing protections in place.

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
* [SLSA Build Level 3 provenance](docs/slsa-conformance.md) — per build type, mapped to evidence
* Build provenance verified against SLSA policy (fail-closed) with [Ampel](https://github.com/carabiner-dev/ampel)
* A [SLSA VSA](https://slsa.dev/verification_summary/v1) letting downstream users easily verify the artifacts you distribute.
* and more

The promise is that if developers use wrangle, wrangle will take care of drudgery, safely,
and let developers focus on the features they want to ship.

## What wrangle is proving

Wrangle's goal is to **prove it's possible** to hand a developer one workflow call and give
back a hardened, fail-closed, *verifiable* supply chain — SLSA Build L3 provenance and a signed
VSA included — without asking them to understand or assemble any of it. The list above is the
bet; [`docs/slsa-conformance.md`](docs/slsa-conformance.md) is the receipts (which build types
meet which level, with evidence); the warning at the top is the honest status — it works and
wrangle dogfoods it, but it hasn't had an independent security review.

Two things fall out of building it this way:

- **You stop having to know what you're supposed to do.** Wrangle makes the choices — which
  tools, which gates, safe defaults — and ships them as one versioned unit. As the landscape
  moves and wrangle adds protections, you pick them up by bumping a pin; you don't have to
  discover that you needed them.
- **It shrinks what an automated agent can get wrong.** When an AI agent wires your release, a
  dozen hand-assembled security steps are a dozen things to misconfigure. One fail-closed call
  is far less surface — and the result is *independently verifiable* (the VSA), no matter how
  the agent behaved.

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
    uses: TomHennen/wrangle/.github/workflows/build_and_publish_go.yml@1448b250fb8d75841dfba3b2c8f5c23e85162b89 # v0.2.0
    with:
      path: "."
```

Once they've done this they'll get tests executed, vuln scanning, attestations, etc.

Developers should also enable Dependabot.  Wrangle can't do that for you unfortunately,
but we can make it easier.  Copy
[`gh_workflow_examples/dependabot.yml`](gh_workflow_examples/dependabot.yml) to
`.github/dependabot.yml` (and customize as needed for your ecosystem).

Once in place it will create a PR whenever a dependency (including Wrangle!) needs to
be updated.

## How Wrangle Works

Behind that one workflow call, wrangle runs your code through a pipeline of well-known security
and supply-chain tools so you don't have to wire them up, configure them, or keep them current
yourself.

### The pipeline

A run typically moves through these stages:

1. **Scan the source** - checks your dependencies for known vulnerabilities (OSV) and lints your
   GitHub Actions workflows for unsafe patterns (Zizmor).
2. **Run your tests** — runs your existing test suite.
3. **Build the artifact** — compiles/packages your project using safe defaults for your
   ecosystem
4. **Describe what's inside** — generates an SBOM for the artifact.
5. **Attest** — produces Sigstore-signed SLSA provenance tying the artifact to the
   workflow that built it.
6. **Verify before shipping** — checks that provenance against a policy and emits a VSA so the
   people who consume your artifact can verify it with a single command.

Source-only and shell projects run the checks without producing a published artifact; the other
ecosystems run the whole pipeline. 

### Security

Wrangle is a supply-chain security tool, so its defaults lean toward safety:

- **Fail-closed on security guarantees.** A load-bearing source-scan finding (OSV, Zizmor) blocks
  the build *before* anything is published. For build types that publish inline (Go, container), a
  failed attestation or policy check fails the run after the push rather than rolling it back — so
  the guarantee consumers rely on is that a bad artifact carries no PASSED VSA, not that it never
  appeared. The [conformance map](docs/slsa-conformance.md) has the per-build-type timing.
- **Dangerous triggers: blocked where it can, flagged everywhere else.** Wrangle refuses to run its
  own workflows under `pull_request_target` (and `workflow_run` chained from it), and its source
  scan runs Zizmor across *all* your workflows to flag that pattern wherever else it appears — it
  can surface a risky trigger in a workflow it doesn't control, even though only you can remove it.
- **Keyless signing.** Attestations are signed with [Sigstore](https://www.sigstore.dev/) using
  Wrangle's identity combined with your repo's identity.
- **Verifiable provenance.** The provenance ties each artifact back to the exact workflow that
  built it, and the SLSA VSA lets downstream users confirm that without trusting you blindly.
- **Least privilege, job by job.** Each job inside a reusable workflow declares its own minimal
  `permissions:` block, so the scan and test jobs run read-only while only the publish, sign,
  and attest jobs hold write or token scopes (`contents: write`, `packages: write`,
  `id-token: write`, `attestations: write`) — and only for the length of that one job.

## Ecosystems

Go, Python, npm, and Container each run the full pipeline and produce an attested, verifiable artifact; Shell and source-only run the checks only. Pick the row matching your project:

| Ecosystem | README | Example |
|-----------|--------|---------|
| Go — uses your `.goreleaser.yml` | [README](build/actions/go/README.md) | [build_go.yml](gh_workflow_examples/build_go.yml) with example goreleaser configs in [pure-Go](gh_workflow_examples/build_go.goreleaser.yml) or [cgo cross-compile](gh_workflow_examples/build_go_cgo.goreleaser.yml) |
| Python — uv or pip, auto-detected | [README](build/actions/python/README.md) | [build_python.yml](gh_workflow_examples/build_python.yml) |
| npm — npm or pnpm, auto-detected | [README](build/actions/npm/README.md) | [build_npm.yml](gh_workflow_examples/build_npm.yml) |
| Container | [README](build/actions/container/README.md) | [build_and_publish_containers.yml](gh_workflow_examples/build_and_publish_containers.yml) |
| Shell | — | [build_shell.yml](gh_workflow_examples/build_shell.yml) |
| Source-only — no build, scan only | [README](actions/scan/README.md) | [check_source_change.yml](gh_workflow_examples/check_source_change.yml) |

## FAQ

How to pin wrangle (by SHA, and why zizmor wants it that way), whether you can
use a tag, and how verification ties to your pin: see [docs/FAQ.md](docs/FAQ.md).
