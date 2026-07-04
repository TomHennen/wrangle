# Tool containerization (#596)

Status: **partially implemented.** osv ships as a pinned OCI image on `main`, dispatched by the
orchestrator via `docker run` and gated at pull time by a fail-closed VSA check; more scan tools and the
signing-path container (#619) are in progress. Not every tool containerizes: scorecard and
dependency-review stay action-pattern (the C3 escape hatch below). SPEC.md remains the contract of record.

Wrangle's adapter tool layer is re-homed so each such tool ships as a **pinned OCI image implementing the
adapter contract**, invoked by the orchestrator via `docker run`. The container is the unit of
distribution *and* isolation.

## 1. Problem

Wrangle's tool layer solves four problems at once, each only partially:

1. **Dependency management.** Tool versions are spread across `tools/go.mod` tool directives (osv,
   ampel, bnd, cosign, wrangle-lint, …), a bespoke `install.sh` (syft), a pip `requirements.txt`
   (zizmor), and action wrappers. Coverage is uneven and drift is a recurring review finding
   (#264/#277/#286).
2. **Speed.** Adapter tools are installed and compiled on every run: `run.sh` `go install`s
   osv-scanner's dependency tree cold, which is slow enough that the scan action raises
   `WRANGLE_INSTALL_TIMEOUT` from its 300 s default to 900 s. The Go build cache that would help is off
   by default on attested paths for SLSA-L3 reasons.
3. **Supply-chain isolation.** A tool today is contained by a stripped environment, the adapter
   contract, and a post-run filesystem snapshot — not a real sandbox. Stronger isolation was deferred
   (#267), and each bespoke `install.sh` adds audit surface.
4. **Ease of adding a tool.** A new tool means choosing an install method, wiring verification, and
   carrying GitHub-Actions-specific dispatch (#137).

A single primitive — a pinned image behind a fixed contract — addresses all four: the digest is the
version, the prebuilt layer removes the per-run install, the container is the sandbox, and "add a tool"
becomes "publish an image that honors the contract."

## 2. Goals and constraints

**Hard constraints:**

- **C1 — dependency visibility preserved.** Pinning by opaque digest alone (no manifest, no SBOM) is out. (One curated tool — syft — takes an explicit, bounded exception to this; recorded in §3.4.)
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
  need it: zizmor's online audits reach the GitHub API, osv refreshes its advisory DB. *Decision:*
  accept full egress for the tools that declare it (they already have it today); a true per-domain
  allowlist needs an egress proxy and is tracked as a later nice-to-have, not a launch requirement.
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

A tool's `kind` captures its **input/stage**, not its output handling:

| Kind | Input / stage | Primary output | Exit | Adopter-substitutable |
|------|---------------|----------------|------|-----------------------|
| `scan` | source tree | `output.sarif` (SARIF 2.1.0) | 0 clean / 1 findings / 2 error | yes |
| `sbom` | source tree or built artifact | `sbom.spdx.json` (SPDX) | 0 ok / 2 error (never 1) | yes |
| `attest`/`verify` | metadata + targets | signed attestations / verdict | tool-specific | no |

`scan` runs on the source tree, `sbom` produces an SBOM at its own pipeline point, a future binary-scan
would run on built outputs. The kind does not change output or exit handling: every tool runs under the
uniform `0`/`1`/`2` contract, and the orchestrator collects `/output` and attests its primary output file
by name. `sbom` is just an instance — a tool that emits an SBOM (syft emits `sbom.spdx.json`) and, having
no findings state, never returns `1`. (CycloneDX is future work: `sbom.cyclonedx.json` ships when a tool
emits it, alongside the wrangle-attest engine allowlist entry.)

**Output handling.** wrangle gives specific filenames special handling — `output.sarif` feeds the
result/Security-tab upload, `output.md` feeds the GHA step summary — and **carries anything else the tool
writes to `/output`** into the published metadata. Attestation is by filename: `output.sarif` is wrapped
as the scan/v1 result, `sbom.spdx.json` is mapped to its in-toto predicate `https://spdx.dev/Document`.
`output.md` and any extra files are propagated as metadata without promising a signature over each. So
the contract is "write your output file; write `output.md` for a human-readable summary; anything else
under `/output` is carried along," not a fixed file list. A run that exits 0 but writes no recognized
output file is a clean no-op (green, no artifact, no attestation) — the tool owns emitting its artifact
or exiting non-zero.

### 3.4 Packaging

A tool's build path follows from **who owns it**:

| Class | Examples | Build path |
|---|---|---|
| Owned Go, adapter in the binary | wrangle-lint, wrangle-attest, a unified `wrangle` | ko / goreleaser `kos:` (the binary is contract-native) |
| Third-party tool wrapped | osv, zizmor (package-manager install); syft (verified-binary, see exception) | Dockerfile via `build_and_publish_container` |
| Adopter's own tool | a BYO SBOM generator | adopter's choice; wrangle ships only the contract |

For wrapped third-party tools, the image is built by **installing the tool through its canonical package
manager** — a Go module/tool directive (osv from `tools/go.mod`), a hash-pinned PyPI install (zizmor),
cargo `--locked`, etc. — into a multi-stage Dockerfile, then copying the result onto a distroless base.
This is deliberately *not* a git-clone-and-rebuild: using the canonical distribution keeps the
dependency manifest (`go.sum`, `requirements.txt`, `Cargo.lock`) in-repo, which is exactly what lets
Dependabot, osv, and govulncheck keep scanning the tool's transitive dependencies and lets wrangle patch
a dependency ahead of upstream. It also matches DEP_MGMT.md's integrity ladder. The install/compile
moves from every run to image-publish time. (Building a single tool from the shared `tools/go.mod` and
extracting one binary is validated — see §4.)

**Exception — syft (an explicit, bounded C1 exception).** syft's image instead copies in the
**cosign-verified syft binary** — the build stage runs the same Sigstore-keyless verify chain wrangle
already runs on `main` (`tools/syft/install.sh`: verify `checksums.txt` against anchore/syft's release
identity, then SHA-check the binary) and copies the result onto the runtime base. No canonical package
manager ships syft's wrangle adapter, and Anchore's official image is unsigned/unverifiable, so the
manifest-preserving path above isn't available without a git-clone-and-rebuild that bloats wrangle-core.
This forfeits C1's in-repo dependency manifest for syft's own transitive deps — accepted as a deliberate
exception because syft runs under the strictest sandbox (`--network none`, read-only `/src`, `--cap-drop
ALL`, `--security-opt no-new-privileges`) and emits an **inert assertion** (a schema-validated SBOM
wrangle signs as "syft produced this," never as correct), and because it **preserves rather than
worsens** syft's posture: syft already ships to wrangle as a cosign-verified binary today, now baked into
a sandboxed image rather than installed at run time.

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

The pull-time VSA gate this orchestration adds (`run.sh` `verify_tool_image`) verifies via `gh attestation
verify`, a coherence cost against the CI-agnostic claim above (#171); `cosign verify-attestation` (SPEC.md
§247) is the documented portable equivalent, and the seam where a future verifier-selector would plug in.

### 3.6 Reference model: a curated catalog

The image digests are not pinned by each adopter; they live in a **wrangle-curated catalog** — a single
`tool → {digest, capabilities}` manifest the orchestrator reads (subsuming the #264 `tools.lock` idea).
The catalog, not a per-tool action input, is the home for tool *definition*, because capabilities
(network, secret, format) don't fit cleanly as action inputs, and because one manifest is the cleanest
thing for the pin tooling to track and for adopters to read.

- **Adopters inherit the catalog by pinning wrangle**, exactly as they already inherit every bundled
  tool version. Wrangle bumps a digest when it updates a tool.
- **Selection stays short-name + policy** — the existing `tools: "osv zizmor:info …"` interface is
  unchanged; a name resolves through the catalog to an image.
- **Custom tools** are an adopter-supplied catalog fragment that only *adds* net-new tools under their own
  names (a name that collides with a built-in is a hard error — add-only, never override; §3.7). A custom
  tool is a pin the adopter now owns the freshness of; wrangle can offer rails (a `docker` Dependabot entry,
  a lint warning on a stale pin) but cannot vouch for an image it does not control.

The shipped catalog (`tools/catalog.json`) is parsed with `jq` (`lib/read_catalog.sh`) and has **two
consumers**: the scan orchestrator dispatches entries the `tools:` selection names that carry
`delivery: image` (the docker-run path; a tool not listed — or one with `delivery: adapter`/no `delivery`
— takes the in-process adapter path), and the verify action resolves one **fixed key**
(`attest-toolbox`) for its in-container `ampel verify`. An entry may therefore omit `delivery` to opt out
of scan dispatch while still being a reviewable grant the verify path resolves; `check_catalog` pin- and
namespace-lints any entry naming an `image`, regardless of `delivery`. Capabilities default closed: an
absent `network`/`secret` means none. The `kind` field is recorded but unused today; the
`command:`/`args:`/`WRANGLE_KIND` passthrough and kind-based (scan vs sbom) dispatch land when a
command-shared or sbom tool does. `osv` carries `network: egress` because it refreshes its advisory DB
from osv.dev.

### 3.7 Capability declaration

Two distinct layers:

- **Selection** (per run, adopter-facing): which tools to run and at what policy — the `tools:` string.
- **Definition** (static, per tool): the catalog entry — `{image digest, kind, network, secret, token,
  output}`.

`token: sigstore` lets wrangle mint a short-lived Sigstore signing token (`SIGSTORE_ID_TOKEN`) into the
tool's container — the signing-token counterpart of `secret: github-token`. It is off by default, and
`check_catalog` allows it only on wrangle's own `attest-toolbox` image, never on a scan/sbom tool or an
adopter's custom tool. The signing path reads it (`lib/toolbox_run.sh`): under the grant plus the
`WRANGLE_VERIFY_AMPEL_TOOLBOX` opt-in, the host mints the token and threads it, by name, into the
toolbox container (§7 Status).

**A capability grant comes from the trusting party — wrangle, or the adopter for their own tool — never
from the image itself.** An image may *request* a capability (e.g. an OCI label), but granting it is the
orchestrator's decision; otherwise the sandboxed tool would define its own sandbox. Grants are therefore
recorded in-repo as reviewable catalog lines, default to `network=none, secret=none`, and are relaxed
only explicitly — consistent with wrangle's least-privilege and input-validation rules.

**Custom tools are add-only, so grants never inherit.** An adopter's file may only *add* net-new tools
(disjoint names) and *deselect* curated ones — never partially override a curated entry. Each added tool
declares its own capabilities standalone; there is no merge with, and no inheritance from, any curated
entry. Two enforced rules make this strictly safer than a field-merge: a name that collides with a curated
tool is a hard error, and **a custom entry's image MUST be outside the wrangle namespace**
(`ghcr.io/tomhennen/wrangle/*` is rejected). An adopter therefore cannot attach a `secret`/`network` grant
to any wrangle-published, VSA-signed image. To change how a curated tool runs, an adopter deselects it and
adds their own full definition, on their own image, under a new name.

### 3.8 Configuration, illustrated

Schema below is the proposed shape; exact field names and file locations are bikeshed-able (§9).

**Internal — wrangle's curated catalog** (wrangle bumps it; adopters inherit by pinning wrangle):

```jsonc
// tools/catalog.json  — wrangle-maintained, one entry per built-in tool
{
  "tools": {
    "osv": {
      "kind": "scan",
      "image": "ghcr.io/tomhennen/wrangle/osv@sha256:1531…",  // installed from this repo's go.mod
      "network": "egress"     // default is none; osv refreshes its advisory DB
    },
    "zizmor": {
      "kind": "scan",
      "image": "ghcr.io/tomhennen/wrangle/zizmor@sha256:9a4c…",
      "network": "egress",
      "secret": "github-token"   // delivered as WRANGLE_EXTRA_GITHUB_TOKEN
    },
    "sbom": {                                                  // wrangle's default SBOM tool; sbom-tool: sbom selects it
      "kind": "sbom",
      "image": "ghcr.io/tomhennen/wrangle/syft@sha256:0b72…"   // network omitted → none; no secret
    },
    // owned Go tools can share ONE image — the unified `wrangle` binary — selected by command
    "wrangle-lint": {
      "kind": "scan",
      "image": "ghcr.io/tomhennen/wrangle/wrangle@sha256:c0de…",
      "command": ["lint"]
    },
    "wrangle-attest": {
      "kind": "attest",
      "image": "ghcr.io/tomhennen/wrangle/wrangle@sha256:c0de…",  // same image, different command
      "command": ["attest"]
    }
  }
}
```

(During migration a catalog entry may carry `delivery: adapter` to keep running the old in-process
adapter for a tool not yet containerized; the default is `delivery: image`. See §10.)

As the `wrangle-lint`/`wrangle-attest` entries above show, an entry can carry an optional
`command:`/`args:` so several tools share **one** image (a unified `wrangle` binary or a toolbox image),
selected by command rather than a separate image per tool — handy for the owned-Go tools (§3.4) and for a
BYO image that exposes more than one tool. The capability rules (§3.7) and least-privilege defaults still
apply per entry; the cost is a larger per-entry surface to validate (§8).

**Adopter — selecting tools** (pin wrangle, choose which to run):

```yaml
# adopter .github/workflows/scan.yml
jobs:
  scan:
    uses: TomHennen/wrangle/.github/workflows/scan.yml@<wrangle-version>  # pin a wrangle release
    with:
      tools: "my-osv zizmor:info"          # scan selection + policy; deselect osv, run my own
      sbom-tool: my-sbom                    # pick the SBOM tool (default: sbom, wrangle's syft)
```

**Adopter — bringing their own tools (add-only).** An adopter commits a `.wrangle/tools.json` (same
`{ "tools": { … } }` shape) at the repo root; `run.sh` auto-discovers it — no workflow input — and unions
its net-new tools into the catalog, then selection (`tools:` / `sbom-tool:`) decides which run. The model is
add-only: a name colliding with a curated tool is a hard error, a custom image must be off the wrangle
namespace, and each entry declares its own capabilities (nothing inherits from curated). The full schema,
validation, and trust boundary are the **canonical contract in [SPEC.md](SPEC.md) → "Custom Tools"**.

Three properties follow:
- **Inheritance** — an adopter who commits no `.wrangle/tools.json` runs wrangle's curated, cooldown-vetted
  images and pins nothing of their own.
- **Add-only, no override** — to replace a curated tool the adopter adds their own (`my-osv`) and deselects
  the curated one via `tools:`, owning the new pin's freshness (wrangle's pin tooling covers only its own
  catalog).
- **Trust direction** — every custom tool's capabilities are declared by the *adopter*; the image grants
  itself nothing, and an unspecified capability defaults closed.

## 4. Evidence

**Contract mechanic.** A `docker run` invocation of a `scan` adapter and an `sbom` adapter confirms:
`--network none` blocks egress, `/src:ro` blocks writes into source, exit codes 0/1/2 propagate, output
written as `root` unless `-u` is set (hence the ownership requirement), and the `sbom` kind writes
`sbom.<format>.json` with no findings exit.

**Speed.** osv-scanner, delivered three ways on fresh cold `ubuntu-latest` (amd64) runners, building/
fetching the pinned v2.4.0:

| Delivery | Cold acquire | Warm acquire | Build (publish-time) |
|----------|-------------:|-------------:|----------------------|
| `go install` (today) | **85.1 s** | 0.29 s | — |
| prebuilt binary (download + verify) | 0.65 s | — | — |
| **container (`docker pull`)** | **1.73 s** | 0.09 s | 97 s build, 82 MB image |

The proposed container delivery cuts the cold acquire from 85 s to 1.7 s (~49×). The win is on the
**cold path** — release builds (forced cold for L3) and adopter first-runs — which is exactly where the
build cache cannot help; on warm PR scans the status quo is already sub-second. The one-time 97 s build
is paid at publish, not per run. (Per-run *scan* time is network-bound by osv's online queries and is
not a meaningful per-delivery signal.)

## 5. Alternatives considered

- **Prebuilt binary (download + verify).** Fastest acquire, but a raw binary carries no dependency
  manifest (no transitive-CVE notices), sits below a package-manager install on the integrity ladder,
  and — downloaded at run time — gets no sandbox. Rejected as the *general* delivery mechanism; useful as
  the speed floor it establishes above. **One bounded exception:** syft's image bakes the cosign-verified
  binary into the sandboxed container (option c, §3.4), keeping the container sandbox while accepting the
  no-manifest cost, because no package manager ships syft's adapter and its strict sandbox + inert SBOM
  output bound that cost.
- **`FROM <upstream image>`.** Fastest of all (no install), but the tool's dependencies leave wrangle's
  manifest so the source scan goes blind, and a registry digest is a checksum served by the same source
  as the bytes — straining the "checksums not from the binary's source" rule. Permitted only for tools
  where wrangle accepts delegating build and patch cadence to upstream, and only with the upstream
  image's provenance verified at pull time. Not the default.
- **Tools as raw `uses:` action steps.** Cedes the execution surface to GitHub Actions and ties the model
  to one CI. Rejected in favor of orchestrator-driven `docker run` (§3.5).

## 6. Security model and prerequisites

- **Tool output is an inert assertion.** SARIF/SBOM is schema-validated before wrangle embeds it in any
  signed predicate, and the pass/fail result is derived orchestrator-side. A wrangle signature attests
  *"tool X produced this,"* never *"this is correct"* — important for adopter-supplied tools.
- **Adoption enforcement (the residual prerequisite).** Installing via the canonical package manager
  keeps the dependency manifest in-repo, so CVE *detection* keeps working. What remains is ensuring a
  published fix is actually *adopted*: the catalog's image digest must be freshness-checked so a stale
  pin cannot pass CI green (the #539/#544 class). The OCI axis is served by a *parallel* set of
  catalog-aware checks — `tools/check_catalog.sh` (static digest/namespace hygiene, per-PR),
  `tools/check_catalog_freshness.sh` (adoption-lag vs `:latest`, a release gate),
  `tools/check_catalog_provenance_freshness.sh` (checks each pinned image was built from current source:
  it reads the image's signed provenance for the commit it was built from, and fails if anything under
  `tools/` or `lib/` changed since — a release gate, the OCI analog of `check_pin_ancestry`/`check_pin_freshness`),
  `tools/bump_catalog_digest.sh` (the fix) — plus the DEP_MGMT.md image integrity rung; the git-pin tools
  (`check_pin_ancestry`, `check_pin_freshness`, `bump_action_pins`, WL005) are left untouched, since
  digests and git SHAs are different axes. Because the digest lives in one curated place (§3.6), this
  stays a narrow, wrangle-internal task, required only before *production consumption*, not before
  prototyping. Source-freshness (`check_catalog_provenance_freshness.sh`) runs release-blocking and as a
  weekly advisory — **not** per run: a stale-but-attested image passes the pull-time VSA gate and is
  consumed like any pinned dependency (the consume-the-pin model, §7/§11), with the post-publish auto-bump
  PR (§11) keeping the pinned digest current. Still open (#623): a digest cooldown and the adoption-lag check's
  advisory→blocking promotion.
- **Pull-time consumer VSA gate.** Before a curated image runs, the orchestrator verifies it carries a
  PASSED, SLSA-Build-L3 wrangle verification-summary attestation signed by the container build+publish
  workflow, fail-closed (`run.sh` `verify_tool_image`, `lib/verify_image_vsa.sh`). The signer identity is
  matched by a regex that admits `@refs/heads/main` (curated tool images build from `main`) as well as a
  release tag — carrying no release-tag-only constraint is deliberate. **Curated tool images must stay
  public:** the gate reads the OCI attestation referrer with the default workflow token, so a private
  image would fail that read and, fail-closed, block the scan. The gate hard-depends on Sigstore's TUF
  CDN every run (it refreshes the trusted root and fails closed if unreachable); `WRANGLE_VERIFY_TOOL_IMAGES=0`
  is a documented **break-glass stopgap** for a sustained Sigstore-TUF outage, to be removed once offline
  trusted-root verification (#632) lands and drops that hard dependency — not a routine off-switch.
- **Adopter-supplied images** are adopter-trusted, not wrangle-trusted: they run under the strictest
  contract by default (no network, no secrets), any relaxation is explicit, and wrangle's signature
  covers provenance of the run, not correctness of the tool.

## 7. Scope

- **In scope:** wrapping third-party adapter tools as contract images, osv first, then all scan-kind
  tools.
- **Track 2 — signing in a container (#619), now proceeding.** cosign, ampel, bnd and wrangle-attest
  share a `go.mod` and run together, so they package as one `attest-toolbox` image. It runs under the
  **consume-the-pin** model: signing consumes the digest-pinned toolbox, VSA-verified before it runs
  (`lib/verify_image_vsa.sh`, Phase 1) — a stale pinned toolbox is consumed like any pinned dependency,
  **not** gated per run. This dissolves the self-signing concern: `attest-toolbox@NEW` is signed by the
  pinned `attest-toolbox@OLD`, which is attested and passes verify-before-run — no circularity, no
  self-build exemption. Source-freshness stays a release/weekly check (§6, §11), with the post-publish
  auto-bump PR (§11) keeping the pinned digest current; there is **no per-signing-run freshness gate**. Containerizing the
  verify path also unlocks **VSA-verified caching** of all tool images — the L3-safe replacement for the
  build cache wrangle disables today.
  **Token delivery.** The host mints an `aud=sigstore` `SIGSTORE_ID_TOKEN` and passes it plus the
  job-scoped `GITHUB_TOKEN` into the container (Option A: sign+push in-container); the
  `ACTIONS_ID_TOKEN_REQUEST_*` vars never enter it — a security improvement over today's in-job binary,
  which can mint a token for any audience.
  **Break-glass.** `WRANGLE_VERIFY_AMPEL_TOOLBOX` unset (or `0`) falls back to in-job, from-source
  signing — the outage escape hatch; no automatic staleness fallback.
  **Status (#596 Track 2):** the toolbox image (`tools/attest-toolbox/`, all four binaries from
  `tools/go.mod`) is built and published like the scan images. Under the curated catalog's
  `attest-toolbox` grant (`delivery: image`, digest-pinned, `network: egress`, `token: sigstore`) plus
  the `WRANGLE_VERIFY_AMPEL_TOOLBOX` opt-in, all three sign sites run in it: the verify job's VSA sign
  (`bnd statement`) and referrer pushes, `attest_provenance`'s `wrangle-attest --sign` + store push, and
  `attest_metadata_oci`'s sign + `cosign` OCI push/download — plus the `oci:` collector verify path
  (registry auth threaded in-container). The host mints the step-local `SIGSTORE_ID_TOKEN` and threads it
  (signing) or `GITHUB_TOKEN` (registry) by name only; each token-bearing `docker run` is fronted by the
  fail-closed `verify_image_vsa` gate (`lib/toolbox_run.sh`). Off by default and byte-identical when
  unset; wrangle dogfoods it when publishing its own tool images (`local_publish_images.yml`,
  `verify-in-container: true`). Reusable callers opt in via the `verify-in-container` input.
- **Separate feature:** emitting an attested container of an adopter's own Go app (the "free container"
  value-add via goreleaser/ko). It reuses some machinery but serves adopter UX, not the goals here.
- **Left as-is:** tools with official GitHub Actions that gain nothing from containerization stay
  action-pattern (an escape hatch C3 explicitly allows).

## 8. Testing and tooling

Premise P-a (tools stay stable while glue iterates) only holds if a tool image can be validated **without
a full wrangle CI/CD run**. Two pieces:

- **Per-image test harness.** Each tool image has a fast test that runs the *image* against committed
  fixtures and asserts the contract: exit code per fixture (clean → 0, findings → 1, broken input → 2),
  output layout (primary output present and schema-valid, `output.md` when expected, nothing written
  outside `/output`), and the metadata-layout assertions (#169). It runs as a per-image matrix job
  triggered on that image's change — the fast inner loop for tool updates, independent of the full
  pipeline. Fixtures live beside the tool (`tools/<name>/testdata/`).
- **Footgun linters.** New checks (wrangle-lint / a catalog validator) to keep the catalog honest: every
  `image:` is digest-pinned (no tag, no `@latest`); every entry declares a `kind`; capabilities are
  default-closed and any `network`/`secret` grant is explicit; curated images come from the allowed
  registry namespace; and every tool named in a default selection exists in the catalog. Plus the
  custom-tools rail (warn on a stale/unpinned adopter pin, §3.6).

## 9. Open questions

Decided in review: positional `<src> <out>` args; full egress for declaring tools (per-domain filtering
deferred); amd64 is the baseline (GitHub's hosted runners default to amd64; arm64 runners are opt-in, so
publish amd64+arm64 but gate nothing on arm64); the catalog (not per-tool action inputs) is the reference
model. Still open:

- **Catalog schema details** — exact field names and the catalog file's location. (Adopter custom tools are
  settled: an auto-discovered `.wrangle/tools.json` at the workspace root; see SPEC.md "Custom Tools".)
- **Registry namespace** — the ghcr path for curated images.
- **SPEC.md** — fold the kind-parameterized contract into the Adapter Script Interface.

## 10. Plan

1. **Prototype osv end-to-end** (scan kind, installed from `tools/go.mod`): `run.sh` invokes the image
   via `docker run`, producing a real `output.sarif` through wrangle's existing collectors. Proves the
   run-via-script integration. *(The contract mechanic and the speed win in §4 are already measured.)*
2. **Freeze the contract in SPEC.md** — the `scan` and `sbom` kinds, the invocation, the isolation
   mapping, and the output-handling rule (§3.1–3.3).
3. **Stand up the per-image test harness** (§8) — so subsequent migrations are validated fast.
4. **Make the catalog digest-aware** (§6) — the parallel `check_catalog*` / `bump_catalog_digest` checks;
   required before any image is consumed in a production wrangle workflow.
5. **Go all-in for the `scan` kind.** Rather than a long mixed-mode tail, migrate the scan adapter tools
   together once the prototype proves out; the catalog's `delivery:` field covers the brief cutover (and
   any tool that stays adapter/action-pattern). osv, then zizmor, behind the curated catalog.
6. **Extend to `sbom`** — syft as the reference implementation and the first adopter-substitutable
   contract test.
7. **Track 2 — signing in a container** (consume-the-pin, §7/#619): the attest/verify toolbox (with its
   speed + VSA-caching payoff) and the adopter container value-add, each on its own merits.

## 11. Release lifecycle

A digest-referenced image can't be built from the commit that references it — the image must be
published before its digest is known. So there is always a one-commit skew between the image (built from
commit C) and the catalog entry naming its digest (commit C+1). This is the same self-bootstrap the
nested-action-SHA pins already carry, on a second axis (image digests).

The model that makes this work: **a tool image is an immutable, independently-versioned artifact — the
digest *is* its version — and a wrangle release references a consistent set of current digests. Cutting a
release does not rebuild or re-tag tool images.**

- **Tool change** — a PR edits `tools/<tool>/Dockerfile` or its go.mod; on merge to main, CI builds and
  publishes the image (with provenance) → a new digest, and the **post-publish auto-bump PR**
  (`local_publish_images.yml`'s `bump-catalog` job → `tools/bump_catalog_to_latest.sh` +
  `tools/open_catalog_bump_pr.sh`) updates the catalog entry to it. First-party
  rebuilds (wrangle's own `ghcr.io/tomhennen/wrangle/*`) are **exempt from the 7-day community-vetting
  cooldown** — that delay exists to let the community vet *third-party* updates for supply-chain attacks,
  which a rebuild of wrangle's own reviewed source is not — so the bump merges on CI/review latency and
  keeps the catalog current. One source PR + one bump PR — not a manual double-bump. The publish trigger is
  a path glob that matches `tools/catalog.json`, so a catalog-only digest change would re-trigger a rebuild;
  the trigger excludes `tools/catalog.json`, which is what keeps the bump from looping.
- **Release tag** — precondition: the catalog is fresh. `check_catalog_freshness.sh` proves the shipped
  half — no digest is behind its published `:latest` (adoption lag); `check_catalog_provenance_freshness.sh`
  proves the stronger half — every digest is the image built from the current tool source, read from each
  image's signed provenance over a coarse `tools/`+`lib/` diff-set (it over-flags a harmless rebuild
  rather than miss a stale image). Both are blocking release gates that fail closed on a backend error
  (exit 2 = precondition unverified); source-freshness also runs as a **weekly advisory**, and is **not**
  a per-signing-run blocker (that would false-block signing during the normal bump window). Then tag. No
  image is built or re-tagged at release time.

Consequences:
- The catalog at a release commit references images built from *ancestor* commits. That is correct as
  long as the tool's definition is unchanged between the image's build commit and the release — exactly
  what the freshness check guarantees. The skew is bounded to the bump commit.
- A tool image's provenance names *its* build commit, not the release tag. Verification policy checks
  "built by wrangle's builder from wrangle's repo," not "commit == release tag," so this is expected, not
  a gap.

Two further wrinkles, both consistent with how wrangle already works but worth writing down:
- **Tool images are wrangle-built, not official upstream tags.** osv ships as `ghcr.io/<org>/wrangle/osv`,
  built from the canonical package manager — *not* Google's official osv image. That can look odd, but
  it's the same trust posture adopters already accept for wrangle's actions and workflows (also
  wrangle-built, not upstream); the manifest-preserving build (§3.4) is what makes it worth doing.
- **"Is this image meant for distribution?" is answered by the signed VSA, not the tag.** A released tool
  image carries a wrangle-signed VSA (from the verify step) proving it passed policy; an
  intermediate/unreleased build does not. So provenance + VSA distinguish a distributable tool image —
  inspecting provenance alone won't.

Doc follow-ups when this lands: the **FAQ** (why a tool image is wrangle-built rather than the upstream
official one) and **RELEASING.md** (the tool-image build → bump → tag steps above).

### 11.1 The deferred wrangle-tools split

The single-repo model carries an inherent self-bootstrap (the repo references artifacts built from
itself). A separate `wrangle-tools` repo would remove it: wrangle would consume *external* tool images
like any third-party dependency — normal cooldown/pin flow, clean dependency direction. The cost is a
second repo's CI/release overhead and cross-repo coordination (a change spanning a tool *and* a workflow
becomes two ordered PRs in two repos) — likely more day-to-day friction than the in-repo freshness
approach for a project this size. **Prove the in-repo model first; split only if the self-bootstrap skew
proves painful.** It is a reversible follow-on.

The split's real complication is shared libs. The libs tools need are **not disjoint** from what wrangle
proper needs — e.g. `lib/sanitize.sh` is used by both a tool (`render_md.sh`) and wrangle proper
(step-summary rendering). So a split can't cleanly put libs on one side, and every option is costly:
duplicate the libs (drift), add a third `wrangle-lib` repo (more overhead), or fetch libs into the
Dockerfile from wrangle proper at a pin (a dependency cycle — wrangle references tool images that
reference wrangle's libs at *some* pin, which goes stale). The clean resolution, if we ever split, is to
make the in-image tool glue **self-contained** — vendor/inline the small lib bits a tool needs (the
sanitize logic is tiny) so `wrangle-tools` has zero back-dependency on wrangle proper. That bears on
today only as a forward-looking lean: if a split feels likely, prefer self-contained tool glue from the
start; otherwise reaching into shared `lib/` via the repo-root build context (§3.4) is fine in-repo.
