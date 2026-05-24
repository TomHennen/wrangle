# Wrangle Build Go

Build a Go project via [`goreleaser`](https://goreleaser.com/), run gofmt/vet/test/govulncheck, generate an SPDX SBOM, and produce SLSA provenance (Build L3) via `slsa-github-generator`. Goreleaser publishes natively on tag push, so adopters wire wrangle with a single `uses:` line and get back a GitHub Release with archives, checksums, SBOM, provenance, plus whatever Docker pushes / Homebrew taps / deb-rpm-snap / announcements their `.goreleaser.yml` configures.

> **Note:** This README documents *currently-shipped* behavior. For the full design — ecosystem-specific-builder-vs-generic-generator pick, cache isolation analysis, permissions architecture — see [`SPEC.md`](./SPEC.md).

## Quick-start

```yaml
# .github/workflows/build_go.yml
name: Go Build
on:
  push:
    tags: ["v*"]
  pull_request:
    branches: ["**"]
  workflow_dispatch:

jobs:
  build:
    permissions:
      contents: write   # goreleaser creates the Release + SLSA generator's upload-assets
      id-token: write   # OIDC for Sigstore signing
      actions: read     # SLSA generator detects the GA environment
    uses: TomHennen/wrangle/.github/workflows/build_and_publish_go.yml@v0.2.0
    with:
      path: "."
      release-events: tag-only
```

Full template with all inputs: [`gh_workflow_examples/build_go.yml`](../../../gh_workflow_examples/build_go.yml).

You also need a `.goreleaser.yml` at `<path>/.goreleaser.yml`. The wrangle-recommended minimum:

```yaml
# .goreleaser.yml
version: 2

builds:
  - main: ./cmd/<your-binary>
    flags: [-trimpath]         # strips local filesystem paths
    env:
      - -buildvcs=false        # don't embed VCS info (timestamps, dirty flag)

# checksums.txt is what wrangle base64-encodes for the SLSA generator —
# its filename is pinned by convention.
checksum:
  name_template: "checksums.txt"
```

Both `-trimpath` and `-buildvcs=false` are zero-cost reproducibility wins. `CGO_ENABLED=0` is **not** recommended as a default — cgo-backed `net`/`os/user` resolvers and many third-party crypto libraries link C — set it only if you specifically want pure-Go binaries. See [goreleaser customization docs](https://goreleaser.com/customization/) for the full schema.

## Recommended companion: source scan

This action hardens *how* your artifact is produced; it does NOT scan your source. Pair with wrangle's source-scan workflow ([`actions/scan/README.md`](../../../actions/scan/README.md)) to catch vulnerable deps, dangerous workflow triggers, and missing branch protection — issues wrangle would otherwise faithfully L3-attest as legitimately built.

Source-stage `gofmt` / `golangci-lint` is tracked in [#194](https://github.com/TomHennen/wrangle/issues/194). Until that lands, the build action's `checks` composite runs `gofmt -l` (with generated-file auto-skip) and `go vet ./...` as cheap toolchain-bundled gates. When #194 ships, those gates move to source-scan and the duplicate inside the build action goes away.

## Build Track level

Consumed through wrangle's reusable workflow (`build_and_publish_go.yml`), the Go build targets **SLSA v1.2 Build L3**. Two conditions narrow it:

- **Reusable consumption only.** Calling the `build/actions/go/*` composites directly from a workflow you author yourself forfeits the build-vs-sign job separation and is **not** a supported L3 path.
- **GitHub-hosted runners only.** Self-hosted runners invalidate the build-environment isolation the L3 verdict assumes.

Release builds run with `actions/setup-go`'s `cache: false` so the bytes the SLSA generator signs derive without consulting any shared, cross-build Go module/build cache — Go's build cache trusts pre-derived compiled output keyed by source fingerprint, the same shape as the uv-cache gap [`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) Finding 1 already calls out. PR builds keep the cache for fast iteration; they produce no provenance.

## Permissions architecture

The build is split into two jobs in the reusable workflow:

- `checks` (`contents: read`) — runs `gofmt`, `go vet`, `go test`, `govulncheck`. `go test` executes arbitrary adopter test code; denying it `contents: write` is real defense-in-depth.
- `release` (`contents: write`) — runs `goreleaser` (which publishes inline on tag pushes), syft, and hash computation.

A failed `checks` job blocks `release` via `needs:` propagation — quality gates always run before any bytes ship.

Cost: ~30s extra latency for the second checkout + setup-go. Benefit: a compromised dependency or hostile test cannot use `$GITHUB_TOKEN` to push to the repo. The split applies only to the supported reusable-workflow path; direct composite consumption forfeits this isolation and is not an L3 path.

## Outputs from the reusable workflow

| Output | What it is |
|---|---|
| `dist-artifact-name` | Workflow-artifact name for the goreleaser-produced `dist/` contents (binaries, archives, `checksums.txt`). |
| `provenance-artifact-name` | SLSA provenance file (empty when `should-release` is false). Format: `go-<shortname>.intoto.jsonl`. |
| `metadata-artifact-name` | SBOM artifact: `go-metadata-<shortname>`. Contents: `sbom.spdx.json`. |
| `checks-metadata-artifact-name` | govulncheck output: `go-checks-metadata-<shortname>`. Contents: `govulncheck.json` (informational findings). |
| `should-release` | `"true"` if the event matches `release-events`. |
| `hashes`, `version` | |

`<shortname>` is path-derived: `.` becomes `_`, `cmd/foo` becomes `cmd_foo`.

## Controlling when releases happen

`release-events` (default: `non-pull-request`) controls which events mint SLSA provenance. Goreleaser publishes *only* on tag pushes (`gh release create` requires a tag) — so `release-events: tag-only` and `release-events: non-pull-request` yield the same publish behavior; the difference is whether the workflow runs at all on non-tag non-PR events (where it builds in `--snapshot` mode without uploading anything).

```yaml
uses: TomHennen/wrangle/.github/workflows/build_and_publish_go.yml@v0.2.0
with:
  path: "."
  release-events: tag-only
```

Full vocabulary in [`docs/SPEC.md`](../../../docs/SPEC.md) "Release-events gating."

## SLSA provenance verification (post-publish, informational)

Wrangle's reusable workflow generates SLSA L3 provenance via `slsa-github-generator` and runs `slsa-verifier verify-artifact` after goreleaser publishes.

**Verify is informational, not a gate.** Goreleaser has already created the release by the time verify runs — a failure does not retract the released artifacts. What verify catches is a tooling regression: a hash mismatch between the bytes the generator signed and the bytes goreleaser put on the release would surface here loudly. To opt out (e.g., custom verification flow): `verify-provenance: false`.

The small "naked window" between goreleaser's publish and the provenance arriving is the same trade wrangle's container build type makes. Hashes are content-addressed, so any consumer who downloads in the window can verify once the attestation lands.

### Verifying after install (downstream consumers)

```bash
# Download binary + provenance from your GitHub release
curl -LO "https://github.com/<owner>/<repo>/releases/download/<tag>/<binary>-<version>-linux-amd64.tar.gz"
curl -LO "https://github.com/<owner>/<repo>/releases/download/<tag>/go-<shortname>.intoto.jsonl"

# Install slsa-verifier (https://github.com/slsa-framework/slsa-verifier#installation)

slsa-verifier verify-artifact \
  --provenance-path go-<shortname>.intoto.jsonl \
  --source-uri "github.com/<owner>/<repo>" \
  <binary>-<version>-linux-amd64.tar.gz
```

Provenance is attached to the GitHub Release on tag pushes only. Non-tag events publish nothing — provenance lives only as a 90-day workflow artifact.

## Further reading

- [`SPEC.md`](./SPEC.md) — this action's full specification
- [`../../../docs/SPEC.md`](../../../docs/SPEC.md) — wrangle's overall architecture
- [`../../../docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) — per-builder L3 conformance audit
- [`../../../actions/scan/README.md`](../../../actions/scan/README.md) — recommended source-scan companion
- [goreleaser customization](https://goreleaser.com/customization/) — the underlying build tool
- [SLSA generic generator](https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/generic/README.md)
- [govulncheck](https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck) — Go-aware callgraph vuln scanner
