# policies/testdata

Fixture attestation bundles for `policies/test.bats` — the drift detector for
the wrangle Ampel PolicySets (`docs/ampel_research.md` §5). Each `*.jsonl` file
is a bundle of unsigned in-toto Statements (one per line) that `ampel verify`
reads via the offline `jsonl:` collector, so the harness needs no signing or
sigstore reachability (it still needs `github.com` to resolve the SHA-pinned
upstream policy locators).

All bundles describe the same subject artifact, `wrangle-app-1.0.0.tgz`, whose
digest is the literal string's sha256:

    printf 'wrangle-app-1.0.0.tgz' | sha256sum
    # 2b27ffb5258939a2700ecf4667a040192e717bfee6446dcad995563fed8a9c0a

`policies/test.bats` hardcodes that digest as `SUBJECT`.

## Two provenance shapes

The fixtures come in two families, matching the two PolicySet families:

- **v1 attest-build-provenance** (`good-{npm,go,python,container}.bundle.jsonl`)
  — what wrangle emits today: `predicateType https://slsa.dev/provenance/v1`,
  `buildType https://actions.github.io/buildtypes/workflow/v1`, and a per-build-
  type `builder.id` of `…/build_and_publish_<eco>.yml`. These back the
  per-ecosystem `wrangle-provenance-{npm,go,python,container}-v1` PolicySets.
