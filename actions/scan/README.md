# Wrangle Source Scan

Run wrangle's bundled source-stage security scanners (OSV-Scanner, Zizmor, Scorecard, Dependency Review) against your repo on every PR and on push to main. The companion to wrangle's build/publish reusable workflows: build/publish hardens *how* your artifact is produced; source scan covers *what was checked into the repo you're building from*.

> **Note:** This README documents currently-shipped behavior. For the design and adoption philosophy, see [`../../docs/SPEC.md`](../../docs/SPEC.md).

## Why pair this with a build/publish workflow

Wrangle's build/publish workflows produce signed SLSA L3 provenance over the bytes they ship. That provenance attests *how* the build happened — but it does not attest that the source was trustworthy. The May 2026 Mini Shai-Hulud compromise of TanStack/router illustrates the gap: a `pull_request_target` workflow with checkout of PR-head SHA let attacker code execute in the privileged base context, poison the GitHub Actions cache, and pollute legitimate downstream builds with malicious modules. The build was honest; the attestation was honest; the source side was the gap.

This scan composite closes that gap on every PR and push to main:

- **[OSV-Scanner](https://github.com/google/osv-scanner)** against your lockfiles. Catches known-vulnerable dependencies before they ship.
- **[Zizmor](https://github.com/woodruffw/zizmor)** static analysis over `.github/workflows/`. Flags dangerous-trigger patterns like the `pull_request_target` + fork-head checkout combination that initiated Mini Shai-Hulud, plus expression injection, unpinned actions, and other known workflow footguns.
- **[Scorecard](https://github.com/ossf/scorecard)** against your repo configuration. Surfaces missing branch protection, code-review requirements, signed-commits, and similar repo-config gaps.
- **[Dependency Review](https://github.com/actions/dependency-review-action)** on PRs that touch lockfiles. Blocks a merge when the PR introduces a known-vulnerable dependency at or above the configured severity (default: `high`). Complements OSV — OSV is the periodic, whole-lockfile scan; dependency-review is the PR-time gate that fires only on what's being added.

Without source scan, an attacker who lands a malicious dep in your lockfile or introduces a dangerous workflow trigger can route around wrangle's build-side hardening — wrangle will then faithfully L3-sign the malicious output, because the build itself *was* legitimate.

## Quick-start (one workflow file)

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
    uses: TomHennen/wrangle/.github/workflows/check_source_change.yml@<version>
```

That's it. Findings appear in the Security tab; the workflow run's step summary shows a quick overview. Pair this with whichever build/publish workflow your project uses (npm, python, container, shell) for end-to-end coverage.

## Customizing which tools run

The `tools` input is a space-separated list. Default: `"osv zizmor scorecard:info dependency-review"`. Suffix a tool with `:info` to make its findings informational (non-blocking).

```yaml
uses: TomHennen/wrangle/.github/workflows/check_source_change.yml@<version>
with:
  tools: "osv zizmor"   # skip Scorecard and dependency-review
```

`dependency-review` only runs on `pull_request` events (the upstream action needs the PR diff). On `push` events it is silently skipped, the same way `scorecard` is silently skipped on PRs. The default severity threshold is `high`; tune it via the tool's wrapper inputs if you fork the action.

## What this composite does NOT do (yet)

- **Build-time vulnerability scanning of compiled dependencies.** OSV reads lockfiles, not installed `node_modules/`, installed wheels, or extracted container layers. Layered binary scanners (Trivy, Grype) against installed artifacts complement this and are out of wrangle's scope today.
- **Active remediation.** Findings are reported, not fixed. Dependabot-style auto-remediation is roadmap.
- **Source provenance attestations.** Coming via [#201](https://github.com/TomHennen/wrangle/issues/201) — integrating [slsa-framework/source-tool](https://github.com/slsa-framework/source-tool) into this same `check_source_change.yml` workflow so adopters keep their one workflow file and gain per-commit source provenance + SLSA Source Track conformance assessment.

## Roadmap

- **[#201](https://github.com/TomHennen/wrangle/issues/201)** — SLSA Source Track integration via `source-tool`. Per-commit source provenance attestations + level-aware status reporting in this same workflow.
- **[#194](https://github.com/TomHennen/wrangle/issues/194)** — npm-specific source-scan tools (ESLint, `tsc --noEmit`). (`dependency-review` already ships ecosystem-agnostic.)
- **[#203](https://github.com/TomHennen/wrangle/issues/203)** — Surface Scorecard findings as actionable remediations rather than informational warnings.
- **[#202](https://github.com/TomHennen/wrangle/issues/202)** — Refuse `pull_request_target` invocations in wrangle's reusable workflows as defense-in-depth alongside Zizmor's static check.

## Further reading

- [`../../docs/SPEC.md`](../../docs/SPEC.md) — wrangle's overall architecture.
- [`../../gh_workflow_examples/check_source_change.yml`](../../gh_workflow_examples/check_source_change.yml) — copy-paste starting point.
- [`./action.yml`](./action.yml) — the composite action this README documents.
