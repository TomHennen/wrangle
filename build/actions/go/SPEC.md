# Wrangle Go Build Type — Phase 1 Research

**Status:** Phase 1 ecosystem research per [`docs/HOW_TO_ADD_A_BUILD_TYPE.md`](../../../docs/HOW_TO_ADD_A_BUILD_TYPE.md). Recommends defaults for an eventual `build/actions/go/` implementation. **No `action.yml` exists yet.** Inputs, outputs, and step sequence are sketched at the level needed to justify the picks; the implementation PR will tighten them.

## Overview

Go projects in 2026 fall into three release shapes:

1. **Binary releases.** A CI build produces one or more `os × arch` binaries, attaches them to a GitHub Release, and (for security-conscious projects) ships SLSA provenance, Cosign signatures, and SBOMs alongside. Examples: `slsa-verifier`, `cosign`, `oras`, `goreleaser` itself.
2. **Library-only modules.** No `main` package, no binary. Consumers fetch source via `go get` / `go install <module>@<version>`; integrity comes from Go's checksum database (`sum.golang.org`, a Trillian-backed Merkle log over `go.sum`-shaped lines — see the [Go module mirror launch announcement](https://go.dev/blog/module-mirror-launch) and [proposal 25530](https://go.googlesource.com/proposal/+/master/design/25530-sumdb.md)).
3. **`go install <repo>@<tag>` for CLI tools whose maintainers chose not to run a release pipeline.** Equivalent to (1) minus the build job; consumers compile from source on their own machines.

**Operating model.** Wrangle owns the build hygiene — test, SBOM, vulnscan, lint, gating, the unified metadata layout. The upstream SLSA generator owns the L3 provenance envelope. One attestation per artifact, not stacked. This is the same shape python and container ship today, and the picks below preserve it.

## Recommended defaults (the picks)

### Build tool — goreleaser for binary releases

