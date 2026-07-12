# wrangle-attest — shared attestation engine

`wrangle-attest` turns the inert result files scan/build tools leave behind into
in-toto v1 Statements and, with `--sign`, keyless-signs each into a Sigstore
bundle. It runs in the `attest` job, the trusted post-build context that signs
every build-metadata attestation (SBOM + scan/v1) over the already-built
dist/image; `actions/verify` then evaluates the policy and signs only the VSA.
It is the single producer-side engine: adding the Nth attestation type is a new
manifest + (for a novel predicate shape) a new case here, never new signing code.

The trust boundary is load-bearing: the `attest` job runs no adopter-controlled
code — only `attest-build-provenance` and `wrangle-attest` over the artifact the
`build` job already produced, never an adopter build or test hook — so a
build-metadata attestation can only ever describe what wrangle itself observed.

## Tools declare, the engine decides

A producer writes a `wrangle_attestation_metadata.json` next to its native result file. The manifest
is the only tool↔engine contract:

```jsonc
{
  "predicate-type": "<URI>",           // required; implies the result-file format
  "result-file":    "<relative-path>", // required; relative to the manifest's own dir
  "tool":   { "name": "<str>", "version": "<str>" },  // .../wrangle/attestation/scan/v1 only
  "result": "clean" | "findings"                       // .../wrangle/attestation/scan/v1 only
}
```

There is **no `format`** field (the predicate-type implies it) and tools **never
set subjects** — the engine owns the subject (see Engine-owned subject). A malformed manifest, an unknown
predicate-type, a missing/absolute/`..` result-file, or an unknown field fails
the whole run closed; scan output is untrusted input.

## Predicate-type → handling

| predicate-type | result-file | handling |
|---|---|---|
| `https://spdx.dev/Document` | `sbom.spdx.json` | passthrough (SPDX is the predicate) |
| `https://ossf.github.io/osv-schema/results` | OSV JSON | passthrough |
| `https://scorecard.dev/result/v0.1` | scorecard JSON | passthrough |
| `https://github.com/TomHennen/wrangle/attestation/scan/v1` | `output.sarif` | thin envelope `{tool, scannedCommit, result, sarif}` |

Passthrough embeds the result file verbatim as the predicate (it must be a JSON
object). The thin envelope hoists `tool`/`result`/`scannedCommit` to the top
level so policy filters on `predicate.tool.name` / `predicate.result` without
parsing nested SARIF. SBOM (passthrough) and the SARIF tools osv, zizmor,
wrangle-lint, and dependency-review (scan/v1 envelope) ship with producers; the
scorecard passthrough is wired so a later producer PR is manifest-only.

dependency-review runs only on `pull_request`; the sign/verify flow runs on
release/push. Its manifest is therefore produced on a PR but never signed —
inert by construction, not a gap.

## Engine-owned subject

Every statement is bound to the **single sha256 artifact subject**, given as a
digest via `--subject` (e.g. a container image) or self-digested from a file via
`--artifact`. The GitHub attestation store (`bnd push github`) keys by subject
digest and rejects a multi-digest subject, so a single sha256 is the only shape
that round-trips through the store — and it is the same digest `run_verify.sh`
binds the VSA to, so a policy resolving by artifact digest finds both. Binding
the scanned git commit as a second subject is deferred to the source-scan PRs.

## CLI

```
wrangle-attest --metadata-root <dir>... (--subject sha256:<hex> | --artifact <file>) \
    [--commit <hex-sha>] [--sign] --out <file>
```

Honors the canonical top-level `<root>/wrangle_attestation_metadata.json` plus,
for each immediate child dir of `<root>/scan/`, `<root>/scan/<tool>/wrangle_attestation_metadata.json`
(a bounded one-level lookup, no recursion). Any other `wrangle_attestation_metadata.json`
deeper in the tree or outside those two locations is ignored (a build-time
dependency could plant one to forge a wrangle-signed attestation).
Builds one Statement per honored manifest bound to the subject and writes them
all to `--out` as JSONL. `--commit` is woven into the `scan/v1` envelope only;
passthrough predicates ignore it.

With `--sign` each statement is keyless-signed (one shared signer — ambient
GitHub OIDC → Fulcio → Rekor; the bundle is byte-identical to `bnd statement`)
and the compact Sigstore bundle is emitted; without it the statements are
emitted unsigned (fully offline-unit-testable). Statements are built and signed
into a buffer before `--out` is touched, so a failure on the Nth manifest — a
malformed manifest or a signing failure — never leaves a partial/unsigned file.
Exit 0 on success; non-zero (fail closed) on any error.

```
wrangle-attest --sign --statement <file> --out <file>
```

Signs an existing in-toto statement file (the verify job's VSA) instead of
discovering manifests: the raw file bytes become the DSSE payload verbatim —
never re-marshaled — so the bundle is byte-identical to `bnd statement` on the
same file, written as one compact bundle line. `--statement` is mutually
exclusive with `--metadata-root`, `--subject`, `--artifact`, and `--commit`; a
missing, empty, or non-JSON-object file fails closed before `--out` is touched.

## Testing

`go test ./wrangle-attest/` — table-driven manifest parse/validate (fail-closed
cases), subject parsing (single sha256, fail-closed on multi/short/wrong-algo;
`--artifact` self-digest), golden Statements (`testdata/`) for the SBOM
passthrough and the SARIF thin-envelope shapes, and hermetic `--sign` (local
ephemeral key: DSSE shape + signature + fail-closed). Regenerate goldens with
`go test ./wrangle-attest/ -update`. The real keyless path is covered by the
dispatch e2e (`actions/attest_provenance` and `actions/attest_metadata_oci` bats
cover the `sign_metadata.sh` glue).
