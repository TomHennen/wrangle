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

- **Provenance builder identity is the SLSA generator's — and for npm/go/python it names where the *provenance* was created, not where the *build* ran.** The L3 provenance `builder.id` is `slsa-framework/slsa-github-generator/…`. For **containers** that's accurate: the container generator builds the image in its own isolated workflow. For **npm/go/python**, *wrangle's* reusable workflow runs the real build (`npm pack`, `goreleaser`, `python -m build`) and hands the artifact hashes to the *generic* generator, which only signs the provenance — so `builder.id` is the prov-signer, not the builder. The generator's keyless identity (enforced by the policy's `common.identities`) and the provenance `build-point` bind the *source repo* and *that a genuine generator signed it*, but **not which workflow in that repo built the artifact** — so the provenance alone can't prove the build went through wrangle's hardened workflow rather than some other (or compromised) workflow in the same repo handing its own hashes to the generic generator. Surfacing wrangle as the builder cleanly needs upstream "bring your own builder." Tracking: [#295](https://github.com/TomHennen/wrangle/issues/295).
- **The verifiable "wrangle built + verified this" anchor is the VSA's signing certificate — not the `builder.id` or `verifier.id` fields.** The VSA `verifier.id` is `https://carabiner.dev/ampel@v1` (the ampel engine, hard-coded), and (above) `builder.id` is the generator. Neither names wrangle. But the VSA is keyless-signed by *wrangle's* reusable workflow (`…/TomHennen/wrangle/.github/workflows/build_and_publish_<type>.yml@…`) in the same run that built the artifact — so a consumer's `cosign verify-blob-attestation` against that signing identity (see each build-type README) is what ties the artifact to wrangle's hardened build+verify, closing the gap above for npm/go/python. Pin wrangle's workflow path, not the engine and not your own repo. Tracking: [#295](https://github.com/TomHennen/wrangle/issues/295).
- **The VSA is provenance-only.** It attests the three SLSA build-provenance tenets (builder, build type, build point) and nothing else yet; SBOM / OSV / Scorecard results are folded in only once they're produced as signed attestations from a registered identity. Tracking: [#247](https://github.com/TomHennen/wrangle/issues/247).

Worked examples with the actual field values — and a visual audit of real provenance/VSAs — are tracked in [#200](https://github.com/TomHennen/wrangle/issues/200) and [#312](https://github.com/TomHennen/wrangle/issues/312).

## Pieces

- [Workflow examples](gh_workflow_examples/README.md) — copy-paste starting points
- [Reusable workflows](.github/workflows/) — what adopters call via `uses:`
- [Source scan action](actions/scan/README.md) — OSV, Zizmor, Scorecard, dependency-review orchestration
- [Build actions](build/) — npm, python, container, shell
- [Tools](tools/) — per-tool adapters and install scripts (OSV, Zizmor, Scorecard, Syft, dependency-review)
- [Spec](docs/SPEC.md) — architecture, contracts, threat model
