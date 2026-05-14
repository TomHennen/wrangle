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

## Contents

1. [Why this audit exists](#why-this-audit-exists)
2. [The central framing: L3-for-signing vs L3-for-build-platform](#the-central-framing-l3-for-signing-vs-l3-for-build-platform)
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
8. [Pattern A vs Pattern B revisit](#pattern-a-vs-pattern-b-revisit)
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

## The central framing: L3-for-signing vs L3-for-build-platform

SLSA v1.2 Build L3 has two halves and adopters routinely conflate them.

**L3-for-signing** is the property of the workflow that emits the signed
attestation. SLSA v1.2 calls this *"Provenance is Unforgeable"*
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

**L3-for-build-platform** is the property of the environment that produced the
bytes being signed. SLSA v1.2 calls this *"Isolated"* (same page, "Isolation
strength" → "Isolated"):

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

When wrangle's docs say "SLSA L3 provenance," they correctly describe the
*signing-side* property. They do **not**, by themselves, claim L3-for-build-platform
conformance. A reader who skims and conflates the two is misled — hence the
adopter-facing framing tweak in [`docs/SPEC.md`](./SPEC.md#slsa-l3-claims-what-wrangle-asserts).

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
(b) verifying at use, or (c) accepting that the build is not L3 for-build-platform
even when the provenance is L3-for-signing.

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

**Conditional caveat:** this verdict is contingent on the reusable-workflow
consumption path. An adopter who calls `build/actions/python@<sha>` directly
from a job that also has `id-token: write` voluntarily forfeits the
separation. The audit recommends documenting this in the build-type READMEs
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
consumption surface produces a different L3-for-build-platform answer. This is
the load-bearing distinction Tom flagged in
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

This separation is the same property the SLSA upstream's BYOB framework
(`delegator_lowperms-generic_slsa3.yml`) enforces for ecosystem-specific Pattern A
builders: the build job has minimal permissions, the signing job runs separately
with `id-token: write`, neither can directly tamper with the other. When an
adopter consumes wrangle via a reusable workflow, they inherit this separation
for free. The signing-key reach into the build environment is **closed** by
construction.

What the reusable workflow does **not** isolate is the cache surfaces of the
underlying setup-* actions and build tools. Those run inside the build job's
runner image and inherit whatever cache surfaces wrangle wires up. The
per-builder audit below treats each of those.

### Composite actions invoked directly (the unsupervised path)

Adopters can also call `tomhennen/wrangle/build/actions/<type>@<ref>` directly
from a workflow they write themselves. In that case, the permissions, the
ordering relative to other steps, and the `id-token: write` reach are
**adopter-managed**. The build runs in whatever job the adopter put it in. If
that job has `id-token: write` and the build also has shell execution access
to the runner, the signing-key separation that the reusable workflow provided
is gone.

The audit treats the reusable workflow as the supported L3 consumption path.
The composite-only path remains supported for non-L3 use cases (e.g.,
local-only builds, custom workflow orchestration), but the L3-for-build-platform
conformance verdicts below assume the reusable-workflow path. See
[Findings](#findings-and-recommendations) for the adopter-facing doc work this implies.

## Per-builder audit

Each builder is audited against the SLSA v1.2 "Isolated" requirement and
the three cache-assessment prompts. Verdicts:

- **MEETS** — no L3-for-build-platform gap.
- **MEETS WITH PRECONDITION** — meets so long as a stated condition holds (e.g.,
  "if `npm ci` is the install command"); the precondition is enforced.
- **GAP** — does not currently meet L3-for-build-platform; recommendation below.
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

There is **no upstream Pattern A pnpm builder** in `slsa-framework/slsa-github-generator`
to compare against ([builder README explicitly states pnpm "not supported"](https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/nodejs/README.md)).
For pnpm specifically, wrangle's Pattern B composite is the only available
SLSA-tooled path on GitHub Actions today.

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
consumed by pip in the same job; it is per-run, not cross-run. This is
acceptable for L3-for-build-platform because the cache is ephemeral with the
runner.

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
against `astral-sh/uv` `main` HEAD. The relevant call chain:

1. `uv_installer::Preparer` calls `database.get_or_build_wheel(&dist, tags, policy)`
   then checks `wheel.satisfies(policy)`, where `policy` carries the lockfile
   hash. ([`crates/uv-installer/src/preparer.rs`](https://github.com/astral-sh/uv/blob/main/crates/uv-installer/src/preparer.rs).)
2. `wheel.hashes()` returns whatever the `Archive` recorded — and on the
   cache-hit path, `Archive` is deserialized from the `.http` or `.rev`
   sidecar pointer via `rmp_serde::from_slice`, with no recomputation from
   the on-disk wheel bytes. The smoking-gun line is the `hashes:
   archive.hashes` assignment in `load_wheel`'s cache-hit branch
   ([`crates/uv-distribution/src/distribution_database.rs`](https://github.com/astral-sh/uv/blob/main/crates/uv-distribution/src/distribution_database.rs)).
3. The cache-hit filter is `archive.has_digests(hashes)`
   ([`crates/uv-distribution-types/src/hash.rs`](https://github.com/astral-sh/uv/blob/main/crates/uv-distribution-types/src/hash.rs)),
   which only checks that the *algorithm name* matches (e.g., "sha256");
   it does **not** compare digest values.

This is structurally the same shape as the pnpm-store cache-poisoning vector
that #205 closed. If an attacker can write to `$UV_CACHE_DIR` between a prior
build and a subsequent install, the subsequent install runs with the
attacker's payload and trusts the attacker's pre-stored hash.

The same SLSA v1.2 threat (`threats.md`, "Poison the build cache") applies.
There is no published CVE against uv for this — Astral's design philosophy
treats the cache as trusted by its containing user account — but for SLSA L3
purposes that design choice is the gap.

**No upstream Pattern A python builder exists**
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
2. **Force refresh on every install.** Run `uv sync --refresh` (or use
   `--refresh-package` for specific packages). Same network cost as option 1
   but more granular if partial caching is desirable.
3. **Pin the cache to a fresh ephemeral location.** Set
   `UV_CACHE_DIR=$RUNNER_TEMP/uv-cache` so the cache cannot survive across
   builds. Cheap to add; relies on `$RUNNER_TEMP` being ephemeral, which is
   GitHub's documented behavior on GitHub-hosted runners.
4. **(Future)** Upstream-petition uv to add a `--verify-hashes-on-cache-hit`
   flag that re-hashes cached files at install time. The behavior is
   structurally cheap (hash the bytes already on disk) and would close the
   gap for every uv user.

**Verdict: GAP.** Recommendation: option (3) as a default for the release path
inside the reusable workflow, with option (1) documented as the adopter-side
opt-out for very high-assurance contexts.

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
reachable from contexts wrangle does not control (PR builds, feature branches,
and — if wrangle ever ships a `pull_request_target` workflow — also that).

**Comparison to upstream.** `slsa-github-generator`'s
[`generator_container_slsa3.yml`](https://github.com/slsa-framework/slsa-github-generator/blob/main/.github/workflows/generator_container_slsa3.yml)
takes a pre-built `(image, digest)` and runs `cosign attest`. **It does not
build the image** and does not opine on the caller's docker build cache
configuration — the upstream README explicitly tells callers to run
`docker/build-push-action` themselves in the caller's job (so caching, or not,
is the caller's choice). There is no Pattern A enforcement to compare against.

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

**1. No direct `actions/cache` calls anywhere in the repository.** Verified by
repo-wide grep at audit time. All caching is mediated through `setup-*`
actions' built-in cache integrations or `docker/build-push-action`'s
`cache-from`/`cache-to`.

**2. No persistent state outside `$RUNNER_TEMP` and the workspace.** No
composite writes to `~/.local` or other home-directory locations explicitly.
The implicit caches managed by `setup-node`, `setup-python`, `setup-uv`, and
BuildKit are the only persistent surfaces, and each is audited above.

**3. `persist-credentials: false` is set on every `actions/checkout` in the
build composites:** [`build/actions/container/action.yml:54`](../build/actions/container/action.yml)
and the reusable workflows that wrap the npm and python composites
([`build_and_publish_python.yml:127`](../.github/workflows/build_and_publish_python.yml)
and parallels). This matches Pattern A enforcement.

**4. Self-hosted runner caveat.** GitHub-hosted runners are ephemeral; SLSA's
"ephemeral build environment" requirement is satisfied by the runner image
being fresh per job. If an adopter consumes wrangle on a **self-hosted**
runner, that assumption no longer holds: `~/.cache/*`, `~/.npm`,
`~/.pnpm-store`, `~/.cache/uv`, and `/var/lib/docker/` may persist across
jobs in attacker-influenced ways. This audit treats GitHub-hosted runners as
the supported substrate. Adopters using self-hosted runners take on additional
build-platform-side responsibility; the adopter-facing doc should call this
out explicitly.

**5. The reusable-workflow consumption path already separates build from
sign.** This is the single biggest reason wrangle's framing is closer to
Pattern A than it might first appear. The build job has `contents: read`; the
provenance job runs `generator_generic_slsa3.yml` (itself an isolated
reusable workflow) with `id-token: write`. The signing key is unreachable from
the build job. Adopters who bypass the reusable workflow and call the
composite directly forfeit this separation; the audit recommends explicitly
documenting this.

## Pattern A vs Pattern B revisit

Wrangle deliberately picked Pattern B (generic generator + per-ecosystem
composites running in the caller's workflow) over Pattern A (ecosystem-specific
generators running the build inside an isolated reusable workflow). The
reasoning is recorded in
[`build/actions/npm/SPEC.md`](../build/actions/npm/SPEC.md) (lines 84–88) and
parallels: the Pattern A Node.js builder is beta as of February 2025, npm-only,
workspaces-unsupported, no `pull_request` trigger.

This audit doesn't dispute that historical choice. It does ask whether the
choice still trades cleanly against L3 isolation. Three concrete things
Pattern A enforces that Pattern B does not:

**1. Job-level permission separation.** Pattern A (via BYOB's
`delegator_lowperms-generic_slsa3.yml`) restricts the build job to
`contents: read` only; the signing job runs separately. Wrangle's reusable
workflows already do this — see [adopter consumption model](#adopter-consumption-model-what-isolation-comes-for-free).
**No gap when wrangle is consumed via reusable workflow.**

**2. Cache disablement at the setup-* step.** Pattern A's Node.js builder has
an explicit comment in `internal/builders/nodejs/action.yml` lines 72–73:
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

**3. `::stop-commands::` guard around the compile step.** Pattern A's Go
builder wraps the compile in `echo "::stop-commands::$(echo -n "${GITHUB_TOKEN}" | sha256sum | head -c 64)"`
so workflow-command injection via build-tool stdout is neutralized. Wrangle
does not. This is defense-in-depth, not an isolation property, and could be
added cheaply.

Things Pattern A is sometimes claimed to enforce but **does not**:

- Containerization or read-only source mount — neither Pattern A's Go builder
  nor BYOB does this; both run on `ubuntu-latest`.
- Network restriction / hermeticity — explicitly marked TODO in
  `builder_go_slsa3.yml` (line 273: *"TODO(hermeticity) OS-level"*).
- Forbidding `cache-from`/`cache-to` on the container build — the container
  generator never even sees the docker build (the caller runs it).

**Pattern A coverage gaps in the wrangle space:** no Pattern A pnpm builder
exists. No Pattern A python builder exists (open since the project's early
days as `slsa-framework/slsa-github-generator#55`). For these two ecosystems,
wrangle's Pattern B is the only SLSA-tooled path on GitHub Actions today —
"switch to Pattern A" is not an available option.

**Per-builder decision:**

| Builder | Pattern A option exists | Audit recommendation |
|---|---|---|
| npm | Beta Node.js builder (no pnpm support, no `pull_request`) | Stay Pattern B; npm sub-path is L3-clean. Continue tracking the Node.js builder for GA. |
| pnpm | None | Stay Pattern B; only option. Already L3-clean via cache disablement. |
| python (pip) | None | Stay Pattern B; only option. Currently L3-clean for isolation. |
| python (uv) | None | Stay Pattern B; only option. Fix the uv-cache gap (see findings below). |
| container | Container generator is signing-only (does not isolate the build) | Stay Pattern B; Pattern A would not solve the cache problem because Pattern A doesn't isolate the build either. Fix the GHA cache gap (see findings below). |
| shell | n/a | Stay; no provenance produced. |

**Conclusion: Pattern B remains the right choice across the board for v0.2.**
The conformance gaps are L3-for-build-platform issues internal to wrangle's
composites, not architectural problems with Pattern B as a whole.

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

**Python uv path.** Same plumbing, different lever — set
`UV_CACHE_DIR=$RUNNER_TEMP/uv-cache` for release builds (ephemeral cache,
disappears with the runner) and leave the default in place for PR builds:

```yaml
- name: Install uv
  if: steps.tooling.outputs.use_uv == 'true'
  uses: astral-sh/setup-uv@<sha>
  with:
    enable-cache: ${{ inputs.cache != 'disabled' }}
```

Or simpler: always set `UV_CACHE_DIR=$RUNNER_TEMP/uv-cache` in the build job's
env on release. Either closes the [Finding 1](#finding-1-uv-cache-integrity-gap-on-the-python-uv-sub-path)
gap.

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

**Does not close:** The Pattern A "build job has stripped permissions"
property. Wrangle's reusable workflow already restricts the build job to
`contents: read`, so the gap is already closed there for the
reusable-workflow consumption path. Adopters who invoke the composite
directly from a job with broader permissions remain on the unsupervised
path. Documenting this is a separate (doc-only) recommendation.

### Should wrangle care about PR-to-PR cache poisoning?

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

This audit produces two GAP findings and one defense-in-depth recommendation.
Each is documentation; concrete remediation lands in separate issues/PRs per
the contract of #216.

### Finding 1: uv cache integrity gap on the python uv sub-path

**Summary.** `astral-sh/setup-uv@v8.1.0` is invoked at
[`build/actions/python/action.yml:69–71`](../build/actions/python/action.yml)
without `enable-cache: false`, so the uv cache is enabled by default on
GitHub-hosted runners. uv's cache-hit code path trusts a pre-stored hash from a
sidecar pointer file instead of re-hashing the cached file on disk, structurally
matching the pnpm-store gap that #205 / #212 closed.

**Severity.** Equivalent to #205 for the uv consumption path: a coherent
(cache index, payload) pair injected into `~/.cache/uv` between builds yields
attested-as-clean poisoned bytes. Requires write access to the cache
directory between builds; on GitHub-hosted runners this requires a prior run's
malicious step.

**Recommendation (preferred): release-vs-PR cache asymmetry.** See
[Release-vs-PR build asymmetry](#release-vs-pr-build-asymmetry-a-structural-remediation-pattern).
Disable the uv cache only when `gate.outputs.should-release == 'true'`; keep
the default behavior for PR builds. Composes with wrangle's existing release
vocabulary and closes the gap without slowing PR iteration.

**Recommendation (fallback, if release-gate plumbing is deferred).** Pin
`UV_CACHE_DIR=$RUNNER_TEMP/uv-cache` unconditionally so the cache is ephemeral
per job (cheap, no network cost). Cheaper to implement; slower PR builds.
Spawn a follow-up issue tracking whichever path is chosen.

### Finding 2: BuildKit GHA cache integrity gap on the container path

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

### Finding 3 (defense in depth): `::stop-commands::` guard around build/test invocations

**Summary.** Pattern A's Go builder shadows the `::` workflow-command prefix
with a per-run token before invoking the compile, neutralizing any attempt by
the build tool (or a dependency's lifecycle hook) to inject workflow commands
via stdout. Wrangle does not.

**Severity.** Defense-in-depth, not an L3-for-build-platform requirement.
Useful given wrangle's threat model includes "lifecycle hook in a transitive
dev-dep" (`ignore-scripts` input exists for similar reasons).

**Recommendation.** Add a `::stop-commands::` wrap around `build_and_pack.sh`,
`run_tests.sh`, and `install_deps.sh` invocations in the composites. Cheap;
optional; nice-to-have. Spawn an issue if and when adopted.

### Adopter-facing framing

In addition to these three findings, the audit recommends:

- A short framing section in [`docs/SPEC.md`](./SPEC.md#slsa-l3-claims-what-wrangle-asserts)
  distinguishing **L3-for-signing** from **L3-for-build-platform**, with a
  pointer to this audit.
- An explicit note in build-type READMEs that the L3 guarantee is contingent
  on consuming wrangle via the reusable workflow rather than calling the
  composite directly. This audit does not produce that change; spawn a
  doc-only issue.
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

### Upstream Pattern A references

- [`generator_generic_slsa3.yml`](https://github.com/slsa-framework/slsa-github-generator/blob/main/.github/workflows/generator_generic_slsa3.yml)
  — wrangle's signing-side generator.
- [`builder_go_slsa3.yml`](https://github.com/slsa-framework/slsa-github-generator/blob/main/.github/workflows/builder_go_slsa3.yml)
  — Pattern A reference for Go (stable). The `::stop-commands::` example
  lives at line 290.
- [`builder_nodejs_slsa3.yml`](https://github.com/slsa-framework/slsa-github-generator/blob/main/.github/workflows/builder_nodejs_slsa3.yml)
  + [`internal/builders/nodejs/action.yml`](https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/nodejs/action.yml)
  — Pattern A Node.js builder (beta). The `cache: npm` TODO comment lives
  at lines 72–73 of `action.yml`.
- [`generator_container_slsa3.yml`](https://github.com/slsa-framework/slsa-github-generator/blob/main/.github/workflows/generator_container_slsa3.yml)
  — pure attestation generator; does not isolate the docker build.
- [`delegator_lowperms-generic_slsa3.yml`](https://github.com/slsa-framework/slsa-github-generator/blob/main/.github/workflows/delegator_lowperms-generic_slsa3.yml)
  — BYOB framework, source of the `contents: read` build-job pattern.
- [Issue #55: Workflow for Python packages](https://github.com/slsa-framework/slsa-github-generator/issues/55)
  — explains why there is no Pattern A python builder.
- [Node.js README, "Other package managers not supported"](https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/nodejs/README.md)
  — explains why there is no Pattern A pnpm builder.

### uv source verification

All on `astral-sh/uv` `main` HEAD at audit time:

- [`crates/uv-installer/src/preparer.rs`](https://github.com/astral-sh/uv/blob/main/crates/uv-installer/src/preparer.rs)
- [`crates/uv-distribution/src/distribution_database.rs`](https://github.com/astral-sh/uv/blob/main/crates/uv-distribution/src/distribution_database.rs)
- [`crates/uv-distribution-types/src/hash.rs`](https://github.com/astral-sh/uv/blob/main/crates/uv-distribution-types/src/hash.rs)
- [`crates/uv-distribution/src/index/built_wheel_index.rs`](https://github.com/astral-sh/uv/blob/main/crates/uv-distribution/src/index/built_wheel_index.rs)

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
- [`build/actions/npm/SPEC.md`](../build/actions/npm/SPEC.md) — Pattern B
  reasoning for npm.
- [`build/actions/python/SPEC.md`](../build/actions/python/SPEC.md) — Pattern
  B reasoning for python.
- [`build/actions/container/SPEC.md`](../build/actions/container/SPEC.md) —
  container build documentation.
