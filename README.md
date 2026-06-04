# wrangle

A composable CI/CD security framework for GitHub Actions. Adopters reference wrangle's reusable workflows and get source scanning, signed builds, SBOMs, and SLSA L3 provenance out of the box. Maintainers update the underlying tooling without adopters touching their repos.

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

## Attestation trust gaps (current)

wrangle emits real, signed SLSA provenance and VSAs today — but two identity fields don't yet name *wrangle* the way we want, and the VSA's policy coverage is deliberately narrow. These are known and tracked; we surface them here so adopters and consumers aren't surprised:

- **Provenance `builder.id` is the SLSA generator's, not wrangle's.** For npm/go/python, *wrangle's* reusable workflow runs the build and the *generic* generator only signs the provenance — so `builder.id` names the prov-signer, and the provenance binds the source repo but **not which workflow built the artifact** (a hole an attacker could exploit by handing the generic generator their own hashes — see [`docs/SPEC.md`](docs/SPEC.md)). Containers differ: the container generator isolates the build. Tracking: [#316](https://github.com/TomHennen/wrangle/issues/316).
- **The verifiable "wrangle did this" anchor is the VSA's signing certificate** — not `builder.id` (the generator) or `verifier.id` (`carabiner.dev/ampel@v1`, the engine); neither names wrangle. The VSA is keyless-signed by *wrangle's* reusable workflow, so verify **that** identity (per each build-type README; `slsa-verifier verify-vsa` can't — it's key-signed-only). Tracking: [#317](https://github.com/TomHennen/wrangle/issues/317).
- **The VSA is provenance-only.** It attests the three SLSA build-provenance tenets (builder, build type, build point) and nothing else yet; SBOM / OSV / Scorecard results are folded in only once they're produced as signed attestations from a registered identity. Tracking: [#247](https://github.com/TomHennen/wrangle/issues/247).

Worked examples with the actual field values — and a visual audit of real provenance/VSAs — are tracked in [#200](https://github.com/TomHennen/wrangle/issues/200) and [#312](https://github.com/TomHennen/wrangle/issues/312).

## Pieces

- [Workflow examples](gh_workflow_examples/README.md) — copy-paste starting points
- [Reusable workflows](.github/workflows/) — what adopters call via `uses:`
- [Source scan action](actions/scan/README.md) — OSV, Zizmor, Scorecard, dependency-review orchestration
- [Build actions](build/) — npm, python, container, shell
- [Tools](tools/) — per-tool adapters and install scripts (OSV, Zizmor, Scorecard, Syft, dependency-review)
- [Spec](docs/SPEC.md) — architecture, contracts, threat model
