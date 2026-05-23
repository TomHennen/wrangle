# Wrangle Build Go

Build a Go project via [`goreleaser`](https://goreleaser.com/), run gofmt/vet/test/govulncheck, generate an SBOM, produce SLSA provenance (Build L3) via `slsa-github-generator`, and publish to GitHub Releases — all in a single `uses:` line. Go has no language-level package registry with a caller-bound OIDC publish constraint (the way PyPI and npm Trusted Publishing have), so publish is owned by wrangle's reusable workflow rather than the adopter — your integration is one job, not two.

> **Note:** This README documents *currently-shipped* behavior. For the full design — three release shapes, the ecosystem-specific-builder-vs-generic-generator pick, cache isolation analysis — see [`SPEC.md`](./SPEC.md).

## Recommended companion: source scan

This action hardens *how* your artifact is produced. It does NOT scan your source — vulnerable deps in `go.sum`, dangerous workflow triggers, or missing branch protection still slip through and would be faithfully L3-attested by wrangle as legitimately built. Pair this with wrangle's source-scan workflow ([`actions/scan/README.md`](../../../actions/scan/README.md)) to close that gap on every PR and push.

Source-stage `gofmt` / `golangci-lint` integration is tracked in [#194](https://github.com/TomHennen/wrangle/issues/194). Until that lands, the Go build action runs `gofmt -l` (fail if non-empty) and `go vet ./...` as cheap toolchain-level gates inside the build job itself — they don't produce SARIF and don't fold into the unified metadata layout, but they prevent the egregious "wrangle let unformatted code ship" failure mode at zero extra dependency.

## Build Track level

Consumed through wrangle's reusable workflow (`build_and_publish_go.yml`), the Go build targets **SLSA v1.2 Build L3**. Two conditions narrow it:

- **Reusable consumption only.** Calling the `build/actions/go` composite directly from a workflow you author yourself forfeits the build-vs-sign job separation and is **not** a supported L3 path.
- **GitHub-hosted runners only.** Self-hosted runners invalidate the build-environment isolation the L3 verdict assumes.

The release-vs-PR cache asymmetry pattern applies: release builds run with `actions/setup-go`'s `cache: false` so the bytes the SLSA generator signs derive without consulting any shared, cross-build Go module/build cache. Go's build cache trusts pre-derived compiled output keyed by source fingerprint (structurally the same shape as the uv-cache L3 gap [`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) Finding 1 already calls out), so disabling it for release builds keeps the L3 isolation property intact. PR builds keep caching for fast iteration — they produce no provenance.

## Before first use

1. **Drop a `.goreleaser.yml` into your project root** (or the directory you set as `path:`). Wrangle does not ship a starter; bring your own per [goreleaser customization docs](https://goreleaser.com/customization/). At minimum, recommend setting:

   ```yaml
   builds:
     - flags: [-trimpath]      # strip local filesystem paths from the binary
       env: [-buildvcs=false]  # don't embed VCS info (timestamps, dirty flag)
   ```

   Both are zero-cost reproducibility wins. `CGO_ENABLED=0` is **not** recommended as a default — cgo-backed `net`/`os/user` resolvers and many third-party crypto libraries link C, and disabling cgo can cost real runtime performance. Set it only if you specifically want pure-Go binaries.

2. **Make sure your tag scheme is `v*`.** The example workflow triggers on `tags: ["v*"]`; goreleaser uses the tag name as the version.

3. **(Optional) Add a `LICENSE` file** if you don't already have one — goreleaser warns if absent.

## Quick-start

A single `uses:` line is the full integration. Publish is owned by wrangle's reusable workflow, so there's no caller-side publish job to wire (this differs from python and npm, which have caller-bound OIDC publish constraints).

```yaml
jobs:
  build:
    permissions:
      contents: write   # SLSA generator's upload-assets job (declared at startup) + publish job's gh release upload
      id-token: write   # OIDC for Sigstore signing
      actions: read     # SLSA generator detects the GitHub Actions environment
    uses: TomHennen/wrangle/.github/workflows/build_and_publish_go.yml@v0.2.0
    with:
      path: "."
      release-events: tag-only   # only tag pushes mint provenance and publish
```

See [`gh_workflow_examples/build_go.yml`](../../../gh_workflow_examples/build_go.yml) for the full template with triggers.

**Composite-action mode** (drop into an existing workflow; you wire your own provenance, verification, and publish — *not* a supported L3 path):

```yaml
- uses: TomHennen/wrangle/build/actions/go@v0.2.0
  with:
    path: "."
```

## What this action does

- Validates that `go.mod` and a `.goreleaser.yml` (or `.yaml`) are present in the project directory.
- Installs Go via `actions/setup-go`. Version resolution: the `go-version` input, then `go.mod`'s `go` directive (the wrangle-recommended path).
- Runs `gofmt -l .` — fails the build if any file is not gofmt-clean. Go's toolchain doesn't enforce formatting at `go build` time, so this gate is necessary until source-stage lint lands ([#194](https://github.com/TomHennen/wrangle/issues/194)).
- Runs `go vet ./...` — toolchain-bundled static checks (printf arg mismatches, shadowed vars, unreachable code, etc.).
- Runs `go test -race ./...` — full test suite with the race detector.
- Runs `govulncheck ./...` — callgraph-based reachable-vuln scan from `golang.org/x/vuln`. Pinned version, installed via `go install` (sum.golang.org-verified). JSON output written to `metadata/go/<shortname>/govulncheck.json`.
- Invokes goreleaser with `release --clean --skip=publish` (tag pushes) or `release --clean --snapshot --skip=publish` (non-tag events). `--skip=publish` is always set: wrangle's reusable workflow owns the GitHub Release upload, running AFTER verify, so the verify-before-publish invariant holds.
- Generates an SPDX SBOM via [`syft`](https://github.com/anchore/syft) (Cosign-keyless-verified install, same tool python and npm use) over the project source tree.
- Computes SHA-256 hashes of the goreleaser-produced artifacts by base64-encoding `dist/checksums.txt` directly (already `sha256sum`-format).

## Outputs from the reusable workflow

- `dist-artifact-name` — workflow-artifact name to download the goreleaser-produced binaries, archives, and `checksums.txt`.
- `provenance-artifact-name` — workflow-artifact name for the SLSA provenance (empty when `should-release` is false). Format: `go-<shortname>.intoto.jsonl` so multiple Go builds in one workflow don't collide on the same artifact name.
- `metadata-artifact-name` — workflow-artifact name for the SBOM and govulncheck JSON (`go-metadata-<shortname>`). See [`docs/SPEC.md`](../../../docs/SPEC.md) "Unified metadata layout."
- `should-release` — `"true"` if the current event matches `release-events`.
- `hashes`, `version`.

## Controlling when releases happen

The `release-events` input controls which events produce SLSA provenance and publish to GitHub Releases. The publish job is *additionally* gated on `startsWith(github.ref, 'refs/tags/')` — only tag pushes ever produce a GitHub Release (creating one off a non-tag ref wouldn't have a meaningful target).

```yaml
uses: TomHennen/wrangle/.github/workflows/build_and_publish_go.yml@v0.2.0
with:
  path: "."
  release-events: tag-only   # only tag pushes mint provenance and publish
```

`release-events` accepts: `non-pull-request` (default), `tag-only`, `main-and-tags`, or a comma-separated `github.event_name` list. See [`docs/SPEC.md`](../../../docs/SPEC.md) "Release-events gating" for the full vocabulary.

## SLSA provenance verification (default-on, opt-out)

Wrangle's reusable workflow generates non-falsifiable SLSA L3 build provenance via `slsa-github-generator`, **then verifies the just-built dist against that provenance** before publishing to the GitHub Release. If verification fails, the workflow fails and the publish job is blocked via standard `needs:` propagation — so a tampered dist between build and publish cannot reach a GitHub Release. To opt out (e.g., custom verification flow), pass `verify-provenance: false`.

## Verifying after install (downstream consumers)

Your binary's consumers verify with `slsa-verifier`:

```bash
# Download binary + provenance from your GitHub release
curl -LO "https://github.com/<owner>/<repo>/releases/download/<tag>/<binary>-<version>-linux-amd64.tar.gz"
curl -LO "https://github.com/<owner>/<repo>/releases/download/<tag>/go-<shortname>.intoto.jsonl"

# Install slsa-verifier (https://github.com/slsa-framework/slsa-verifier#installation)

# Verify
slsa-verifier verify-artifact \
  --provenance-path go-<shortname>.intoto.jsonl \
  --source-uri "github.com/<owner>/<repo>" \
  <binary>-<version>-linux-amd64.tar.gz
```

Provenance is attached to the GitHub Release on tag pushes (via wrangle's publish job). Non-tag events publish nothing — provenance lives only as a 90-day workflow artifact in that case.

## SBOM

The action writes an SPDX JSON SBOM to `metadata/go/<shortname>/sbom.spdx.json`, plus `govulncheck.json` for the vuln scan output. The reusable workflow zips them as `go-metadata-<shortname>` and exposes the name via the `metadata-artifact-name` output. Naming and layout follow the unified-metadata convention shared across every build type — see [`docs/SPEC.md`](../../../docs/SPEC.md) "Unified metadata layout."

`<shortname>` is the path-derived short name — `.` becomes `_`, `cmd/foo` becomes `cmd_foo`.

## Further reading

- [`SPEC.md`](./SPEC.md) — this action's full specification
- [`../../../docs/SPEC.md`](../../../docs/SPEC.md) — wrangle's overall architecture
- [`../../../docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) — the per-builder L3 conformance audit (Go entry tracked alongside the implementation)
- [`../../README.md`](../../README.md) — the build/ directory overview
- [`../../../actions/scan/README.md`](../../../actions/scan/README.md) — recommended source-scan companion
- [goreleaser customization](https://goreleaser.com/customization/) — the underlying build tool
- [SLSA generic generator](https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/generic/README.md)
- [govulncheck](https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck) — Go-aware callgraph vuln scanner
