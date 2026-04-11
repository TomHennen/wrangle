# Wrangle Build Container

A GitHub composite action that builds and publishes a container image to GitHub Container Registry (ghcr.io), generates and extracts an SBOM, and (when wired into the reusable workflow) signs the image with Cosign and attaches SLSA L3 provenance.

> **Note:** This README documents *currently-shipped* behavior. For the full design — including Cosign signing, SLSA L3 provenance, the release gate, failure contract, and trust model — see [`SPEC.md`](./SPEC.md). The spec is forward-looking; features described there but not yet implemented in `action.yml` will land in follow-up PRs, and this README will be updated in the same commit. The full structure this README must eventually cover (quick-start example, verification commands, failure runbook) is defined in [`SPEC.md` §"Required contents of `build/actions/container/README.md`"](./SPEC.md#required-contents-of-buildactionscontainerreadmemd).

## What this action does today

- Builds a Docker image from a Dockerfile at a caller-provided path
- Pushes the image to a container registry (ghcr.io supported; other registries are out of scope — see [`SPEC.md`](./SPEC.md#current-scope-ghcrio-only))
- Generates a BuildKit-native SBOM and attaches it to the image as an OCI attestation
- Extracts the SBOM in SPDX JSON format and uploads it as a workflow artifact
- Generates a step summary with the results

## Planned (per spec, not yet implemented)

- Cosign keyless signing of the pushed image digest
- SLSA L3 provenance via `slsa-github-generator` (the reusable workflow in `.github/workflows/build_and_publish_container.yml` is the entry point for this)
- SBOM vulnerability scanning with `osv-scanner` (non-blocking)
- The release gate job that enforces "image is signed AND attested before any downstream release job runs"

## SBOM

The action generates an SBOM for the container it builds. Today the SBOM is available two ways:

- As a workflow artifact (`container-build-results-<shortname>`), downloadable from the Actions run page or via `actions/download-artifact` in a downstream job
- Embedded in the OCI image manifest as a BuildKit attestation, retrievable from the image itself with `docker buildx imagetools inspect --format '{{ json .SBOM.SPDX }}' <image>@<digest>`

See [`SPEC.md` §"Where to find the SBOM"](./SPEC.md#where-to-find-the-sbom) for the full publication story (including the planned cosign SBOM attestation).

## Container vulnerability scanning

Per the failure contract in [`SPEC.md`](./SPEC.md#failure-contract), SBOM vulnerability scanning is **non-blocking**: findings are uploaded as SARIF and visible in the Security tab, but they do not fail the build. This is a deliberate design choice — vulnerability triage is a policy decision adopters own, and hard-blocking can itself become a release blocker when a fix needs to ship despite an unavoidable upstream CVE. See the spec for the full rationale.

![Wrangle Build Container Summary showing vulns found by OSV](/assets/images/osv_sbom_summary.png)

## Further reading

- [`SPEC.md`](./SPEC.md) — this action's full specification
- [`../../../docs/SPEC.md`](../../../docs/SPEC.md) — wrangle's overall architecture and build-type model
- [`../../README.md`](../../README.md) — the build/ directory overview
