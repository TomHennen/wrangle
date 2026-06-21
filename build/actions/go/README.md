# Wrangle Build Go

Wrangle uses your `.goreleaser.yml` to build your binaries, then takes over the publish: it runs goreleaser with `--skip=publish` and uploads only what it can attest — the archives, `checksums.txt`, and a signed bundle per archive — to a GitHub Release you create. On top of the build, wrangle adds the security drudgery: gofmt/vet/test/govulncheck, an SPDX SBOM, SLSA Build L3 provenance, and a signed VSA your users verify with one command.

This build type is for Go projects that ship binaries. Ship a CLI people `go install` today? Adopting wrangle additionally gets your users attested, downloadable binaries — and `go install` keeps working unchanged. Library-only modules (no binary to build) aren't supported ([#239](https://github.com/TomHennen/wrangle/issues/239)).

Because wrangle publishes only the attested archives + `checksums.txt`, goreleaser's downstream publisher verbs (Docker pushes, Homebrew taps, deb/rpm, announcements) are **not** run — wrangle won't be party to publishing artifacts it can't attest. Need attested images? Pair with the [container build type](../container/README.md). Need a tap or deb/rpm? Run that from a separate job against the binaries wrangle published.

## Quick start

Copy [`build_go.yml`](../../../gh_workflow_examples/build_go.yml) into `.github/workflows/` and set `path`. The example includes a tag-gated `create-release` job — wrangle attaches assets to a pre-existing release and never creates one, so that job (or your own release-creation step) is a precondition:

```yaml
jobs:
  build:
    permissions:
      contents: write         # verify attaches the attested assets to the release
      id-token: write         # Sigstore keyless signing
      attestations: write     # GitHub-issued SLSA provenance
      actions: read           # source scan
      security-events: write  # scan findings -> Security tab
    uses: TomHennen/wrangle/.github/workflows/build_and_publish_go.yml@v0.2.2 # zizmor: ignore[unpinned-uses] - immutable
    with:
      path: "."
```

You also need a `.goreleaser.yml` at `<path>/.goreleaser.yml` — the minimum wrangle recommends (complete version in the [example config](../../../gh_workflow_examples/build_go.goreleaser.yml)):

```yaml
version: 2
builds:
  - main: ./cmd/<your-binary>
    # Both settings make builds reproducible, at zero runtime cost.
    flags: [-trimpath]
    env:
      - GOFLAGS=-buildvcs=false
checksum:
  name_template: "checksums.txt"   # keep this exact name — it's how wrangle knows what to attest
```

Push a `v`-prefixed semver tag (e.g. `v1.2.3`) and wrangle runs the full pipeline, then uploads the attested archives + `checksums.txt` + signed bundles to the release for that tag. PRs build and test without publishing.

## What you get

