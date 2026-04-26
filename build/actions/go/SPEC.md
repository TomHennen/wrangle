# Wrangle Go Build Type — Phase 1 Research

This document captures Phase 1 ecosystem research per [`docs/HOW_TO_ADD_A_BUILD_TYPE.md`](../../../docs/HOW_TO_ADD_A_BUILD_TYPE.md).

**Status:** research only. No implementation has been written. No build-type adapter contract is committed. Inputs, outputs, step sequence, and reusable workflow shape are intentionally absent — those are downstream of the contract decisions tracked in [#171](https://github.com/TomHennen/wrangle/issues/171).

The goal of this document is to make whoever picks up Go implementation (and whoever picks up #171) *more decisive* about the load-bearing trade-offs, not to enumerate options.

## Design principles

### Binary-build vs. tag-and-`go-install` — the load-bearing question

The runbook flags Go as awkward because "a lot of Go projects skip a binary build entirely and let consumers `go install <repo>@<tag>` from a tag, so 'build tool' may not be the right framing." Phase 1 resolution: there are **three modes**, not two, and the picture is cleaner than the runbook framing suggests.

1. **Binary releases via a CI build pipeline.** Every Go project that explicitly publishes — `slsa-verifier`, `cosign`, `goreleaser` itself, `oras`, etc. — does run a CI build. The output is one or more architecture-specific binaries attached to a GitHub Release, plus checksums, plus (for security-conscious projects) SLSA provenance, Cosign signatures, and SBOMs. This is the case wrangle's "artifact-producing" template was designed for and where wrangle adds the most value.
2. **Pure libraries (no `main` package).** There is no binary, ever. The "artifact" is the tagged source tree as fetched by `go get` / `go install`. Integrity comes from Go's checksum database (`sum.golang.org`), which is itself a tamper-evident Merkle-tree transparency log over `(module@version, hash(source))` pairs ([Go module mirror launch announcement](https://go.dev/blog/module-mirror-launch); [proposal 25530](https://go.googlesource.com/proposal/+/master/design/25530-sumdb.md)). This is integrity-of-source, not build provenance — they answer different questions — but it is not nothing.
3. **`go install <repo>@<tag>` for CLI tools whose maintainers chose not to run a release pipeline.** This is mode 1 minus the release pipeline. The "missing build" the runbook gestures at is almost always a maintainer-side choice not to run CI release for a project that *could* release binaries; it is rarely a property of the project's source.

**Resolution.** Wrangle's Go build type should target mode 1 as primary. Mode 2 is out of scope for an artifact-producing template — wrangle has no surface to attach to when there is no build job, and `sum.golang.org` already provides what mode-2 consumers verify. Mode 3 is "the maintainer hasn't adopted wrangle yet" rather than a separate shape; once they do, they're in mode 1. The runbook's framing — "Go may not fit the artifact-producing template" — overstates the gap. *Projects that adopt wrangle* are by definition projects that want a CI release pipeline; for those, the artifact-producing template applies, with the caveats below.

What this implies for #171: there is no need to design a separate "tag-and-attest" build-type shape for Go. If one is needed at all (which is debatable — `sum.golang.org` arguably already serves the use case), it would be a different, future build type, not a mode of the Go build type.

### `builder_go_slsa3.yml` vs. `goreleaser`+generic generator — the contract-shape tension

This is the finding that stresses the #171 contract most. The Go ecosystem offers two mature patterns for SLSA L3 provenance, and they map differently onto wrangle's existing reusable-workflow shape:

**Pattern A: `slsa-framework/slsa-github-generator/.github/workflows/builder_go_slsa3.yml`.**
[Documented at slsa-framework/slsa-github-generator/internal/builders/go/README.md](https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/go/README.md). This is a Go-specific *builder*, not a generator: it performs the build itself inside an isolated reusable workflow, driven by a `.slsa-goreleaser.yml` config file (despite the filename, this format is the SLSA builder's own — it is not goreleaser config). The builder runs `go mod vendor` and `go build` with the configured `goos`, `goarch`, `flags`, `ldflags`, `binary`, `main`, `dir`, and `evaluated-envs`, and emits a binary plus signed `.intoto.jsonl` provenance whose `predicateType` is `https://slsa.dev/provenance/v0.2`. SLSA L3 with the strongest "hardened build platform" guarantee in the Go ecosystem because the build itself is hermetic and isolated. Caller permissions: `id-token: write`, `contents: write`, `actions: read`. Trigger restriction: `pull_request` is unsupported (per the builder README).

`slsa-verifier`'s own [release workflow](https://github.com/slsa-framework/slsa-verifier/blob/main/.github/workflows/release.yml) demonstrates the canonical use: a 6-cell matrix (`os: [linux, windows, darwin] × arch: [amd64, arm64]`) of separate `builder_go_slsa3.yml` jobs, one per `.slsa-goreleaser/<os>-<arch>.yml` config file, since each builder invocation produces exactly one binary.

**Pattern B: `goreleaser` (or plain `go build`) inside a normal job, then `slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml`.**
[Goreleaser's example workflow](https://github.com/goreleaser/goreleaser-example-slsa-provenance/blob/master/.github/workflows/goreleaser.yml) demonstrates: goreleaser produces `dist/checksums.txt`, a follow-up step extracts and base64-encodes that file, and `generator_generic_slsa3.yml` is invoked with `base64-subjects: ${{ steps.hash.outputs.hashes }}` — the same shape Wrangle's python build type uses today. SLSA L3, but via the *generic* generator, which signs provenance about pre-built artifacts rather than performing the build inside the trusted builder. The "hardened build platform" property is correspondingly weaker: a compromise of the calling workflow could produce a binary whose hashes match valid provenance, because the generator only attests to the inputs it was given.

**Why this is contract-relevant.** Wrangle's existing python and (planned per #171) generic shape look like:

```
build job  (composite action: build, test, SBOM, hash) ──> hashes
                                                            │
                                            generator_generic_slsa3.yml
                                                            │
                                                       provenance
```

The composite owns the build, emits hashes, and the SLSA generator runs in a separate job consuming those hashes. SBOM generation, test execution, the `release_gate` job, and the verify job all slot in around this seam.

`builder_go_slsa3.yml` does not have a hashes input — it has a `config-file` input and performs the build itself. There is no place inside wrangle's reusable workflow to insert `go test`, `syft`-driven SBOM generation, or `actions/release_gate`-style gating between "build" and "provenance," because by the time wrangle hands off to the builder, the build has not yet happened, and after the builder returns, the build has shipped to a release. The build-then-attest seam wrangle relies on for python isn't there.

There are three honest paths, and #171 has to pick one:

- **(i) Match python.** Use Pattern B (`goreleaser` or `go build` inside the composite, `generator_generic_slsa3.yml` for provenance). The contract stays uniform; SBOM/test/gate/verify slot in identically. Loss: the Go-specific isolated-builder property.
- **(ii) Adopt `builder_go_slsa3.yml`.** Wrangle's reusable workflow becomes a coordinator that runs SBOM/test in one job, then delegates to `builder_go_slsa3.yml` for the actual build+provenance, then runs verify. Test/SBOM run on a *separate checkout* of the same source — they don't certify the same byte-for-byte build the SLSA builder produces. The contract for Go diverges from python in a visible way.
- **(iii) Two variants, like python's pip vs. uv.** Adopters who care about the strongest L3 isolation get the `builder_go_slsa3.yml` flavor; adopters who want the full wrangle pipeline (SBOM-of-the-built-artifact, integrated test gating) get the Pattern B flavor. Doubles surface area, but each variant is internally clean.

This document does not pick. The point for #171 is that Go is the first build type where an ecosystem-native SLSA L3 path *inverts* wrangle's "composite owns build, reusable workflow owns provenance" seam. Python and container both decompose cleanly along that seam (the SLSA generator consumes the composite's outputs); `builder_go_slsa3.yml` does not. Whether the contract bends to accommodate or whether wrangle accepts a weaker isolation guarantee for Go is the trade-off.

A separate, related tension: GitHub now ships [`actions/attest-build-provenance`](https://github.com/actions/attest-build-provenance) and [docs guidance](https://docs.github.com/actions/security-guides/using-artifact-attestations-and-reusable-workflows-to-achieve-slsa-v1-build-level-3) framing org-level reusable workflows + that action as the path to SLSA v1 Build L3. It produces `slsa.dev/provenance/v1` predicates today, which `slsa-github-generator` does not. Wrangle's container and python specs explicitly stay on `slsa-github-generator` for the isolated-builder property; the same tension applies here. The Go SPEC should not silently endorse `actions/attest-build-provenance` as a substitute, even though it is the one path that produces v1 predicates today.

### Canonical build tool(s)

For a wrangle-shape "wrangle invokes the build" pipeline (Pattern B above), three options exist, in order of how much wrangle has to own:

- **Plain `go build`.** Lowest dependency. Cross-compilation is a `GOOS`/`GOARCH` matrix. No artifact orchestration (archive packaging, checksum file, changelog generation) — wrangle would have to hand-roll those. Reasonable if wrangle's goal is a single-binary release; awkward for multi-binary or multi-platform.
- **`goreleaser`** ([customization docs](https://goreleaser.com/customization/), [supply chain post](https://goreleaser.com/blog/supply-chain-security/), [SBOMs](https://goreleaser.com/customization/sbom/)). Config-driven (`.goreleaser.yml`). Produces multi-platform binaries, archives, checksums file, container images, and packages (deb/rpm/apk/snap) in one invocation. Has built-in SBOM generation (delegates to syft by default) and built-in cosign signing of artifacts (calls the `cosign` binary; `cosign-installer` Action installs it). Integrates with `slsa-github-generator/generator_generic_slsa3.yml` via the checksums.txt → base64 hashes step; this is the pattern goreleaser themselves [document and demonstrate](https://goreleaser.com/blog/slsa-generation-for-your-artifacts/). De facto standard for serious Go release pipelines (`oras`, the goreleaser-example project, plus any project with a `.goreleaser.yml`). Caveat: the goreleaser project's [own release workflow](https://github.com/goreleaser/goreleaser/blob/main/.github/workflows/release.yml) does not use `slsa-github-generator` — it uses `cosign-installer`, syft, and goreleaser-action, plus presumably GitHub artifact attestations.
- **`slsa-framework/slsa-github-generator/.github/workflows/builder_go_slsa3.yml`.** Pattern A above. The build tool *is* the SLSA builder. `.slsa-goreleaser.yml` despite its filename is **not** goreleaser config — it's the SLSA builder's own format. Used by `slsa-verifier`.

If wrangle picks Pattern B and a single canonical tool, `goreleaser` is the dominant choice. The detection rule "is `.goreleaser.yml`/`.goreleaser.yaml` present" is unambiguous. A "no goreleaser, fall back to `go build`" path is *possible* but the runbook lesson from python (`setup.py`-only fallback that didn't actually work) cautions against shipping fallbacks that aren't end-to-end tested.

### Canonical SBOM tool

The Go ecosystem has two viable SBOM generators:

- **`syft`** ([anchore/syft](https://github.com/anchore/syft)). Wrangle already uses syft for the python build type, with a Cosign-keyless-verified install (`tools/syft/install.sh`). It produces SPDX natively and works against both source trees and compiled binaries. Reusing it for Go is the lowest-friction path: no new install script, no new Cosign verification dance, no new checksum to track. Per [the SBOM-tools landscape](https://sbomgenerator.com/guides/go), syft is the de facto choice for Go SBOM generation in 2026.
- **`cyclonedx-gomod`** ([CycloneDX/cyclonedx-gomod](https://github.com/CycloneDX/cyclonedx-gomod)). Tighter Go integration (uses the Go toolchain to introspect modules), produces CycloneDX natively. Listed in wrangle's [`docs/docker_best_practices.md`](../../../docs/docker_best_practices.md) Go row — but that table predates the python build type's syft adoption, and the listing should not be read as a contract. CycloneDX → SPDX conversion exists but is lossy; the cleanest SPDX path for a Go project is "run syft directly," not "run cyclonedx-gomod and convert."

Wrangle uses SPDX consistently across build types ([`docs/SPEC.md`](../../../docs/SPEC.md) "Decisions to inherit"). Reusing syft is the obvious default. `cyclonedx-gomod` is mentioned here for completeness; #171 should default to syft unless there's a Go-specific signal that argues otherwise.

`goreleaser` itself can drive SBOM generation (`sboms:` block in `.goreleaser.yml`, syft as default backend). If wrangle adopts Pattern B with goreleaser, it has a choice: let goreleaser drive the SBOM (one less wrangle-owned step) or run syft separately (consistent with the python action, which runs syft directly rather than asking the build backend to do it). The python action runs syft directly — picking the same shape for Go keeps the SBOM step uniform across build types.

### Canonical publish target

GitHub Releases, with binaries (one per `<goos>-<goarch>`) attached as release assets, plus a checksums file, optionally plus a `.intoto.jsonl` provenance file and `.sig`/`.pem` cosign artifacts. This is what `slsa-verifier`, `cosign`, `oras`, the goreleaser-example project, and goreleaser itself all do.

There is no Go-specific package registry to publish to. `pkg.go.dev` is a documentation index, not a registry; it auto-discovers tagged versions from `proxy.golang.org`'s view of GitHub (and other VCS hosts). No publish action, no token, no auth — just push the tag. (This is also why mode 2 / mode 3 from the binary-vs-tag discussion are even possible: there is no separate publish step to skip.)

Container images via [`ko`](https://ko.build/) are a parallel publish path some Go projects use (small distroless images built from Go binaries without a Dockerfile). Out of scope for the Go build type — `ko`-using projects already have a container build need, and wrangle's container build type is the right home for that.

### Canonical attestation pattern

In the Go ecosystem, "the attestation" almost always means SLSA L3 provenance, signed via Sigstore keyless OIDC, recorded in Rekor. Both Pattern A (`builder_go_slsa3.yml`) and Pattern B (`generator_generic_slsa3.yml`) produce this; both emit `slsa.dev/provenance/v0.2` predicates today. There is no Go-ecosystem-native attestation analogous to npm provenance or PEP 740 — Go binaries' attestations *are* SLSA provenance. The transparency log is Rekor for the provenance, plus `sum.golang.org` for *source* integrity (which is independent — `sum.golang.org` doesn't know or care that a binary was produced).

Cosign keyless signing of binaries is a complementary layer (signs the binary digest directly, like wrangle's container build type does for image digests). `goreleaser` integrates with cosign natively; the [Cosign v3 upgrade post](https://goreleaser.com/blog/cosign-v3/) covers the current `--bundle`-style signing. This layer is ecosystem-supported but less universally adopted than SLSA provenance — `slsa-verifier`'s release workflow attests but does not separately Cosign-sign its binaries (the SLSA provenance bundle already includes a Sigstore-signed in-toto envelope), while goreleaser's own release workflow does. Whether wrangle's Go build type ships Cosign signing as a default, an opt-in, or not at all is a contract decision for #171, not a Phase 1 finding.

### Authentication model

Publishing Go binaries to GitHub Releases requires `contents: write` (the same permission `slsa-github-generator`'s `upload-assets` job needs anyway). No external registry credentials. This is the simplest auth model of any artifact-producing build type: no Trusted Publisher to configure (unlike PyPI), no registry token, no OIDC trust setup beyond what GitHub Actions natively provides for Sigstore keyless signing.

The permission cascade lesson from python applies (the runbook's "Permission cascade through nested reusable workflows" gotcha): callers of a wrangle Go reusable workflow that calls `builder_go_slsa3.yml` must grant the union of permissions every called job declares. For `builder_go_slsa3.yml`: `id-token: write`, `contents: write`, `actions: read`.

`pkg.go.dev` indexing is automatic — `proxy.golang.org` discovers tags within minutes of `git push --tags`. No publish step, no auth.

### Reference workflow patterns

Three primary-source workflows, drawn for variety:

- **[`slsa-framework/slsa-verifier/.github/workflows/release.yml`](https://github.com/slsa-framework/slsa-verifier/blob/main/.github/workflows/release.yml).** Pattern A (`builder_go_slsa3.yml`). 6-job `os × arch` matrix, one config file per cell, separate builder invocation per binary. No goreleaser. Pinned at `builder_go_slsa3.yml@v2.0.0`. Caller permissions: `id-token: write`, `contents: write`, `actions: read`. Demonstrates that multi-platform Go releases require fan-out at the wrangle-reusable-workflow level, not inside a single build action.
- **[`goreleaser/goreleaser-example-slsa-provenance/.github/workflows/goreleaser.yml`](https://github.com/goreleaser/goreleaser-example-slsa-provenance/blob/master/.github/workflows/goreleaser.yml).** Pattern B. `goreleaser/goreleaser-action` with `args: release --clean` produces all platform binaries plus `dist/checksums.txt` in one job; a `jq | base64` step converts that file into the `hashes` output; `generator_generic_slsa3.yml` consumes it. Trigger: tag push only. The goreleaser job runs with `contents: write packages: write id-token: write`; the provenance job with `actions: read id-token: write contents: write`. Same shape wrangle's python reusable workflow uses today, modulo build tool.
- **[`goreleaser/goreleaser/.github/workflows/release.yml`](https://github.com/goreleaser/goreleaser/blob/main/.github/workflows/release.yml).** goreleaser's own release. Uses `goreleaser/goreleaser-action`, `sigstore/cosign-installer`, `anchore/sbom-action/download-syft`. Notably: does **not** use `slsa-github-generator` — relies on goreleaser's built-in Sigstore signing and (presumably) GitHub artifact attestations rather than slsa-github-generator-style isolated-builder provenance. Useful as a counter-example: the most Go-savvy team chose not to use either Pattern A or Pattern B, suggesting the wrangle-default trade-off is a real one rather than a settled question.

The common shape across all three is "tag-triggered release job that produces binaries + checksums + signatures/provenance, attaches them to a GitHub Release." Pattern variation lives entirely in *who builds, who attests, and at what isolation level*.

### Awkward cases

Surfaced for #171's awareness; none of these are wrangle-Go-specific so much as they expose where the contract has to bend.

- **Multi-binary repos** (`cmd/foo`, `cmd/bar` under one module). With Pattern A, each binary needs its own `.slsa-goreleaser.yml` and its own builder workflow invocation — a matrix dimension on top of `os × arch`. With Pattern B, one `goreleaser` invocation handles all of them, and `dist/checksums.txt` covers every artifact in a single hashes string the generic generator can sign. This is one of the cleanest cases for Pattern B over Pattern A.
- **Cross-compilation matrices.** Pattern A: matrix at the wrangle-reusable-workflow level (`slsa-verifier` does 6 cells). Pattern B: matrix inside `goreleaser` config (`builds.goos[]`, `builds.goarch[]`); single CI job. Pattern B is dramatically simpler operationally, at the cost of the L3 isolation noted above.
- **CGo / platform-specific toolchains.** `CGO_ENABLED=1` builds need a C toolchain matching the target OS. `builder_go_slsa3.yml` accepts `evaluated-envs` whitelisted to `CGO_*` and `GO*` prefixes. Pattern B has no restriction but has to manage the toolchain matrix itself (typically: build per-OS on per-OS runners, which a Pattern A matrix achieves naturally). Cross-compiling CGo is hard regardless of build type.
- **Pure libraries (no `main`).** Mode 2 from the binary-vs-tag discussion. Wrangle's Go build type, if it follows mode 1, has no entry point for these. They are not broken — `sum.golang.org` already serves them — they just don't need wrangle. A future "Go library" or "Go module" build type could attest to test results and source provenance without producing a binary; it would share zero step sequence with the binary build type and would be a separate `build/actions/` directory.
- **`go install` for adopters who don't run releases.** Mode 3. Same answer as mode 2: out of scope for the artifact-producing build type. If they want wrangle, they want a binary release pipeline.
- **`vendor/` directories.** `builder_go_slsa3.yml` runs `go mod vendor` itself; pre-vendored repos may interact strangely. Pattern B inherits whatever the build tool does. Worth fixture-testing if either pattern is chosen.
- **Workspaces (`go.work`).** Multi-module repos. `goreleaser` has explicit support; `builder_go_slsa3.yml` is single-module-shaped. Another data point favoring Pattern B for complex repos.

## Notes for #171 contract design

Restating the trade-offs the runbook's #171-feeding research is meant to surface:

1. **The seam.** Wrangle's existing build types decompose along "composite owns build → reusable workflow owns provenance," with the SLSA generator consuming the composite's hash output. `builder_go_slsa3.yml` does not honor that seam — it owns the build itself. Whether the #171 contract treats this as "Go is an edge case" (matching python's shape, dropping to L3-via-generic) or "the contract has a builder-owned-build mode" (more general but stresses the existing build types), or "Go ships two flavors" (most user-facing surface), is a #171 decision.
2. **Verification of the same artifact wrangle tests.** Pattern A's hermetic builder rebuilds the binary from source independently; if wrangle's composite ran tests on a different checkout, those tests don't certify the bytes the SLSA builder produced. Wrangle's "test before publish" property may be weaker for Go-via-Pattern-A than for python or container, where the SBOM/test/build all run in one composite against one workspace. This is a real wrangle-contract concern, not just an aesthetic one.
3. **`actions/attest-build-provenance` as a third path.** Wrangle has so far stayed off this action for python and container (in favor of `slsa-github-generator`'s isolated builder). Go presents the same choice. The Go SPEC should not silently adopt it; that's a wrangle-wide architectural call orthogonal to Go.
4. **SBOM-tool reuse.** `syft` is already in wrangle. Reusing it for Go is the path of least friction. `cyclonedx-gomod` listed in `docs/docker_best_practices.md` is a stale pre-python-build-type prediction, not a commitment.
5. **Mode 2 and mode 3 don't bend the contract.** They are out of scope for the artifact-producing template, not edge cases of it. The runbook's framing ("Go may not fit") overstates the awkwardness once mode 1 vs. mode 2/3 is teased apart.
6. **Cross-axis stress.** Together with npm and generic (the other two Phase 1 research targets per the [#171 sequence comment](https://github.com/TomHennen/wrangle/issues/171)), Go gives the contract three different axes of stress: Go = where-build-happens (composite vs. external trusted builder); npm = ecosystem-native attestation alongside SLSA; generic = user-supplied build command. Together they should be enough evidence to design the contract in #171 without further Phase 1 research.
