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

All fixtures are **v1 attest-build-provenance** — what wrangle emits today:
`predicateType https://slsa.dev/provenance/v1`, `buildType
https://actions.github.io/buildtypes/workflow/v1`, and a per-build-type
`builder.id` of `…/build_and_publish_<eco>.yml`. The
`good-{npm,go,python,container}.bundle.jsonl` provenance-only fixtures back the
per-ecosystem `wrangle-provenance-{npm,go,python,container}-v1` PolicySets.

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
| `bad-wrong-builder.bundle.jsonl` | provenance with an attacker builder id | provenance-npm-v1 **FAIL** (slsa-builder-id) |
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
Rekor-proofed release bundle from the public `TomHennen/wrangle-test` repo, no
secrets. It is the **complete default tier** — six statements: SLSA
`provenance/v1`, a `verification_summary/v1` VSA, an SPDX SBOM, and a clean
`scan/v1` for each of `osv-scanner`, `zizmor`, and `wrangle-lint` — each
carrying a `tlogEntries` (Rekor) proof. The unsigned fixtures above can only run
against the logic variant, so the signer-identity admission is never exercised
against a real signature; this bundle runs the FULL production
`wrangle-default-python-v1` tier and PASSES cleanly (every tenet PASS), proving
each tenet's signer identity validates end to end. Its subject is digested at
test time from the checked-in wheel
(`wrangle_test_fixture-0.0.1.dev27905469742-py3-none-any.whl`), as
`actions/verify` does, so the test proves the bundle is about that artifact; the
per-release context stays hardcoded in `test.bats`. Re-fetch the bundle as the
`*.whl.intoto.jsonl` release asset of the showcase tracking tag (e.g. `gh
release download v20260621-ec5399a --repo TomHennen/wrangle-test -p
'*whl.intoto.jsonl'`) and the wheel via `gh run download 27905469742 --repo
TomHennen/wrangle-test -n python-dist-python`.

The per-eco PASS rows double as **cross-ecosystem isolation** checks: a sibling
fixture is the "wrong builder" for another type's policy (e.g. `good-go` FAILs
`provenance-npm-v1`'s `slsa-builder-id`, and `good-npm` FAILs
`provenance-container-v1`), proving each baked `builder.id` is load-bearing.

¹ Each shipped PolicySet binds its SLSA provenance tenets to a signer identity
(`common.identities`): every policy to wrangle's `build_and_publish_<eco>.yml`
keyless identity. These fixtures are **unsigned**,
so against the *production* PolicySets they fail closed on identity validation.
`policies/test.bats` therefore evaluates the tenet-logic rows above against a
logic-only *variant* (identity gate stripped), and separate tests run each good
fixture against its production PolicySet to prove it fails closed. See the
`test.bats` file header.

Regenerate by editing the statements directly — they are plain JSON; keep the
subject digest in sync with `SUBJECT` in `policies/test.bats`. The fixtures
mirror what `actions/attest-build-provenance` emits (`predicate.buildDefinition
.buildType` + `predicate.runDetails.builder.id`).