- **Source scan** built in — vulnerable dependencies (OSV), unsafe workflow patterns (Zizmor), and more ([details](../../../actions/scan/README.md)); a load-bearing finding blocks the release. No separate scan workflow needed.
- **Checks before bytes ship** — gofmt, `go vet`, `go test`, govulncheck run in a read-only job; a failure blocks the release job.
- **An SPDX SBOM, scan findings (incl. govulncheck), and the signed bundle** in one `go-metadata-<sn>` workflow artifact ([what's in it](../../../docs/metadata_layout.md)).
- **SLSA Build L3 provenance** tying each artifact to the workflow that built it ([the requirements it meets](../../../docs/REQUIREMENTS_MAPPING.md)).
- **Release assets on tag pushes** — wrangle uploads the dist archives, `checksums.txt`, each `<archive>.intoto.jsonl` bundle (signed VSA + provenance), and a `go-metadata-<sn>.zip` with the SBOM + scan results to the release you created. Only attested bytes are published. Downstream users verify with one command.

## Good to know

- **Tags must be `v`-prefixed semver** (`v1.2.3`) — goreleaser derives the version from the nearest `v*` tag. No `v*` tags yet? Use the [example config](../../../gh_workflow_examples/build_go.goreleaser.yml)'s snapshot template, which doesn't depend on tag history.
- **You must create the release.** wrangle attaches to a pre-existing GitHub Release for the tag and never creates one; the example's `create-release` job handles this, or add your own `gh release create` step. No release for the tag? The assets stay workflow artifacts only.
- **Provenance covers everything in `checksums.txt`** — the archives wrangle publishes. goreleaser's Docker/Homebrew/deb/rpm/announce verbs don't run under wrangle (it publishes only what it can attest); pair with the [container build type](../container/README.md) for attested images.
- **`pull_request_target` can't trigger this workflow** — that trigger (and `workflow_run` chained from it) is a common exploit vector, so wrangle blocks both at startup.
- **`release-events`** (default: `tag-only`) controls which events run the full pipeline — see [`docs/SPEC.md`](../../../docs/SPEC.md) "Release-events gating".
- **Workflow outputs** are documented in [`build_and_publish_go.yml`](../../../.github/workflows/build_and_publish_go.yml) itself.
- **Enable Dependabot too** — copy [`dependabot.yml`](../../../gh_workflow_examples/dependabot.yml) to `.github/` and uncomment the `gomod` entry. Its `github-actions` entry also keeps your `uses: TomHennen/wrangle/...` pin current.

## Cross-compiling

Want binaries for platforms beyond linux/amd64? Without cgo, Go cross-compiles everywhere for free — goreleaser's default matrix already builds linux, darwin, and windows on amd64 and arm64. With cgo enabled, the runner's C toolchain only targets linux/amd64, and anything else fails with opaque `# runtime/cgo` errors. In that case:

| Situation | Fix |
|---|---|
| You don't actually need cgo (most projects) | Set `CGO_ENABLED=0` in `builds.env`. |
| cgo, but only linux/amd64 | Restrict `goos: [linux]`, `goarch: [amd64]` — the runner's native gcc handles it. |
| cgo + multi-arch / darwin | Pass `install-zig: true` and set `CC=zig cc -target <triple>` per build — working config in the [cgo example](../../../gh_workflow_examples/build_go_cgo.goreleaser.yml). |
| cgo + another toolchain (musl-gcc, mingw) | Install it in `before.hooks` and set `CC=`/`CXX=` yourself; leave `install-zig` unset. |

## Verifying what you shipped

Downstream users verify a release archive with one command. Download the archive and its `<archive>.intoto.jsonl` bundle from the release (it carries the archive's VSA; ampel self-selects the one matching `--subject`), then ([ampel](https://github.com/carabiner-dev/ampel) ≥ v1.3.0):

```bash
ampel verify --subject <archive> \
  --policy git+https://github.com/TomHennen/wrangle@v0.2.2#policies/wrangle-vsa-consumer-v1.hjson \
  --collector jsonl:<archive>.intoto.jsonl \
  --context expectedResourceUri:pkg:golang/<module-path>@<version> \
  --context sourceRepo:https://github.com/<your-org>/<your-repo>
```

That single command checks — fail-closed — the signature, wrangle's signer identity, that the build ran in *your* repo, and that policy passed at SLSA Build L3. The module path is the `module` directive in your `go.mod`. No ampel? See the [artifact verification guide](../../../docs/verifying_artifacts.md) for an equivalent cosign recipe and the full trust model.

The VSA is also posted to your repo's GitHub attestation store, so consumers can fetch it by digest with no download via ampel's `--collector github:<your-org>/<your-repo>` — see the [by-digest path](../../../docs/verifying_artifacts.md#by-digest-from-the-github-attestation-store).

## Further reading

- [`SPEC.md`](./SPEC.md) — design rationale: tool choices, permissions architecture, cache isolation.
- [`docs/verifying_artifacts.md`](../../../docs/verifying_artifacts.md) — consumer verification: ampel, cosign, `gh attestation verify`, and the publish/attest timing model.
- [`docs/REQUIREMENTS_MAPPING.md`](../../../docs/REQUIREMENTS_MAPPING.md) — the SLSA Build L3 requirements mapping (the conditions behind the claim).
- [goreleaser customization](https://goreleaser.com/customization/) — the underlying build tool.
