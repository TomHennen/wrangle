# Wrangle Go Build Type — Phase 1 Research

**Status:** Phase 1 ecosystem research per [`docs/HOW_TO_ADD_A_BUILD_TYPE.md`](../../../docs/HOW_TO_ADD_A_BUILD_TYPE.md). Recommends defaults for an eventual `build/actions/go/` implementation. **No `action.yml` exists yet.** Inputs, outputs, and step sequence are sketched at the level needed to justify the picks; the implementation PR will tighten them.

## Overview

Go projects in 2026 fall into three release shapes:

1. **Binary releases.** A CI build produces one or more `os × arch` binaries, attaches them to a GitHub Release, and (for security-conscious projects) ships SLSA provenance, Cosign signatures, and SBOMs alongside. Examples: `slsa-verifier`, `cosign`, `oras`, `goreleaser` itself.
2. **Library-only modules.** No `main` package, no binary. Consumers fetch source via `go get` / `go install <module>@<version>`; integrity comes from Go's checksum database (`sum.golang.org`, a Trillian-backed Merkle log over `go.sum`-shaped lines — see the [Go module mirror launch announcement](https://go.dev/blog/module-mirror-launch) and [proposal 25530](https://go.googlesource.com/proposal/+/master/design/25530-sumdb.md)).
3. **`go install <repo>@<tag>` for CLI tools whose maintainers chose not to run a release pipeline.** Equivalent to (1) minus the build job; consumers compile from source on their own machines.

**Operating model.** Wrangle owns the build hygiene — test, SBOM, vulnscan, lint, gating, the unified metadata layout — and produces its own L3 SLSA provenance via `actions/attest-build-provenance` run inside its reusable workflow, exposed as a Sigstore-bundle workflow artifact. The L3 bundle is verifiable offline by any consumer regardless of where the binary is hosted. Same shape python and container ship today, and the picks below preserve it.

## Recommended defaults (the picks)

### Build tool — goreleaser for binary releases