- **v0.2 slsa-github-generator** (`good.bundle.jsonl`, `good-strict`, `bad-*`)
  — the legacy generic-generator shape. These still back `wrangle-default-v1` /
  `wrangle-strict-v1`, which are generic and not yet migrated off the generator
  identity (deferred — #328).

The **default/strict tier** fixtures (`good-default`, `good-strict-default`,
`bad-{osv,zizmor,wrangle-lint}-{findings,absent}`, `bad-default-*`) are
production-shape: v1 attest-build-provenance (go builder) + SPDX SBOM + one
wrangle `scan/v1` envelope per tool (`osv-scanner`, `zizmor`, `wrangle-lint`),
plus an OpenSSF Scorecard result for the strict rows. They back the per-eco
`wrangle-default-go-v1` / `wrangle-strict-go-v1` (the go sibling stands in for
all four ecos — the scan/SBOM/scorecard tenets are identical across them).

| Bundle | Contents | Expected against the logic variant¹ |
|--------|----------|------------------------------------------|
| `good-npm.bundle.jsonl` | v1 attest-build-provenance, builder `build_and_publish_npm.yml` | provenance-npm-v1 **PASS** |
| `good-go.bundle.jsonl` | v1 attest-build-provenance, builder `build_and_publish_go.yml` | provenance-go-v1 **PASS** |
| `good-python.bundle.jsonl` | v1 attest-build-provenance, builder `build_and_publish_python.yml` | provenance-python-v1 **PASS** |
| `good-container.bundle.jsonl` | v1 attest-build-provenance, builder `build_and_publish_container.yml` | provenance-container-v1 **PASS** |
| `good.bundle.jsonl` | v0.2 generic-generator provenance + SPDX SBOM + clean OSV | default-v1 **PASS** |
| `bad-missing-sbom.bundle.jsonl` | provenance + clean OSV (no SBOM) | default-v1 **FAIL** (sbom-exists) |
| `bad-osv-vuln.bundle.jsonl` | provenance + SBOM + OSV results with a vulnerability | default-v1 **FAIL** (openvex) |
| `bad-wrong-builder.bundle.jsonl` | provenance with an attacker builder id + SBOM + clean OSV | default-v1 / provenance-npm-v1 **FAIL** (slsa-builder-id) |
| `bad-wrong-buildtype.bundle.jsonl` | provenance with a non-generic buildType + SBOM + clean OSV | default-v1 **FAIL** (slsa-build-type) |
| `bad-wrong-buildpoint.bundle.jsonl` | provenance whose source repo ≠ the buildPoint context + SBOM + clean OSV | default-v1 **FAIL** (slsa-build-point) |
| `good-strict.bundle.jsonl` | `good.bundle` + OpenSSF Scorecard result (score 8.2) | strict-v1 **PASS** |
| `bad-low-scorecard.bundle.jsonl` | `good.bundle` + Scorecard result (score 5.0) | strict-v1 **FAIL** (wrangle-scorecard-min-score) |
| `good-default.bundle.jsonl` | v1 go provenance + SBOM + clean osv/zizmor/wrangle-lint `scan/v1` | default-go-v1 **PASS** |
| `bad-osv-findings.bundle.jsonl` | as `good-default` but the osv-scanner scan reports `findings` | default-go-v1 **FAIL** (osv-scan-clean) |
| `bad-osv-absent.bundle.jsonl` | as `good-default` but no osv-scanner `scan/v1` (size>0 fails closed) | default-go-v1 **FAIL** (osv-scan-clean) |
| `bad-zizmor-findings.bundle.jsonl` | as `good-default` but the zizmor scan reports `findings` | default-go-v1 **FAIL** (zizmor-scan-clean) |
| `bad-zizmor-absent.bundle.jsonl` | as `good-default` but no zizmor `scan/v1` | default-go-v1 **FAIL** (zizmor-scan-clean) |
| `bad-wrangle-lint-findings.bundle.jsonl` | as `good-default` but the wrangle-lint scan reports `findings` | default-go-v1 **FAIL** (wrangle-lint-scan-clean) |
| `bad-wrangle-lint-absent.bundle.jsonl` | as `good-default` but no wrangle-lint `scan/v1` | default-go-v1 **FAIL** (wrangle-lint-scan-clean) |
| `bad-default-missing-sbom.bundle.jsonl` | as `good-default` but no SBOM | default-go-v1 **FAIL** (sbom-exists) |
| `good-strict-default.bundle.jsonl` | `good-default` + OpenSSF Scorecard result (score 8.2) | strict-go-v1 **PASS** |
| `bad-default-low-scorecard.bundle.jsonl` | `good-default` + Scorecard result (score 5.0) | strict-go-v1 **FAIL** (wrangle-scorecard-min-score) |
| `bad-default-scorecard-absent.bundle.jsonl` | `good-default` with no Scorecard result (size>0 fails closed) | strict-go-v1 **FAIL** (wrangle-scorecard-min-score) |

## Signed bundle

`good-default-signed.bundle.jsonl` is the one **signed** fixture: a real
Rekor-proofed release bundle from the public `TomHennen/wrangle-test` repo
(provenance + VSA + SPDX SBOM + one zizmor `scan/v1`, no secrets). The unsigned
fixtures above can only run against the logic variant, so the signer-identity
admission is never exercised against a real signature; this bundle runs the
FULL production `wrangle-default-python-v1` tier and proves its scan tenet's
identity validates. It carries its own subject (`sha256:b757…` of the wheel)
and per-release context — both hardcoded in `test.bats` — and only the zizmor
scan, so osv/wrangle-lint fail on MISSING-scan (a different failure than
identity). Re-fetch via `gh run download 27902476403 --repo
TomHennen/wrangle-test -n python-metadata-python` and take the
`.whl.intoto.jsonl`.

The per-eco PASS rows double as **cross-ecosystem isolation** checks: a sibling
fixture is the "wrong builder" for another type's policy (e.g. `good-go` FAILs
`provenance-npm-v1`'s `slsa-builder-id`, and `good-npm` FAILs
`provenance-container-v1`), proving each baked `builder.id` is load-bearing.

¹ Each shipped PolicySet binds its SLSA provenance tenets to a signer identity
(`common.identities`): the `wrangle-provenance-*-v1` policies to wrangle's
`build_and_publish_<eco>.yml` keyless identity, and `default-v1` / `strict-v1`
to the legacy `slsa-github-generator` identity. These fixtures are **unsigned**,
so against the *production* PolicySets they fail closed on identity validation.
`policies/test.bats` therefore evaluates the tenet-logic rows above against a
logic-only *variant* (identity gate stripped), and separate tests run each good
fixture against its production PolicySet to prove it fails closed. See the
`test.bats` file header.

Regenerate by editing the statements directly — they are plain JSON; keep the
subject digest in sync with `SUBJECT` in `policies/test.bats`. The v1 fixtures
mirror what `actions/attest-build-provenance` emits (`predicate.buildDefinition
.buildType` + `predicate.runDetails.builder.id`); the v0.2 fixtures mirror the
generic generator's `predicate.builder` / `buildType` / `materials` shape.
