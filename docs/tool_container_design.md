# Tool containerization — proposal (#596)

Status: **proposal for discussion, not yet implemented.** SPEC.md remains the contract of record until
this lands.

This proposes re-homing wrangle's tool layer so each tool ships as a **pinned OCI image implementing the
adapter contract**, invoked by the orchestrator via `docker run`. The container becomes the unit of
distribution *and* isolation.

## 1. Problem

Wrangle's tool layer solves four problems at once, each only partially:

1. **Dependency management.** Tool versions are spread across `tools/go.mod` tool directives (osv,
   ampel, bnd, cosign, wrangle-lint, …), a bespoke `install.sh` (syft), a pip `requirements.txt`
   (zizmor), and action wrappers. Coverage is uneven and drift is a recurring review finding
   (#264/#277/#286).
2. **Speed.** Adapter tools are compiled from source on every run: `run.sh` `go install`s osv-scanner's
   dependency tree cold, which is slow enough that the scan action raises `WRANGLE_INSTALL_TIMEOUT` from
   its 300 s default to 900 s. The Go build cache that would help is off by default on attested paths
   for SLSA-L3 reasons.
3. **Supply-chain isolation.** A tool today is contained by a stripped environment, the adapter
   contract, and a post-run filesystem snapshot — not a real sandbox. Stronger isolation was deferred
   (#267), and each bespoke `install.sh` adds audit surface.
4. **Ease of adding a tool.** A new tool means choosing an install method, wiring verification, and
   carrying GitHub-Actions-specific dispatch (#137).

A single primitive — a pinned image behind a fixed contract — addresses all four: the digest is the
version, the prebuilt layer removes the per-run compile, the container is the sandbox, and "add a tool"
becomes "publish an image that honors the contract."

## 2. Goals and constraints

**Hard constraints:**

- **C1 — dependency visibility preserved.** Pinning by opaque digest alone (no manifest, no SBOM) is out.
- **C2 — faster** than install-at-runtime.
- **C3 — broadly applicable** to most tools (an occasional non-transitionable tool is acceptable).
- **C4 — no harder to coordinate wrangle updates.**

**Premises:** **P-a** tool binaries are stable; the glue and output routing change more often than the
tools. **P-b** adopters may want to supply their own tool as a conforming image. **P-c** non-GitHub
portability is desirable but not required.

**Key risk to weigh.** The proposal adds a publish-then-consume step: a tool fix isn't available until
its image is published. The mitigations (below) lean on P-a — but P-a is also why the speed pain is
modest. The design keeps the release-before-use cost small by keeping the volatile parts (output
routing, policy, signing) on the orchestrator and only the stable binary in the image.

## 3. Proposal

### 3.1 The contract

The orchestrator runs each tool as:

```
docker run --rm --network <policy> -u <runner_uid>:<gid> \
  -v <src>:/src:ro -v <out>:/output [-e WRANGLE_KIND=<kind>] [declared tool env] <image> /src /output
```

- **Mounts** — `/src` read-only, `/output` writable; the tool writes nothing outside `/output`.
- **Ownership** — the container runs as the runner UID/GID, or output files are written as `root` and
  the runner cannot consume them.
- **Network** — `--network none` by default; egress is a **per-tool** opt-in (not per-kind). Some tools
  need it: zizmor's online audits reach the GitHub API, osv refreshes its advisory DB. *Granularity:*
  Docker offers deny-all vs allow-all cheaply; a true domain allowlist needs an egress proxy, so opt-in
  initially means full egress for the tools that declare it.
- **Secrets** — `scan`/`sbom` tools receive none by default; a tool needing an authed call (zizmor → a
  GitHub token) declares it and receives it through the existing `WRANGLE_EXTRA_` channel.

### 3.2 Isolation

`docker run` replaces `run.sh`'s in-process isolation, so each current mechanism is carried over
deliberately:

| Today (`run.sh`) | Container equivalent |
|---|---|
| `env -i <allowlist>` — adapter sees only allowed env | bare `docker run` inherits nothing; allowed vars passed explicitly with `-e` |
| `WRANGLE_EXTRA_*` forwarding | explicit `-e WRANGLE_EXTRA_*` per declaring tool |
| post-run filesystem snapshot (warn-only) | `/src:ro` + `/output`-only mount — fail-closed write confinement, an upgrade |

SPEC's Adapter Script Interface (environment/security sections) is updated in the same change.

### 3.3 Tool kinds

The contract is parameterized over tool kind:

| Kind | Input | Output | Exit | Adopter-substitutable |
|------|-------|--------|------|-----------------------|
| `scan` | `src_dir` (ro) | `output.sarif` (SARIF 2.1.0) | 0 clean / 1 findings / 2 error | yes |
| `sbom` | `src_dir` or built artifact | `sbom.<format>.json` (SPDX or CycloneDX, declared) | 0 ok / 2 error | yes |
| `attest`/`verify` | metadata + targets | signed attestations / verdict | tool-specific | no |

`sbom` declares its format rather than assuming SPDX; its exit codes have no "findings" state; and its
input may be a built artifact, not source. Everything else matches today's adapter interface.

### 3.4 Packaging

A tool's build path follows from **who owns it**:

| Class | Examples | Build path |
|---|---|---|
| Owned Go, adapter in the binary | wrangle-lint, wrangle-attest, a unified `wrangle` | ko / goreleaser `kos:` (the binary is contract-native) |
| Third-party tool wrapped | osv, syft, zizmor | Dockerfile via `build_and_publish_container` |
| Adopter's own tool | a BYO SBOM generator | adopter's choice; wrangle ships only the contract |

For wrapped third-party tools, the image is **built from source** by default: a multi-stage Dockerfile
compiles the tool from wrangle's `tools/go.mod` and copies the binary onto a distroless base. This keeps
the `go.mod` in-repo, so Dependabot, osv, and govulncheck continue to see the tool's transitive
dependencies and wrangle retains the ability to patch a dependency ahead of upstream. The compile moves
from every run to image-publish time. (Building a single tool from the shared `tools/go.mod` and
extracting one binary is validated — see §4.)

zizmor moves into this model too. It is action-pattern today only because Rust/pip install was awkward;
its upstream action's one distinct function — uploading SARIF to the Security tab — is something wrangle
already does for its adapter tools via its own `upload-sarif` steps. Containerizing it (`zizmor --format
sarif` → `output.sarif`, mapping findings to exit 1) removes the action wrapper, the pip path, and the
upstream-action dependency.

### 3.5 Orchestration: run via script, not `uses:`

The orchestrator (`run.sh`) issues the `docker run`; tools are **not** wired in as `uses:` action steps.
This is what lets wrangle own the surface — mounts, network, user, environment, exit-code mapping, and
output layout — rather than ceding it to whatever an action's `action.yml` chooses to do. It also keeps
the model CI-agnostic (#171) and flattens the nested `uses: ./tools/*` composition (#137).

### 3.6 Reference model

The image digest is a **wrangle-curated default**, not something each adopter pins. Two compatible
homes:

- a **defaulted input** on the scan action (`osv-image: ghcr.io/…@sha256:…`), and/or
- a **`tools.lock`** — a single `tool → digest` manifest the orchestrator reads (subsuming the #264
  lock idea), which is the cleaner central store for the pin tooling and gives adopters a transparent
  view of what they run.

Either way, **adopters inherit the image by pinning wrangle**, exactly as they already inherit every
bundled tool version. Wrangle bumps its own default when it updates a tool. An adopter who *overrides*
(brings their own image, or pins a different digest) owns that pin's freshness; wrangle can offer rails
(a `docker` Dependabot entry, a lint warning on a stale override) but cannot vouch for an image it does
not control.

### 3.7 Capability declaration

Two distinct layers:

- **Selection** (per run, adopter-facing): which tools to run and at what policy — today's
  `tools: "osv zizmor:info …"` string.
- **Definition** (static, per tool): a tool name resolves to `{image digest, kind, network, secret,
  output}`. Capabilities live here, alongside the reference model, not in the selection string.

**A capability grant comes from the trusting party — wrangle, or the adopter for their own tool — never
from the image itself.** An image may *request* a capability (e.g. an OCI label), but granting it is the
orchestrator's decision; otherwise the sandboxed tool would define its own sandbox. Grants are therefore
recorded in-repo as reviewable lines, default to `network=none, secret=none`, and are relaxed only
explicitly — consistent with wrangle's least-privilege and input-validation rules.

### 3.8 Configuration, illustrated

The reference model (§3.6) and the capability definition (§3.7) live together in one wrangle-curated
**catalog** (the `tools.lock` of §3.6). Capabilities — network, secret, output format — don't fit
cleanly as action inputs, so the catalog file is the natural home for *definition*; the scan action's
input stays *selection* plus an optional override pointer. Schema below is illustrative; the exact
format is open (§8).

**Internal — wrangle's curated catalog** (wrangle bumps it; adopters inherit by pinning wrangle):

```yaml
# tools/catalog.yaml  — wrangle-maintained, one entry per built-in tool
tools:
  osv:
    kind: scan
    image: ghcr.io/tomhennen/wrangle/osv@sha256:1531…   # built from this repo's go.mod
    network: egress          # default is none; osv refreshes its advisory DB
  zizmor:
    kind: scan
    image: ghcr.io/tomhennen/wrangle/zizmor@sha256:9a4c…
    network: egress
    secret: github-token     # delivered as WRANGLE_EXTRA_GITHUB_TOKEN
  syft:
    kind: sbom
    image: ghcr.io/tomhennen/wrangle/syft@sha256:0b72…
    format: spdx-json
    # network omitted → none; no secret
```

**Adopter — selecting tools** (pin wrangle, choose which to run, optionally point at an override file):

```yaml
# adopter .github/workflows/scan.yml
jobs:
  scan:
    uses: TomHennen/wrangle/.github/workflows/scan.yml@v0.4.0   # pin → inherit the catalog above
    with:
      tools: "osv zizmor:info my-sbom"     # selection + policy (unchanged from today)
      tool-overrides: .wrangle/tools.yaml  # optional; overrides/extends the catalog
```

**Adopter — overriding an image and bringing their own tool**:

```yaml
# adopter .wrangle/tools.yaml  — merged over wrangle's catalog
tools:
  osv:                                       # override a curated default with a different digest
    image: ghcr.io/myorg/osv@sha256:7c1d…    # adopter now owns this pin's freshness
  my-sbom:                                   # BYO a tool wrangle doesn't ship — full definition
    kind: sbom
    image: ghcr.io/myorg/my-sbom-generator@sha256:e88f…
    format: cyclonedx-json
    # no network / no secret → runs under the strictest contract by default
```

What the three pieces demonstrate:
- **Inheritance** — an adopter who only sets `tools:` runs wrangle's curated, cooldown-vetted images
  and pins nothing of their own.
- **Override ownership** — overriding `osv` means pinning a digest the adopter now owns the freshness
  of; wrangle's pin tooling covers its own catalog, not this entry (wrangle can offer a Dependabot
  entry / lint warning, §3.6, but not vouch for it).
- **Trust direction** — `my-sbom`'s capabilities are declared by the *adopter*, in the adopter's file;
  the image grants itself nothing, and an unspecified capability defaults closed (no network, no
  secret).

## 4. Evidence

**Contract mechanic.** A `docker run` invocation of a `scan` adapter and an `sbom` adapter confirms:
`--network none` blocks egress, `/src:ro` blocks writes into source, exit codes 0/1/2 propagate, output
written as `root` unless `-u` is set (hence the ownership requirement), and the `sbom` kind writes
`sbom.<format>.json` with no findings exit.

**Speed.** osv-scanner, delivered three ways on fresh cold `ubuntu-latest` (amd64) runners, building/
fetching the pinned v2.4.0:

| Delivery | Cold acquire | Warm acquire | Build (publish-time) |
|----------|-------------:|-------------:|----------------------|
| `go install` from source (today) | **85.1 s** | 0.29 s | — |
| prebuilt binary (download + verify) | 0.65 s | — | — |
| **container (`docker pull`)** | **1.73 s** | 0.09 s | 97 s build, 82 MB image |

The proposed container delivery cuts the cold acquire from 85 s to 1.7 s (~49×). The win is on the
**cold path** — release builds (forced cold for L3) and adopter first-runs — which is exactly where the
build cache cannot help; on warm PR scans the status quo is already sub-second. The one-time 97 s build
is paid at publish, not per run. (Per-run *scan* time is network-bound by osv's online queries and is
not a meaningful per-delivery signal.)

## 5. Alternatives considered

- **Prebuilt binary (download + verify).** Fastest acquire, but a raw binary carries no `go.mod`
  manifest (no transitive-CVE notices), sits below build-from-source on the integrity ladder, and gets
  no sandbox. Rejected as the delivery mechanism; useful only as the speed floor it establishes above.
- **`FROM <upstream image>`.** Fastest of all (no compile), but the tool's dependencies leave wrangle's
  `go.mod` so the source scan goes blind, and a registry digest is a checksum served by the same source
  as the bytes — straining the "checksums not from the binary's source" rule. Permitted only for tools
  where wrangle accepts delegating build and patch cadence to upstream, and only with the upstream
  image's provenance verified at pull time. Not the default.
- **Tools as raw `uses:` action steps.** Cedes the execution surface to GitHub Actions and ties the
  model to one CI. Rejected in favor of orchestrator-driven `docker run` (§3.5).

## 6. Security model and prerequisites

- **Tool output is an inert assertion.** SARIF/SBOM is schema-validated before wrangle embeds it in any
  signed predicate, and the pass/fail result is derived orchestrator-side. A wrangle signature attests
  *"tool X produced this,"* never *"this is correct"* — important for adopter-supplied tools.
- **Adoption enforcement (the residual prerequisite).** Build-from-source keeps CVE *detection* working
  via the in-repo `go.mod`. What remains is ensuring a published fix is actually *adopted*: the
  consuming reference (image digest) must be freshness/ancestry/cooldown-checked so a stale pin cannot
  pass CI green (the #539/#544 class). This means teaching the pin toolchain (WL005 cooldown,
  `check_pin_ancestry`, `check_pin_freshness`, `bump_action_pins`, `self_ref_pin_paths`) to understand
  OCI `@sha256:` digests, adding a `docker` Dependabot ecosystem, and a DEP_MGMT.md integrity rung for
  images. Because the digest lives in one curated place (§3.6), this is a narrow, wrangle-internal task,
  and it is required only before *production consumption*, not before prototyping.
- **Adopter-supplied images** are adopter-trusted, not wrangle-trusted: they run under the strictest
  contract by default (no network, no secrets), any relaxation is explicit, and wrangle's signature
  covers provenance of the run, not correctness of the tool.

## 7. Scope

- **In scope:** wrapping third-party adapter tools as contract images, osv first.
- **Held, tracked separately:** the attest/verify toolchain (cosign, ampel, bnd, wrangle-attest). It
  shares a `go.mod` and runs together, so it would package as one image — but it *inverts* the sandbox
  (it needs network and the OIDC signing token) and would interpose an image-supply-chain link in front
  of the signing key. That is a different, higher-stakes problem than the scan path and is not part of
  this proposal.
- **Separate feature:** emitting an attested container of an adopter's own Go app (the "free container"
  value-add via goreleaser/ko). It reuses some machinery but serves adopter UX, not the goals here.
- **Left as-is:** tools with official GitHub Actions that gain nothing from containerization stay
  action-pattern (an escape hatch C3 explicitly allows).

## 8. Open questions

- **Invocation arg convention** — positional `<src> <out>` (matches today's adapters) vs
  `WRANGLE_SRC`/`WRANGLE_OUTPUT` env (cleaner, more portable).
- **Catalog schema and overrides** — §3.8 settles the broad shape (a manifest holds *definition* —
  digest + capabilities — because capabilities can't be action inputs; the action carries *selection*
  plus an override pointer). Open: the exact on-disk schema, the catalog file's name/location, and
  whether an adopter override is a file path or inline.
- **Egress granularity** — accept full egress for network-declaring tools, or invest in a filtering
  proxy for true per-domain allowlists (the `network: egress` field in §3.8 is the coarse form).
- **Registry/hosting and multi-arch** — ghcr namespace; amd64-only first or amd64+arm64.
- **SPEC.md** — fold the kind-parameterized contract into the Adapter Script Interface.

## 9. Plan

1. **Prototype osv end-to-end** (scan kind, built from source): `run.sh` invokes the image via
   `docker run`, producing a real `output.sarif` through wrangle's existing collectors. Proves the
   run-via-script integration. *(The contract mechanic and the speed win in §4 are already measured.)*
2. **Freeze the contract in SPEC.md** — the `scan` and `sbom` kinds, the invocation, and the isolation
   mapping (§3.1–3.3).
3. **Make the pin toolchain digest-aware** (§6) — required before any image is consumed in a production
   wrangle workflow.
4. **Migrate osv for real** — published from source via `build_and_publish_container`, referenced as a
   curated default (§3.6), `run.sh` rewired to `docker run`.
5. **Extend to the rest of the adapter tools** — syft as the `sbom` reference implementation (and the
   first adopter-substitutable contract test), then zizmor.
6. **Revisit the held items** — the attest/verify toolbox and the adopter container value-add, each on
   its own merits.
