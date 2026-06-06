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

wrangle emits real, signed SLSA provenance and VSAs today. The headline build-confusion gap — provenance `builder.id` naming the generator rather than wrangle — is now **closed** (#316); what remains is a consumer-facing anchor nuance and the VSA's deliberately narrow policy coverage. These are known and tracked; we surface them here so adopters and consumers aren't surprised:

- **✅ Resolved ([#316](https://github.com/TomHennen/wrangle/issues/316)) — provenance `builder.id` now names wrangle's build workflow.** Previously the *generic* slsa-github-generator only signed the provenance, so `builder.id` named the prov-signer and bound the source repo but **not which workflow built the artifact** (a hole an attacker could exploit by handing the generic generator their own hashes). wrangle now produces its SLSA L3 provenance with `actions/attest-build-provenance` run *inside* each reusable build workflow, so `builder.id` and the Sigstore signing certificate both resolve to that workflow (`build_and_publish_<type>.yml`) — verified in-run, fail-closed, against the signer identity. The slsa-github-generator path has been dropped and the VSA PolicySets rebaselined onto wrangle's identity.
- **The verifiable "wrangle did this" anchor is the VSA's signing certificate** — the single signed attestation a consumer trusts, keyless-signed by *wrangle's* reusable workflow, so verify **that** identity (per each build-type README; `slsa-verifier verify-vsa` can't — it's key-signed-only). The provenance's `builder.id` now also names that workflow, but reading it means fetching and verifying the provenance; the VSA cert is the one identity to pin. (`verifier.id`, `carabiner.dev/ampel@v1`, is the engine, not wrangle.) Tracking: [#317](https://github.com/TomHennen/wrangle/issues/317).
- **The VSA is provenance-only.** It attests the three SLSA build-provenance tenets (builder, build type, build point) and nothing else yet; SBOM / OSV / Scorecard results are folded in only once they're produced as signed attestations from a registered identity. Tracking: [#247](https://github.com/TomHennen/wrangle/issues/247).
- **The one-command `ampel verify` consumer path doesn't bind the origin repo.** It checks the VSA's signer (wrangle's reusable workflow) + predicate fields, but ampel (v1.2.1) matches only the signing cert's issuer + SAN — not the source-repository extension — so it does not assert *which repo* built the artifact. The `cosign verify-blob-attestation` path does, via `--certificate-github-workflow-repository`. Tracking: [#321](https://github.com/TomHennen/wrangle/issues/321).

Worked examples with the actual field values — and a visual audit of real provenance/VSAs — are tracked in [#200](https://github.com/TomHennen/wrangle/issues/200) and [#312](https://github.com/TomHennen/wrangle/issues/312).

## Pieces

- [Workflow examples](gh_workflow_examples/README.md) — copy-paste starting points
- [Reusable workflows](.github/workflows/) — what adopters call via `uses:`
- [Source scan action](actions/scan/README.md) — OSV, Zizmor, Scorecard, dependency-review orchestration
- [Build actions](build/) — npm, python, container, shell
- [Tools](tools/) — per-tool adapters and install scripts (OSV, Zizmor, Scorecard, Syft, dependency-review)
- [Spec](docs/SPEC.md) — architecture, contracts, threat model