**Pick:** [`goreleaser`](https://goreleaser.com/) for binary releases.

**Why:** It's the dominant ecosystem norm. One config-driven invocation handles the cross-compilation matrix (`builds.goos[]` × `builds.goarch[]`), archive packaging, `dist/checksums.txt`, GitHub Release upload, and (optionally) deb/rpm/apk/snap packaging — see [goreleaser customization docs](https://goreleaser.com/customization/) and the [supply-chain blog post](https://goreleaser.com/blog/supply-chain-security/). Used by `slsa-verifier`, `cosign`, `oras`, and many others. Detection rule for the action: `.goreleaser.yml` or `.goreleaser.yaml` present.

Plain `go build` is a viable fallback for single-binary, single-platform repos but offers nothing goreleaser doesn't, and the python build type's experience with a `setup.py`-only fallback that didn't actually work ([HOW_TO_ADD_A_BUILD_TYPE.md "Implement minimally before adding fallback paths"](../../../docs/HOW_TO_ADD_A_BUILD_TYPE.md)) cautions against shipping fallbacks before they're end-to-end tested. The first implementation should require goreleaser.

For repos with no binary at all, see "Validation-only sub-shape" below — wrangle still adds value there.

### SBOM — `syft`

**Pick:** [`syft`](https://github.com/anchore/syft), the same tool wrangle's python build type uses, with the same Cosign-keyless-verified install (`tools/syft/install.sh`).

**Why:** Reuses an existing wrangle-verified install, produces SPDX natively (matching wrangle's cross-build-type SPDX choice — see [`docs/SPEC.md`](../../../docs/SPEC.md) "Decisions to inherit"), and is the de-facto Go SBOM choice in the broader ecosystem. `cyclonedx-gomod` is an alternative with tighter Go-toolchain integration but produces CycloneDX; converting to SPDX is lossy. `goreleaser`'s `sboms:` block can also drive syft, but running syft directly (the way python does) keeps the SBOM step uniform across build types and survives a future move off goreleaser.

The stale `cyclonedx-gomod` reference in [`docs/docker_best_practices.md`](../../../docs/docker_best_practices.md) predates python's syft adoption and should be treated as informational, not a contract.

### Publish target — GitHub Releases

**Pick:** GitHub Releases. Goreleaser handles the upload natively given a `GITHUB_TOKEN` with `contents: write`.

**Why:** This is what `slsa-verifier`, `cosign`, `oras`, the goreleaser-example project, and goreleaser itself all do. There is no separate Go binary registry. `pkg.go.dev` is a documentation index that auto-discovers tagged versions from `proxy.golang.org` — no publish action, no token required for module consumers.

### Attestation — Pattern B (`generator_generic_slsa3.yml`)

**Pick:** Goreleaser produces `dist/checksums.txt`; wrangle hashes those filenames into base64-encoded subjects and hands them to `slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@v2.1.0`. This is the same shape wrangle's python build type uses today, and the same shape goreleaser themselves [document and demonstrate](https://goreleaser.com/blog/slsa-generation-for-your-artifacts/).

**Why this pick:**

- **Same shape as python and container.** The composite owns build/test/SBOM/lint and emits hashes; the SLSA generator runs in a separate reusable-workflow job consuming those hashes; the verify job re-fetches the artifact and runs `slsa-verifier verify-artifact`. Consistency keeps the per-build-type cognitive load low.
- **Preserves the test/SBOM/lint seam.** Wrangle's value-add steps slot between "build" and "provenance" the same way they do for python — the build action emits `dist/`, runs syft against it, runs gating, and then hands off. There's nowhere new to learn.
- **Same L3 isolation as Pattern A.** All wrangle reusable workflows already run the SLSA generator inside its own isolated reusable workflow. Both patterns get the L3 "hardened build platform" property by virtue of running through `slsa-github-generator`'s isolated builder; the previous version of this doc framed Pattern A as "stronger isolation" and that was wrong.
- **`actions/release_gate` works either way.** Wrangle gates the `uses:` invocation of the provenance reusable workflow with `if: ${{ needs.gate.outputs.should-release == 'true' }}`. That predicate-on-the-job-call pattern is build-type-agnostic.

**Cosign keyless signing of binaries — in scope.** Recommend `cosign sign-blob --yes` against each artifact, identity bound to the calling workflow's OIDC token. This matches what `cosign`, `goreleaser`, and many other Go binary publishers do, and it's the ecosystem norm for binary signatures (parallel to wrangle's container build type signing the image digest). Interface compatibility — verifiers reach for `cosign verify-blob` regardless of who emitted the signature — matters more than implementation match with the SLSA bundle.

**Predicate version (v0.2 vs v1).** `slsa-github-generator` v2.1.0 currently emits `slsa.dev/provenance/v0.2`. `actions/attest-build-provenance` emits `v1`. Wrangle's container and python specs intentionally stay on `slsa-github-generator` for the L3 isolation property; the Go build type follows the same convention. When upstream ships v1, wrangle adopts it across all build types in one change. The doc shouldn't silently endorse `actions/attest-build-provenance` as a substitute.

#### Pattern A (alternative, not picked)

`slsa-framework/slsa-github-generator/.github/workflows/builder_go_slsa3.yml` is a Go-specific *builder* that performs the build itself inside an isolated reusable workflow, driven by a `.slsa-goreleaser.yml` config file (the filename predates goreleaser conventions; the format is the SLSA builder's own). `slsa-verifier`'s [release workflow](https://github.com/slsa-framework/slsa-verifier/blob/main/.github/workflows/release.yml) demonstrates the canonical 6-cell `os × arch` matrix. It exists as an alternative for adopters who specifically want `.slsa-goreleaser.yml`-driven isolated builds. The cost is wrangle's seam: `builder_go_slsa3.yml` has no `hashes` input — the build, the SBOM, the test, and the provenance all happen inside one sealed reusable workflow with no caller hook between them, so wrangle's `syft` / `go test` / `release_gate` steps either run on a separate checkout (different bytes than the builder produces) or don't run at all. Adopters who want that trade can opt in via a separate variant in a later iteration; not the v0.x default. Pattern A also doesn't support `pull_request` triggers (per the upstream README).

#### Pattern C (one-line alternative)

GitHub's [`actions/attest@v4`](https://github.com/actions/attest) (used by [`goreleaser`'s own release workflow](https://github.com/goreleaser/goreleaser/blob/main/.github/workflows/release.yml), invoked twice — once over `dist/checksums.txt`, once over Docker digests) emits `slsa.dev/provenance/v1` predicates today, but lacks the L3-isolated-builder property and doesn't compose with wrangle's metadata layout — same reason wrangle's container and python specs don't use it.

### Linting — `gofmt` + `golangci-lint`

`gofmt` is mandatory (built into the Go toolchain); CI typically runs `gofmt -l .` and fails if the output is non-empty. [`golangci-lint`](https://golangci-lint.run/) is the canonical aggregator (vet, staticcheck, errcheck, ineffassign, unused, etc.), used by the goreleaser repo, slsa-verifier, oras, and most production Go projects.

Source-stage placement is the natural fit (alongside OSV-Scanner and Zizmor in `actions/scan`); the build action could optionally invoke `gofmt -l .` and `golangci-lint run` if declared. Concrete recommendation for the implementation PR: enable lint by default with an opt-out input, mirroring the `run-tests: true` default python uses.

### Tests — `go test ./...` before build

Run `go test ./...` (with `-race` on the linux-amd64 cell when not cross-compiling) before the build step. Tests run naturally before build; this isn't a wrangle-imposed ordering. Combined with the reproducibility flags below, the wrangle-tested source compiles to the same bytes the SLSA generator hashes — the test run *does* certify the released artifact, not just an arbitrary checkout. The container build type has the same property (build, then SBOM, then sign, then provenance; the bytes don't change between steps).

### Reproducibility — `-trimpath -buildvcs=false`

Out of the box, `go build` embeds build info (working directory, VCS revision, dirty flag, build timestamps) into the binary, which breaks reproducibility — two builds of the same source produce different bytes. Setting `-trimpath` (strips local filesystem paths from the binary) and `-buildvcs=false` (suppresses VCS-info embedding) plus a fixed `CGO_ENABLED=0` (where applicable) makes Go binaries reproducible. Goreleaser exposes these via `builds.flags` and `builds.env`; the wrangle action should set them by default and let the adopter's `.goreleaser.yml` opt out if they have a specific reason.

This matters because it closes the wrangle-tested-bytes vs. SLSA-attested-bytes gap. Without reproducibility, "we tested the source and SLSA attests the build" is two different artifacts; with it, they are the same artifact byte-for-byte.

### Authentication — `GITHUB_TOKEN` only

Publishing to GitHub Releases requires `contents: write` (the same permission `slsa-github-generator`'s `upload-assets` job requires anyway, and the same one python's caller already grants). No external registry credentials, no Trusted Publisher to configure, no API tokens. This is the simplest auth model of any artifact-producing build type.

The permission cascade lesson from python ([HOW_TO_ADD_A_BUILD_TYPE.md "Permission cascade through nested reusable workflows"](../../../docs/HOW_TO_ADD_A_BUILD_TYPE.md)) applies: callers must grant the union of every nested job's declared permissions. For the picked Pattern B path: `id-token: write`, `contents: write`, `actions: read`.

`pkg.go.dev` indexing is automatic — `proxy.golang.org` discovers tags within minutes of `git push --tags`. No publish step, no auth.

## Validation-only sub-shape (non-binary repos)

Library-only modules and `go install`-pattern repos that don't produce a binary at release time are *not* out of scope. Wrangle still adds value: SBOM (`syft dir:.` against the source tree), `go test ./...`, vulnscan via `osv-scanner` against `go.sum` (or `govulncheck` as a Go-aware alternative), and lint (`gofmt`, `golangci-lint`). What it does NOT add is SLSA build provenance — there's no build artifact wrangle produces, so there's nothing to attest. `sum.golang.org`'s tlog already serves source integrity for `go install`-style consumers, and SLSA source-track attestations (a separate workstream) cover the orthogonal "this tag was reviewed/tested/scanned by my CI" property a future adopter might want.

This sub-shape is structurally similar to wrangle's existing `shell` build type — validation-only, no artifact, no provenance. The implementation could either:

- Live as a `mode:` input on the Go build type (`mode: binary` vs. `mode: validate-only`, auto-detected from `.goreleaser.yml` presence), or
- Live as a separate `build/actions/go-validate/` action.

The first option is simpler and avoids a directory split for what's essentially the same set of source-stage checks. Recommend deciding in the implementation PR; either is workable.

## ko / container builds

Go projects that publish container images via [`ko`](https://ko.build/) (small distroless images built from Go binaries without a Dockerfile) should use **wrangle's existing container build type**, not the Go build type. ko produces an OCI image; the container build type already handles SBOM, Cosign signing, and SLSA provenance for OCI images. The Go build type doesn't need a ko-specific code path — ko-using projects already have a container build need, and routing them to the container action keeps wrangle's per-ecosystem boundaries clean.

This mirrors how the container build type doesn't try to handle goreleaser-built tarball artifacts: each artifact shape gets its own build type.

## Wrangle's value-add

Across both binary releases and the validation-only sub-shape, wrangle adds the same set of properties an adopter would otherwise re-implement per repo:

- **SBOM generation** with a verified-install syft, written to the unified `metadata/go/<shortname>/` layout.
- **Test gating** — tests must pass before SLSA provenance is generated (binary mode) or before the workflow declares success (validate-only mode).
- **Vulnscan** via the existing source-scan infrastructure (OSV-Scanner against `go.sum`).
- **Lint** via `gofmt` + `golangci-lint`.
- **Release-events gating** — the `release_gate` job decides whether to invoke the SLSA provenance reusable workflow at all (binary mode); the same predicate vocabulary as python.
- **Hash-pinned handoff** to `slsa-github-generator` (binary mode) — no string interpolation across job boundaries, no surface for a hash-substitution attack.
- **Consistent metadata layout, step summary, and artifact upload naming** — same shape as every other build type.
- **One-line adoption** — a single `uses:` line replaces a multi-step workflow.

The build artifact differs across the two modes (release binaries vs. nothing), but the value-add is the same.

## Awkward cases

- **Multi-binary repos** (`cmd/foo`, `cmd/bar` under one module). Goreleaser handles multiple `builds:` entries in one config, and `dist/checksums.txt` covers every artifact in a single hashes string the generic generator can sign. Clean fit for Pattern B.
- **Cross-compilation matrices.** Pattern B handles them inside the goreleaser config; one CI job builds all targets. Operationally simpler than fan-out at the workflow level.
- **CGo / platform-specific toolchains.** `CGO_ENABLED=1` builds need a C toolchain matching the target OS, which usually means per-OS runners. Goreleaser supports this with `builds.env` and runner matrix; cross-compiling CGo is hard regardless of build type.
- **Library-only modules.** Handled via the validation-only sub-shape above.
- **`vendor/` directories and Go workspaces (`go.work`).** Goreleaser supports both natively; wrangle inherits whatever goreleaser does. Worth a fixture if either lands in the v0.x scope.

## Implementation notes

Practical notes for whoever picks up the implementation PR.

- **Match python's reusable-workflow shape.** `build_and_publish_go.yml` mirrors `build_and_publish_python.yml`: a `build` job (composite action), a `gate` job (`actions/release_gate`), a `provenance` job (`generator_generic_slsa3.yml`, gated on `should-release`), and a `verify` job (`slsa-verifier verify-artifact`, gated on `should-release && verify-provenance`). Outputs follow the unified naming: `metadata-artifact-name`, `dist-artifact-name`, `provenance-artifact-name`, `should-release`.
- **Goreleaser invocation.** Use `goreleaser/goreleaser-action` SHA-pinned, with `args: release --clean`. Set `-trimpath` and `-buildvcs=false` defaults via `.goreleaser.yml` template the action ships, or document them as a hard requirement on the adopter's config.
- **Hashes step.** Same `cd dist && sha256sum * | base64 -w0` shape python uses. Bare filenames (not `./*`) so `slsa-verifier`'s subject match works.
- **Cosign signing.** Add `cosign sign-blob --yes` against each artifact in `dist/`, after the build step and before the metadata upload. Identity is the calling workflow's OIDC token (same model as the container build type's image signing). Sigstore retry strategy mirrors container's: exponential backoff, hard-fail on exhaustion, no fallback to weaker signing.
- **Predicate version.** Stay on `slsa-github-generator`'s v0.2 predicate today; bump to v1 when upstream ships it across all build types in one change. Don't silently switch to `actions/attest-build-provenance`.
- **Integration fixture.** A `go/` directory in the wrangle-test companion repo with a minimal `go.mod`, `cmd/example/main.go`, a `.goreleaser.yml`, and a `tests/` directory. The `test-go` job in `test-wrangle.yml.template` grants `contents: write`, `id-token: write`, `actions: read`.

## Open questions

- **Binary vs. validate-only as one action or two.** See "Validation-only sub-shape." Decide in the implementation PR.
- **Lint placement.** Source-stage (in `actions/scan`) vs. build-stage (in the Go build action) vs. both. Python doesn't currently lint in the build action; Go could either follow that or differ.
- **`.goreleaser.yml` template ownership.** Should wrangle ship a starter `.goreleaser.yml` for adopters (with `-trimpath` / `-buildvcs=false` baked in), or require adopters to bring their own and validate it has the reproducibility flags? Python doesn't ship a starter `pyproject.toml`; consistency with python argues "require adopters to bring their own."
- **`govulncheck` vs. `osv-scanner` for Go vulnscan.** Source-stage scanning already uses OSV-Scanner; `govulncheck` is Go-aware (callgraph-based, fewer false positives) and could be a complementary check. Decide in the implementation PR; not load-bearing for Phase 1.
