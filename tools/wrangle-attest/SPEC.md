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

Passthrough embeds the result file's JSON object as the predicate. It is
re-encoded, not byte-preserved: the predicate is a protobuf `Struct` (a map), so
key order is normalized and the attested bytes are semantically identical to the
result file but not identical to it. Same for the SARIF nested in the scan/v1
envelope. Compare the predicate as JSON, never as bytes. Byte-preservation holds
only where it is stated below: `--statement`'s payload and `assemble`'s
`--provenance`. The thin envelope hoists `tool`/`result`/`scannedCommit` to the top
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
GitHub OIDC → Fulcio → Rekor, the same signing path as `bnd statement`: the
DSSE payload is the statement bytes verbatim) and the compact Sigstore bundle
is emitted; without it the statements are
emitted unsigned (fully offline-unit-testable). Statements are built and signed
into a buffer before `--out` is touched, so a failure on the Nth manifest — a
malformed manifest or a signing failure — never leaves a partial/unsigned file.
Exit 0 on success; non-zero (fail closed) on any error.

Transient Sigstore I/O is retried by the signer itself (`carabiner-dev/signer`
configures retries on the Fulcio, Rekor, and TSA hops, and on TUF/OIDC fetches),
so the engine adds no retry of its own and signs exactly as `bnd` does.

```
wrangle-attest --sign --statement <file> --out <file> [--append <bundle>]
```

Signs an existing in-toto statement file (the verify job's VSA) instead of
discovering manifests: the raw file bytes become the DSSE payload verbatim —
never re-marshaled — written as one compact bundle line. `--statement` is
mutually exclusive with `--metadata-root`, `--subject`, `--artifact`, and
`--commit`; a missing, empty, or non-JSON-object file fails closed before
`--out` is touched.

`--append` additionally appends the identical signed line + `\n` to the
existing bundle at `<bundle>` (the attest-assembled per-artifact bundle). It
requires `--statement` and must not name the same file as `--out`; a missing
or empty append target fails closed before signing — a VSA-only bundle is
impossible. Any failure exits non-zero having modified neither file, except a
failed append after `--out` was written, which removes `--out` again
(best-effort) before exiting non-zero.

```
wrangle-attest assemble --metadata-root <dir>... --subjects-file <file> \
    (--provenance <file> | --provenance-referrers <file>) [--commit <hex-sha>] --sign \
    --bundle-dir <dir> --statements-out <file>
```

The attest job's orchestration. `--subjects-file` is newline-separated
subjects (blank lines dropped; an empty set fails closed): a `algo:hex`
digest-form subject must be `sha256:<64-hex>` (any other digest errors, it is
never reinterpreted as a path), anything else is a dist file the engine
self-digests. For each subject, every discovered manifest is built and signed
with one shared signer (one OIDC/Fulcio flow total; zero manifests fails
closed), and `<bundle-dir>/<basename, ':'→'-'>.intoto.jsonl` is written as the
provenance verbatim plus one signed line per statement; `--statements-out`
collects every newly signed line in the same order. `--provenance` is copied
byte-for-byte; `--provenance-referrers` filters raw `cosign download attestation`
output to the SLSA provenance envelopes, keeping each surviving line's
original bytes (zero matches or a malformed line fails closed). A bundle-name
collision — within the subject set or with a file already under
`--bundle-dir` — fails closed. Everything is buffered and validated before
anything is written, so a validation or signing failure (including on the last
signature) writes nothing; a write-phase failure exits non-zero and a re-run
refuses the partially written `--bundle-dir` via the pre-existence check.
`assemble` requires `--sign` and rejects `--subject`, `--artifact`,
`--statement`, `--out`, and `--append`.

```
wrangle-attest verify (--subject sha256:<hex> | --artifact <file>) \
    --policy <path-or-locator> --bundle <file> [--collector <c>]... \
    [--context <kv>] [--attestation <file>] [--fail=<bool>] --out <file>
```

The verify job's orchestration: evaluate the policy over one subject by
exec-ing the sibling `ampel` binary (both ship in the attest-toolbox image),
then keyless-sign the VSA ampel emitted — the raw file bytes verbatim, the
same signer path as `--statement` — and deliver it. `--bundle` is the
attest-assembled per-artifact bundle: it is fed to the policy as ampel's
`jsonl:` collector and, on success, appended with the identical signed line
(same append semantics as `--append`: non-empty precheck before ampel runs,
must not alias `--out`, a failed append removes the just-written `--out`).
A file subject is self-digested to the single sha256 and passed as ampel's
`--subject-hash`; a digest subject passes through as `--subject`. ampel's
report (`--format=html`, stdout) passes through to stdout for the step
summary; the exec is retried once for transient collector I/O, with the
results file removed and the report buffer reset between attempts. The child
env is scrubbed of `SIGSTORE_ID_TOKEN`, `ACTIONS_ID_TOKEN_REQUEST_*`, and
`AMPEL_*` — ampel parses semi-trusted attestations and must never hold
signing material, and it resolves policy context keys from `AMPEL_<KEY>`.

The verdict is dual-checked, because ampel's exit code alone is not a safe
PASS signal: ampel exits 1 for a FAILED verdict *and* for every tool error
(`cmd/ampel/main.go` exits 1 on any returned error;
`internal/cmd/verify.go` `os.Exit(1)` only on `StatusFAIL`), so exit 0 does
not prove a VSA was written, bound to this subject, or well-formed. Signing
therefore requires ampel exit 0 AND that `--results-path` parses as an in-toto
VSA statement bound to exactly the requested single-sha256 subject with
`predicate.verificationResult` exactly `PASSED`. With `--fail=false` (warn
mode) ampel runs with `--exit-code=false` and an explicitly `FAILED` VSA is
still signed and delivered; any other verdict value fails closed in both
modes. Exit 0 = verified, signed, delivered; 1 = FAILED verdict with
`--fail=true` (nothing signed); 2 = anything else (nothing signed).

A `SOFTFAIL` (a policy group with `enforce: OFF` — wrangle's own advisory
`wrangle-release-pinned` tenet is one) is **not** distinguishable from a PASS
here: ampel exits 0 and maps SOFTFAIL to `verificationResult: PASSED`
(`pkg/attest/vsa.go` `resultStringToSLSAResult`). That is the intended policy
semantics, unchanged from the shell, not a gap this check closes.

## Testing

`go test ./wrangle-attest/` — table-driven manifest parse/validate (fail-closed
cases), subject parsing (single sha256, fail-closed on multi/short/wrong-algo;
`--artifact` self-digest), golden Statements (`testdata/`) for the SBOM
passthrough and the SARIF thin-envelope shapes, and hermetic `--sign` (local
ephemeral key: DSSE shape + signature + fail-closed). `--statement` mode is
covered by a recording signer pinning the payload to the file bytes verbatim, a
local-key payload round-trip, a fail-closed table (including a signing failure
leaving a pre-existing `--out` untouched), and the tag-gated keyless
integration test. `--append` and `assemble` are covered hermetically with fake
signers (byte-exact bundle goldens, buffer-then-write fail-closed). `verify`
is covered with a scripted fake ampel + fake signer (the exit-code x VSA
verdict matrix, env scrub, argv shape, retry); the real ampel CLI contract is
pinned by the bats real-parser test and the dispatch e2e. Regenerate
goldens with
`go test ./wrangle-attest/ -update`. The real keyless path is covered by the
dispatch e2e (`actions/attest_provenance` and `actions/attest_metadata_oci` bats
cover the `sign_metadata.sh` glue).
