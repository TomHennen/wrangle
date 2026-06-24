# Tool containerization — design exploration (#596)

Status: **draft for discussion.** Not a committed contract; SPEC.md remains the source of truth.

> **Revised after three independent reviews** (architecture / adversarial-security / strategic).
> They converged on: **measure before architecting, and do much less than the original sketch.**
> The full container architecture is recorded below as *the eventual shape, conditional on a spike* —
> but the committed next step is a measurement spike plus a security-prerequisites decision, not a
> migration. Review findings and the corrections they forced are in §10.

## 0a. Phase 0 result — gate **CLEARED** (osv, ubuntu-latest amd64, 2026-06-24)

Spike ran the three arms on fresh cold runners (playground repo, checking out real wrangle for the osv
pin + `download_verify.sh`; all arms produced osv-scanner **2.4.0**):

| Arm | Delivery | **Cold acquire** | Warm acquire | Notes |
|-----|----------|-----------------:|-------------:|-------|
| A | `go install` from source | **85.1 s** | 0.29 s | cold = the release/first-run cost; warm only helps PR scans |
| B | prebuilt binary (download+verify) | **0.65 s** | — | speed *floor*; reference only (no `go.mod`, no sandbox) |
| C | container (`docker pull`) | **1.73 s** | 0.09 s | build 97 s (publish-time, amortized); image 82 MB |

**Verdict:** C beats A on cold acquire by ~83 s (~49×) and lands within ~1 s of B's floor **while keeping
the manifest + sandbox** — so it clears both bars of the §11 kill-criteria. → **proceed** to the §3
contract + the §9.1 consumer-side pin-freshness prerequisite.

