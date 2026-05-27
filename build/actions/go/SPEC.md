# Wrangle Go Build Type — Phase 1 Research

**Status:** Phase 1 ecosystem research per [`docs/HOW_TO_ADD_A_BUILD_TYPE.md`](../../../docs/HOW_TO_ADD_A_BUILD_TYPE.md). Recommends defaults for the `build/actions/go/` implementation that shipped in #238. The v0.1 implementation is live; the picks below remain the authoritative rationale. See "Inputs" below for the adopter-facing contract; the full input/output table will be backfilled here from `build_and_publish_go.yml` as v0.2 work lands.

## Overview

Go projects in 2026 fall into three release shapes:

1. **Binary releases.** A CI build produces one or more `os × arch` binaries, attaches them to a GitHub Release, and (for security-conscious projects) ships SLSA provenance, Cosign signatures, and SBOMs alongside. Examples: `slsa-verifier`, `cosign`, `oras`, `goreleaser` itself.
2. **Library-only modules.** No `main` package, no binary. Consumers fetch source via `go get` / `go install <module>@<version>`; integrity comes from Go's checksum database (`sum.golang.org`, a Trillian-backed Merkle log over `go.sum`-shaped lines — see the [Go module mirror launch announcement](https://go.dev/blog/module-mirror-launch) and [proposal 25530](https://go.googlesource.com/proposal/+/master/design/25530-sumdb.md)).
3. **`go install <repo>@<tag>` for CLI tools whose maintainers chose not to run a release pipeline.** Equivalent to (1) minus the build job; consumers compile from source on their own machines.

**Operating model.** Wrangle owns the build hygiene — test, SBOM, vulnscan, lint, gating, the unified metadata layout — and produces its own L3 SLSA provenance via the upstream generator, stored in `metadata/go/<shortname>/`. The L3 bundle is verifiable offline by any consumer regardless of where the binary is hosted. Same shape python and container ship today, and the picks below preserve it.

## Inputs

