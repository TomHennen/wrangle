# wrangle-attest — shared attestation engine

`wrangle-attest` turns the inert result files scan/build tools leave behind into
**unsigned** in-toto v1 Statements, ready for `bnd` to sign in the trusted
post-build context (`actions/verify`). It is the single producer-side engine:
adding the Nth attestation type is a new manifest + (for a novel predicate
shape) a new case here, never new signing code.

## Tools declare, the engine decides

A producer writes a `manifest.json` next to its native result file. The manifest
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
set subjects** — the engine owns the subject. A malformed manifest, an unknown
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
parsing nested SARIF. v1 ships SBOM; the OSV/scorecard/SARIF cases are wired so
later producer PRs are manifest-only.

## Engine-owned subject

Every statement is bound to the **single sha256 artifact subject** passed via
`--subject`. The GitHub attestation store (`bnd push github`) keys by subject
digest and rejects a multi-digest subject, so a single sha256 is the only shape
that round-trips through the store — and it is the same digest `run_verify.sh`
binds the VSA to, so a policy resolving by artifact digest finds both. Binding
the scanned git commit as a second subject is deferred to the source-scan PRs.

## CLI

```
wrangle-attest --metadata-root <dir>... --subject sha256:<hex> \
    [--commit <hex-sha>] --out <file>
```

Walks each `--metadata-root` for `manifest.json`, builds one unsigned Statement
per manifest bound to `--subject`, and writes them all to `--out` as JSONL.
`--commit` is woven into the `scan/v1` envelope only; passthrough predicates
ignore it. All statements are built into a buffer before `--out` is touched, so a
failure on the Nth manifest never leaves a partially-written file. Exit 0 on
success; non-zero (fail closed) on any error.

Signing is **not** here: `run_verify.sh` bnd-signs each emitted statement in the
same trusted process as the VSA, so the engine has no Sigstore code and is fully
offline-unit-testable.

## Testing

`go test ./wrangle-attest/` — table-driven manifest parse/validate (fail-closed
cases), subject parsing (single sha256, fail-closed on multi/short/wrong-algo),
and golden Statements (`testdata/`) for the SBOM passthrough and the SARIF
thin-envelope shapes. Regenerate goldens with `go test ./wrangle-attest/
-update`. The `actions/verify` bats cover the `run_verify.sh` glue.
