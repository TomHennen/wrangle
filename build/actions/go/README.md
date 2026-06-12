# Wrangle Build Go

Wrangle wraps your existing `.goreleaser.yml` — it doesn't replace it. You keep your goreleaser config and everything it already does (Docker pushes, Homebrew taps, deb/rpm, announcements). Wrangle adds the security drudgery around it: gofmt/vet/test/govulncheck, an SPDX SBOM, SLSA Build L3 provenance, and a signed VSA your users can verify with one command.

This build type is for Go projects that ship binaries: it builds them with goreleaser and publishes downloadable archives to a GitHub Release. Ship a CLI people `go install` today? Adopting wrangle additionally gets your users attested, downloadable binaries — and `go install` keeps working unchanged. Library-only modules (no binary to build) aren't supported ([#239](https://github.com/TomHennen/wrangle/issues/239)).

## Quick start

Copy [`build_go.yml`](../../../gh_workflow_examples/build_go.yml) into `.github/workflows/` and set `path`:

```yaml
jobs:
  build:
    permissions:
      contents: write         # goreleaser creates the Release; verify attaches the VSA
      id-token: write         # Sigstore keyless signing
      attestations: write     # GitHub-issued SLSA provenance
      actions: read           # source scan
      security-events: write  # scan findings -> Security tab
    uses: TomHennen/wrangle/.github/workflows/build_and_publish_go.yml@v0.2.0
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

Push a `v`-prefixed semver tag (e.g. `v1.2.3`) and wrangle runs the full pipeline and publishes the release. PRs build and test without publishing.

## What you get

- **Source scan** built in — vulnerable dependencies (OSV), unsafe workflow patterns (Zizmor), and more ([details](../../../actions/scan/README.md)); a load-bearing finding blocks the release. No separate scan workflow needed.
- **Checks before bytes ship** — gofmt, `go vet`, `go test`, govulncheck run in a read-only job; a failure blocks the release job.
- **An SPDX SBOM**, uploaded as a workflow artifact.
- **SLSA Build L3 provenance** tying each artifact to the workflow that built it ([the conditions behind the claim](../../../docs/SLSA_L3_AUDIT.md)).
- **A signed VSA** attached to the release, so downstream users can verify your artifacts with one command.

## Good to know

- **Tags must be `v`-prefixed semver** (`v1.2.3`) — goreleaser derives the version from the nearest `v*` tag. No `v*` tags yet? Use the [example config](../../../gh_workflow_examples/build_go.goreleaser.yml)'s snapshot template, which doesn't depend on tag history.
- **Provenance covers everything in `checksums.txt`.** Docker images and Homebrew taps goreleaser pushes are *not* covered — pair with wrangle's [container build type](../container/README.md) for images.
- **`pull_request_target` can't trigger this workflow** — wrangle refuses it at startup (likewise `workflow_run` chained from it); those triggers hand fork PRs elevated access.
- **`release-events`** (default: `tag-only`) controls which events run the full pipeline — see [`docs/SPEC.md`](../../../docs/SPEC.md) "Release-events gating".
- **Workflow outputs** are documented in [`build_and_publish_go.yml`](../../../.github/workflows/build_and_publish_go.yml) itself.

## Cross-compiling

Want binaries for platforms beyond linux/amd64? Without cgo, Go cross-compiles everywhere for free — goreleaser's default matrix already builds linux, darwin, and windows on amd64 and arm64. With cgo enabled, the runner's C toolchain only targets linux/amd64, and anything else fails with opaque `# runtime/cgo` errors. In that case:

| Situation | Fix |
|---|---|
| You don't actually need cgo (most projects) | Set `CGO_ENABLED=0` in `builds.env`. |
| cgo, but only linux/amd64 | Restrict `goos: [linux]`, `goarch: [amd64]` — the runner's native gcc handles it. |
| cgo + multi-arch / darwin | Pass `install-zig: true` and set `CC=zig cc -target <triple>` per build — working config in the [cgo example](../../../gh_workflow_examples/build_go_cgo.goreleaser.yml). |
| cgo + another toolchain (musl-gcc, mingw) | Install it in `before.hooks` and set `CC=`/`CXX=` yourself; leave `install-zig` unset. |

## Verifying what you shipped

Downstream users verify a release archive with one command. Download the archive and its VSA (`<archive>.intoto.jsonl`) from the release, then ([ampel](https://github.com/carabiner-dev/ampel) ≥ v1.3.0):

```bash
ampel verify --subject <archive> \
  --policy git+https://github.com/TomHennen/wrangle@v0.2.0#policies/wrangle-vsa-consumer-v1.hjson \
  --attestation <archive>.intoto.jsonl \
  --context expectedResourceUri:pkg:golang/<module-path>@<version> \
  --context sourceRepo:https://github.com/<your-org>/<your-repo>
```

That single command checks — fail-closed — the signature, wrangle's signer identity, that the build ran in *your* repo, and that policy passed at SLSA Build L3. The module path is the `module` directive in your `go.mod`. No ampel? See the [artifact verification guide](../../../docs/verifying_artifacts.md) for an equivalent cosign recipe and the full trust model.

## Further reading

- [`SPEC.md`](./SPEC.md) — design rationale: tool choices, permissions architecture, cache isolation.
- [`docs/verifying_artifacts.md`](../../../docs/verifying_artifacts.md) — consumer verification: ampel, cosign, `gh attestation verify`, and the publish/attest timing model.
- [`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) — the conditions behind the Build L3 claim.
- [goreleaser customization](https://goreleaser.com/customization/) — the underlying build tool.