The adopter-facing reusable workflow lives at `.github/workflows/build_and_publish_go.yml`. This section captures the contract for inputs whose intent isn't self-evident from the workflow's `description:` field; the other inputs (`path`, `go-version`, `run-tests`, `run-race-detector`, `run-gofmt-check`, `release-events`, `ref`, `verify-provenance`) are listed for completeness and will be expanded in the v0.2 backfill, modeled on `build/actions/python/SPEC.md` §Inputs.

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `path` | No | `.` | Relative path to the directory containing `go.mod` and `.goreleaser.yml`. |
| `go-version` | No | (auto-detect) | Go version override. If empty, read from `go.mod`'s `go` directive via `actions/setup-go`'s `go-version-file`. |
| `run-tests` | No | `true` | Run the `checks` job (gofmt / vet / test / govulncheck) before release. |
| `run-race-detector` | No | `true` | Run `go test -race`. Set false when CGO is disabled (race detector requires cgo). |
| `run-gofmt-check` | No | `true` | Run `gofmt -l` before build. `// Code generated ... DO NOT EDIT.` files are auto-skipped. |
| `govulncheck-version` | No | `""` (wrangle's vetted pin) | Pinned semver tag (e.g., `vX.Y.Z`) overriding wrangle's vetted `govulncheck` pin. See policy below. |
| `release-events` | No | `tag-only` | Which events trigger wrangle's full pipeline. See [`docs/SPEC.md`](../../../docs/SPEC.md) "Release-events gating." |
| `ref` | No | `""` (uses `github.sha`) | Git ref to check out. |
| `verify-provenance` | No | `true` | Run `slsa-verifier verify-artifact` post-publish. |

### `govulncheck-version` policy

`govulncheck-version` is an **escape hatch** for the CVE-response window: upstream `govulncheck` ships a fix or a new reachability check, the adopter needs the newer scanner *now*, and wrangle's 7-day adoption window hasn't closed. The default (empty) resolves to wrangle's vetted pin (currently `v1.1.4`) — and the recommended setting for most adopters is to leave it empty so the wrangle pin moves uniformly on bump cycles.

The contract:

- **Pinned semver only.** `validate_inputs.sh` matches the input against `^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?(\+[A-Za-z0-9.-]+)?$` and rejects `@latest`, `@main`, branch names, and any other floating ref. `go install` would happily resolve those, so the enforcement is wrangle-side — supply-chain discipline per [`CLAUDE.md`](../../../CLAUDE.md).
- **Fail-fast.** Validation runs before `setup-go`, so an invalid version aborts the checks job before any tool downloads.
- **No GHA expression injection.** The validated value flows through `with:` and `env:` into the composite, never directly into a `run:` block.
- **Pin lives at the env coalesce.** The wrangle default appears three times in `build/actions/go/checks/action.yml` (composite input `default:`, validate-step env coalesce, run-step env coalesce). The pin-sync test in `build/actions/go/test.bats` enforces that all three stay aligned; the reusable workflow's `default: ""` deliberately delegates the pin to the composite so the override path and the default path converge on the same code.

The wrangle pin bumps are coordinated; the override is meant for the gap, not for long-lived divergence.

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

### Attestation — `generator_generic_slsa3.yml` (the generic generator)

**Pick:** Goreleaser produces `dist/checksums.txt`; wrangle hashes those filenames into base64-encoded subjects and hands them to `slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@v2.1.0`. This is the same shape wrangle's python and npm build types use today, and the same shape goreleaser themselves [document and demonstrate](https://goreleaser.com/blog/slsa-generation-for-your-artifacts/).

[`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) §"Ecosystem-specific builders vs the generic generator" sets the terminology used below: the SLSA project ships *ecosystem-specific builders* (e.g., `builder_go_slsa3.yml`) that run the build inside the trusted upstream reusable workflow, and a *generic generator* (`generator_generic_slsa3.yml`) that signs hashes the caller produces. Wrangle uses the generic generator across all build types. The audit concludes that recommendation continues to hold for v0.2.

**Why this pick:**

- **Same shape as python, npm, and container.** The composite owns build/test/SBOM/lint and emits hashes; the SLSA generator runs in a separate reusable-workflow job consuming those hashes; the verify job re-fetches the artifact and runs `slsa-verifier verify-artifact`. Consistency keeps the per-build-type cognitive load low.
- **Preserves the test/SBOM/lint seam.** Wrangle's value-add steps slot between "build" and "provenance" the same way they do for python — the build action emits `dist/`, runs syft against it, runs gating, and then hands off. There's nowhere new to learn.
- **Same L3 isolation as the ecosystem-specific Go builder.** All wrangle reusable workflows already run the SLSA generator inside its own isolated reusable workflow. Both architectures get the L3 "hardened build platform" property by virtue of running through `slsa-github-generator`'s isolated infrastructure; per the L3 audit, switching to `builder_go_slsa3.yml` would not close any conformance gap the generic generator leaves open.
- **`actions/release_gate` works either way.** Wrangle gates the `uses:` invocation of the provenance reusable workflow with `if: ${{ needs.gate.outputs.should-release == 'true' }}`. That predicate-on-the-job-call pattern is build-type-agnostic.

#### Cosign `sign-blob` on top of SLSA — not picked

Goreleaser's own release pipeline runs `cosign sign-blob` against each artifact in addition to producing SLSA provenance, and an earlier draft of this doc recommended the same. On second look the case doesn't hold up: SLSA provenance already attests the artifact's SHA-256 as the in-toto subject, so `slsa-verifier verify-artifact` is the strictly stronger check — it confirms "the bytes I'm holding match what the provenance signed" *and* binds workflow identity, commit, and builder. `cosign verify-blob` would give a downstream verifier the bytes claim only, and would do so via a separate signature, separate verification command, and separate failure mode. The only argument for shipping it is verifier-tool familiarity — a sigstore-literate consumer who runs `cosign verify` on container images can `cosign verify-blob` a Go binary without installing `slsa-verifier`. That is a UX argument, not a security argument; it does not justify the extra signing step, the extra signature artifact, or the second verifier surface to document. If adopters request `cosign verify-blob` ergonomics later, expose it as an opt-in input on the Go build action — but don't make it the default. Same posture as wrangle's other build types: one strong signature path, not two.

#### Publish-first, attest-second (the picked sequence)

Wrangle does NOT force goreleaser into `--skip=publish`. Doing so would neuter every downstream goreleaser verb — Docker pushes, Homebrew taps, deb/rpm/snap, AUR, Slack/Discord announcements, all the post-build distribution the adopter put in their `.goreleaser.yml`. For most adopters, those features are most of why they reach for goreleaser; wrangle taking over the publish would be a major UX regression.

The sequence is therefore:

1. **Goreleaser publishes natively** on tag push (`release --clean`, no `--skip=publish`). It creates the GitHub Release, attaches archives + checksums, and runs every adopter-configured downstream verb.
2. **Wrangle hashes** `dist/checksums.txt`, hands the result to `generator_generic_slsa3.yml`.
3. **The SLSA generator** signs and uploads the `.intoto.jsonl` to the same release via its `upload-assets: true` (gated on tag push).
4. **Wrangle verifies** post-publish with `slsa-verifier verify-artifact`, surfacing any mismatch loudly even though the bytes are already live.

This is the same shape wrangle's container build type uses (`docker push` then `slsa-github-generator` provenance). The small window between goreleaser's publish and the provenance arriving is acceptable: the provenance attests content-addressed hashes, so consumers who download in the window can verify once the attestation lands, and hashes don't change in transit. Adopters who want a stronger "no naked window" guarantee can opt out by setting up their own release pipeline; wrangle's posture matches the established container path.

On non-tag events goreleaser runs `release --clean --snapshot --skip=publish` — `--snapshot` because `release` refuses to run off a tag, `--skip=publish` because there's no release to publish to. PR builds exercise the goreleaser pipeline without publishing.

**Predicate version (v0.2 vs v1).** `slsa-github-generator` v2.1.0 currently emits `slsa.dev/provenance/v0.2`. `actions/attest-build-provenance` emits `v1`. Wrangle's container, python, and npm specs intentionally stay on `slsa-github-generator` for the L3 isolation property; the Go build type follows the same convention. When upstream ships v1, wrangle adopts it across all build types in one change. The doc shouldn't silently endorse `actions/attest-build-provenance` as a substitute.

#### Alternative: ecosystem-specific Go builder (`builder_go_slsa3.yml`) — not picked

`slsa-framework/slsa-github-generator/.github/workflows/builder_go_slsa3.yml` is an ecosystem-specific Go *builder* that performs the build itself inside the same reusable workflow that signs the provenance, driven by a `.slsa-goreleaser.yml` config file (the filename predates goreleaser conventions; the format is the SLSA builder's own). `slsa-verifier`'s [release workflow](https://github.com/slsa-framework/slsa-verifier/blob/main/.github/workflows/release.yml) demonstrates the canonical 6-cell `os × arch` matrix. **L3 isolation is comparable to the generic generator** — both run the build inside an upstream-controlled reusable workflow the adopter can't falsify, both sign provenance via Sigstore against the workflow's OIDC identity. Per [`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) §"Would switching to an ecosystem-specific builder close the L3 gaps?", the only L3-relevant property the ecosystem-specific Go builder enforces that wrangle does not get by-construction is the `::stop-commands::` guard around the compile step (defense-in-depth against workflow-command injection via build-tool stdout) — and that gap was closed for wrangle's existing build types in #230, so the Go implementation should adopt the same guard regardless of which builder model it uses. The actual remaining difference is **operational**: the ecosystem-specific builder binds build and sign in one upstream-controlled reusable workflow with no caller hook, so wrangle's `syft` / `go test` / `release_gate` steps either run on a separate checkout (against different bytes than the builder produces) or don't run at all. The generic generator keeps build inside wrangle's reusable workflow and signs in a separate one — two reusable-workflow boundaries instead of one, with a caller-side hook in between for hygiene. Wrangle does not currently plan an ecosystem-specific-builder variant; adopters with a specific need can file an issue. The ecosystem-specific Go builder also doesn't support `pull_request` triggers (per the upstream README).

#### Alternative: `actions/attest@v4` (one-line) — not picked

GitHub's [`actions/attest@v4`](https://github.com/actions/attest) (used by [`goreleaser`'s own release workflow](https://github.com/goreleaser/goreleaser/blob/main/.github/workflows/release.yml), invoked twice — once over `dist/checksums.txt`, once over Docker digests) emits `slsa.dev/provenance/v1` predicates today, but lacks the L3-isolated-builder property and doesn't compose with wrangle's metadata layout — same reason wrangle's container, python, and npm specs don't use it.

### Linting — `gofmt` + `golangci-lint` in source scans (tracked under #194; build-action stop-gap shipped)

`gofmt` is mandatory (built into the Go toolchain); CI typically runs `gofmt -l .` and fails if the output is non-empty. [`golangci-lint`](https://golangci-lint.run/) is the canonical aggregator (vet, staticcheck, errcheck, ineffassign, unused, etc.), used by the goreleaser repo, slsa-verifier, oras, and most production Go projects.

The wrangle-wide convention is **source-stage lint** (in `actions/scan` alongside OSV/Zizmor/Scorecard, not in the build action) — same placement npm picks. Wiring language-specific linters into `actions/scan` is tracked across the build types under [#194](https://github.com/TomHennen/wrangle/issues/194); Go fits the same shape (`gofmt` + `golangci-lint`) as the npm entry that issue currently scopes. Until #194 lands, the Go *build action* runs `gofmt -l .` (fail if non-empty) and `go vet ./...` as cheap toolchain-bundled gates — they don't produce SARIF and don't fold into the unified metadata layout, but they prevent the egregious "wrangle let unformatted code ship" failure mode that `go build` / `go test` / `goreleaser` would otherwise miss (none of those tools enforce `gofmt`). When source-stage lint lands, these build-action gates can be removed.

### Tests — `go test ./...` before build

Run `go test ./...` (with `-race` on the linux-amd64 cell when not cross-compiling) before the build step. Tests run naturally before build; this isn't a wrangle-imposed ordering. Combined with the reproducibility flags below, the wrangle-tested source compiles to the same bytes the SLSA generator hashes — the test run *does* certify the released artifact, not just an arbitrary checkout. The container build type has the same property (build, then SBOM, then sign, then provenance; the bytes don't change between steps).

### Reproducibility — `-trimpath -buildvcs=false` by default; CGO opt-in only

Out of the box, `go build` embeds build info (working directory, VCS revision, dirty flag, build timestamps) into the binary, which breaks bit-for-bit reproducibility. Two flags get most of the way without operational cost:

- **`-trimpath`** — strips local filesystem paths. No runtime impact. Recommend by default.
- **`-buildvcs=false`** — suppresses VCS-info embedding. No runtime impact. Recommend by default.

Goreleaser exposes both via `builds.flags`; the wrangle action should set them by default and let `.goreleaser.yml` opt out.

`CGO_ENABLED=0` is sometimes mentioned in the same breath but should **not** be a default. Disabling cgo can cost real performance (cgo-backed `net` and `os/user` resolvers, third-party crypto/compression libraries that link C, etc.) and breaks any program whose own dependencies require cgo. Treat it as an opt-in input the adopter sets only if they specifically want pure-Go binaries.

Under the generic generator (the pick) wrangle's test step and wrangle's hash step both run against the same bytes goreleaser produced in the same job, so reproducibility isn't needed to close a wrangle-vs-builder gap (the ecosystem-specific-builder gap doesn't apply here). The published artifact IS the binary consumers run — they don't typically rebuild from source. Reproducibility's primary value is **for security audits and SLSA verification chains** that want to confirm "the bytes the provenance attests came from this source," not for routine consumer use. The two zero-cost flags pay for themselves; cgo-disabling doesn't.

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

- **`$GOPATH/pkg/mod` (module cache).** Holds downloaded module source. The Go toolchain re-verifies cached modules against the project's checked-in `go.sum` on every load — same trust model as `npm ci` re-verifying tarballs against `package-lock.json`. `go.sum` is in the source tree the SLSA generator is attesting, so a poisoned cache entry whose hash doesn't match `go.sum` is rejected at module load time. This is structurally npm-like ("MEETS WITH PRECONDITION" per the audit's terminology), **not** uv-like.
- **`~/.cache/go-build` (build cache).** Holds compiled object files keyed by a content fingerprint over inputs (source files, compiler flags). If an attacker plants an entry with a legitimate fingerprint but malicious compiled output, the toolchain uses the cached output without re-deriving. There is no checked-in source-of-truth hash to compare against (unlike `go.sum` for modules), so the cache contents are trusted on hit. **This is the load-bearing GAP** — structurally the same shape as the uv-cache GAP in [`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) Finding 1: pre-stored compiled output is trusted on cache hits.

The conservative posture for L3 isolation is the **release-vs-PR cache asymmetry pattern** established in #226: PR builds keep both caches enabled (fast iteration, no L3 attestation produced); release builds disable both via `actions/setup-go`'s `cache: false`, so the bytes the SLSA generator signs derive without consulting the unverified build cache. Disabling the module cache alongside is technically unnecessary for L3 (it re-verifies on use) but is cheap and avoids a setup-go knob that only disables one of the two — `cache: false` covers both. The Go build composite exposes a `cache: enabled|disabled` input that the reusable workflow flips on `should-release`, identical in shape to python's uv-cache gating. Direct callers of the composite (not a supported L3 path) get caching by default; they aren't claiming L3 provenance.

This adds Go alongside python-uv and container as the third release-cache-disabled path; [`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) gets a per-builder verdict update when the Go implementation lands.

### Authentication — `GITHUB_TOKEN` only

Publishing to GitHub Releases requires `contents: write` (the same permission `slsa-github-generator`'s `upload-assets` job requires anyway, and the same one python's caller already grants). No external registry credentials, no Trusted Publisher to configure, no API tokens. This is the simplest auth model of any artifact-producing build type.

The permission cascade lesson from python ([HOW_TO_ADD_A_BUILD_TYPE.md "Permission cascade through nested reusable workflows"](../../../docs/HOW_TO_ADD_A_BUILD_TYPE.md)) applies: callers must grant the union of every nested job's declared permissions. For the picked generic-generator path: `id-token: write`, `contents: write`, `actions: read`.

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
- **Release-events gating** — the `release_gate` job decides whether to invoke the SLSA provenance reusable workflow at all (binary mode); the same predicate vocabulary as python.
- **Hash-pinned handoff** to `slsa-github-generator` (binary mode) — no string interpolation across job boundaries, no surface for a hash-substitution attack.
- **Consistent metadata layout, step summary, and artifact upload naming** — same shape as every other build type.
- **One-line adoption** — a single `uses:` line replaces a multi-step workflow.

The build artifact differs across the two modes (release binaries vs. nothing), but the value-add is the same.

## Awkward cases

- **Multi-binary repos** (`cmd/foo`, `cmd/bar` under one module). Goreleaser handles multiple `builds:` entries in one config, and `dist/checksums.txt` covers every artifact in a single hashes string the generic generator can sign. Clean fit.
- **Cross-compilation matrices.** Handled inside the goreleaser config; one CI job builds all targets. Operationally simpler than per-cell workflow fan-out (which the ecosystem-specific Go builder requires).
- **CGo / platform-specific toolchains.** `CGO_ENABLED=1` builds need a C toolchain matching the target OS, which usually means per-OS runners. Goreleaser supports this with `builds.env` and runner matrix; cross-compiling CGo is hard regardless of build type.
- **Library-only modules.** Handled via the validation-only sub-shape above.
- **`vendor/` directories and Go workspaces (`go.work`).** Goreleaser supports both natively; wrangle inherits whatever goreleaser does. Worth a fixture if either lands in the v0.x scope.

## Implementation notes

Practical notes for whoever picks up the implementation PR.

- **Match python's reusable-workflow shape.** `build_and_publish_go.yml` mirrors `build_and_publish_python.yml`: a `build` job (composite action), a `gate` job (`actions/release_gate`), a `provenance` job (`generator_generic_slsa3.yml`, gated on `should-release`), and a `verify` job (`slsa-verifier verify-artifact`, gated on `should-release && verify-provenance`). Outputs follow the unified naming: `metadata-artifact-name`, `dist-artifact-name`, `provenance-artifact-name`, `should-release`.
- **Goreleaser invocation.** Use `goreleaser/goreleaser-action` SHA-pinned, with `args: release --clean`. Set `-trimpath` and `-buildvcs=false` defaults via `.goreleaser.yml` template the action ships, or document them as a hard requirement on the adopter's config.
- **Hashes step.** Same `cd dist && sha256sum * | base64 -w0` shape python uses. Bare filenames (not `./*`) so `slsa-verifier`'s subject match works.
- **`::stop-commands::` guard around build/test invocations.** The ecosystem-specific Go builder wraps the compile step in a `::stop-commands::` directive so workflow-command injection via build-tool stdout is neutralized. Wrangle adopted this for its existing build types in #230 via the shared `lib/stop_commands_guard.sh` helper; the Go build action MUST use the same helper around `goreleaser` and `go test` invocations. See npm's `build/actions/npm/build_and_pack.sh` and python's `build/actions/python/run_tests.sh` for the invocation pattern.
- **Cache gating on release status.** Goreleaser caches the Go module cache and build cache by default. Per the release-vs-PR build asymmetry pattern established in #226 (see [`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) §"Release-vs-PR build asymmetry"), the Go build action should leave caches enabled for non-release events and disable them on release events — caches that are unsafe to use for an L3-attested build are safe for a PR build because no provenance is produced.
- **Predicate version.** Stay on `slsa-github-generator`'s v0.2 predicate today; bump to v1 when upstream ships it across all build types in one change. Don't silently switch to `actions/attest-build-provenance`.
- **Integration fixture.** A `go/` directory in the wrangle-test companion repo with a minimal `go.mod`, `cmd/example/main.go`, a `.goreleaser.yml`, and a `tests/` directory. The `test-go` job in `test-wrangle.yml.template` grants `contents: write`, `id-token: write`, `actions: read`.

## Open questions

- **Binary vs. validate-only as one action or two.** See "Validation-only sub-shape." Decide in the implementation PR.
- **Lint placement is decided: source-stage only.** Lint runs in `actions/scan` alongside OSV/Zizmor/Scorecard, not in the Go build action. Wrangle-wide; python and container should adopt source-stage lint too in the same iteration to stay consistent.
- **`.goreleaser.yml` template ownership.** Should wrangle ship a starter `.goreleaser.yml` for adopters (with `-trimpath` / `-buildvcs=false` baked in), or require adopters to bring their own and validate it has the reproducibility flags? Python doesn't ship a starter `pyproject.toml`; consistency with python argues "require adopters to bring their own."
- **`govulncheck` for Go-aware vulnscan, complementary to OSV-Scanner.** Recommendation is to support `govulncheck` for Go projects — it's Go-aware (callgraph-based), so it has a lower false-positive rate than lockfile scanning by reporting only vulnerabilities actually reachable from the project's code. OSV-Scanner against `go.sum` stays as a candidate too (it complements rather than competes — OSV catches vulnerable deps the callgraph misses). Decide whether to ship both or just `govulncheck` in the implementation PR; not load-bearing for Phase 1.

## Follow-ups tracked separately

- **macOS codesigning + notarization for native-binary build types.** Out of scope for the Go build type itself. Go projects that need hardware-backed key custody on macOS (Secure Enclave with the `keychain-access-groups` entitlement) require codesigning + notarization in the release pipeline — without it, the binary can sign with the Enclave but can't persist keys across process restarts. The same need applies to Rust, C, and any other ecosystem that ships native macOS binaries, so this is better solved as a separate, build-type-agnostic action (e.g., `actions/sign-macos/`) rather than baked into the Go build type. Testing the full notarization round-trip takes real effort; tracking-only for now. To be tracked in a follow-up issue.
