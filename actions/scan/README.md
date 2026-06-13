# Wrangle Source Scan

Runs OSV-Scanner, Zizmor, Scorecard, and Dependency Review against your repo on every PR and push to main. Catches vulnerable dependencies, workflow-config mistakes, and supply-chain gaps before they merge. As wrangle adds source-side tools over time, adopters pick them up automatically by bumping the version pin — no per-tool wiring in your repo.

Wrangle's `build_and_publish_*` workflows embed this scan (via their `scan-tools` input), so adopters with a wrangle build type get it automatically. The standalone workflow below is for repos with no wrangle build type.

## Quick-start

Copy [`../../gh_workflow_examples/check_source_change.yml`](../../gh_workflow_examples/check_source_change.yml) into your repo at `.github/workflows/check_source_change.yml`:

```yaml
name: Check Source Change
on:
  push:
    branches: ["main"]
  pull_request:
    branches: ["**"]
  workflow_dispatch:

jobs:
  check-change:
    permissions:
      actions: read
      contents: read
      security-events: write   # SARIF upload to the Security tab
    uses: TomHennen/wrangle/.github/workflows/check_source_change.yml@v0.2.0
```

Findings appear in the Security tab; the run's step summary shows an overview.

## What runs

- **[OSV-Scanner](https://github.com/google/osv-scanner)** — known-vulnerable dependencies in your lockfiles.
- **[Zizmor](https://github.com/woodruffw/zizmor)** — static analysis over `.github/workflows/`. Flags dangerous triggers (`pull_request_target` + fork-head checkout), expression injection, unpinned actions.
- **[Scorecard](https://github.com/ossf/scorecard)** — repo-config gaps (branch protection, code review, signed commits).
- **[Dependency Review](https://github.com/actions/dependency-review-action)** — PR-time gate on lockfile changes. Blocks the merge when a PR adds a vulnerable dep at the configured severity (default `high`). Complements OSV: OSV is the periodic whole-lockfile scan; dependency-review fires only on what's being added.

## Why source scanning matters

Source scan catches two distinct classes of problem the build side can't see:

- **Honest mistakes that ship anyway.** A vulnerable dep in your lockfile, a `pull_request_target` workflow that grants too much, a missing branch-protection rule — wrangle's build path will faithfully L3-sign whatever you point it at, including code that introduced these issues by accident. Source scan flags them at PR time, before they reach a release.
- **Deliberate attacks the build side authenticates as legitimate.** Wrangle's build workflows produce signed SLSA L3 provenance over the bytes they ship — that attests *how* the build ran, not whether the source was trustworthy. Without source scan, an attacker who lands a malicious dep or a dangerous workflow trigger routes around the build-side hardening, and wrangle will L3-sign the malicious output because the build itself *was* legitimate.

The May 2026 Mini Shai-Hulud compromise of TanStack/router is the canonical example of the second case: a `pull_request_target` workflow with checkout of PR-head SHA let attacker code execute in the privileged base context, poison the GitHub Actions cache, and pollute legitimate downstream builds. The build was honest; the source side was the gap.

## Customizing which tools run

The `tools` input is a space-separated list. Default: `"osv zizmor scorecard:info dependency-review"`. Suffix with `:info` to make a tool's findings non-blocking.

```yaml
uses: TomHennen/wrangle/.github/workflows/check_source_change.yml@v0.2.0
with:
  tools: "osv zizmor"   # skip Scorecard and dependency-review
```

`dependency-review` only runs on `pull_request` events (the upstream action needs the PR diff); on `push` it is silently skipped, the same way `scorecard` is skipped on PRs. Per-tool configuration is not yet exposed — see [#221](https://github.com/TomHennen/wrangle/issues/221).

## Out of scope (today)

- **Build-time scanning of installed dependencies.** OSV reads lockfiles, not installed `node_modules/`, wheels, or extracted container layers. Layer binary scanners (Trivy, Grype) at install time if you need that.
- **Active remediation.** Findings are reported, not fixed.
- **Source provenance.** Coming via [#201](https://github.com/TomHennen/wrangle/issues/201) — SLSA Source Track integration in this same workflow.

## Roadmap

- [#201](https://github.com/TomHennen/wrangle/issues/201) — SLSA Source Track via `source-tool` (per-commit source provenance).
- [#194](https://github.com/TomHennen/wrangle/issues/194) — npm-specific tools (ESLint, `tsc --noEmit`).
- [#203](https://github.com/TomHennen/wrangle/issues/203) — Surface Scorecard findings as actionable remediations.
- [#202](https://github.com/TomHennen/wrangle/issues/202) — Block any workflow that invokes a wrangle reusable workflow from a `pull_request_target` trigger.

## Further reading

- [`../../docs/SPEC.md`](../../docs/SPEC.md) — architecture, contracts, threat model.
- [`./action.yml`](./action.yml) — the composite this README documents.
