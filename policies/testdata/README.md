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

| Bundle | Contents | Expected against the logic variant¹ |
|--------|----------|------------------------------------------|
| `good.bundle.jsonl` | SLSA v0.2 provenance (slsa-github-generator generic, builder/buildType/materials as wrangle emits) + SPDX SBOM + clean OSV results | default-v1 **PASS** |
| `bad-missing-sbom.bundle.jsonl` | provenance + clean OSV (no SBOM) | default-v1 **FAIL** (sbom-exists) |
| `bad-osv-vuln.bundle.jsonl` | provenance + SBOM + OSV results with a vulnerability | default-v1 **FAIL** (openvex) |
| `bad-wrong-builder.bundle.jsonl` | provenance with an attacker builder id + SBOM + clean OSV | default-v1 **FAIL** (slsa-builder-id) |
| `bad-wrong-buildtype.bundle.jsonl` | provenance with a non-generic buildType + SBOM + clean OSV | default-v1 **FAIL** (slsa-build-type) |
| `bad-wrong-buildpoint.bundle.jsonl` | provenance whose source repo ≠ the buildPoint context + SBOM + clean OSV | default-v1 **FAIL** (slsa-build-point) |
| `good-container.bundle.jsonl` | SLSA v0.2 provenance from the container generator (builder `generator_container_slsa3.yml`, buildType `…/container@v1`) | provenance-container-v1 **PASS** |
| `good-strict.bundle.jsonl` | `good.bundle` + OpenSSF Scorecard result (score 8.2) | strict-v1 **PASS** |
| `bad-low-scorecard.bundle.jsonl` | `good.bundle` + Scorecard result (score 5.0) | strict-v1 **FAIL** (wrangle-scorecard-min-score) |

¹ The shipped `default-v1`/`strict-v1` PolicySets bind their SLSA provenance
tenets to the `slsa-github-generator` signer identity (`common.identities`).
These fixtures are **unsigned**, so against the *production* PolicySets they
fail closed on identity validation. `policies/test.bats` therefore evaluates
the tenet-logic rows above against a logic-only *variant* (identity gate
stripped), and a separate test runs `good.bundle.jsonl` against the production
`default-v1` to prove it fails closed. See the `test.bats` file header.

The provenance fields are shaped to match what wrangle's publish workflow emits
via `slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml`
(buildType `https://github.com/slsa-framework/slsa-github-generator/generic@v1`),
so the policy context bindings are exercised against a realistic release.
Regenerate by editing the statements directly — they are plain JSON; keep the
subject digest in sync with `SUBJECT` in `policies/test.bats`.
