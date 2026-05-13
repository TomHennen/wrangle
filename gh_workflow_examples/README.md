# Wrangle Workflow Examples

Starting points for adopting wrangle. Copy to `.github/workflows/` in your repo and customize the inputs (paths, image names, etc.) for your project.

**Recommended pattern:** pair *any* build/publish workflow below with `check_source_change.yml`. Build/publish hardens *how* your artifact is produced; the source-scan workflow covers *what was checked into the repo you're building from*. Without both, an attacker who lands a malicious dep or workflow misconfiguration routes around the build-side hardening — wrangle will still faithfully attest the result. See [`../actions/scan/README.md`](../actions/scan/README.md) for the full rationale.

## check_source_change.yml

Run OSV-Scanner, Zizmor, and Scorecard source scanning on every PR and push to main. **Adopt alongside whichever build/publish workflow below matches your project.** Roadmap: [#201](https://github.com/TomHennen/wrangle/issues/201) extends this with per-commit SLSA Source Track attestations via [slsa-framework/source-tool](https://github.com/slsa-framework/source-tool) — adoption stays a single workflow file.

## build_shell.yml

Run shellcheck and bats tests on shell projects.

## build_and_publish_containers.yml

Build, sign, and publish a container image with SBOM and SLSA L3 provenance.

## build_npm.yml

Build an npm package (`npm pack`), run tests, generate an SPDX SBOM, and produce SLSA L3 build provenance. Publishes to npmjs.org via Trusted Publishing (no `NPM_TOKEN`) — the publish job lives in the caller workflow because npm's Trusted Publishing OIDC token must come from the caller's workflow filename, not a reusable workflow. Adopters must bootstrap-publish v0.0.1 once manually and configure a [Trusted Publisher on npmjs.com](https://docs.npmjs.com/trusted-publishers/) before the first automated publish — see [`build/actions/npm/README.md`](/build/actions/npm/README.md) for the onboarding checklist.

## build_python.yml

Build a Python package (wheel + sdist), run pytest, generate an SPDX SBOM, and produce SLSA L3 build provenance. Optionally verify the provenance with `slsa-verifier` before publishing to PyPI via Trusted Publishing (no API tokens). Adopters must configure a [Trusted Publisher on PyPI](https://docs.pypi.org/trusted-publishers/) before the first publish — see [`build/actions/python/README.md`](/build/actions/python/README.md) for the onboarding checklist.
