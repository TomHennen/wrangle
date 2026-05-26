# Wrangle Build Go

**Wrangle wraps your existing `.goreleaser.yml`; it does not replace it.** Bring your goreleaser config; wrangle adds gofmt/vet/test/govulncheck, an SPDX SBOM, SLSA L3 provenance, and post-publish verification around it. Goreleaser publishes natively on tag push, so your Docker pushes, Homebrew taps, deb/rpm/snap, and announcements all keep working — wrangle attaches SLSA provenance to the GitHub Release shortly after.

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

## What the SLSA provenance covers (and what it doesn't)

Wrangle hashes the contents of goreleaser's `dist/checksums.txt` and hands those hashes to the SLSA generator. Anything in `checksums.txt` is a provenance subject; anything outside it is NOT — including artifacts goreleaser pushes to OCI registries, Homebrew taps, or chat webhooks.

| Goreleaser output | Covered by wrangle's SLSA provenance? |
|---|---|
| Archives in `dist/` (tar.gz, zip) | **Yes** — hashed via `checksums.txt` |
| `dist/checksums.txt` itself | Yes (file-level integrity, distinct subject) |
| deb / rpm / apk / snap packages in `dist/` | **Yes**, when goreleaser includes them in `checksums.txt` (its default) |
| Docker images pushed by goreleaser | **No** — wrangle does not attest registry-side image artifacts; pair with wrangle's container build type for those |
| Homebrew formula updates (tap-repo commits) | **No** — those are commits in a separate repo, outside `checksums.txt` |
| GitHub Release notes / announcements | **No** — informational, not signed |

If your release ships Docker images alongside binaries and you need provenance for both, plan to call wrangle's container build type for the image and `build_and_publish_go.yml` for the binaries in the same workflow.

## "Publish first, attest second" — the timing model

Goreleaser publishes the release inline (creates the GitHub Release, uploads archives, runs Docker pushes / Homebrew taps / announcements). The SLSA generator's `upload-assets` job appends the provenance file to that release shortly after — typically 30s-2min later. Same shape as wrangle's container build type (`docker push` first, attestation second).

**This is fine — because the SLSA contract is "consumer runs the verifier," not "consumer trusts that a provenance file exists."** A security-aware consumer always runs `slsa-verifier verify-artifact` (or equivalent) against the bytes they downloaded. They don't trust the presence of an `.intoto.jsonl`; they trust the result of verifying it.

Two consequences worth knowing:

- A consumer downloading during the gap sees archives without the provenance file. If they run verify, they get "no provenance found" → they should treat the artifact as untrusted and retry later. If they download without running verify, they've already opted out of SLSA's guarantees.
- A consumer downloading after the provenance lands runs verify and gets a confirmed chain.
- A consumer downloading after a wrangle-side verify failure (e.g., a tooling regression that produced provenance whose hashes don't match the artifacts) runs verify and gets "verification failed" → they reject the artifact. The fact that the broken provenance is technically on the release does no harm; verify is what's load-bearing.

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

`release-events` (default: `tag-only`) governs **which events run wrangle's full pipeline** (build, tests, SBOM, provenance). It does NOT control publish directly — publish happens whenever you push a tag (`gh release create` requires one). The interaction:

| Setting | Tag push behavior | Non-tag push (e.g. main) | PR build |
|---|---|---|---|
| `tag-only` (default) | Full pipeline + publish | Workflow doesn't run | Workflow doesn't run |
| `non-pull-request` | Full pipeline + publish | Full pipeline, no publish (snapshot mode) | Workflow doesn't run |
| `main-and-tags` | Full pipeline + publish | Full pipeline on `main`, no publish (snapshot mode) | Workflow doesn't run |

For most adopters: **`tag-only` is the cheapest setting** (workflow runs only when it would do something meaningful). Use `non-pull-request` if you want main/dispatch builds to exercise the pipeline for early failure-detection (at the cost of a snapshot goreleaser run on every push).

```yaml
uses: TomHennen/wrangle/.github/workflows/build_and_publish_go.yml@v0.2.0
with:
  path: "."
  release-events: tag-only
```

Full vocabulary in [`docs/SPEC.md`](../../../docs/SPEC.md) "Release-events gating."

## Overriding the govulncheck version

`govulncheck-version` (default: empty -> wrangle's vetted pin) lets you opt into a newer `govulncheck` ahead of wrangle's bump cycle. The intended use case is a CVE response: upstream `govulncheck` ships a fix or a new reachability check, you want the newer scanner *now*, and wrangle's 7-day adoption window hasn't closed yet. Pass a pinned semver:

```yaml
uses: TomHennen/wrangle/.github/workflows/build_and_publish_go.yml@v0.2.0
with:
  path: "."
  govulncheck-version: "v1.1.5"   # newer than wrangle's pin; pinned literally
```

Wrangle accepts only pinned versions — `latest` and `main` are not permitted (and would be rejected by `go install`'s module spec parser regardless). Omitting the input or passing `""` keeps wrangle's vetted default, which is the recommended setting for most adopters.

## SLSA provenance verification (wrangle-side, post-publish)

After goreleaser publishes, wrangle runs `slsa-verifier verify-artifact` against the just-built dist. This is wrangle dogfooding the same check downstream consumers will run — if it fails, consumers running verify will fail too, so the artifact is effectively rejected at the security-aware-consumer layer regardless of whether bad provenance landed on the release. (See "Publish first, attest second" above for why presence ≠ trust in the SLSA model.)

A wrangle-side verify failure surfaces a tooling regression (hash mismatch between what the generator signed and what goreleaser uploaded) loudly in CI. To opt out (e.g., custom verification flow): `verify-provenance: false`.

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