Two honest caveats: (1) the win is concentrated on the **cold path** (release + adopter first-run, which
is forced cold for L3 anyway) — on warm PR scans A is already ~0.3 s, so the gain there is negligible;
cold is simply the case that matters. (2) Per-arm *run* time (A 8.2 s / B 12.4 s / C 1.4 s) is
network-dominated (osv's online queries) and noisy — **not** a per-arm signal; a cleaner re-run would
pin an offline advisory DB to remove it.

## 0. Revised plan (what we actually do next)

1. **Phase 0 — measure (a spike, not a migration).** Containerize **osv only** (the real cold-compile
   offender — it `go install`s from `tools/go.mod`), build-from-source, amd64-only. Benchmark, on a
   real GitHub runner, net per-run wall-clock of `docker pull (warm + cold) + run` against **both**:
   - today's `go install` cold path, **and**
   - a **verified prebuilt-binary fetch** via the existing `lib/download_verify.sh`.
   No frozen contract, no SBOM kind, no ko, no Track A. One tool, one number.
2. **Gate (corrected — owner):** C must **beat A on speed** *and* have a better maintainability/
   security/extensibility story than B. B (verified prebuilt binary) is a *speed reference, not an
   option we'd adopt* — a raw binary has no `go.mod` manifest (⇒ no transitive-CVE notices), sits below
   build-from-source on the integrity ladder, and gets no sandbox. If C's pull cost can't beat A's
   compile, **stop**; otherwise C clears B on the qualitative axes by construction (build-from-source
   keeps the manifest + adds the sandbox). B's *speed* never vetoes C.
3. **Only if the spike wins (it did — §0a):** design the contract (§3) **and the invocation/reference
   model**: `run.sh` does `docker run` (not `uses:`), and the image digest is a **defaulted input** on
   the scan action — curated/bumped by wrangle, inherited by adopters via the wrangle pin they already
   maintain (§9.1). The digest-aware pin work is the **last** build step (gates production *consumption*,
   not prototyping); the reference model is chosen *now* so it stays tractable.
4. **Split out and hold Track 2 (attest/verify toolbox)** — it inverts the sandbox model and sits in
   front of the signing key; it is *riskier* than today as drawn (§10, security).
5. **Track A (adopter "free attested container") is a separate product feature** — decoupled from
   #596 entirely; do not let it justify build-tool spend here.

The rest of this doc is the analysis behind that plan.

## 1. Problem

Wrangle's tool layer solves four things at once, each only partially (#596): **dependency
management** (versions spread across `tools/go.mod` tool directives, syft's `install.sh`, zizmor's
pip `requirements.txt`, action wrappers — drift is recurring: #264/#277/#286); **speed** (adapter
tools `go install` from source per run; osv-scanner's tree compiles cold — the scan action bumps
`WRANGLE_INSTALL_TIMEOUT` from its 300s default to **900s** for osv; `go-cache` is off by default on
attested paths for L3 reasons); **supply-chain safety** (isolation today is a stripped env + adapter
contract + filesystem snapshot; #267 deferred stronger sandboxing); **ease of adding a tool** (#137).

**Correction (review):** osv-scanner is a `tools/go.mod` `tool` directive installed by `run.sh`'s
upfront `go install`, **not** an `install.sh`. syft *is* `install.sh`, but it's a fast
download-and-verify, not a cold compile. So the speed pain is the `go install` batch (osv), and
containerizing syft saves an `install.sh` but **none** of the compile time.

## 2. Constraints (hard) and premises

- **C1 — dependency visibility preserved.** Opaque-digest-only pinning (no manifest/SBOM) is out.
- **C2 — faster** than install-at-runtime. *Hard constraint, currently unmeasured — Phase 0 gates it.*
- **C3 — broadly applicable** (an occasional non-transitionable tool is OK).
- **C4 — no harder to coordinate wrangle updates.**

Premises: **P-a** tools are stable lately (we move glue/output more than binaries); **P-b** adopters
may want to supply their own tool as a container (an outside contributor → a different SBOM generator); **P-c**
non-GitHub portability is nice-to-have.

> **Advisor's C4 caveat:** the mitigations for the release-before-use cost lean on P-a — but P-a is
> also why C2's pain is small. *The premise that makes the cost cheap is the premise that makes the
> benefit small.* This is the central tension; the spike exists to find out which side wins.

## 3. The contract (the eventual shape, if the spike wins)

The adapter contract already mirrors a container API. The generalization is making the container the
unit of distribution/isolation and parameterizing over **tool kinds**.

### 3.1 Invocation (validated by experiment — §8)

```
docker run --rm --network <policy> -u <runner_uid>:<gid> \
  -v <src>:/src:ro -v <out>:/output [-e WRANGLE_KIND=<kind>] [declared tool env] <image> /src /output
```

- **Mounts** — `/src` read-only, `/output` writable (both confirmed enforced).
- **Ownership** — **must** run as the runner UID/GID (`-u`), or output is `root`-owned and unusable.
- **Network** — `--network none` is the **default**, not universal; egress is a **per-*tool*** opt-in
  (not per-kind): even within `scan`, zizmor-online hits the GitHub API (**+ needs a token** → network
  *and* secret, the case that most strains the sandbox) and osv refreshes its advisory DB. *Granularity
  caveat:* Docker's cheap primitives are deny-all vs allow-all — a true *domain* allowlist (zizmor →
  github.com only) needs an egress proxy / filtering sidecar, so "opt-in" likely means full egress for
  declared tools unless we invest in filtering (open question, §12).
- **Secrets** — most `scan`/`sbom` tools get none; a tool needing an authed call (zizmor → token) uses
  the existing `WRANGLE_EXTRA_` channel. The default stays zero-secrets; secret-bearing is an
  explicit per-tool declaration.

### 3.2 The isolation contract is part of the contract (review's #1 risk)

`docker run` does **not** just replace dispatch — it replaces `run.sh`'s isolation mechanism, which is
three concrete things that MUST be re-derived item-by-item, not silently dropped:

| Today (`run.sh`) | Container equivalent | Status |
|---|---|---|
| `env -i <allowlist>` — adapter sees only allowed env | bare `docker run` inherits nothing (safer) **+** explicit `-e` for each allowed var | must rebuild deliberately |
| `WRANGLE_EXTRA_*` forwarding | explicit `-e WRANGLE_EXTRA_*` per declared tool | must rebuild |
| post-run filesystem snapshot diff (warn-only; a SPEC MUST) | `/src:ro` + `/output`-only mount = **fail-closed** write confinement | **upgrade** — fix today's warn-only gap |

SPEC's Adapter Script Interface (ENVIRONMENT/SECURITY) must be updated in the same change.

### 3.3 Tool kinds

| Kind | Input | Output | Exit | BYO? |
|------|-------|--------|------|------|
| `scan` | `src_dir` (ro) | `output.sarif` (SARIF 2.1.0) | 0 clean / 1 findings / 2 error | yes |
| `sbom` | `src_dir` **or built artifact** | `sbom.<format>.json` (SPDX **or** CycloneDX — declared) | 0 ok / 2 error | yes |
| `attest/verify` | metadata + targets | signed attestations / verdict | tool-specific | no |

Deltas from today's SARIF-only contract: output is kind-specific and SBOM declares its **format**
(don't hardcode SPDX); exit codes are per-kind (`sbom` has no "findings"); input may be src **or**
artifact (a build-path SBOM reads the built binary, not source).

## 4. Packaging — decided by ownership

`ko` builds *Go source you own* into a bare-binary image with the tool's *native* interface; it can't
bundle a foreign binary + adapter shim. So:

| Class | Examples | Path | Why |
|---|---|---|---|
| Own it, Go, adapter in binary | wrangle-lint, wrangle-attest, unified `wrangle` | ko / goreleaser `kos:` | binary *is* contract-native |
| Adopter's own Go app | (Track A value-add) | ko / goreleaser | their binary, no Dockerfile |
| Third-party wrap | osv, syft, **zizmor** | Dockerfile via `build_and_publish_container` | needs upstream binary + shim |
| BYO | a third-party SBOM gen | their choice — wrangle ships only the contract | not our build problem |

**zizmor is a viable container target (owner — corrects the review).** It is action-pattern today only
because Rust/pip install was awkward, not because the wrapper is essential. The upstream action's one
special function is the `advanced-security` Security-tab SARIF upload — which wrangle **already performs
itself** for adapter tools via its own `codeql-action/upload-sarif` steps (osv, wrangle-lint);
everything else (findings/error disambiguation in `collect_sarif.sh`, the md, the scan manifest) is
already wrangle-side. Containerizing zizmor (`zizmor --format sarif` → `output.sarif`, then map
findings→exit 1 since SARIF mode exits 0) would drop the action ladder, the pip install path, **and**
the upstream-action dependency — plausibly *better*, and exactly the #137 flattening. It's also the
clean test case for the §3.1 per-tool egress+credential capability: zizmor's online audits need GitHub
API egress + a token via `WRANGLE_EXTRA_`.

### 4.1 Third-party base: from-source vs FROM-upstream

- **Build-from-source** (`FROM golang AS build → FROM distroless → COPY`): keeps the `go.mod` in-repo
  ⇒ Dependabot per-dep alerts, osv/govulncheck source scan, and ahead-of-upstream patching intact;
  moves compile from per-run to per-publish. **Default for security-critical tools.**
  - *Caveat (review):* osv shares the **single** `tools/go.mod` with cosign/ampel/bnd/govulncheck/
    wrangle-attest/wrangle-lint. A per-tool from-source image needs its own module file — a new
    drift surface (the very #264/#277 problem we're trying to reduce).
- **FROM-upstream-image** (`FROM ghcr.io/google/osv-scanner@sha256:…`): fastest, but the tool's deps
  leave our `go.mod` so the source scan goes blind (and there is **no image-scan step today**).
  - **Security blocker (review S3):** a registry digest is a "checksum" served by the *same source*
    as the bytes — this strains CLAUDE.md's "no checksums from the binary's source" rule. FROM-upstream
    is permitted **only** with independent provenance verification at pull time (verify upstream's SLSA
    attestation against a pinned identity, the way `lib/download_verify.sh` fails closed) — digest
    alone is not sufficient. Detection of CVEs is recoverable via `osv-scanner scan image`; **ahead-of-
    upstream remediation is not.**

## 5. Tracks (conditional, post-spike)

- **Track B (#596 core)** — wrap third-party tools (osv first) as contract images, Dockerfile
  from-source.
- **Track A (separate feature)** — goreleaser emits an attested image of a Go app, serving the adopter
  value-add *and* wrangle's owned Go tools. **Correction:** the "goreleaser `--skip=publish` then a
  gated job pushes the digest" flow in the prior draft is a synthesis of two *different* existing
  flows that **neither implements** — `build_and_publish_go`'s `--skip=publish` uploads checksummed
  *archives* to a GitHub Release (no registry push, no digest-attest); the digest push+attest lives in
  `build_and_publish_container` and happens **mid-composite, not in a gated job**. Track A needs a
  genuinely new gated-image-push job designed, not assumed.
- **Track 2 (split out, HELD)** — attest/verify toolbox (cosign/ampel/bnd/wrangle-attest). Inverts the
  sandbox (network + OIDC token in) and interposes an image-supply-chain link **in front of the signing
  key**. Strictly riskier than today's in-job binaries (§10 S2). Do not ship on this framing.

## 6. Pilot choice — honest version

The syft/SBOM pilot is attractive for **contract** reasons (it's the cheapest tool to containerize,
and an outside contributor's generator gives a real BYO second implementation — two impls is what makes a contract real). It is
**not** a speed pilot (syft isn't the compile cost; the container SBOM is BuildKit-derived, not syft).
So: **osv is the Phase-0 *speed/spike* pilot; syft is the eventual *contract* pilot** — and the
contract pilot only happens if the spike clears the gate. Don't conflate them, as the first draft did.

## 7. Pros / cons against the constraints

**Pros** — C1: `go.mod` stays in-repo + signed image SBOM is additive. C2 *(if the spike confirms)*:
pull a layer vs compile per run. Safety: container is a real sandbox (read-only, `--network none`,
fail-closed write confinement — an *upgrade* over today's warn-only check). C3/portability: `docker
run` is CI-agnostic (#171), flattens `uses: ./tools/*` (#137). P-b: BYO becomes "ship a conforming
image."

**Cons / costs** — **C4 release-before-use**: every tool fix needs a publish-then-bump hop, felt by
the maintainer on every security patch (and see the §2 circularity). **Security tooling is blind to
OCI digests** (§10 S1 — a blocker, not an open question). **FROM-upstream** strains the checksum-source
rule (S3). **Track 2** inverts isolation in front of the key (S2). New build-time dep (ko) to vet if
Track A proceeds. Multi-arch adds CI cost.

> **Weakened claim (advisor):** the prior draft said pinned-digest pull is "cleaner than the
> build-cache wart that forces `go-cache` off on L3 paths." That's shaky — a pinned image digest is
> *also* trusting compiled output you didn't build this run, so the L3 bar is the **same**, not lower.
> Don't lead with this as a benefit.

## 8. Experiment results (Docker, this environment)

Validated the contract mechanic with a from-scratch `scan` adapter and an `sbom` variant:
`--network none` blocks egress; `/src:ro` blocks writes into src; exit **0/1/2 all propagate**;
default output is **root-owned**, `-u 1000:1000` fixes it (⇒ orchestrator must set `-u`); `WRANGLE_KIND=sbom`
writes `sbom.spdx.json` with exit-0/no-findings; a public-registry pull works (FROM-upstream feasible).

Deferred (need Go 1.26 + ko/syft, absent here): the real ko build of wrangle-lint and the **osv
build-from-source-vs-upstream-vs-prebuilt timing benchmark** — which is now Phase 0 and gates the rest.

## 9. Security prerequisites (BLOCKERS, not open questions)

Before any tool image is *consumed* in a wrangle workflow:

1. **Make the pin toolchain digest-aware** — but note build-from-source already shrinks this (owner).
   Because the image is built from the in-repo `go.mod`, Dependabot/osv/govulncheck still see the
   tool's transitive deps and fire CVE notices, and we rebuild + redeploy to remediate — so the
   *detection/remediation* half of the blocker is handled (this is a concrete reason build-from-source
   beats both FROM-upstream and B, which throw the manifest away). The **residual** is enforcement, and the
   **reference model shrinks it further** (owner): the image digest is a **defaulted input** on the scan
   action, curated and bumped by wrangle, threaded into `run.sh`'s `docker run`. So **adopters inherit
   the image via the wrangle pin they already maintain** — no new adopter-side pin tooling for the
   common (default) case. What's left is *wrangle-internal*: bump + freshness/cooldown-check wrangle's
   **own** default image input(s) — one known field in our `action.yml`, an extension of the existing
   self-reference bump family (`bump_action_pins`/`self_ref_pin_paths`), **not** a generic "track
   arbitrary OCI digests everywhere." Adopter **overrides** (BYO image, or a pinned different digest) are
   adopter-owned for freshness; wrangle offers hooks (a `docker` Dependabot snippet, a wrangle-lint warn
   on a stale/unpinned override) but can't guarantee an image it doesn't control. This is the **last**
   build step — it gates production *consumption*, not prototyping — and the reference model is chosen
   *now* so it stays tractable. (Add a DEP_MGMT.md integrity rung for images regardless.)
   - **Reference-model options (decide in contract design):** (i) *defaulted action input* per tool;
     (ii) a **`tools.lock`** — one `tool → digest` file `run.sh` reads — which is the #264 manifest this
     subsumes and the *cleanest* central store for the bump/freshness/cooldown tooling (one schema, not
     scattered input defaults); (iii) **both** — `tools.lock` holds wrangle's curated defaults, the
     action input is a per-tool *override* that beats the lock. `tools.lock` also adds **adopter
     transparency** (they see exactly what they get) and, in a Dependabot/Renovate-recognized format,
     lets adopters' own bots manage their *overrides* — the only place the adopter gains; the default
     path is inherited via the wrangle pin either way, and overriding still means owning freshness.
2. **Treat tool output as inert, validated data.** Schema-validate (not just JSON-parse) SARIF/SBOM
   before embedding into any signed predicate; derive the pass/fail `result` orchestrator-side from
   validated content. wrangle's signature attests *"tool X produced this,"* never *"this is correct."*
3. **State the BYO trust model** (S5): a BYO image is *adopter-trusted, not wrangle-trusted*; runs
   under the strictest contract by default (network none, no creds); any relaxation is explicit and
   logged. Decide whether wrangle verifies a BYO image's own provenance before running it.
4. **FROM-upstream requires pull-time provenance verification** (S3), not digest-alone.
5. **Track 2 / OIDC** (S2): if ever containerized, from-source only, verify the toolbox image's
   provenance before the token is in scope, mint/consume `id-token` in the narrowest step, and re-audit
   against SLSA_L3_AUDIT "secret material MUST NOT be accessible to the env running user steps."
6. **Expedited security-bump path** for tool images so the cooldown doesn't delay legitimate fixes (S6).

## 10. Review findings (three independent reviews)

**Architecture** — contract generalization is faithful; but flagged factual errors (osv is go.mod not
install.sh; container SBOM is BuildKit not syft; the `--skip=publish`/gated-push mapping is unimplemented;
osv shares one `tools/go.mod`). The review also called zizmor's action wrapper "load-bearing" — the
owner corrected this: zizmor is action-pattern only for install convenience and is a viable container
target (see §4). Biggest risk: the container
boundary silently replaces `run.sh`'s isolation contract (`env -i` allowlist + `WRANGLE_EXTRA_` +
post-run snapshot, a SPEC MUST) — must be re-derived item-by-item (now §3.2).

**Adversarial security** — net neutral-to-safer for scan/sbom *only if* the pin/verify gaps are built
first; **Track 2 net-riskier** and should be split/held. Ranked: S1 digest-blind tooling (HIGH **as
written — but much lower for build-from-source, which keeps the `go.mod` notice loop; residual is
consumer-side pin freshness, §9.1**),
S2 OIDC-in-container in front of the key (HIGH), S3 FROM-upstream checksum-source (MED-HIGH), S4
poisoned-output-signed-clean (MED, pre-existing, widened by BYO), S5 no BYO trust model (MED), S6
cooldown delays security fixes (LOW-MED). All folded into §9.

**Strategic (advisor)** — "do much less, not yet." The one quantifiable goal (C2) is undiagnosed;
measure osv before architecting, and beat **both** today's cold path **and** a verified prebuilt-binary
fetch (`lib/download_verify.sh`) or containerization is an over-build. Cut Track A from #596; defer the
kind-contract, image-scanning, multi-arch. Drove §0 and §6.

## 11. Phase 0 spike — detailed spec

**Question:** for the worst cold-compile tool (osv-scanner), what is the net per-run wall-clock under
each delivery model, on a real GitHub-hosted runner — and does the container model beat the cheaper
alternatives by a margin an adopter notices?

**Three arms** (same pinned osv-scanner version, same fixture, same runner, network policy held
constant):

| Arm | Delivery | Acquire step | L3 posture |
|-----|----------|--------------|------------|
| **A — status quo** | `go install` from `tools/go.mod` | compile from source | builds cold on release (go-cache off for L3); warm cache only helps PR scans |
| **B — prebuilt binary** | upstream release binary via `lib/download_verify.sh` (hardcoded checksum) | download + verify, no compile | trusts a binary you didn't build — verify upstream provenance to hold L3 |
| **C — container (from-source)** | distroless image built from source, run via `docker run -u … --network … -v src:ro -v out` | `docker pull` | trusts compiled output you didn't build *this run* — same bar as a cache; image built cold at publish |

**Measure** (median of N≥5 runs each, on `ubuntu-latest`; record arch):
- **acquire** time and **run** time *separately* (so we see where the cost is).
- **cold** (fresh runner / cache miss — the real first-run adopter case) **and** **warm** (go build
  cache for A; image layer cache for C; B is re-download unless cached).
- bytes pulled/downloaded per arm.
- osv's own advisory-DB fetch held constant across arms (or run offline-DB) so it doesn't skew `run`.

**Harness sketch** (one workflow, a job per arm, `time` around acquire vs run, fixed fixture repo
checked out read-only; emit a CSV/step-summary table). No contract, no ko, no Track A.

**Decision rule (kill-criteria) — corrected (owner):** B is a **speed reference, not an adoption
candidate.** wrangle doesn't want raw-binary installs: B has no `go.mod` manifest (⇒ no transitive-CVE
notices, no build-from-source integrity tier) and no sandbox. So B's speed does **not** decide anything.
- **C must beat A** on net wall-clock (if C's pull cost doesn't beat A's compile, there's no speed case
  → **stop**).
- **C must beat B on the maintainability / security / extensibility story** — which it does, because
  C-from-source keeps the `go.mod` (notices + redeploy) and adds the sandbox, while B loses the manifest.
- If C beats A and clears the qualitative bar over B → proceed to §3 contract + §9 prerequisites.
- B's number only *bounds how much speed is on the table* — useful context, never a veto.

**Explicitly out of scope for the spike:** the frozen contract, the SBOM kind, ko, Track A, multi-arch,
image-scanning, any change to `actions/scan`. One tool, three numbers, one decision.

**Note on B's status (owner-decided):** B is a **speed reference, not an adoption candidate** — wrangle
doesn't want raw-binary installs (no `go.mod` manifest, no sandbox). Its number bounds how much speed is
on the table; it never decides the outcome.

## 12. Tool-definition surface (catalog vs selection; capability trust direction)

Two layers, easy to conflate:
- **Selection** (per-run, adopter-facing): *which* tools + policy — today's `tools: "osv zizmor:info …"`
  string; the `:fail`/`:info` suffix is the precedent. Stays lightweight.
- **Definition / catalog** (static, per-tool): a tool name resolves to `{image digest, kind, network,
  secret, output}`. This is the new surface; capabilities live here, not in the selection string.

**Trust direction is the load-bearing rule:** a capability grant (network, a credential) comes from the
**trusting party** — wrangle, or the adopter for their own BYO tool — **never self-granted by the image.**
An image self-declaring `network=all, secret=token` would let the sandboxed thing decide how much sandbox
to remove. It's the phone-app model: the image *manifest* may *request* (an OCI label is fine as a
documented request), but wrangle/the adopter *grants*. Request ≠ grant. Consequences:
- **In-repo, reviewable** catalog (the `tools.lock` sibling) beats image-embedded labels — a network/token
  grant must be a diffable line someone approved (satisfies "validate every input" + least-privilege).
- **Least privilege by default:** catalog entries default to `network=none, secret=none`; every relaxation
  is explicit.
- **BYO ≠ image self-declares:** the *adopter* authors the capability entry for their own tool (they're the
  trusting party for their image); the image may carry a requested-capabilities label that wrangle/the
  adopter chooses whether to honor.

(This generalizes today's `WRANGLE_EXTRA_` per-tool credential channel into one declaration: image digest +
kind + network + which credential + output.)
