# wrangle

> [!WARNING]
> Wrangle is an **experimental proof of concept**. Interfaces, policies, and security guarantees are still settling, and the code hasn't had independent security review — don't rely on it to protect anything important yet. Kick the tires, file issues, but keep your existing protections in place.

Developers want to ship features.  They'd like to do it securely but it's hard.  We ask too much of them:

* Remember to scan for vulns
* Remember not to use pull_request_target
* Remember to produce an SBOM
* Remember to update your dependencies
* ...

What if... we could do this for developers, so they don't need to remember?

Wrangle is a one-stop shop for GitHub Actions CI/CD.  Developers add **a single** job that
uses one of wrangle's reusable workflows.  With that single job developers get:

* Vulnerability scanning with [osv](https://github.com/google/osv-scanner)
* GitHub Action safety checks with [Zizmor](https://github.com/zizmorcore/zizmor)
* A check that your repo is configured for automatic dependency updates ([Dependabot](https://docs.github.com/code-security/dependabot)), behind a safety cooldown
* Automatic execution of unit tests
* Automatic builds with safe defaults
* [SBOMs](https://spdx.dev)
* [SLSA Build Level 3 provenance](docs/REQUIREMENTS_MAPPING.md) — per build type, mapped to evidence
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
    uses: TomHennen/wrangle/.github/workflows/build_and_publish_go.yml@v0.2.2 # zizmor: ignore[unpinned-uses] - immutable
    with:
      path: "."
```

Once they've done this they'll get tests executed, vuln scanning, attestations, etc.

Wrangle requires Dependabot so your dependencies and action pins keep updating automatically. It can't turn Dependabot on
for you, but it does check you've set it up: a missing config fails the source scan until you fix it (or suppress the
finding). Copy gh_workflow_examples/dependabot.yml to .github/dependabot.yml and tailor it to your ecosystem.

Once in place it will create a PR whenever a dependency (including Wrangle!) needs to
be updated.

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

## Where's my stuff?

Each build produces two workflow artifacts (zipfiles):

- **`<type>-dist-<sn>`** — your built product (wheels/sdist for python, the npm tarball, goreleaser's `dist/` for go). Container builds push the image to the registry instead.
- **`<type>-metadata-<sn>`** — the SBOM, the scan findings, and (on release runs) the SLSA provenance + signed VSA, all in one artifact. The [source-only scan workflow](actions/scan/README.md) uploads just `scan/` as `scan` (or `scan-<sn>` for a subdir).

The reusable workflow exposes both names as the `dist-artifact-name` and `metadata-artifact-name` outputs so you don't have to hardcode them. For the full file layout — and which `scan/` subdirs appear on a given event — see [docs/metadata_layout.md](docs/metadata_layout.md).

On a **tag push**, wrangle also attaches each dist `<artifact>` and its `<artifact>.intoto.jsonl` bundle (a flat verify-pair) plus one `<type>-metadata-<sn>.zip` holding the SBOM + scan results to the GitHub Release wrangle creates for you. Go's dist + `checksums.txt` come from goreleaser. See [docs/verifying_artifacts.md](docs/verifying_artifacts.md); suppress with the verify action's `attach-release-assets: false`.

To find them in the UI: click **Actions** → your wrangle workflow → the run → scroll to **Artifacts**. The URL looks like `https://github.com/<owner>/<repo>/actions/runs/<id>#artifacts`. For a live example, see a run in the [wrangle-test companion repo](https://github.com/TomHennen/wrangle-test/actions). Per-ecosystem details are in the [ecosystem READMEs](#ecosystems) above.

## How Wrangle Works

Behind that one workflow call, wrangle runs your code through a pipeline of well-known security
and supply-chain tools so you don't have to wire them up, configure them, or keep them current
yourself.

### The pipeline

A run typically moves through these stages:

1. **Scan the source** - checks your dependencies for known vulnerabilities (OSV), lints your
   GitHub Actions workflows for unsafe patterns (Zizmor), and checks your Dependabot config is
   set up so dependency and action updates land automatically, behind a safety cooldown.
2. **Run your tests** — runs your existing test suite.
3. **Build the artifact** — compiles/packages your project using safe defaults for your
   ecosystem
4. **Describe what's inside** — generates an SBOM for the artifact.
5. **Attest** — produces Sigstore-signed SLSA provenance and other attestations with your scan
   results tying the artifact to the workflow that built it and the scans that were done.
7. **Verify before shipping** — checks that provenance against a policy and emits a VSA so the
   people who consume your artifact can verify it with a single command.

Source-only and shell projects run the checks without producing a published artifact; the other
ecosystems run the whole pipeline. 

### Security

Wrangle is a supply-chain security tool, so its defaults lean toward safety:

- **Fail-closed on security guarantees.** A load-bearing scan finding blocks the build before
  publish; a failed attestation or policy check means no PASSED VSA is emitted for the artifact.
- **Keyless signing.** Attestations are signed with [Sigstore](https://www.sigstore.dev/) using
  Wrangle's identity combined with your repo's identity.
- **Verifiable provenance.** The provenance ties each artifact back to the exact workflow that
  built it, and the SLSA VSA lets downstream users confirm that without trusting you blindly.
- **Least privilege, job by job.** Each job inside a reusable workflow declares its own minimal
  `permissions:` block, so the scan and test jobs run read-only while only the publish, sign,
  and attest jobs hold write or token scopes (`contents: write`, `packages: write`,
  `id-token: write`, `attestations: write`) — and only for the length of that one job.

## FAQ

You can find answers to a number of questions in [the FAQ](docs/FAQ.md).
