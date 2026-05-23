# SLSA v1.2 Build Track L3 Isolation Audit

**Status:** Audit, not a fix plan. Each finding records evidence and a recommended
direction; concrete remediations spawn their own issues per the contract of
[#216](https://github.com/TomHennen/wrangle/issues/216).

**Audit date:** 2026-05-14
**Wrangle commit at audit time:** `a84c855` (tip of `main` immediately before this commit).
**Spec version:** [SLSA v1.2 (released November 2025)](https://slsa.dev/spec/v1.2/),
specifically the [Build: Requirements for producing artifacts](https://slsa.dev/spec/v1.2/build-requirements)
page on the `releases/v1.2` branch of `slsa-framework/slsa`.

This document is intended to outlast the conversation that produced it. Every
spec quote points at a URL on the SLSA `releases/v1.2` branch so future readers
do not have to re-do the lookup. Every wrangle claim points at `file:line` so
future readers can independently re-verify.

## Bottom line: per-builder Build Track level today

Wrangle's adopter-facing docs should claim exactly one Build Track level per
workflow — **Build L2** or **Build L3** — and nothing finer-grained. This
audit's per-builder verdicts translate to that vocabulary as follows, for an
adopter consuming wrangle through one of wrangle's **reusable workflows**:

| Builder | Build Track level today | After follow-up fix |
|---|---|---|
| npm path (npm sub-path) | **Build L3** [^npmci] | — |
| npm path (pnpm sub-path) | **Build L3** | — |
| python path (pip sub-path) | **Build L3** | — |
| python path (uv sub-path) | **Build L2** | Build L3 (Finding 1) |
| container path | **Build L2** | Build L3 (Finding 2) |
| shell path | **N/A** — no provenance produced | — |

[^npmci]: Conditional on the install command being `npm ci`, which re-verifies
    each cached tarball's SHA against `package-lock.json` on every install.
    `npm ci` is the command wrangle invokes, so the precondition holds
    by-construction; full detail at [npm path (npm sub-path)](#npm-path-npm-sub-path).

> **Update — 2026-05-17.** Findings 1 and 2 are now **resolved** by
> [PR #226](https://github.com/TomHennen/wrangle/pull/226) (issue
> [#224](https://github.com/TomHennen/wrangle/issues/224)): the python-uv and
> container reusable workflows disable their shared caches for release builds,
> so **both paths now meet Build L3**. The "Build L2 today" rows above are the
> point-in-time verdict at the audit date (commit `a84c855`); the "After
> follow-up fix" column is now the live state. The per-builder analysis below
> is kept as the historical record of why the fix was needed.

Two caveats narrow every Build L3 row above:

- **Direct composite consumption is not a supported L3 path.** Calling the
  `build/actions/<type>` composites directly from an adopter-authored job
  forfeits the build-vs-sign job separation; see
  [Direct composite consumption](#direct-composite-consumption-not-a-supported-l3-path).
- **Self-hosted runners invalidate these verdicts.** Every level call above
  assumes GitHub-hosted runners; see [cross-cutting finding 4](#cross-cutting-findings).

The rest of this document is the per-builder analysis behind those level
calls. It works through the SLSA v1.2 Build L3 requirements by their own
spec names. Two of the five carry the analysis: **"Provenance is
Unforgeable"** (satisfied by-construction — see below) and **"Isolated"**
(where every per-builder gap lives). Wrangle's user-facing docs should not
reproduce this requirement-by-requirement breakdown either; they should make
a single Build L2 / Build L3 claim per workflow (tracked as a
[follow-up issue](#findings-and-recommendations)).

## Contents

1. [Why this audit exists](#why-this-audit-exists)
2. [The two L3 requirements this audit turns on](#the-two-l3-requirements-this-audit-turns-on)
3. [The SLSA v1.2 L3 isolation requirement, verbatim](#the-slsa-v12-l3-isolation-requirement-verbatim)
4. [Coverage of the other L3 requirements](#coverage-of-the-other-l3-requirements)
5. [Adopter consumption model (what isolation comes for free)](#adopter-consumption-model-what-isolation-comes-for-free)
6. [Per-builder audit](#per-builder-audit)
   - [npm path (npm sub-path)](#npm-path-npm-sub-path)
   - [npm path (pnpm sub-path)](#npm-path-pnpm-sub-path)
   - [Python path (pip sub-path)](#python-path-pip-sub-path)
   - [Python path (uv sub-path)](#python-path-uv-sub-path)
   - [Container path](#container-path)
   - [Shell path](#shell-path)
7. [Cross-cutting findings](#cross-cutting-findings)
8. [Ecosystem-specific builders vs the generic generator](#ecosystem-specific-builders-vs-the-generic-generator)
9. [Release-vs-PR build asymmetry: a structural remediation pattern](#release-vs-pr-build-asymmetry-a-structural-remediation-pattern)
10. [Findings and recommendations](#findings-and-recommendations)
11. [References](#references)

---

## Why this audit exists

The May 2026 Mini Shai-Hulud / TanStack compromise ([#205](https://github.com/TomHennen/wrangle/issues/205))
exploited pnpm-store cache poisoning: pnpm stores extracted modules under
content-addressed paths but does not re-verify content against the claimed hash
at install time, so a tampered cache yields a tampered build whose SLSA
provenance is faithfully signed over the poisoned bytes. Wrangle addressed that
one path in [#212](https://github.com/TomHennen/wrangle/pull/212) by disabling
the pnpm cache.

But the lesson is structural, not specific. Wrangle uses the
[`generator_generic_slsa3.yml`](https://github.com/slsa-framework/slsa-github-generator/blob/main/.github/workflows/generator_generic_slsa3.yml)
generator, which signs over a base64 subjects list the caller hands it. The
generator's L3 isolation guarantee covers the *signing* path. The *build* path
that produces those bytes runs in wrangle's composite, inside a job whose
environment wrangle and the adopter both shape. If any cache, persistent state,
or non-build influence taints that environment, the resulting provenance is
faithfully signed garbage.

This audit asks the same question of every builder wrangle ships: does the
build environment that produces the bytes the generator signs over actually
meet SLSA v1.2 Build L3 "Isolated"?

## The two L3 requirements this audit turns on

SLSA v1.2 Build L3 is the cumulative top of a five-requirement matrix in
[`build-requirements.md`](https://github.com/slsa-framework/slsa/blob/releases/v1.2/spec/build-requirements.md).
Two of those five requirements carry this audit's analysis — **"Provenance is
Unforgeable"** and **"Isolated"** — and adopter-facing prose routinely
conflates them ("we have SLSA L3 provenance" reads as a claim about both).
The audit refers to each by its own SLSA spec name throughout. The other
three L3 requirements (*"Provenance Exists"*, *"Provenance is Authentic"*,
*"Hosted"*) are covered in
[their own section below](#coverage-of-the-other-l3-requirements).

**"Provenance is Unforgeable"** is the property of the workflow that emits the
signed attestation
([build-requirements.md, "Provenance is Unforgeable"](https://github.com/slsa-framework/slsa/blob/releases/v1.2/spec/build-requirements.md)):

> Provenance MUST be strongly resistant to forgery by tenants.
>
> - Any secret material used for authenticating the provenance, for example
>   the signing key used to generate a digital signature, MUST be stored in a
>   secure management system appropriate for such material and accessible only
>   to the build service account.
> - Such secret material MUST NOT be accessible to the environment running the
>   user-defined build steps.
> - Every field in the provenance MUST be generated or verified by the build
>   platform in a trusted control plane. The user-controlled build steps MUST
>   NOT be able to inject or alter the contents…

`generator_generic_slsa3.yml` satisfies these requirements by construction:
the signing key is an OIDC-bound Sigstore identity tied to the generator's own
`workflow_ref`, the generator runs in its own isolated reusable workflow, and
the signing step in wrangle's reusable workflows lives in a separate job
([`.github/workflows/build_and_publish_python.yml`:174–194](../.github/workflows/build_and_publish_python.yml)
and parallels in npm/container) that the build job cannot influence.

**"Isolated"** is the property of the environment that produced the
bytes being signed (same page, "Isolation strength" → "Isolated"):

> The build platform ensured that the build steps ran in an isolated
> environment, free of unintended external influence. … any external
> influence on the build was specifically requested by the build itself.
> This MUST hold true even between builds within the same tenant project.
>
> The build platform MUST guarantee the following:
>
> - It MUST NOT be possible for a build to access any secrets of the build
>   platform…
> - It MUST NOT be possible for two builds that overlap in time to influence
>   one another…
> - It MUST NOT be possible for one build to persist or influence the build
>   environment of a subsequent build. In other words, an ephemeral build
>   environment MUST be provisioned for each build.
> - **It MUST NOT be possible for one build to inject false entries into a
>   build cache used by another build, also known as "cache poisoning". In
>   other words, the output of the build MUST be identical whether or not the
>   cache is used.**
> - The build platform MUST NOT open services that allow for remote influence
>   unless all such interactions are captured as `externalParameters` in the
>   provenance.

Emphasis added. The cache-poisoning prohibition is the rule that #205 found
wrangle's pnpm path violating. This audit asks the same question of every
other builder.

The *"MUST NOT open services that allow for remote influence"* bullet
(third from the bottom, "open services" rule) is satisfied by-construction
across every wrangle builder: none of the build composites start listening
sockets, debug servers, or remote-control endpoints. The composites' outbound
network calls are scoped to dependency fetches (npm registry, PyPI, container
base-image registry) and the `docker/build-push-action` step that pushes the
built image. None of these are services *the build* opens; they are clients
of services the dependency ecosystem or adopter-configured registry opens.
The `externalParameters` carve-out is therefore not needed and not used.

When wrangle's docs today say "SLSA L3 provenance," that phrasing speaks only
to "Provenance is Unforgeable" and does **not**, by itself, establish that the
build met "Isolated." A reader who skims and conflates the two is misled. The
audit's recommended fix is **not** to teach adopters to reason about the two
requirements separately — it is for wrangle's user-facing docs to drop the
unqualified "SLSA L3 provenance" phrasing and instead claim a single Build
Track level per workflow, exactly as the [bottom-line table](#bottom-line-per-builder-build-track-level-today)
above does (a [follow-up issue](#findings-and-recommendations)).

## The SLSA v1.2 L3 isolation requirement, verbatim

The single most load-bearing block of spec language for this audit is the
"Isolated" requirement quoted above. Three additional spec excerpts inform
the per-builder verdicts:

**1. Build cache, defined.** From the `releases/v1.2` terminology page,
[`terminology.md`](https://github.com/slsa-framework/slsa/blob/releases/v1.2/spec/terminology.md),
under "Build model":

> *Build caches* are intermediate artifact storage managed by the platform that
> maps intermediate artifacts to their explicit inputs. Subsequent builds on
> the platform may share these caches.

**2. Threat: poison the build cache.** From the `releases/v1.2` threats page,
[`threats.md`](https://github.com/slsa-framework/slsa/blob/releases/v1.2/spec/threats.md),
"Build threats" section, threat *"Poison the build cache"* (Build L3):

> **Threat:** Add a malicious artifact to a build cache that is later picked up
> by a benign build process.
>
> **Mitigation:** Build caches must be isolated between builds to prevent such
> cache poisoning attacks.

The spec's worked example states the L3 bar for caches explicitly:

> Each cache entry is keyed by the transitive closure of the inputs, and the
> cache entry is itself a SLSA Build L3 build with its own provenance.

That is a high bar — strictly read, *none* of the GitHub-Actions-native caches
(`actions/cache`, `setup-*` integrated caches, BuildKit's `type=gha` cache)
satisfy it on their own. They are content-keyed but not themselves L3-built,
and the cache backend is not part of the SLSA generator's trust boundary. This
puts the burden on the calling build to choose between (a) disabling the cache,
(b) verifying at use, or (c) accepting that the build does not meet "Isolated"
even though the provenance is Unforgeable.

**3. Assessment prompts.** From the `releases/v1.2` assessing-build-platforms
page, [`assessing-build-platforms.md`](https://github.com/slsa-framework/slsa/blob/releases/v1.2/spec/assessing-build-platforms.md),
"Cache" section:

> - What sorts of caches are available to build environments?
> - How are those caches populated?
> - How are cache contents validated before use?

These are the three questions answered per cache surface in the [per-builder
audit](#per-builder-audit) below.

## Coverage of the other L3 requirements

SLSA v1.2 Build L3 is the cumulative top of a five-row matrix
([`build-requirements.md` overview table](https://github.com/slsa-framework/slsa/blob/releases/v1.2/spec/build-requirements.md)).
This audit's deep evidence-gathering focused on **Isolated** because that is
where the cache-related gaps live and where issue #216 points the audit. The
other four requirements are covered briefly here. Each is largely satisfied
by-construction by wrangle's choice of `generator_generic_slsa3.yml` plus the
reusable-workflow consumption model; this section records the verdicts so the
audit's "L3" framing is honest end-to-end rather than implicitly conflating
the unaudited requirements with the audited one.

### Provenance Exists (L1 + L2 + L3)

> The build process MUST generate provenance that unambiguously identifies the
> output package by cryptographic digest and describes how that package was
> produced. The format MUST be acceptable to the package ecosystem and/or
> consumer.
> *— `build-requirements.md`, "Provenance Exists"*

**Verdict: MEETS.** Every wrangle reusable workflow that produces provenance
invokes `slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@v2.1.0`
(e.g.,
[`.github/workflows/build_and_publish_python.yml:183`](../.github/workflows/build_and_publish_python.yml),
parallels for npm and container). The generator emits SLSA Provenance in
the recommended interoperable format with a base64-subjects list that names
each artifact by SHA-256 digest. The hashes are computed by wrangle's build
composites
([`build/actions/python/action.yml:138–149`](../build/actions/python/action.yml),
[`build/actions/npm/action.yml:156–167`](../build/actions/npm/action.yml))
from the produced files in `dist/`. Verified by the in-workflow `verify` job
([`build_and_publish_python.yml:203–230`](../.github/workflows/build_and_publish_python.yml))
before declaring the build successful, so a mismatch fails the workflow.

### Provenance is Authentic (L2 + L3)

> Consumers MUST be able to validate the authenticity of the provenance
> attestation… The provenance MUST be generated by the control plane (i.e.
> within the trust boundary identified in the provenance) and not by a tenant
> of the build platform.
> *— `build-requirements.md`, "Provenance is Authentic"*

**Verdict: MEETS.** The provenance is signed by `cosign`/Sigstore via the
generator's OIDC-bound keyless identity. The generator's `workflow_ref` is
the trust anchor: `slsa-verifier` validates the OIDC subject is exactly
`slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@refs/tags/v2.1.0`,
making the attestation traceable to a specific generator version. The
provenance fields are populated by the generator's control plane, not by
wrangle's build composites. The only fields wrangle's composites supply are
the documented exceptions in the spec (the subjects' names and digests),
which is the explicit carve-out:

> Exceptions for fields that MAY be generated by a tenant of the build
> platform: The names and cryptographic digests of the output artifacts, i.e.
> `subject` in [SLSA Provenance].

No L3-specific gap. The same `verify` job mentioned under "Provenance Exists"
also catches tampering between build and publish.

### Provenance is Unforgeable (L3 only)

> Provenance MUST be strongly resistant to forgery by tenants.
> - Any secret material used for authenticating the provenance… MUST be stored
>   in a secure management system… accessible only to the build service
>   account.
> - Such secret material MUST NOT be accessible to the environment running the
>   user-defined build steps.
> - Every field in the provenance MUST be generated or verified by the build
>   platform in a trusted control plane. The user-controlled build steps MUST
>   NOT be able to inject or alter the contents.
> *— `build-requirements.md`, "Provenance is Unforgeable"*

**Verdict: MEETS** when wrangle is consumed via reusable workflow.
The Sigstore signing identity is the generator's OIDC token, minted inside
the generator's own isolated reusable workflow. The build composite runs in
a different job ([`build_and_publish_python.yml:114–158`](../.github/workflows/build_and_publish_python.yml))
with `permissions: contents: read` and no `id-token: write`, so the build
cannot mint a Sigstore certificate. The generator's job runs in a separate
job invocation (line 174 onward) with `id-token: write`, and that job's user
code is the generator itself, not wrangle's composite. The
build-job-can't-sign / sign-job-can't-build separation is the structural
property this requirement asks for.

The "user-controlled build steps MUST NOT be able to inject or alter the
contents" half is satisfied because the generator builds the provenance from
its own context (`github` context, `workflow_ref`, the time it ran, the
subjects list, the SLSA generator's own version) — none of which the
wrangle build composite can rewrite. The one field the build composite does
supply is the `base64-subjects` (the digests of the artifacts), which falls
under the spec's explicit tenant-allowed carve-out for the `subject` field.

**Conditional caveat:** this verdict is contingent on the adopter consuming
wrangle via one of **wrangle's** reusable workflows
([`build_and_publish_python.yml`](../.github/workflows/build_and_publish_python.yml)
and parallels — not to be confused with the upstream SLSA generator's
reusable workflow, which is invoked from inside wrangle's). An adopter who
calls `build/actions/python@<sha>` directly from a workflow they wrote
themselves — placing the composite in a job that also has `id-token: write`
— voluntarily forfeits the build-vs-sign job separation. The audit recommends
documenting this in the build-type READMEs
(see [Findings](#findings-and-recommendations)).

### Hosted (L2 + L3)

> All build steps ran using a hosted build platform on shared or dedicated
> infrastructure, not on an individual's workstation.
> *— `build-requirements.md`, "Hosted"*

**Verdict: MEETS** on GitHub-hosted runners (the supported substrate;
spec cites GitHub Actions as an example). Adopters using self-hosted runners
take on this requirement themselves — flagged in the cross-cutting findings
below.

### Summary

Of the five L3 requirements, four are satisfied by-construction by wrangle's
choice of generator + reusable-workflow consumption model. The fifth —
**Isolated** — is the requirement where wrangle's composites determine the
outcome, and where the audit found two GAP findings (uv cache; BuildKit GHA
cache). The remainder of this document focuses there.

## Adopter consumption model (what isolation comes for free)

Wrangle is published as both reusable workflows and composite actions. Each
consumption surface produces a different answer on "Isolated" (and on
"Provenance is Unforgeable"). This is the load-bearing distinction Tom flagged in
[issue #216's comment](https://github.com/TomHennen/wrangle/issues/216#issuecomment-4454952677)
and worth surfacing first because it changes the verdict on later findings.

### Reusable workflows (the recommended path)

Five reusable workflows form wrangle's public consumption surface:

| Workflow | Caller's `uses:` | Triggers |
|---|---|---|
| `check_source_change.yml` | `tomhennen/wrangle/.github/workflows/check_source_change.yml@<ref>` | source scanning |
| `build_and_publish_npm.yml` | `tomhennen/wrangle/.github/workflows/build_and_publish_npm.yml@<ref>` | npm + pnpm |
| `build_and_publish_python.yml` | `tomhennen/wrangle/.github/workflows/build_and_publish_python.yml@<ref>` | python pip + uv |
| `build_and_publish_container.yml` | `tomhennen/wrangle/.github/workflows/build_and_publish_container.yml@<ref>` | container |
| `build_shell.yml` | `tomhennen/wrangle/.github/workflows/build_shell.yml@<ref>` | shell lint/test |

Each reusable workflow places the build composite in its own job with
deliberately scoped permissions. Concrete evidence from `build_and_publish_python.yml`:

- Build job permissions: [`contents: read`](../.github/workflows/build_and_publish_python.yml) (line 117)
- Provenance job (calls `generator_generic_slsa3.yml`): separate job with
  `id-token: write` + `contents: write` (lines 174–194)
- Verify job: `permissions: {}` (line 207)

The same shape holds in [`build_and_publish_npm.yml`](../.github/workflows/build_and_publish_npm.yml)
(build job at line 85: `contents: read`; provenance job at line 109: `id-token: write`)
and [`build_and_publish_container.yml`](../.github/workflows/build_and_publish_container.yml)
(line 24: `contents: read`).

Wrangle implements this build-vs-sign job separation itself, in its own
reusable workflows. It is the same separation the SLSA project's
ecosystem-specific builders inherit from the BYOB framework
(`delegator_lowperms-generic_slsa3.yml`) — restricted-permission build job,
separate signing job — but wrangle reaches it by a different route. Wrangle
does not use an ecosystem-specific SLSA builder; it uses the *generic
generator* (`generator_generic_slsa3.yml`) and wraps it in wrangle-authored
reusable workflows that place the build composite and the generator
invocation in separate jobs. See [Ecosystem-specific builders vs the generic
generator](#ecosystem-specific-builders-vs-the-generic-generator) below for
why wrangle uses the generic generator and whether switching would help.
The relevant property here: the build job has minimal permissions, the
signing job runs separately with `id-token: write`, neither can directly
tamper with the other. When an adopter consumes wrangle through a reusable
workflow ("reusable consumption" — the supported L3 path), they inherit this
separation for free. The signing-key reach into the build environment is
**closed** by construction.

What the reusable workflow does **not** isolate is the cache surfaces of the
underlying setup-* actions and build tools. Those run inside the build job's
runner image and inherit whatever cache surfaces wrangle wires up. The
per-builder audit below treats each of those.

### Direct composite consumption (NOT a supported L3 path)

Adopters can also call `tomhennen/wrangle/build/actions/<type>@<ref>` directly
from a workflow they write themselves ("direct consumption"). In that case,
the permissions, the ordering relative to other steps, and the
`id-token: write` reach are **adopter-managed**. The build runs in whatever
job the adopter put it in. If that job has `id-token: write` and the build
also has shell execution access to the runner, the build-vs-sign separation
the reusable workflow provided is gone — a compromised build step can mint
its own Sigstore certificate and forge provenance.

> ⚠️ **WARNING — direct composite consumption is NOT a supported SLSA L3
> path.** Every "Isolated" verdict in this audit, and the "Provenance is
> Unforgeable" verdict, assumes the adopter
> consumes wrangle through one of wrangle's **reusable workflows**. Calling
> the `build/actions/<type>` composites directly places the build in an
> adopter-authored job whose permissions wrangle cannot constrain; the
> build-vs-sign job separation becomes the adopter's responsibility and is
> easy to get wrong (one stray `id-token: write` on the build job forfeits
> it). Wrangle's reusable workflows are the **only** supported way to obtain
> wrangle's L3 claims. Direct composite consumption is supported solely for
> explicitly non-L3 use cases — local-only builds, experimentation, or custom
> orchestration where the adopter is not claiming L3 provenance — and an
> adopter on that path MUST NOT advertise the resulting artifacts as carrying
> wrangle's L3 guarantees.

The audit treats reusable consumption as the only supported L3 path, and the
"Isolated" verdicts below assume it. The audit
recommends a follow-up issue to carry this warning, loudly and explicitly,
into the build-type READMEs rather than leaving it only here. See
[Findings](#findings-and-recommendations).

## Per-builder audit

Each builder is audited against the SLSA v1.2 "Isolated" requirement and
the three cache-assessment prompts. Verdicts:

- **MEETS** — no "Isolated" gap.
- **MEETS WITH PRECONDITION** — meets so long as a stated condition holds (e.g.,
  "if `npm ci` is the install command"); the precondition is enforced.
- **GAP** — does not currently meet "Isolated"; recommendation below.
- **N/A** — builder does not produce L3 provenance (shell only).

### npm path (npm sub-path)

**Files:** [`build/actions/npm/action.yml`](../build/actions/npm/action.yml),
[`build/actions/npm/detect_tooling.sh`](../build/actions/npm/detect_tooling.sh),
[`build/actions/npm/build_and_pack.sh`](../build/actions/npm/build_and_pack.sh).

| Cache surface | Populated by | Validated at use | Verdict |
|---|---|---|---|
| `actions/setup-node`'s `cache: npm` | setup-node, keyed on `package-lock.json` hash | `npm ci` re-validates each cached tarball's SHA against `package-lock.json` on every install | **MEETS WITH PRECONDITION** |
| `~/.npm` (npm's own download cache, inside `setup-node`'s scope) | npm | Same as above — `npm ci` is the validator | covered by above |
| `actions/cache` direct calls | n/a | n/a | none — repo-wide grep returns zero hits |

**Evidence — `cache: npm` is set:**
[`build/actions/npm/action.yml:87`](../build/actions/npm/action.yml):
```yaml
cache: ${{ steps.tooling.outputs.cache }}
```
The output is `npm` on the npm sub-path:
[`build/actions/npm/detect_tooling.sh:64–65`](../build/actions/npm/detect_tooling.sh):
```bash
printf 'package-manager=npm\n' >> "$GITHUB_OUTPUT"
printf 'cache=npm\n' >> "$GITHUB_OUTPUT"
```

**Evidence — `npm ci` is what install_deps runs:**
[`build/actions/npm/build_and_pack.sh:88–89`](../build/actions/npm/build_and_pack.sh)
runs `npm ci`, which re-validates the on-disk tarball's `integrity` against
`package-lock.json` on every install. This is npm's documented behavior
([`npm ci` docs](https://docs.npmjs.com/cli/v11/commands/npm-ci)) and is what
the wrangle code comment at
[`build/actions/npm/detect_tooling.sh:24–26`](../build/actions/npm/detect_tooling.sh)
relies on:

```bash
# The npm path emits `cache=npm` because `npm ci` re-validates each cached
# tarball's integrity against package-lock.json on every install; pnpm
# install has no equivalent re-verification.
```

**Precondition.** The MEETS verdict depends on `npm ci` being the install
command. If a future change replaces `npm ci` with `npm install`, the
verification-on-use property breaks (`npm install` does not re-validate against
the lockfile on every install). Recommendation: keep `npm ci` as the only
install command for the npm sub-path, and add a structural test that asserts
this in `build/actions/npm/test.bats`.

**Verdict: MEETS WITH PRECONDITION.**

### npm path (pnpm sub-path)

**Files:** as above. The pnpm path is taken when `pnpm-lock.yaml` is present
in the project directory.

| Cache surface | Populated by | Validated at use | Verdict |
|---|---|---|---|
| `actions/setup-node`'s `cache:` | **explicitly disabled** by wrangle (PR #212) | n/a | **MEETS** via cache absence |
| pnpm-store (`~/.local/share/pnpm/store` or `~/.pnpm-store`) | pnpm itself | **pnpm does NOT re-verify cached modules at install time** — this is the #205 vector | irrelevant because cache is fresh each run |
| Corepack download cache | Corepack | integrity verified via npm registry signed metadata at download | acceptable |

**Evidence — `cache=` (empty) is emitted on the pnpm path:**
[`build/actions/npm/detect_tooling.sh:59–62`](../build/actions/npm/detect_tooling.sh):
```bash
if [[ -f "$INPUT_PATH/pnpm-lock.yaml" ]]; then
    printf 'package-manager=pnpm\n' >> "$GITHUB_OUTPUT"
    printf 'cache=\n' >> "$GITHUB_OUTPUT"
    printf 'Detected pnpm-lock.yaml; using pnpm. setup-node caching deliberately disabled (see issue #205).\n'
```

The block comment at lines 18–26 of the same file is the in-code justification
and references #205 directly. Cache absence eliminates the cache-poisoning
vector at the L3 layer wrangle controls.

There is **no upstream ecosystem-specific pnpm builder** in `slsa-framework/slsa-github-generator`
to compare against ([builder README explicitly states pnpm "not supported"](https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/nodejs/README.md)).
For pnpm specifically, wrangle's generic-generator composite is the only
available SLSA-tooled path on GitHub Actions today.

**Verdict: MEETS.** No follow-up.

### Python path (pip sub-path)

**Files:** [`build/actions/python/action.yml`](../build/actions/python/action.yml),
[`build/actions/python/install_deps.sh`](../build/actions/python/install_deps.sh).
The pip sub-path is taken when `uv.lock` is absent.

| Cache surface | Populated by | Validated at use | Verdict |
|---|---|---|---|
| `actions/setup-python`'s `cache:` | not set by wrangle | n/a (cache not enabled) | acceptable |
| `~/.cache/pip` | pip itself | pip-default behavior re-validates wheel hashes only when `--require-hashes` is in effect; otherwise relies on the wheel filename's embedded hash and the index's signature | latent concern, see below |

**Evidence — wrangle does not opt into `setup-python`'s cache integration:**
[`build/actions/python/action.yml:48–52`](../build/actions/python/action.yml)
sets `python-version-file` but not `cache:`:

```yaml
- name: Setup Python
  uses: actions/setup-python@a26af69be951a213d495a4c3e4e4022e16d87065 # v5.6.0
  with:
    python-version: ${{ inputs.python-version || '' }}
    python-version-file: ${{ inputs.python-version == '' && format('{0}/pyproject.toml', inputs.path) || '' }}
```

Without `cache: 'pip'`, `setup-python` does not restore `~/.cache/pip` across
runs. The pip cache that does exist within a single run is populated and
consumed by pip in the same job; it is per-run, not cross-run. This satisfies
"Isolated" because the cache is ephemeral with the runner.

**Latent concern.** Wrangle's pip install command does not pass
`--require-hashes`, and `pyproject.toml` does not encode dependency hashes in
the way `requirements.txt` does. The integrity story for pip-installed
dependencies relies on pip trusting (a) the index (PyPI) being honest, and
(b) the wheel filenames it sees there. This is a *supply-chain* concern, not
an *isolation* concern — it would not change between L3 and non-L3 — and is
out of scope for this audit. Flagged for future consideration: wrangle could
recommend or generate hash-pinned `requirements.txt` files for adopter projects
that need fully content-addressed Python builds.

**Verdict: MEETS** for the L3 isolation question this audit addresses.

### Python path (uv sub-path)

**Files:** [`build/actions/python/action.yml`](../build/actions/python/action.yml).
The uv sub-path is taken when `uv.lock` is present.

| Cache surface | Populated by | Validated at use | Verdict |
|---|---|---|---|
| uv's internal cache (`~/.cache/uv`) via `astral-sh/setup-uv`'s default `enable-cache: auto` | uv at first install | **uv does NOT re-verify cached files against the lockfile on cache hits** — it trusts a pre-stored hash in a sidecar pointer file (`.http`/`.rev`) | **GAP** |

**Evidence — `setup-uv` is invoked without `enable-cache: false`:**
[`build/actions/python/action.yml:69–71`](../build/actions/python/action.yml):

```yaml
- name: Install uv
  if: steps.tooling.outputs.use_uv == 'true'
  uses: astral-sh/setup-uv@08807647e7069bb48b6ef5acd8ec9567f424441b # v8.1.0
```

The `setup-uv` action defaults `enable-cache: auto`, which is `true` on
GitHub-hosted runners. The uv cache is therefore enabled and restored from
prior runs unless wrangle explicitly disables it.

**Evidence — uv's cache-hit path does not re-hash on use.** Source-verified
against `astral-sh/uv` at commit
[`1e99086`](https://github.com/astral-sh/uv/tree/1e99086e645038804c3f479ef24cc50f4ec74a96)
(2026-05-16). wrangle's uv path runs `uv sync`
([`build/actions/python/install_deps.sh`](../build/actions/python/install_deps.sh)),
resolving PyPI wheels from `uv.lock`. The full chain:

1. `uv sync` builds the hash strategy from the lockfile:
   `HashStrategy::from_resolution(&resolution, HashCheckingMode::Verify)`
   ([`crates/uv/src/commands/project/sync.rs:814`](https://github.com/astral-sh/uv/blob/1e99086e645038804c3f479ef24cc50f4ec74a96/crates/uv/src/commands/project/sync.rs#L814)).
   Hash checking is **on** — this is not a "hashes disabled" story.
2. `uv_installer::Preparer` calls `database.get_or_build_wheel(&dist, tags, policy)`;
   for a registry (PyPI) wheel this routes to `get_wheel` → `download_wheel`
   ([`crates/uv-distribution/src/distribution_database.rs:124,185`](https://github.com/astral-sh/uv/blob/1e99086e645038804c3f479ef24cc50f4ec74a96/crates/uv-distribution/src/distribution_database.rs#L124)).
3. `download_wheel` calls `cached_client().get_serde_with_retry(req, &http_entry, …, download)`.
   The `download` closure is the **only** code that streams the wheel bytes
   through `HashReader` to compute a hash
   ([`distribution_database.rs:909–933`](https://github.com/astral-sh/uv/blob/1e99086e645038804c3f479ef24cc50f4ec74a96/crates/uv-distribution/src/distribution_database.rs#L909-L933)).
4. On a cache hit, `get_cacheable` returns the `Archive` deserialized straight
   from the `.http` sidecar and **never invokes the `download` closure**
   ([`crates/uv-client/src/cached_client.rs:289–335`](https://github.com/astral-sh/uv/blob/1e99086e645038804c3f479ef24cc50f4ec74a96/crates/uv-client/src/cached_client.rs#L289-L335))
   — so on a cache hit no wheel bytes are read or hashed.
5. `download_wheel` then filters the cached archive: `archive.has_digests(hashes)`
   and `archive.exists(cache)`
   ([`distribution_database.rs:997–1003`](https://github.com/astral-sh/uv/blob/1e99086e645038804c3f479ef24cc50f4ec74a96/crates/uv-distribution/src/distribution_database.rs#L997-L1003)).
   `has_digests` → `has_required_algorithms` is an **algorithm-name-only**
   check (confirms a `sha256` entry exists, never compares the digest value);
   `exists` only checks the unzipped directory is present. Neither reads
   content.
6. `Preparer` then checks `wheel.satisfies(policy)` → `HashPolicy::matches`
   ([`preparer.rs:146`](https://github.com/astral-sh/uv/blob/1e99086e645038804c3f479ef24cc50f4ec74a96/crates/uv-installer/src/preparer.rs#L146),
   [`uv-distribution-types/src/hash.rs:66–79`](https://github.com/astral-sh/uv/blob/1e99086e645038804c3f479ef24cc50f4ec74a96/crates/uv-distribution-types/src/hash.rs#L66-L79)).
   This **does** compare full `(algorithm, digest)` values — but against
   `archive.hashes`, which was read from the `.http` sidecar, not recomputed
   from the wheel the build consumes.
7. Install: `link_wheel_files` → `link_dir` clones/hardlinks/copies the
   unzipped wheel from the cache into site-packages
   ([`crates/uv-install-wheel/src/linker.rs:252–269`](https://github.com/astral-sh/uv/blob/1e99086e645038804c3f479ef24cc50f4ec74a96/crates/uv-install-wheel/src/linker.rs#L252-L269))
   — **no hashing**. `validate_and_heal_record` runs only at cache-population
   time, and its own comment states it does not validate content hashes
   (*"It's not validated anyway (pip doesn't)"*).

(The `file://`/path-wheel path, `load_wheel`, has the same shape via the
`.rev` sidecar plus an mtime check; wrangle's PyPI dependencies take the
registry path above.)

**The unzipped cache is not content-addressed.** The bytes installed in step 7
live in `archive-v0/<id>`, where `<id>` comes from `ArchiveId::new()` →
`uv_fastid::Id::insecure()` — a **random** token, not a content hash. uv's own
`persist` function carries the comment `// TODO(charlie): Support
content-addressed persistence via SHAs`
([`crates/uv-cache/src/lib.rs:386`](https://github.com/astral-sh/uv/blob/1e99086e645038804c3f479ef24cc50f4ec74a96/crates/uv-cache/src/lib.rs#L386)).
`Archive::exists` checks only that the directory is present and a
bucket-version integer matches
([`crates/uv-distribution/src/archive.rs`](https://github.com/astral-sh/uv/blob/1e99086e645038804c3f479ef24cc50f4ec74a96/crates/uv-distribution/src/archive.rs)).
There is no per-file manifest, signature, or MAC. Nothing relates the
installed directory back to the verified download hash.

**Consequence — the attacker need not touch the sidecar.** An earlier draft of
this finding said the attacker must write "a coherent `(wheel, sidecar)`
pair." That overstates the work required. The hash uv recorded is computed
over the original *download stream*; the bytes that get *installed* are the
*unzipped* directory addressed by a random id. The two are linked only at
population time. An attacker with write access to `$UV_CACHE_DIR` overwrites
files in the `archive-v0/<id>/` directory and touches **no sidecar and forges
no hash** — `satisfies` still compares the untouched sidecar hash to the
untouched lockfile hash and passes, while the install copies the poisoned
directory.

This is structurally the same shape as the pnpm-store cache-poisoning vector
that #205 closed, and the SLSA v1.2 threat (`threats.md`, "Poison the build
cache") applies directly. There is no published CVE against uv, and uv does
not treat this as a vulnerability: uv's
[`SECURITY.md`](https://github.com/astral-sh/uv/blob/main/SECURITY.md)
declares that executing arbitrary code (PEP 517 build backends, package code)
is expected behavior, and uv's
[cache documentation](https://docs.astral.sh/uv/concepts/cache/) discusses
only operational safety (thread-safety, "never modify the cache directly"),
never the cache as a security boundary. That is a deliberate design posture —
the cache is trusted by its containing user account — but for SLSA L3 that
posture is precisely the gap.

**Threat model — why the recorded hash provides no protection.** Cache
poisoning generally requires one of: (1) a cache keyed by an
attacker-predictable name, where merely populating the key is enough; or
(2) a content-addressed cache that re-verifies at *creation* but not at *use*,
where the attacker must swap the stored bytes and the stored hash together.
uv's cache *looks* like case (2) — it records a hash — but is weaker in
practice: the recorded hash is never bound to the bytes that get installed
(the random-id-addressed unzipped directory), so the attacker does not even
need to forge a matching hash. Overwriting the unzipped directory is
sufficient, as traced above.

**Is it fair to assume the attacker has that write access?** Yes — and the
mechanism is the [GitHub Actions cache service](#cross-cutting-findings),
not persistent-runner compromise. There is **no privilege boundary inside a
job**: every step, and every piece of code those steps invoke, runs as the
same `runner` user with the same access to `$UV_CACHE_DIR`. Crucially,
`uv run pytest` (wrangle's test step) imports and executes the project's
*entire dependency tree*, and an sdist install runs that package's PEP 517
build backend — all third-party code, running as `runner`. So write access to
`$UV_CACHE_DIR` is not a privileged capability; it is held by every line of
dependency code wrangle's own build runs. `astral-sh/setup-uv`'s cache
integration then saves `$UV_CACHE_DIR` to the GHA cache service at job end and
restores it at job start, so a poisoned cache from one build propagates to
later builds. An attacker who can run a build step at all — a malicious
dependency lifecycle hook, a poisoned `pyproject.toml` build script, a
malicious test, a build-tool exploit — can rewrite `$UV_CACHE_DIR` inside
their own build; `setup-uv` then publishes the poisoned cache, and GHA's
branch-scoped cache rules govern which later builds restore it. This is the
#205 pnpm vector exactly, and the mechanism in Adnan Khan's "Monsters in your
build cache" research. The attacker never needs a persistent or self-hosted
runner; the GHA cache service *is* the cross-build write channel.

**Which later builds restore it — and the `pull_request_target` caveat.**
GHA caches are branch-scoped: a run restores caches from its own ref, its base
branch (for PRs), and the default branch. So an *ordinary* `pull_request`
build's poisoned cache is scoped to `refs/pull/N/merge` and cannot reach a
release build — the poisoning entry has to land in the **default-branch
scope**, which normally means the planting build itself ran on the default
branch (e.g., post-merge CI of a merged dependency change). **`pull_request_target`
removes that caveat.** A `pull_request_target` (or `workflow_run`) workflow
runs with `github.ref` set to the *base* branch, so its cache scope is the
default branch — and if it executes any PR-controlled code or build inputs, an
external attacker who never gets a PR merged can write straight into the
default-branch cache scope a release build restores from. wrangle does not
ship a `pull_request_target` workflow today; the exposure is an **adopter** who
calls a wrangle reusable workflow from a `pull_request_target` context. See
[cross-cutting findings](#cross-cutting-findings) and
[Finding 1](#finding-1-uv-cache-integrity-gap-on-the-python-uv-sub-path).

**What can prevent it, and what does SLSA L3 require?** SLSA v1.2's
"Isolated" requirement is categorical: *"It MUST NOT be possible for one build
to inject false entries into a build cache used by another build … the output
of the build MUST be identical whether or not the cache is used."* The spec's
worked example sets an even higher bar (each cache entry keyed by the
transitive closure of inputs and itself an L3 build). uv's cache meets
neither — entries are not re-verified at use, and the GHA cache service
shares them across builds. SLSA L3 therefore leaves two roads: (a) make the
cache poisoning-proof — re-hash on use, which only uv upstream can do — or
(b) do not consume a shared cache for L3-attested builds. Road (b) is what
the [release-vs-PR asymmetry](#release-vs-pr-build-asymmetry-a-structural-remediation-pattern)
recommendation takes: disable the uv cache on release builds so the bytes the
generator signs over never pass through cross-build storage. The mitigation
options below are the concrete levers for road (b).

**No upstream ecosystem-specific python builder exists**
([slsa-framework/slsa-github-generator issue #55](https://github.com/slsa-framework/slsa-github-generator/issues/55)
remains open). Wrangle is the only SLSA-tooled python build path on GitHub
Actions today, so the choice is between fixing this in wrangle or living with
the gap.

**Mitigation options, in order of strength:**

1. **Disable the uv cache for release builds.** Set
   [`astral-sh/setup-uv`](https://github.com/astral-sh/setup-uv)'s
   `enable-cache: false` input on the wrangle invocation, or set
   `UV_NO_CACHE=1` in the build job's env. Cost: every dependency downloaded
   every release build. Likely acceptable given release frequency.
2. **(Not effective for PyPI; documented as a trap.)** `uv sync --refresh`
   sounds like the natural "force re-download" fix, but it does **not** close
   this vector for the common PyPI case. Source-verified against `astral-sh/uv`
   `main`: `--refresh` produces `Refresh::All(now)`
   ([`crates/uv-cache/src/lib.rs:1373`](https://github.com/astral-sh/uv/blob/main/crates/uv-cache/src/lib.rs#L1373))
   which marks entries `Freshness::Stale` →
   `CacheControl::MustRevalidate`
   ([`crates/uv-client/src/cached_client.rs:182`](https://github.com/astral-sh/uv/blob/main/crates/uv-client/src/cached_client.rs#L182)),
   which sets `Cache-Control: no-cache` on the HTTP request
   ([`cached_client.rs:495`](https://github.com/astral-sh/uv/blob/main/crates/uv-client/src/cached_client.rs#L495)).
   PyPI wheel URLs are content-addressed and immutable, so the server returns
   **304 Not Modified** essentially always. On 304, uv rewrites the
   cache-policy bytes and returns `Payload::from_aligned_bytes(cached.data)`
   ([`cached_client.rs:306–335`](https://github.com/astral-sh/uv/blob/main/crates/uv-client/src/cached_client.rs#L306-L335)),
   deserializing the existing `Archive { id, hashes, filename }` from the
   unchanged `.http` sidecar — the on-disk wheel bytes are never re-hashed.
   Only the 200-Modified branch
   ([`distribution_database.rs:683–745`](https://github.com/astral-sh/uv/blob/main/crates/uv-distribution/src/distribution_database.rs#L683-L745))
   re-hashes via `HashReader`, and that branch is only taken when the upstream
   URL's content actually changed — precisely the case where no protection
   was needed. For completeness: `--reinstall` controls site-packages
   reinstallation (not the cache), and also does not close the gap.
3. **Pin the cache to a fresh ephemeral location.** Set
   `UV_CACHE_DIR=$RUNNER_TEMP/uv-cache` so the cache cannot survive across
   builds. Cheap to add; relies on `$RUNNER_TEMP` being ephemeral, which is
   GitHub's documented behavior on GitHub-hosted runners. **Caveat:** this
   protection only holds if no `actions/cache` step rehydrates
   `$UV_CACHE_DIR` (or any path under `$RUNNER_TEMP` that includes it) before
   `uv sync` runs. An adopter who wires their own `actions/cache` around the
   wrangle composite and keys it on a stable name re-creates the poisoning
   surface inside `$RUNNER_TEMP` and the protection collapses. Wrangle itself
   uses no `actions/cache` calls (see cross-cutting finding #1), so the
   protection holds for wrangle's own invocation; adopters adding caching
   around wrangle need to be aware.
4. **(Future)** Upstream-petition uv to add a `--verify-hashes-on-cache-hit`
   flag that re-hashes cached files at install time. The behavior is
   structurally cheap (hash the bytes already on disk) and would close the
   gap for every uv user.

**Verdict: GAP.** Recommendation: option (1) — disable the uv cache on the
release path inside the reusable workflow. It is the safer lever: it removes
the shared-cache surface entirely, so SLSA's "the output of the build MUST be
identical whether or not the cache is used" holds *categorically*. Option (3)
is a lighter-touch alternative, but its protection is *conditional* — it
relies on `$RUNNER_TEMP` staying ephemeral and on no adopter `actions/cache`
step rehydrating the path (see the option (3) caveat above) — so it is a
fallback, not the default. Option (2) is listed only to mark it as a trap —
anyone reaching for "force refresh" as the obvious fix should find this
paragraph rather than reach for `--refresh` and assume it works.

### Container path

**Files:** [`build/actions/container/action.yml`](../build/actions/container/action.yml).

| Cache surface | Populated by | Validated at use | Verdict |
|---|---|---|---|
| BuildKit GHA cache (`type=gha`, `mode=max`) | every BuildKit build that runs the action, in every branch scope GitHub allows | **Not re-verified on cache hits.** Digest check happens at *ingest* via containerd's `Writer.Commit`, but the "expected" digest used for that check comes from the cache index itself — which an attacker controls together with the blob. Subsequent reads through `ReaderAt`/`GetByBlob`/`FromRemote` perform no content verification. | **GAP** |
| GHA cache scope rules | GitHub | GHA cache is branch-scoped server-side; a default-branch run, a `pull_request_target` run, or a parent-branch run can write entries that a protected build will resolve | exploits exist |

**Evidence — `type=gha,mode=max` is configured:**
[`build/actions/container/action.yml:89–90`](../build/actions/container/action.yml):

```yaml
cache-from: type=gha
cache-to: type=gha,mode=max
```

**Evidence — BuildKit verifies on ingest but not on reuse.** Source-verified
against `moby/buildkit` `master` HEAD. The relevant call sites:

- `cache/remotecache/gha/gha.go` — `ciProvider.loadEntry` returns the cached
  bytes through a `readerAt` wrapper that enforces size bounds but performs no
  cryptographic verification against `desc.Digest`.
- `cache/remotecache/import.go` — `readBlob` only enters the digest-check
  branch on `io.EOF`; successful reads return unverified. It is also capped at
  1 MiB (it handles the *cache index*, not the actual layer blobs).
- `cache/manager.go` — `cacheManager.GetByBlob` looks up by chain-ID without
  re-verifying.
- `worker/base/worker.go` — `FromRemote` calls `Provider.Info` (existence
  check), not a content hash.

The one place verification *does* happen is when containerd ingests a new blob
into the local content store: `content/local/writer.go` `Writer.Commit`
compares the streamed bytes' computed digest to the `expected` value
passed by `content.Copy`. But that `expected` value comes from the **cache
index**, which the attacker also controls. A coherent (index, blob) pair from
a poisoning vector passes this check.

**Evidence — GHA cache scope allows cross-scope poisoning.** GitHub's
[`actions/cache` scoping rules](https://docs.github.com/en/actions/using-workflows/caching-dependencies-to-speed-up-workflows)
let workflow runs restore caches written by (a) the current branch, (b) the
base branch of a pull request, or (c) the default branch. Public research
documents three concrete cross-scope poisoning vectors:

- **`pull_request_target` writes to base-repo scope.** A `pull_request_target`
  workflow executes in the base repo's context with base-repo cache write
  access; default-branch builds will later resolve those entries. Documented
  in the [TanStack postmortem](https://safedep.io/tanstack-github-actions-cache-poisoning/).
- **Default-branch code execution poisoning.** Any code execution attained on
  the default branch (via maintainer compromise, expression-injection in a
  default-branch workflow, etc.) writes entries every later run resolves.
  Adnan Khan's
  ["Monsters in Your Build Cache"](https://adnanthekhan.com/2024/05/06/the-monsters-in-your-build-cache-github-actions-cache-poisoning/)
  is the canonical writeup.
- **Parent-branch poisoning.** A run on a parent branch (e.g., `dev` if it's
  parent to feature branches) writes entries every feature-branch run will
  resolve. Same source.

BuildKit's `scope=` attribute only namespaces between configurations *within*
a branch; it does not protect across branches. The branch scope is enforced
GitHub-side and is invisible to BuildKit.

The SLSA v1.2 spec is explicit: *"the output of the build MUST be identical
whether or not the cache is used."* For the current configuration, the output
can differ if the cache is poisoned, and the poisoning conditions are
reachable from contexts wrangle does not control (PR builds, feature
branches). The exposure widens sharply if a `pull_request_target` (or
`workflow_run`) workflow is in the picture: those run in the *base-branch*
cache scope, so PR-controlled code can poison the default-branch scope
directly. wrangle ships no such workflow, but an **adopter** who calls a
wrangle reusable workflow from a `pull_request_target` context creates exactly
that exposure — the adopter-facing docs must warn against it.

**Comparison to upstream.** `slsa-github-generator`'s
[`generator_container_slsa3.yml`](https://github.com/slsa-framework/slsa-github-generator/blob/main/.github/workflows/generator_container_slsa3.yml)
takes a pre-built `(image, digest)` and runs `cosign attest`. **It does not
build the image** and does not opine on the caller's docker build cache
configuration — the upstream README explicitly tells callers to run
`docker/build-push-action` themselves in the caller's job (so caching, or not,
is the caller's choice). There is no ecosystem-specific SLSA builder for
containers to compare against.

**Mitigation options, in order of strength:**

1. **Disable cache for release builds.** Gate `cache-from` and `cache-to` on
   `github.ref` and `github.event_name`: don't set them when building a
   release tag or pushing to `main`. Cost: longer release builds; arguably
   acceptable.
2. **Move to a content-addressed, write-restricted registry cache.** Use
   `cache-from: type=registry,ref=ghcr.io/.../buildcache` and
   `cache-to: type=registry,ref=ghcr.io/.../buildcache`, with the registry
   tag's write permission restricted to default-branch / release jobs.
   Registry pulls are digest-addressable; write-gating prevents PR/feature
   branches from poisoning.
3. **Make `cache-to` conditional on trusted-context detection.** Read-only
   `cache-from` for PR/feature-branch runs; both `cache-from` and `cache-to`
   only on the default branch and release tags. Prevents poisoning without
   giving up cache reuse.
4. **Enable BuildKit cache-index signing** (BuildKit's GHA exporter supports a
   `sign=...` block). Raises the attacker's bar from "can write to the GHA
   cache scope" to "must possess the signing key."

**Verdict: GAP.** Recommendation: a combination of (3) for everyday CI and
(1) for release-tag builds.

### Shell path

**Files:** [`build/actions/shell/action.yml`](../build/actions/shell/action.yml).

The shell build type runs `shellcheck` and `bats`. It produces no artifact and
generates no SLSA provenance. The reusable workflow
[`build_shell.yml`](../.github/workflows/build_shell.yml) calls only the
composite, no generator.

The "every builder" claim of #216 is honest only if this is documented:
**the shell builder is intentionally outside the L3 audit scope because it
produces no provenance to attest.** No cache surfaces; no L3 concern.

**Verdict: N/A.**

## Cross-cutting findings

**1. No *direct* `actions/cache` calls — but the cache surfaces wrangle does
use are backed by GitHub's Actions cache service.** Verified by repo-wide grep
at audit time: wrangle calls no `actions/cache` step directly. "No direct
calls" is not "no cache service," however. Three of wrangle's cache surfaces
route to the GitHub Actions cache service (a GitHub-managed cross-build
backend, not the runner's local disk):

- **npm `cache: npm`** ([`build/actions/npm/action.yml:87`](../build/actions/npm/action.yml))
  — `actions/setup-node`'s cache integration calls `actions/cache`
  internally, so the cached `~/.npm` entries live on the GHA cache service.
- **uv cache** — `astral-sh/setup-uv` is invoked without `enable-cache: false`
  ([`build/actions/python/action.yml:69–71`](../build/actions/python/action.yml)),
  so it defaults to `enable-cache: auto` (true on GitHub-hosted runners) and
  saves/restores `$UV_CACHE_DIR` through the GHA cache service.
- **container `type=gha`** ([`build/actions/container/action.yml:89–90`](../build/actions/container/action.yml))
  — BuildKit's `type=gha` backend talks to the GitHub Actions cache API
  directly; it *is* the GHA cache service.

The one cache surface **not** on the GHA cache service is pip's
`~/.cache/pip`: wrangle does not set `cache:` on `actions/setup-python`
([covered above](#python-path-pip-sub-path)), so that cache is per-run and
local to the runner. So "no direct `actions/cache` calls" is true but does
not put the cross-build cache service out of scope — it is the backing store
for the npm, uv, and container cache surfaces, and the branch-scoped sharing
rules of that service are exactly what the uv and container GAP findings
exploit.

**2. No persistent state outside `$RUNNER_TEMP` and the workspace.** No
composite writes to `~/.local` or other home-directory locations explicitly.
The implicit caches managed by `setup-node`, `setup-python`, `setup-uv`, and
BuildKit are the only persistent surfaces, and each is audited above.

**3. `persist-credentials: false` is set on every `actions/checkout` in the
build composites:** [`build/actions/container/action.yml:54`](../build/actions/container/action.yml)
and the reusable workflows that wrap the npm and python composites
([`build_and_publish_python.yml:127`](../.github/workflows/build_and_publish_python.yml)
and parallels). This matches the `persist-credentials: false` practice the
SLSA ecosystem-specific builders follow.

**4. Self-hosted runner caveat.**

> ⚠️ **WARNING — wrangle's L3 verdicts assume GitHub-hosted runners.**
> Adopters who run wrangle's composites or reusable workflows on **self-hosted
> runners** invalidate the cross-cutting "ephemeral build environment"
> assumption every per-builder verdict in this audit depends on, and may
> silently fail SLSA's "Isolated" requirement — dropping the workflow to
> Build L2 — without any other change
> on their side. If your CI moves to self-hosted runners (whether for cost,
> capacity, or hardware reasons), the L3 isolation analysis must be redone
> against the runner-management posture you operate; the verdicts here do
> not transfer.

GitHub-hosted runners are ephemeral on two axes: the runner VM image is
re-provisioned per job (so on-disk state like `~/.cache/*`, `~/.npm`,
`~/.pnpm-store`, `~/.cache/uv`, and `/var/lib/docker/` does not survive a
runner reboot), and the GitHub Actions cache service (where `actions/cache`
and BuildKit's `type=gha` entries actually live — these are not stored on
the runner VM but on a separate GitHub-managed cache backend, keyed by
repo + branch scope and retrieved over the network at the start of each job)
enforces the [cache scope rules](https://docs.github.com/en/actions/using-workflows/caching-dependencies-to-speed-up-workflows)
that the per-builder audit treats as the in-scope threat surface. The
runner image is fresh per job; the cache contents are not — that asymmetry
is exactly what the BuildKit / uv cache findings exploit.

On a **self-hosted** runner, neither axis is guaranteed. The runner VM /
container may be long-lived (state in `~/.cache/*`, the local Docker layer
store, etc. persists across jobs in attacker-influenced ways), and depending
on how the operator wires GitHub's cache service in, additional persistent
surfaces may exist that this audit did not enumerate. Adopters using
self-hosted runners take on the responsibility for meeting "Isolated"
themselves; the adopter-facing doc should call this out explicitly.

**5. Reusable consumption already separates build from sign.** Wrangle's
reusable workflows give the build-vs-sign job separation that the SLSA
ecosystem-specific builders get from BYOB, even though wrangle uses the
generic generator rather than a builder. The build job has `contents: read`;
the provenance job runs `generator_generic_slsa3.yml` (itself an isolated
reusable workflow) with `id-token: write`. The signing key is unreachable
from the build job. Adopters who bypass the reusable workflow and call the
composite directly ("direct consumption") forfeit this separation — see the
[warning above](#direct-composite-consumption-not-a-supported-l3-path).

## Ecosystem-specific builders vs the generic generator

A note on terminology first. An earlier draft of this audit used a home-grown
"Pattern A / Pattern B" shorthand that conflated two unrelated axes; this
audit no longer uses it. The two axes are:

- **SLSA architecture axis — ecosystem-specific *builder* vs *generic
  generator*.** The SLSA project ships two kinds of trusted reusable workflow.
  An *ecosystem-specific builder* (e.g., `builder_go_slsa3.yml`, the beta
  `builder_nodejs_slsa3.yml`) runs the actual build *inside* the trusted
  upstream reusable workflow. A *generic generator*
  (`generator_generic_slsa3.yml`) does not build anything — the caller
  builds, hashes the artifacts, and hands the hashes to the generator, which
  only signs. **Wrangle uses the generic generator.** Wrangle's per-ecosystem
  build logic lives in wrangle's own composite actions; wrangle invokes
  `generator_generic_slsa3.yml` purely for the signing step.
- **Wrangle consumption axis — *reusable* vs *direct*.** Independently of the
  above, an adopter consumes wrangle either through one of wrangle's reusable
  workflows ("reusable consumption" — the supported L3 path) or by calling
  wrangle's composite actions directly ("direct consumption" — see the
  [warning above](#direct-composite-consumption-not-a-supported-l3-path)).
  This axis is about wrangle's public interface, not about the SLSA generator
  architecture.

These axes are orthogonal. Wrangle is "generic generator" on the first axis
regardless of which consumption path the adopter takes on the second. The
remainder of this section is about the first axis only: would switching from
the generic generator to an ecosystem-specific builder close the L3 gaps?

### Why wrangle uses the generic generator

Wrangle deliberately picked the generic generator over an ecosystem-specific
builder. The reasoning is recorded in
[`build/actions/npm/SPEC.md`](../build/actions/npm/SPEC.md) ("The SLSA Node.js
builder is NOT the v0.1 path") and parallels: the ecosystem-specific Node.js
builder is beta, npm-only, workspaces-unsupported, and has no `pull_request`
trigger; there is no ecosystem-specific builder for python or for pnpm at all.

### Would switching to an ecosystem-specific builder close the L3 gaps?

This audit doesn't dispute the historical choice. It asks whether the choice
still trades cleanly against L3 isolation. Three concrete things an
ecosystem-specific builder enforces that the generic-generator model does not
give you automatically:

**1. Job-level permission separation.** The BYOB framework
(`delegator_lowperms-generic_slsa3.yml`, which ecosystem-specific builders are
built on) restricts the build job to `contents: read` only; the signing job
runs separately. Wrangle's reusable workflows already do this themselves —
see [adopter consumption model](#adopter-consumption-model-what-isolation-comes-for-free).
**No gap under reusable consumption.** Direct consumption forfeits it — see
the [warning above](#direct-composite-consumption-not-a-supported-l3-path).

**2. Cache disablement at the setup-* step.** The ecosystem-specific Node.js
builder has an explicit comment in `internal/builders/nodejs/action.yml`
lines 72–73:
```yaml
# TODO(#1679): cache dependencies.
# cache: npm
```
The comment marks caching as known-unsafe and on a future-work list. Wrangle
enables `cache: npm` on the npm sub-path but does so safely because `npm ci`
re-verifies on every install ([covered above](#npm-path-npm-sub-path)). On the
pnpm sub-path, wrangle disables the cache outright per #205. On the uv sub-path
and the container path, wrangle does **not** disable the cache — these are the
two GAPs in this audit.

**3. `::stop-commands::` guard around the compile step.** The
ecosystem-specific Go builder wraps the compile in `echo "::stop-commands::$(echo -n "${GITHUB_TOKEN}" | sha256sum | head -c 64)"`
so workflow-command injection via build-tool stdout is neutralized. Wrangle
does not. This is technically defense-in-depth rather than an isolation
property, but the audit treats it as highly recommended given wrangle's
threat model — see [Finding 3](#finding-3-highly-recommended-stop-commands-guard-around-buildtest-invocations).

Things an ecosystem-specific builder is sometimes claimed to enforce but
**does not**:

- Containerization or read-only source mount — neither the Go builder nor
  BYOB does this; both run on `ubuntu-latest`.
- Network restriction / hermeticity — explicitly marked TODO in
  `builder_go_slsa3.yml` (line 273: *"TODO(hermeticity) OS-level"*).
- Forbidding `cache-from`/`cache-to` on the container build — the container
  generator never even sees the docker build (the caller runs it).

**Builder coverage gaps in the wrangle space:** there is no ecosystem-specific
pnpm builder, and no ecosystem-specific python builder (the latter open since
the project's early days as `slsa-framework/slsa-github-generator#55`). For
those two ecosystems, wrangle's generic-generator model is the only
SLSA-tooled path on GitHub Actions today — "switch to an ecosystem-specific
builder" is not an available option.

**Per-builder decision:**

| Builder | Ecosystem-specific builder available | Audit recommendation |
|---|---|---|
| npm | Beta Node.js builder (no pnpm support, no `pull_request`) | Keep the generic generator; npm sub-path is L3-clean. Continue tracking the Node.js builder for GA. |
| pnpm | None | Keep the generic generator; only option. Already L3-clean via cache disablement. |
| python (pip) | None | Keep the generic generator; only option. Currently L3-clean for isolation. |
| python (uv) | None | Keep the generic generator; only option. Fix the uv-cache gap (see findings below). |
| container | Container generator is signing-only (does not isolate the build) | Keep the generic generator; an ecosystem-specific builder would not solve the cache problem because the container generator does not isolate the build either. Fix the GHA cache gap (see findings below). |
| shell | n/a | Keep; no provenance produced. |

**Conclusion: the generic-generator model remains the right choice across the
board for v0.2.** The conformance gaps are "Isolated" issues
internal to wrangle's composites, not architectural problems with the
generic-generator model as a whole.

## Release-vs-PR build asymmetry: a structural remediation pattern

The two GAP findings ([uv cache](#python-path-uv-sub-path),
[BuildKit GHA cache](#container-path)) share a structural property: the gap
only matters for builds that produce L3-attested artifacts. PR builds run
under wrangle today, but they do **not** produce L3 provenance (the `provenance`
job is gated on `gate.outputs.should-release`). A cache that is unsafe to use
for a release build can be perfectly safe for a PR build — the attested
output set is empty either way.

This audit recommends gating caches on the same `should-release` signal
wrangle already uses to gate provenance creation. The pattern:

- **PR / feature-branch / non-release events:** caches enabled. Fast iteration
  for "does this change still build?" PR builds get cache hits from prior
  blessed entries; PR builds may write entries that later PR builds read. No
  L3 provenance is produced, so cache-poisoning is not an L3 concern at this
  layer.
- **Release events (tag push, default branch, or whatever the adopter's
  `release-events` input configures):** caches disabled. Fresh download / fresh
  build / no shared mutable state between builds. The bytes the generator
  signs over are derived without consulting any cross-build cache.

This composes naturally with wrangle's existing release-gate vocabulary
([`actions/release_gate/action.yml`](../actions/release_gate/action.yml)).
Adopters who set `release-events: tag-only` already pay no provenance cost on
default-branch pushes; they would similarly pay no cache cost on tag pushes
and benefit from full caching everywhere else.

### What wrangle does today

Build, test, and SBOM run on every event the reusable workflow is called on
(see [`build_and_publish_python.yml:114–158`](../.github/workflows/build_and_publish_python.yml),
parallels for npm and container). Only the `provenance` job
([line 175](../.github/workflows/build_and_publish_python.yml): `if: ${{ needs.gate.outputs.should-release == 'true' }}`)
and the `verify` job ([line 204](../.github/workflows/build_and_publish_python.yml))
are gated on `should-release`.

Adopter publish jobs typically depend on the reusable workflow's
`should-release` output (see [`gh_workflow_examples/`](../gh_workflow_examples/)),
so they inherit the same gating. PRs build and test for free; nothing is
published, signed, or attested.

Cache configuration is currently **not** gated. The `cache-from: type=gha` +
`cache-to: type=gha,mode=max` in
[`build/actions/container/action.yml:89–90`](../build/actions/container/action.yml)
and the implicit `setup-uv` cache in
[`build/actions/python/action.yml:71`](../build/actions/python/action.yml)
both run on every event regardless of release-status. This is the lever the
audit recommends pulling.

### Per-builder implementation sketch

These are sketches, not patches. Concrete implementation belongs in follow-up
issues per the contract of #216.

**Container path.** Plumb `should-release` from the reusable workflow into
the composite as an input (e.g., `cache: 'auto' | 'enabled' | 'disabled'`,
default `'auto'`), then conditionally emit `cache-from`/`cache-to` in the
`docker/build-push-action` step:

```yaml
# Reusable workflow:
- uses: TomHennen/wrangle/build/actions/container@<sha>
  with:
    cache: ${{ needs.gate.outputs.should-release == 'true' && 'disabled' || 'enabled' }}

# Composite action.yml:
- name: Build and push (cached, PR/dev path)
  if: inputs.cache != 'disabled'
  uses: docker/build-push-action@<sha>
  with:
    cache-from: type=gha
    cache-to: type=gha,mode=max
    # ... rest unchanged

- name: Build and push (cache-free, release path)
  if: inputs.cache == 'disabled'
  uses: docker/build-push-action@<sha>
  # no cache-from / cache-to
  # ... rest unchanged
```

Alternative simpler shape: pass empty strings for `cache-from`/`cache-to`
when release; `docker/build-push-action` treats empty as "don't cache."
One step instead of two, less duplication, slightly more magic.

**Python uv path.** Same plumbing — disable the uv cache on the release path
by passing `enable-cache: false` to `setup-uv` (option (1) from the uv
[mitigation menu](#python-path-uv-sub-path)), and leave caching on for PR builds:

```yaml
- name: Install uv
  if: steps.tooling.outputs.use_uv == 'true'
  uses: astral-sh/setup-uv@<sha>
  with:
    enable-cache: ${{ inputs.cache != 'disabled' }}
```

This closes the [Finding 1](#finding-1-uv-cache-integrity-gap-on-the-python-uv-sub-path)
gap categorically — a release build consumes no uv cache at all. Pinning
`UV_CACHE_DIR=$RUNNER_TEMP/uv-cache` (option (3)) is a lighter-touch fallback
only; its protection is conditional on `$RUNNER_TEMP` ephemerality.

**Python pip path.** Already L3-clean; no change needed. (PR caching could be
*added* for speed using `setup-python`'s `cache: 'pip'` input gated the same
way, since pip's lockfile-less install model means PRs and releases would have
disjoint caches by default. Optional optimization, not a security fix.)

**npm path (npm sub-path).** Already L3-clean via `npm ci` re-verification at
install time. Cache can stay enabled in both PR and release contexts without
risking the L3 verdict.

**npm path (pnpm sub-path).** Currently cache-disabled in both contexts per
#205. Could be relaxed for PRs only: enable pnpm-store caching when
`should-release == false`, keep disabled on release. Trade-off: a malicious
PR that poisons the pnpm-store for itself only affects that PR's unattested
output, but a maintainer who runs that PR's branch locally or merges without
careful review could spread the impact. Probably worth a separate threat-model
discussion before changing.

**Shell path.** No caches; no provenance; no change.

### What the pattern closes and doesn't close

**Closes:** The two GAP findings, completely, for the release path. Release
builds consume no cross-build state; the bytes the generator signs over are
derived from the just-downloaded lockfile contents and the just-checked-out
source. SLSA v1.2's *"the output of the build MUST be identical whether or
not the cache is used"* is satisfied trivially when the cache is not used.

**Does not close:** PR-to-PR cache poisoning. A malicious PR that poisons the
GHA cache (or uv cache) for itself still gets to influence subsequent PR
builds reading from the same scope. Not an L3 concern (PRs produce no L3
attestation), but a real CI-hygiene concern. See
[next subsection](#should-wrangle-care-about-pr-to-pr-cache-poisoning).

**Does not close:** The "build job has stripped permissions" property that
BYOB-based ecosystem-specific builders enforce. Wrangle's reusable workflow
already restricts the build job to `contents: read`, so the gap is already
closed for reusable consumption. Adopters who invoke the composite directly
from a job with broader permissions remain on the unsupported direct-consumption
path — see the [warning above](#direct-composite-consumption-not-a-supported-l3-path).
Carrying that warning into the build-type READMEs is a separate (doc-only)
recommendation.

### Should wrangle care about PR-to-PR cache poisoning?

> **Resolved by [PR #231](https://github.com/TomHennen/wrangle/pull/231)**
> (issue [#225](https://github.com/TomHennen/wrangle/issues/225)). The
> container build now exposes an adopter-tunable `pr-cache` knob
> (`enabled` | `isolated` | `read-only` | `disabled`). The implementation
> goes one step stricter than the original recommendation below: the
> default is **`isolated`** (per-PR scope keyed by the GitHub-assigned PR
> number), not the original "default unchanged" — secure-by-default fits
> wrangle's supply-chain positioning, and `isolated` keeps in-PR cache
> hits so the developer-experience cost is small. The per-PR scope is
> keyed by `github.event.pull_request.number` rather than `head_ref` so
> two PRs with the same source branch name (e.g. both `patch-1` from
> different forks) do not collide in cache namespace. The analysis below
> is retained as the historical record.

This is a judgment call, not a SLSA-spec lookup. The audit's recommendation:
**yes, proportionately** — not as a default-on lockdown, but as a documented
adopter-tunable knob, with a stricter posture on wrangle's own repo where
the dogfooding argument bites.

**The threat shape.** Two PRs (A and B) on the same repo. PR A obtains code
execution in its build step — easy if PR A submits a `package.json` with a
malicious `postinstall` hook, a poisoned `Dockerfile`, a malicious test, or
exploits a known vulnerability in a build tool. PR A writes a poisoned entry
to the shared GHA cache. PR B (or PR A itself on a later run, or a feature
branch derived from PR A's base) reads the poisoned entry. PR B's CI runs
attacker-controlled bytes.

Consequences range from mild to meaningful:

- **Misleading review signals.** PR B's "tests pass" may be a lie; SBOM may
  not reflect actual installed dependencies. A reviewer or merge-bot acting
  on these signals can be tricked into merging code that's actually broken
  or contains backdoors.
- **`GITHUB_TOKEN` exfiltration.** Wrangle's reusable workflow restricts the
  build job to `contents: read`, so the worst exfiltration is read access to
  the repo's source — limited but not nothing.
- **Cache persistence.** Adnan Khan's
  ["Cacheract"](https://adnanthekhan.com/2024/12/21/cacheract-the-monster-in-your-build-cache/)
  research demonstrates "cache-native malware": poisoned entries that survive
  in the cache for the GHA-eviction window (7 days of no access).
- **Staging for release-path poisoning.** Closed by the [release-vs-PR
  asymmetry](#release-vs-pr-build-asymmetry-a-structural-remediation-pattern)
  recommendation above — if release builds skip the cache, PR-staged
  poisoning can't reach an attested release. But the protection relies on
  the asymmetry being in place. An adopter who overrides or misconfigures
  it loses this guarantee.

**Why not default-on lockdown.** PR build performance matters. Cache-free PRs
slow every adopter's developer iteration loop for a threat that is real but
not constant-rate. Most adopters' threat profile is "trusted contributors
submit PRs, occasional fork PR from someone we vet," not "every PR is
attacker-controlled." Locking down PR caches by default trades developer
experience for a marginal security gain on the typical repo.

**Why not "wrangle ignores it." ** Wrangle's product positioning is supply-chain
security. Closing the cache-poisoning vector for release builds while leaving
the same vector open on every PR build is hard to defend with a straight
face, even though it's technically not an L3-conformance issue. Adopters
expect strong defaults *and* informed adopter-side knobs.

**The audit's recommended posture:**

1. **Default unchanged.** PR caches on, release caches off — the asymmetry
   already recommended.
2. **Document the PR-to-PR threat** in adopter-facing READMEs and in this
   audit (this section) so adopters can make an informed choice.
3. **Expose tuning knobs** for adopters who want stricter PR isolation:
   - **Per-PR cache namespacing.** For BuildKit:
     `cache-from: type=gha,scope=${{ github.head_ref || github.ref_name }}`
     and matching `cache-to`. Each PR gets its own cache scope; PR A cannot
     write entries PR B reads. Cost: PRs no longer share entries across
     branches; rebuilds within a PR still hit cache. For uv: ephemeral
     `UV_CACHE_DIR=$RUNNER_TEMP/uv-cache` works identically.
   - **Read-only cache-from on PRs.** PRs read main-branch entries written
     by trusted contexts (fast first build) but `cache-to` is omitted on
     PR runs (PRs cannot poison). Released entries fill the cache; PRs
     consume but never produce. Trade-off: PR-internal rebuilds don't
     benefit from caching beyond the initial main-branch entries.
   - **Global cache-disabled mode.** An adopter-facing `cache: 'never'`
     input on the reusable workflow disables caching on every event. Heavy
     hammer for strict-isolation contexts (regulated, government, etc.).
4. **Dogfood the strict position on wrangle's own repo.** Wrangle's own
   compromise propagates to every adopter — that is a different threat tier
   than a typical user repo. Wrangle's own PR CI should run cache-clean
   (the strictest of the knobs above). Tracks with the
   [Supply Chain Discipline](../CLAUDE.md) principle that wrangle's code
   must be exemplary.
5. **Explicitly warn against `pull_request_target`** in any cache-touching
   path. `pull_request_target` workflows execute in base-repo context with
   base-repo cache write access; if such a workflow ever touches wrangle's
   build composite, it becomes the highest-risk poisoning vector by a wide
   margin. Wrangle should refuse to run on `pull_request_target` or, if
   that's too strict, surface a loud warning. Cross-reference
   [#202](https://github.com/TomHennen/wrangle/issues/202) for the
   defense-in-depth `pull_request_target` refusal guard that's already
   tracked.

This expands the audit's recommendation set to four follow-up issues
(in priority order):

- Implement the release-vs-PR cache asymmetry (the L3 fix).
- Add adopter-tunable PR cache knobs (per-PR scope, read-only, never).
- Adopt the strictest knob on wrangle's own CI (dogfooding).
- Document the PR-to-PR threat and the available knobs in build-type
  READMEs.

None of these belong in this audit doc beyond the recommendation —
implementation lives in their own issues per the contract of #216.

### Why this pattern is preferred over per-finding mitigations

The audit's [Finding 1](#finding-1-uv-cache-integrity-gap-on-the-python-uv-sub-path)
and [Finding 2](#finding-2-buildkit-gha-cache-integrity-gap-on-the-container-path)
each list local mitigation options (pin `UV_CACHE_DIR`, gate `cache-to` on
branch ref, etc.). The release-vs-PR asymmetry subsumes both:

- Composes with the existing release-gate vocabulary, no parallel mechanism.
- Closes both gaps with one structural change instead of two ad hoc ones.
- Preserves PR-build performance (the original reason `type=gha`/`enable-cache`
  exist) where it doesn't cost L3 conformance.
- Leaves adopters with the existing tightening knob (`release-events`) — an
  adopter who wants every build cache-clean can set `release-events:
  always-release` (or equivalent) and get the strictest behavior without
  changing wrangle.

The audit recommends adopting this asymmetry as the **primary** remediation
pattern, with the per-finding options retained as supplemental fallbacks
(e.g., for adopters who already want cache-free PR builds for other reasons,
or for environments where the release-gate vocabulary doesn't fit). Spawn one
follow-up issue per affected builder.

## Findings and recommendations

This audit produces two GAP findings (uv cache, BuildKit GHA cache) and one
highly-recommended defense-in-depth finding (`::stop-commands::` guard). Each
is documentation; concrete remediation lands in separate issues/PRs per the
contract of #216.

### Finding 1: uv cache integrity gap on the python uv sub-path

> **Resolved by [PR #226](https://github.com/TomHennen/wrangle/pull/226).**
> The python reusable workflow now passes `cache=disabled` to the build
> composite on release builds, which sets `astral-sh/setup-uv`'s
> `enable-cache: false` — the preferred option (1) below. The analysis that
> follows is retained as the historical record of the gap.

**Summary.** `astral-sh/setup-uv@v8.1.0` is invoked at
[`build/actions/python/action.yml:69–71`](../build/actions/python/action.yml)
without `enable-cache: false`, so the uv cache is enabled by default on
GitHub-hosted runners. uv's cache-hit code path trusts a pre-stored hash from a
sidecar pointer file instead of re-hashing the cached file on disk, structurally
matching the pnpm-store gap that #205 / #212 closed.

**Severity — P2 / should-fix; a durable provenance-integrity gap, not a
release RCE.** The precondition is code execution as `runner` in a build whose
cache reaches a release build. That precondition is itself serious — code
running in wrangle's build job can already tamper with the *current* release
artifact directly (install, test, and `uv build` share one job). So in the
base case the cache gap grants the attacker no new victims and no new code
execution. Its *marginal* danger over direct tampering is specific: (1)
**persistence** — the poison outlives both the ephemeral runner and the
malicious dependency, lingering in the GHA cache service until the cache key
changes or evicts; (2) **stealth** — it breaks the correspondence between the
reviewed/attested inputs (`uv.lock`, SLSA provenance) and the bytes actually
installed, so a low-profile package can poison a trusted pinned package's
bytes while every diff, lockfile, and provenance still looks clean. Unlike a
declared malicious dependency (which SLSA's threat model explicitly pushes to
"apply SLSA recursively to dependencies"), this **is** a violation of L3's
named cache-isolation requirement. Net: real and worth fixing, but it is not a
critical release-compromise hole — the honest rating is P2.

The "must reach the default-branch cache scope" caveat is load-bearing, and it
is **removed** if a `pull_request_target` / `workflow_run` workflow is in play
(see [the uv evidence section](#python-path-uv-sub-path)): that promotes the
finding to a path an external, unmerged attacker can drive. wrangle ships no
such workflow; adopters who do must not call wrangle's reusable workflows from
that context.

**Recommendation (preferred): release-vs-PR cache asymmetry.** See
[Release-vs-PR build asymmetry](#release-vs-pr-build-asymmetry-a-structural-remediation-pattern).
Disable the uv cache (option (1) from the uv
[mitigation menu](#python-path-uv-sub-path) — `enable-cache: false`) when
`gate.outputs.should-release == 'true'`; keep caching on for PR builds.
Composes with wrangle's existing release vocabulary and closes the gap
without slowing PR iteration. Option (1) is the safer lever: a release build
then consumes no uv cache at all, rather than relying on an ephemeral cache
location holding.

**Recommendation (fallback, if release-gate plumbing is deferred).** Pin
`UV_CACHE_DIR=$RUNNER_TEMP/uv-cache` unconditionally (option (3)) so the cache
is ephemeral per job (cheap, no network cost). Cheaper to implement; slower PR
builds; protection is conditional on `$RUNNER_TEMP` ephemerality. Spawn a
follow-up issue tracking whichever path is chosen.

### Finding 2: BuildKit GHA cache integrity gap on the container path

> **Resolved by [PR #226](https://github.com/TomHennen/wrangle/pull/226).**
> The container reusable workflow now passes `cache=disabled` to the build
> composite on release builds, which drops `cache-from`/`cache-to` from the
> `docker/build-push-action` step — the preferred recommendation below. The
> analysis that follows is retained as the historical record of the gap.

**Summary.** [`build/actions/container/action.yml:89–90`](../build/actions/container/action.yml)
sets `cache-from: type=gha` and `cache-to: type=gha,mode=max`. BuildKit
verifies layer digests at ingest time using the digest from the cache index
itself; subsequent reads through `ReaderAt`/`GetByBlob` do not re-verify.
GitHub's branch-scoped cache rules let a `pull_request_target` run, a
default-branch run, or a parent-branch run write entries that protected builds
will resolve. The combined behavior violates SLSA v1.2's
*"the output of the build MUST be identical whether or not the cache is used"*.

**Severity.** Real and exploitable in the public-CI threat model; multiple
published research writeups demonstrate the vector. Wrangle's exposure is
specifically bounded by what triggers wrangle's container reusable workflow
admits — verify that there is no `pull_request_target` path that reaches the
container composite.

**Recommendation (preferred): release-vs-PR cache asymmetry.** See
[Release-vs-PR build asymmetry](#release-vs-pr-build-asymmetry-a-structural-remediation-pattern).
Drop both `cache-from` and `cache-to` when `gate.outputs.should-release ==
'true'`; keep both enabled for PR builds. PR builds remain fast; release
builds consume and write no cross-build state, so the cross-scope poisoning
vector is unreachable for L3-attested artifacts.

**Recommendation (supplemental, stronger long-term posture).** Migrate from
`type=gha` to `type=registry` with write-restricted tags, so that even the PR
cache uses content-addressable lookups gated by registry credentials. More
implementation work; closes PR-to-PR poisoning too. Worth a separate proposal.

Spawn a follow-up issue tracking the implementation. Also verify that no
`pull_request_target` path reaches this composite — `pull_request_target` is
the highest-risk poisoning vector and is uniquely dangerous because it
executes in base-repo context.

### Finding 3 (highly recommended): `::stop-commands::` guard around build/test invocations

> **Resolved by [PR #230](https://github.com/TomHennen/wrangle/pull/230)**
> (issue [#225](https://github.com/TomHennen/wrangle/issues/225)). Every
> wrangle build composite that runs ecosystem build tooling now wraps the
> build/test invocation in a `::stop-commands::` guard
> (`lib/stop_commands_guard.sh`, a per-run random token): the npm
> `build_and_pack.sh` call, the python `install_deps.sh` and `run_tests.sh`
> calls, the container `docker/build-push-action` step, and the shell
> composite's `shellcheck` and `bats` invocations. New build composites
> are kept honest by `test/test_build_guard_coverage.bats`, which
> enumerates `build/actions/*/action.yml` and fails if a composite
> ships without the guard (or without a written allowlist entry). The
> SPEC requirement is in `docs/SPEC.md` "Workflow-command-injection
> guard for build composites". The analysis that follows is retained
> as the historical record.

**Summary.** The SLSA ecosystem-specific Go builder shadows the `::`
workflow-command prefix with a per-run token before invoking the compile,
neutralizing any attempt by the build tool (or a dependency's lifecycle hook)
to inject workflow commands via stdout. Wrangle does not.

**Severity.** Strictly speaking this is defense-in-depth rather than a
SLSA v1.2 L3 requirement (it does not appear in the
"Isolated" bullets). The audit elevates the recommendation because
wrangle's threat model is unusually aligned with the attack class this
defense addresses:

- Wrangle's entire reason for existing is the npm / PyPI / container supply
  chain attack class — exactly the contexts where a malicious lifecycle hook
  in a transitive dev-dep can drop a `::set-output::`, `::add-mask::`, or
  `::add-path::` line into stdout and silently re-route the build job
  ([adopter README's `ignore-scripts` input](../build/actions/npm/README.md)
  exists for the same threat surface, addressing a different facet).
- Wrangle is positioned as a *security* framework. A compromise of wrangle
  propagates to every adopter (see [`CLAUDE.md`](../CLAUDE.md)'s "Supply
  Chain Discipline" section). The marginal cost of `::stop-commands::` is a
  one-line wrapper per shell-invoking step; the marginal benefit is
  closing the most well-known workflow-command-injection vector for free
  on every adopter.
- The SLSA ecosystem-specific Go builder
  ([`builder_go_slsa3.yml:290`](https://github.com/slsa-framework/slsa-github-generator/blob/main/.github/workflows/builder_go_slsa3.yml))
  already does this. Wrangle's generic-generator composites should match.

**Recommendation.** Add a `::stop-commands::` wrap around `build_and_pack.sh`,
`run_tests.sh`, and `install_deps.sh` invocations in every composite that
runs ecosystem build tooling (npm, python, container). Spawn a follow-up
issue; treat it on par with Finding 1 and Finding 2 in priority despite the
"defense-in-depth, not L3-required" framing.

### Adopter-facing framing

In addition to these three findings, the audit recommends:

- **A single Build Track level claim per workflow in wrangle's user-facing
  docs.** `docs/SPEC.md` and the build-type READMEs currently say "SLSA L3
  provenance" unqualified — phrasing that holds for "Provenance is
  Unforgeable" but not necessarily for "Isolated." The audit recommends
  *against* asking adopters to reason about individual L3 requirements at
  all — that is the confusing part — and instead recommends that each
  workflow claim exactly **Build L2** or **Build L3**
  per the [bottom-line table](#bottom-line-per-builder-build-track-level-today).
  Under that vocabulary the container and python-uv workflows are Build L2
  today and reach Build L3 once Findings 2 and 1 land. This audit does not
  produce that doc change; spawn a doc-only issue covering `docs/SPEC.md`
  and every README that asserts an "L3" claim.
- A loud, explicit warning in build-type READMEs that wrangle's L3 guarantee
  is contingent on **reusable consumption** (calling wrangle's reusable
  workflow) and that **direct consumption** (calling the `build/actions/<type>`
  composites directly) is NOT a supported L3 path — mirroring the
  [warning above](#direct-composite-consumption-not-a-supported-l3-path).
  This audit does not produce that change; spawn a doc-only issue, and treat
  it as a priority item rather than a nicety, since an adopter on the direct
  path who believes they have L3 has a false assurance.
- A self-hosted-runner caveat (cross-cutting finding 4 above) in the same
  README locations.

## References

### SLSA v1.2 specification

All on the `releases/v1.2` branch of `slsa-framework/slsa`, accessed 2026-05-14:

- [Build: Requirements for producing artifacts](https://github.com/slsa-framework/slsa/blob/releases/v1.2/spec/build-requirements.md)
  ([rendered](https://slsa.dev/spec/v1.2/build-requirements))
- [Terminology](https://github.com/slsa-framework/slsa/blob/releases/v1.2/spec/terminology.md)
  ([rendered](https://slsa.dev/spec/v1.2/terminology))
- [Threats and mitigations](https://github.com/slsa-framework/slsa/blob/releases/v1.2/spec/threats.md)
  ([rendered](https://slsa.dev/spec/v1.2/threats))
- [Assessing build platforms](https://github.com/slsa-framework/slsa/blob/releases/v1.2/spec/assessing-build-platforms.md)
  ([rendered](https://slsa.dev/spec/v1.2/assessing-build-platforms))
- [Build track basics](https://github.com/slsa-framework/slsa/blob/releases/v1.2/spec/build-track-basics.md)
  ([rendered](https://slsa.dev/spec/v1.2/build-track-basics))

### Upstream SLSA builder / generator references

- [`generator_generic_slsa3.yml`](https://github.com/slsa-framework/slsa-github-generator/blob/main/.github/workflows/generator_generic_slsa3.yml)
  — the generic generator; the generator wrangle invokes to sign provenance.
- [`builder_go_slsa3.yml`](https://github.com/slsa-framework/slsa-github-generator/blob/main/.github/workflows/builder_go_slsa3.yml)
  — ecosystem-specific builder for Go (stable). The `::stop-commands::`
  example lives at line 290.
- [`builder_nodejs_slsa3.yml`](https://github.com/slsa-framework/slsa-github-generator/blob/main/.github/workflows/builder_nodejs_slsa3.yml)
  + [`internal/builders/nodejs/action.yml`](https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/nodejs/action.yml)
  — ecosystem-specific Node.js builder (beta). The `cache: npm` TODO comment
  lives at lines 72–73 of `action.yml`.
- [`generator_container_slsa3.yml`](https://github.com/slsa-framework/slsa-github-generator/blob/main/.github/workflows/generator_container_slsa3.yml)
  — pure attestation generator; does not isolate the docker build.
- [`delegator_lowperms-generic_slsa3.yml`](https://github.com/slsa-framework/slsa-github-generator/blob/main/.github/workflows/delegator_lowperms-generic_slsa3.yml)
  — BYOB framework, source of the `contents: read` build-job pattern
  ecosystem-specific builders inherit.
- [Issue #55: Workflow for Python packages](https://github.com/slsa-framework/slsa-github-generator/issues/55)
  — explains why there is no ecosystem-specific python builder.
- [Node.js README, "Other package managers not supported"](https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/nodejs/README.md)
  — explains why there is no ecosystem-specific pnpm builder.

### uv source verification

All pinned to `astral-sh/uv` commit
[`1e99086`](https://github.com/astral-sh/uv/tree/1e99086e645038804c3f479ef24cc50f4ec74a96)
(2026-05-16):

- [`crates/uv/src/commands/project/sync.rs`](https://github.com/astral-sh/uv/blob/1e99086e645038804c3f479ef24cc50f4ec74a96/crates/uv/src/commands/project/sync.rs)
  — `uv sync` builds `HashStrategy` in `HashCheckingMode::Verify`.
- [`crates/uv-installer/src/preparer.rs`](https://github.com/astral-sh/uv/blob/1e99086e645038804c3f479ef24cc50f4ec74a96/crates/uv-installer/src/preparer.rs)
- [`crates/uv-distribution/src/distribution_database.rs`](https://github.com/astral-sh/uv/blob/1e99086e645038804c3f479ef24cc50f4ec74a96/crates/uv-distribution/src/distribution_database.rs)
  — `get_wheel` / `download_wheel` / `load_wheel`; the `download` closure is
  the only code that hashes wheel bytes.
- [`crates/uv-client/src/cached_client.rs`](https://github.com/astral-sh/uv/blob/1e99086e645038804c3f479ef24cc50f4ec74a96/crates/uv-client/src/cached_client.rs)
  — `get_cacheable`: a fresh-cache hit returns the sidecar `Archive` and never
  invokes the download callback.
- [`crates/uv-distribution-types/src/hash.rs`](https://github.com/astral-sh/uv/blob/1e99086e645038804c3f479ef24cc50f4ec74a96/crates/uv-distribution-types/src/hash.rs)
  — `matches` (value comparison) vs `has_required_algorithms` (algorithm-only).
- [`crates/uv-cache/src/lib.rs`](https://github.com/astral-sh/uv/blob/1e99086e645038804c3f479ef24cc50f4ec74a96/crates/uv-cache/src/lib.rs)
  + [`crates/uv-cache/src/archive.rs`](https://github.com/astral-sh/uv/blob/1e99086e645038804c3f479ef24cc50f4ec74a96/crates/uv-cache/src/archive.rs)
  — `persist`'s `TODO(charlie): Support content-addressed persistence via
  SHAs`; `ArchiveId` is a random `uv_fastid::Id::insecure()`.
- [`crates/uv-install-wheel/src/linker.rs`](https://github.com/astral-sh/uv/blob/1e99086e645038804c3f479ef24cc50f4ec74a96/crates/uv-install-wheel/src/linker.rs)
  — `link_wheel_files` links/copies the unzipped wheel with no hashing.
- [`crates/uv-distribution/src/index/built_wheel_index.rs`](https://github.com/astral-sh/uv/blob/1e99086e645038804c3f479ef24cc50f4ec74a96/crates/uv-distribution/src/index/built_wheel_index.rs)
- uv's [`SECURITY.md`](https://github.com/astral-sh/uv/blob/main/SECURITY.md)
  and [cache documentation](https://docs.astral.sh/uv/concepts/cache/) — no
  treatment of the cache as a security boundary.

### BuildKit / containerd source verification

- [`cache/remotecache/gha/gha.go`](https://github.com/moby/buildkit/blob/master/cache/remotecache/gha/gha.go)
  — GHA cache exporter/importer.
- [`cache/remotecache/import.go`](https://github.com/moby/buildkit/blob/master/cache/remotecache/import.go)
  — `readBlob` and its conditional digest check.
- [`cache/manager.go`](https://github.com/moby/buildkit/blob/master/cache/manager.go)
  — `cacheManager.GetByBlob`.
- [`worker/base/worker.go`](https://github.com/moby/buildkit/blob/master/worker/base/worker.go)
  — `FromRemote`.
- [`content/helpers.go`](https://github.com/containerd/containerd/blob/release/1.7/content/helpers.go)
  in `containerd/containerd` — `ReadBlob`, `Copy`.
- [`content/local/writer.go`](https://github.com/containerd/containerd/blob/v1.7.27/content/local/writer.go)
  — `Writer.Commit`'s ingest-time digest check.

### GHA cache poisoning research

- [GitHub: caching dependencies docs](https://docs.github.com/en/actions/using-workflows/caching-dependencies-to-speed-up-workflows)
  (cache scope rules).
- Adnan Khan, [The Monsters in Your Build Cache](https://adnanthekhan.com/2024/05/06/the-monsters-in-your-build-cache-github-actions-cache-poisoning/),
  2024-05-06.
- Adnan Khan, [Cacheract: the monster in your build cache](https://adnanthekhan.com/2024/12/21/cacheract-the-monster-in-your-build-cache/),
  2024-12-21.
- Adnan Khan, [Angular compromise through dev-infra](https://adnanthekhan.com/posts/angular-compromise-through-dev-infra/).
- SafeDep, [TanStack GitHub Actions cache poisoning](https://safedep.io/tanstack-github-actions-cache-poisoning/).
- CodeQL: [`actions/actions-cache-poisoning-direct-cache`](https://codeql.github.com/codeql-query-help/actions/actions-cache-poisoning-direct-cache/),
  [`actions/actions-cache-poisoning-code-injection`](https://codeql.github.com/codeql-query-help/actions/actions-cache-poisoning-code-injection/).

### Wrangle internal references

- [#205](https://github.com/TomHennen/wrangle/issues/205) — pnpm-store cache
  poisoning (the precipitating finding).
- [#212](https://github.com/TomHennen/wrangle/pull/212) — pnpm cache disabled.
- [#216](https://github.com/TomHennen/wrangle/issues/216) — this audit.
- [`build/actions/npm/SPEC.md`](../build/actions/npm/SPEC.md) —
  generic-generator reasoning for npm.
- [`build/actions/python/SPEC.md`](../build/actions/python/SPEC.md) —
  generic-generator reasoning for python.
- [`build/actions/container/SPEC.md`](../build/actions/container/SPEC.md) —
  container build documentation.