**Pick:** [`goreleaser`](https://goreleaser.com/) for binary releases.

**Why:** It's the dominant ecosystem norm. One config-driven invocation handles the cross-compilation matrix (`builds.goos[]` × `builds.goarch[]`), archive packaging, `dist/checksums.txt`, GitHub Release upload, and (optionally) deb/rpm/apk/snap packaging — see [goreleaser customization docs](https://goreleaser.com/customization/) and the [supply-chain blog post](https://goreleaser.com/blog/supply-chain-security/). Used by `slsa-verifier`, `cosign`, `oras`, and many others. Detection rule for the action: `.goreleaser.yml` or `.goreleaser.yaml` present.

Plain `go build` is a viable fallback for single-binary, single-platform repos but offers nothing goreleaser doesn't, and the python build type's experience with a `setup.py`-only fallback that didn't actually work ([HOW_TO_ADD_A_BUILD_TYPE.md "Implement minimally before adding fallback paths"](../../../docs/HOW_TO_ADD_A_BUILD_TYPE.md)) cautions against shipping fallbacks before they're end-to-end tested. The first implementation should require goreleaser.

For repos with no binary at all, see "Validation-only sub-shape" below — wrangle still adds value there.

### SBOM — `syft`

**Pick:** [`syft`](https://github.com/anchore/syft), the same tool wrangle's python build type uses, with the same Cosign-keyless-verified install (`tools/syft/install.sh`).

**Why:** Reuses an existing wrangle-verified install, produces SPDX natively (matching wrangle's cross-build-type SPDX choice — see the unified metadata layout in [`docs/SPEC.md`](../../../docs/SPEC.md)), and is the de-facto Go SBOM choice in the broader ecosystem. `cyclonedx-gomod` is an alternative with tighter Go-toolchain integration but produces CycloneDX; converting to SPDX is lossy. `goreleaser`'s `sboms:` block can also drive syft, but running syft directly (the way python does) keeps the SBOM step uniform across build types and survives a future move off goreleaser.

The stale `cyclonedx-gomod` reference in [`docs/docker_best_practices.md`](../../../docs/docker_best_practices.md) predates python's syft adoption and should be treated as informational, not a contract.

### Publish target — GitHub Releases

**Pick:** GitHub Releases. Goreleaser handles the upload natively given a `GITHUB_TOKEN` with `contents: write`.

**Why:** This is what `slsa-verifier`, `cosign`, `oras`, the goreleaser-example project, and goreleaser itself all do. There is no separate Go binary registry. `pkg.go.dev` is a documentation index that auto-discovers tagged versions from `proxy.golang.org` — no publish action, no token required for module consumers.

### Attestation — `actions/attest-build-provenance`

**Pick:** Goreleaser produces `dist/checksums.txt`; wrangle hands that file to `actions/attest-build-provenance` via `subject-checksums: dist/checksums.txt`, run as a step inside an `attest:` job in wrangle's own reusable workflow. This is the same shape wrangle's python, npm, and container build types use as of #316.

[`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) §"Ecosystem-specific builders vs the generic generator" sets the terminology used below. **History:** wrangle previously routed all build types through the upstream generic generator (`generator_generic_slsa3.yml`), signing caller-produced hashes; as of #316 it instead runs `actions/attest-build-provenance` inside its reusable workflow. The L3 isolation property is unchanged — it now comes from wrangle's reusable workflow being the trusted builder — but the new path emits a v1 predicate and names wrangle's workflow (not the generator) as the `builder.id`.

**Why this pick:**

- **Same shape as python, npm, and container.** The composite owns build/test/SBOM/lint and emits `dist/`; the `attest:` job (a separate job inside wrangle's reusable workflow) calls `actions/attest-build-provenance` over the dist; the `verify:` job then verifies that provenance (ampel against the wrangle PolicySet, fail-closed) and emits the signed VSA. Consistency keeps the per-build-type cognitive load low.
- **Preserves the test/SBOM/lint seam.** Wrangle's value-add steps slot between "build" and "provenance" the same way they do for python — the build action emits `dist/`, runs syft against it, runs gating, and then hands off. There's nowhere new to learn.
- **Same L3 isolation as the ecosystem-specific Go builder.** L3 comes from the provenance being produced by an isolated, trusted builder; wrangle's reusable workflow *is* that builder, and the `attest:` step runs inside it, so its `job_workflow_ref` is both the Sigstore cert SAN and the provenance `builder.id`. Per the L3 audit, switching to `builder_go_slsa3.yml` would not close any conformance gap this approach leaves open.
- **`lib/release_gate.sh` works either way.** Wrangle gates the `attest:` job with `if: ${{ needs.gate.outputs.should-release == 'true' }}`. That predicate-on-the-job pattern is build-type-agnostic.

#### Cosign `sign-blob` on top of SLSA — not picked

Goreleaser's own release pipeline runs `cosign sign-blob` against each artifact in addition to producing SLSA provenance, and an earlier draft of this doc recommended the same. On second look the case doesn't hold up: SLSA provenance already attests the artifact's SHA-256 as the in-toto subject, so `gh attestation verify` is the strictly stronger check — it confirms "the bytes I'm holding match what the provenance signed" *and* binds workflow identity, commit, and builder. `cosign verify-blob` would give a downstream verifier the bytes claim only, and would do so via a separate signature, separate verification command, and separate failure mode. The only argument for shipping it is verifier-tool familiarity — a sigstore-literate consumer who runs `cosign verify` on container images can `cosign verify-blob` a Go binary without reaching for `gh attestation verify`. That is a UX argument, not a security argument; it does not justify the extra signing step, the extra signature artifact, or the second verifier surface to document. If adopters request `cosign verify-blob` ergonomics later, expose it as an opt-in input on the Go build action — but don't make it the default. Same posture as wrangle's other build types: one strong signature path, not two.

#### Publish-first, attest-second (the picked sequence)

Wrangle does NOT force goreleaser into `--skip=publish`. Doing so would neuter every downstream goreleaser verb — Docker pushes, Homebrew taps, deb/rpm/snap, AUR, Slack/Discord announcements, all the post-build distribution the adopter put in their `.goreleaser.yml`. For most adopters, those features are most of why they reach for goreleaser; wrangle taking over the publish would be a major UX regression.

The sequence is therefore:

1. **Goreleaser publishes natively** on tag push (`release --clean`, no `--skip=publish`). It creates the GitHub Release, attaches archives + checksums, and runs every adopter-configured downstream verb.
2. **Wrangle attests** by handing `dist/checksums.txt` to `actions/attest-build-provenance` (`subject-checksums: dist/checksums.txt`) in the `attest:` job, producing a signed Sigstore bundle.
3. **Wrangle verifies and attaches** in the `verify:` job: ampel verifies the provenance against the wrangle PolicySet (fail-closed against `common.identities` + the SLSA tenets), emits the signed per-binary VSA, and attaches it to the same release on tag pushes — surfacing any mismatch loudly even though the bytes are already live. The provenance bundle itself is exposed as a workflow artifact.

This is the same shape wrangle's container build type uses (`docker push` then `actions/attest-build-provenance`). The small window between goreleaser's publish and the provenance arriving is acceptable: the provenance attests content-addressed hashes, so consumers who download in the window can verify once the attestation lands, and hashes don't change in transit. Adopters who want a stronger "no naked window" guarantee can opt out by setting up their own release pipeline; wrangle's posture matches the established container path.

On non-tag events goreleaser runs `release --clean --snapshot --skip=publish` — `--snapshot` because `release` refuses to run off a tag, `--skip=publish` because there's no release to publish to. PR builds exercise the goreleaser pipeline without publishing.

**Predicate version (v1).** `actions/attest-build-provenance` emits `slsa.dev/provenance/v1` with buildType `https://actions.github.io/buildtypes/workflow/v1`. The Go build type uses the same producer as wrangle's container, python, and npm types (all moved to it in #316), so all four emit v1 predicates with a wrangle-workflow `builder.id`. The old generic generator emitted `v0.2` and named itself as `builder.id`; #316 closed both gaps at once.

#### Alternative: ecosystem-specific Go builder (`builder_go_slsa3.yml`) — not picked

`slsa-framework/slsa-github-generator/.github/workflows/builder_go_slsa3.yml` is an ecosystem-specific Go *builder* that performs the build itself inside the same reusable workflow that signs the provenance, driven by a `.slsa-goreleaser.yml` config file (the filename predates goreleaser conventions; the format is the SLSA builder's own). `slsa-verifier`'s [release workflow](https://github.com/slsa-framework/slsa-verifier/blob/main/.github/workflows/release.yml) demonstrates the canonical 6-cell `os × arch` matrix. **L3 isolation is comparable to wrangle's picked approach** — both run the build inside a reusable workflow the adopter can't falsify, both sign provenance via Sigstore against the workflow's OIDC identity. Per [`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) §"Would switching to an ecosystem-specific builder close the L3 gaps?", the only L3-relevant property the ecosystem-specific Go builder enforces that wrangle does not get by-construction is the `::stop-commands::` guard around the compile step (defense-in-depth against workflow-command injection via build-tool stdout) — and that gap was closed for wrangle's existing build types in #230, so the Go implementation should adopt the same guard regardless of which builder model it uses. The actual remaining difference is **operational**: the ecosystem-specific builder binds build and sign in one upstream-controlled reusable workflow with no caller hook, so wrangle's `syft` / `go test` / `release_gate` steps either run on a separate checkout (against different bytes than the builder produces) or don't run at all. Wrangle's approach keeps build and attest as separate jobs *inside its own* reusable workflow, with the hygiene steps in between. Wrangle does not currently plan an ecosystem-specific-builder variant; adopters with a specific need can file an issue. The ecosystem-specific Go builder also doesn't support `pull_request` triggers (per the upstream README).

### Linting — `gofmt` + `golangci-lint` in source scans (tracked under #194; build-action stop-gap shipped)

`gofmt` is mandatory (built into the Go toolchain); CI typically runs `gofmt -l .` and fails if the output is non-empty. [`golangci-lint`](https://golangci-lint.run/) is the canonical aggregator (vet, staticcheck, errcheck, ineffassign, unused, etc.), used by the goreleaser repo, slsa-verifier, oras, and most production Go projects.

The wrangle-wide convention is **source-stage lint** (in `actions/scan` alongside OSV/Zizmor/Scorecard, not in the build action) — same placement npm picks. Wiring language-specific linters into `actions/scan` is tracked across the build types under [#194](https://github.com/TomHennen/wrangle/issues/194); Go fits the same shape (`gofmt` + `golangci-lint`) as the npm entry that issue currently scopes. Until #194 lands, the Go *build action* runs `gofmt -l .` (fail if non-empty) and `go vet ./...` as cheap toolchain-bundled gates — they don't produce SARIF and don't fold into the unified metadata layout, but they prevent the egregious "wrangle let unformatted code ship" failure mode that `go build` / `go test` / `goreleaser` would otherwise miss (none of those tools enforce `gofmt`). When source-stage lint lands, these build-action gates can be removed.

### Tests — `go test ./...` before build

Run `go test ./...` (with `-race` on the linux-amd64 cell when not cross-compiling) before the build step. Tests run naturally before build; this isn't a wrangle-imposed ordering. Combined with the reproducibility flags below, the wrangle-tested source compiles to the same bytes `actions/attest-build-provenance` attests — the test run *does* certify the released artifact, not just an arbitrary checkout. The container build type has the same property (build, then SBOM, then sign, then provenance; the bytes don't change between steps).

### Reproducibility — `-trimpath -buildvcs=false` by default; CGO opt-in only

Out of the box, `go build` embeds build info (working directory, VCS revision, dirty flag, build timestamps) into the binary, which breaks bit-for-bit reproducibility. Two flags get most of the way without operational cost:

- **`-trimpath`** — strips local filesystem paths. No runtime impact. Recommend by default.
- **`-buildvcs=false`** — suppresses VCS-info embedding. No runtime impact. Recommend by default.

Goreleaser exposes both via `builds.flags`; the wrangle action should set them by default and let `.goreleaser.yml` opt out.

`CGO_ENABLED=0` is sometimes mentioned in the same breath but should **not** be a default. Disabling cgo can cost real performance (cgo-backed `net` and `os/user` resolvers, third-party crypto/compression libraries that link C, etc.) and breaks any program whose own dependencies require cgo. Treat it as an opt-in input the adopter sets only if they specifically want pure-Go binaries.

Under the picked approach wrangle's test step and the attest step both run against the same bytes goreleaser produced in the same workflow, so reproducibility isn't needed to close a wrangle-vs-builder gap (the ecosystem-specific-builder gap doesn't apply here). The published artifact IS the binary consumers run — they don't typically rebuild from source. Reproducibility's primary value is **for security audits and SLSA verification chains** that want to confirm "the bytes the provenance attests came from this source," not for routine consumer use. The two zero-cost flags pay for themselves; cgo-disabling doesn't.

### Permissions architecture — checks and release as separate jobs

The reusable workflow splits the build into two jobs with different permissions:

- `checks` (`contents: read`) — `gofmt`, `go vet`, `go test`, `govulncheck`.
- `release` (`contents: write`) — `goreleaser` (which publishes inline on tag pushes), `syft`, hash computation.

The split exists because `go test` executes arbitrary adopter test code (and `govulncheck` walks the full callgraph). Composite actions inherit their calling job's permissions; if those two steps lived in the same composite as the `goreleaser` invocation, `go test` would run with `contents: write` — meaning a compromised dependency or hostile test could use `$GITHUB_TOKEN` to push to the repo. Splitting denies that capability.

The split costs ~30s of extra latency (a second checkout + setup-go). The L3 audit pattern from #226 (release-vs-PR cache asymmetry) is preserved on both sides: both composites accept the `cache` input and disable caching on release builds.

`release` depends on `checks` via `needs:`, so quality gates always run first and a failure blocks any bytes from shipping.

Adopters consuming via direct composite mode forfeit this isolation (everything runs in their own job under whatever permissions they grant). That's already documented as a non-L3 path.

### Cache isolation — release-vs-PR asymmetry applies to Go

`actions/setup-go` enables two caches by default, both restored from GitHub's cache service with the standard branch-scoped rules. The two have different re-verification properties:

- **`$GOPATH/pkg/mod` (module cache).** Holds downloaded + extracted module source. `go.sum` pins module integrity, but the toolchain does **not** re-hash the extracted tree on every build: on a warm cache `download()` returns the extracted directory on structural markers alone (a `.ziphash` sidecar present, no `.partial` file), and `checkMod` verifies only that *sidecar* hash against `go.sum` — never the bytes the compiler reads. So a restored cache whose extracted source was tampered with (sidecar left intact) compiles the poisoned source undetected; empirically confirmed against go1.22 (`modfetch.download`/`DownloadDir`/`checkMod`, `modcmd/verify.go`). The one thing that re-hashes the tree is an explicit `go mod verify`, which compares it to the sidecar — and since a normal build independently pins that sidecar to `go.sum`, running `go mod verify` before the build transitively pins the extracted tree to `go.sum`. So the module cache is **not** automatically npm-like: `npm ci` re-verifies every tarball on each install; Go reaches the equivalent only when you add `go mod verify`. Absent that step it is uv-shaped (trust-on-restore), narrower only because the sidecar↔`go.sum` link still rejects a tampered *zip*.
- **`~/.cache/go-build` (build cache).** Holds compiled object files keyed by an action ID (a content fingerprint over source, toolchain, and flags). On a cache hit the toolchain serves the stored output by name + size with no content re-hash on the path the linker consumes (`cache.GetFile`/`OutputFile`; only the in-memory `GetBytes` path checks `sha256 == OutputID`, and `GODEBUG=gocacheverify` is off by default). There is no checked-in source-of-truth for compiled output — `go.sum` covers inputs, not build products — so a planted entry with a matching action ID is trusted. **This is the load-bearing GAP, and unlike the module cache it has no `go mod verify` analogue** — structurally the same shape as the uv-cache GAP in [`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) Finding 1.

The conservative posture for L3 isolation is the **release-vs-PR cache asymmetry pattern** established in #226: PR builds keep both caches enabled (fast iteration, no L3 attestation produced); release builds disable both via `actions/setup-go`'s `cache: false`. Disabling the module cache is **not** redundant: without a `go mod verify` gate its extracted tree is trusted on restore (above), so a release build that consulted it would inherit the uv-shaped gap. `cache: false` disables both caches with one knob and sidesteps the question; keeping the module cache on for release would mean an explicit `go mod verify` after restore plus split per-cache `actions/cache` steps (setup-go's single knob can't disable just the build cache) — more machinery than the attested path warrants. The Go build composite exposes a `cache: enabled|disabled` input that the reusable workflow flips on `should-release`, identical in shape to python's uv-cache gating. Direct callers of the composite (not a supported L3 path) get caching by default; they aren't claiming L3 provenance.

This adds Go alongside python-uv and container as the third release-cache-disabled path; [`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) gets a per-builder verdict update when the Go implementation lands.

### Authentication — `GITHUB_TOKEN` only

Publishing to GitHub Releases requires `contents: write` (goreleaser creates the release; the `verify:` job also needs it to attach the per-binary VSA, and python's caller already grants it). No external registry credentials, no Trusted Publisher to configure, no API tokens. This is the simplest auth model of any artifact-producing build type.

The permission cascade lesson from python ([HOW_TO_ADD_A_BUILD_TYPE.md "Permission cascade through nested reusable workflows"](../../../docs/HOW_TO_ADD_A_BUILD_TYPE.md)) applies: callers must grant the union of every job's declared permissions. For the picked path the union is `id-token: write` (Sigstore signing in the `attest`/`verify` jobs), `contents: write` (goreleaser publish + VSA attach), and `attestations: write` (the `attest` job writes to GitHub's attestation store). Note the absence of `actions: read` — that was the former generator's requirement; `actions/attest-build-provenance` does not need it.

`pkg.go.dev` indexing is automatic — `proxy.golang.org` discovers tags within minutes of `git push --tags`. No publish step, no auth.

## Validation-only sub-shape (non-binary repos) — deferred to v0.2.x

Library-only modules and `go install`-pattern repos that don't produce a binary at release time are *not* permanently out of scope. The value-add wrangle would offer them — SBOM (`syft dir:.` against the source tree), `go test ./...`, vulnscan via `osv-scanner` against `go.sum` (or `govulncheck` as a Go-aware alternative), and lint (`gofmt`, `golangci-lint`) — is real, and the surface is structurally similar to wrangle's existing `shell` build type (validation-only, no artifact, no provenance). What this sub-shape doesn't add is SLSA build provenance — there's no build artifact wrangle produces, so there's nothing to attest; `sum.golang.org`'s tlog already serves source integrity for `go install`-style consumers, and SLSA source-track attestations (a separate workstream) cover the "this tag was reviewed/tested/scanned by my CI" property orthogonally.

**v0.1 ships binary mode only.** `validate_inputs.sh` rejects any project without a `.goreleaser.yml` (or `.goreleaser.yaml`). Adopters who fit the validation-only shape need to wait or wire `syft`/`go test`/`osv-scanner` from their own workflow against the existing wrangle adapters in the meantime. Implementation of the sub-shape (likely a `mode:` input on the Go build type — `mode: binary` vs. `mode: validate-only`, auto-detected from `.goreleaser.yml` presence — rather than a sibling `build/actions/go-validate/` directory) is tracked for a v0.2.x point release. To be filed as a follow-up issue.

## ko / container builds

Go projects that publish container images via [`ko`](https://ko.build/) (small distroless images built directly from Go modules without a Dockerfile) are **out of scope for v0.1**. ko uses its own toolchain (it doesn't drive `docker buildx` or consume a Dockerfile), so wrangle's existing container build type — which expects a Dockerfile and `docker buildx build` — does not cover the ko case. A ko-aware build type (or a `mode: ko` variant of the Go build type that invokes `ko build` and hands the resulting OCI digest to the container provenance generator) is a possible follow-up but isn't in scope for the Go Phase 1 design.

## Wrangle's value-add

Across both binary releases and the validation-only sub-shape, wrangle adds the same set of properties an adopter would otherwise re-implement per repo:

- **SBOM generation** with a verified-install syft, written to the unified `metadata/go/<shortname>/` layout.
- **Test gating** — tests must pass before SLSA provenance is generated (binary mode) or before the workflow declares success (validate-only mode).
- **Vulnscan** via the existing source-scan infrastructure (OSV-Scanner against `go.sum`).
- **Lint** via `gofmt` + `golangci-lint`.
- **Release-events gating** — the `release_gate` job decides whether to run the `attest`/`verify` jobs at all (binary mode); the same predicate vocabulary as python.
- **Checksum-pinned handoff** to `actions/attest-build-provenance` (binary mode) — the attest step reads `dist/checksums.txt` directly, no string interpolation across job boundaries, no surface for a hash-substitution attack.
- **Consistent metadata layout, step summary, and artifact upload naming** — same shape as every other build type.
- **One-line adoption** — a single `uses:` line replaces a multi-step workflow.

The build artifact differs across the two modes (release binaries vs. nothing), but the value-add is the same.

## Awkward cases

- **Multi-binary repos** (`cmd/foo`, `cmd/bar` under one module). Goreleaser handles multiple `builds:` entries in one config, and `dist/checksums.txt` covers every artifact in a single subject set `actions/attest-build-provenance` attests. Clean fit.
- **Cross-compilation matrices.** Handled inside the goreleaser config; one CI job builds all targets. Operationally simpler than per-cell workflow fan-out (which the ecosystem-specific Go builder requires).
- **CGo / platform-specific toolchains.** `CGO_ENABLED=1` builds need a C toolchain matching the target OS, which usually means per-OS runners. Goreleaser supports this with `builds.env` and runner matrix; cross-compiling CGo is hard regardless of build type.
- **Library-only modules.** Handled via the validation-only sub-shape above.
- **`vendor/` directories and Go workspaces (`go.work`).** Goreleaser supports both natively; wrangle inherits whatever goreleaser does. Worth a fixture if either lands in the v0.x scope.

## Implementation notes

Practical notes for whoever picks up the implementation PR.

- **Match python's reusable-workflow shape.** `build_and_publish_go.yml` mirrors `build_and_publish_python.yml`: a `checks`/`release` build pair, a `gate` job (`lib/release_gate.sh`), an `attest` job (`actions/attest-build-provenance`, gated on `should-release`), and a `verify` job (`actions/verify` verifying the provenance against the wrangle PolicySet and emitting the signed VSA, gated on `should-release`). Outputs follow the unified naming: `metadata-artifact-name`, `dist-artifact-name`, `provenance-artifact-name`, `should-release`.
- **Goreleaser invocation.** Use `goreleaser/goreleaser-action` SHA-pinned, with `args: release --clean`. Set `-trimpath` and `-buildvcs=false` defaults via `.goreleaser.yml` template the action ships, or document them as a hard requirement on the adopter's config.
- **Subjects.** Pass `subject-checksums: dist/checksums.txt` to `actions/attest-build-provenance` — not a `dist/*` glob: goreleaser writes non-artifact bookkeeping (`artifacts.json`, `config.yaml`, `metadata.json`) and per-target build subdirs into `dist/` that are not released artifacts. The checksums file is the canonical released-artifact set, and the same set the VSA binds to.
- **`::stop-commands::` guard around build/test invocations.** The ecosystem-specific Go builder wraps the compile step in a `::stop-commands::` directive so workflow-command injection via build-tool stdout is neutralized. Wrangle adopted this for its existing build types in #230 via the shared `lib/stop_commands_guard.sh` helper; the Go build action MUST use the same helper around `goreleaser` and `go test` invocations. See npm's `build/actions/npm/build_and_pack.sh` and python's `build/actions/python/run_tests.sh` for the invocation pattern.
- **Cache gating on release status.** Goreleaser caches the Go module cache and build cache by default. Per the release-vs-PR build asymmetry pattern established in #226 (see [`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) §"Release-vs-PR build asymmetry"), the Go build action should leave caches enabled for non-release events and disable them on release events — caches that are unsafe to use for an L3-attested build are safe for a PR build because no provenance is produced.
- **Predicate version.** `actions/attest-build-provenance` emits `slsa.dev/provenance/v1` (buildType `https://actions.github.io/buildtypes/workflow/v1`), same as wrangle's other build types since #316.
- **Integration fixture.** A `go/` directory in the wrangle-test companion repo with a minimal `go.mod`, `cmd/example/main.go`, a `.goreleaser.yml`, and a `tests/` directory. The `test-go` job in `test-wrangle.yml.template` grants `contents: write`, `id-token: write`, `attestations: write`.

## Open questions

- **Binary vs. validate-only as one action or two.** See "Validation-only sub-shape." Decide in the implementation PR.
- **Lint placement is decided: source-stage only.** Lint runs in `actions/scan` alongside OSV/Zizmor/Scorecard, not in the Go build action. Wrangle-wide; python and container should adopt source-stage lint too in the same iteration to stay consistent.
- **`.goreleaser.yml` template ownership.** Should wrangle ship a starter `.goreleaser.yml` for adopters (with `-trimpath` / `-buildvcs=false` baked in), or require adopters to bring their own and validate it has the reproducibility flags? Python doesn't ship a starter `pyproject.toml`; consistency with python argues "require adopters to bring their own."
- **`govulncheck` for Go-aware vulnscan, complementary to OSV-Scanner.** Recommendation is to support `govulncheck` for Go projects — it's Go-aware (callgraph-based), so it has a lower false-positive rate than lockfile scanning by reporting only vulnerabilities actually reachable from the project's code. OSV-Scanner against `go.sum` stays as a candidate too (it complements rather than competes — OSV catches vulnerable deps the callgraph misses). Decide whether to ship both or just `govulncheck` in the implementation PR; not load-bearing for Phase 1.

## Follow-ups tracked separately

- **macOS codesigning + notarization for native-binary build types.** Out of scope for the Go build type itself. Go projects that need hardware-backed key custody on macOS (Secure Enclave with the `keychain-access-groups` entitlement) require codesigning + notarization in the release pipeline — without it, the binary can sign with the Enclave but can't persist keys across process restarts. The same need applies to Rust, C, and any other ecosystem that ships native macOS binaries, so this is better solved as a separate, build-type-agnostic action (e.g., `actions/sign-macos/`) rather than baked into the Go build type. Testing the full notarization round-trip takes real effort; tracking-only for now. To be tracked in a follow-up issue.
