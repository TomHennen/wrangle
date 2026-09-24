// Command wrangle-attest is the shared attestation engine: it turns the inert
// result files that scan/build tools leave behind into in-toto v1 Statements
// and, with --sign, keyless-signs each into a Sigstore bundle in the trusted
// post-build context (actions/verify). It is the single producer-side engine:
// adding the Nth attestation type is a new manifest + (for a novel predicate
// shape) a new case here, never new signing code.
//
// Tools declare, the engine decides. Each producer writes a
// wrangle_attestation_metadata.json next to its native result (sbom.spdx.json,
// results.json, output.sarif, …):
//
//	{
//	  "predicate-type": "<URI>",           // required; implies the result format
//	  "result-file":    "<relative-path>", // required; relative to the manifest dir
//	  "tool":   {"name": "<str>", "version": "<str>"}, // .../scan/v1 only
//	  "result": "clean" | "findings"                    // .../scan/v1 only
//	}
//
// The engine walks --metadata-root for wrangle_attestation_metadata.json files and builds one
// Statement per manifest:
//   - passthrough predicates (SPDX, OSV, scorecard) embed the result file
//     verbatim as the predicate;
//   - the wrangle scan predicate (.../wrangle/attestation/scan/v1) wraps SARIF
//     in a thin envelope {tool, scannedCommit, result, sarif} so policy can
//     filter on predicate.tool.name / predicate.result without parsing SARIF.
//
// The engine OWNS the subject: every statement is bound to the SINGLE sha256
// subject, passed via --subject (a digest, e.g. a container image) or computed
// by self-digesting --artifact. It is the same digest the run's VSA binds to.
// The GitHub attestation store rejects a multi-digest subject, so a single
// sha256 is the only shape that round-trips through `bnd push github`. Binding
// the scanned commit as a second subject is deferred to the source-scan PRs.
//
// With --sign each statement is keyless-signed via one shared signer (ambient
// GitHub OIDC -> Fulcio -> Rekor), producing a Sigstore bundle. Without it the
// statements are emitted unsigned (offline-unit-testable).
//
// With --sign --statement <file> the engine instead signs one existing
// statement file (the verify job's VSA) through the same signer — no manifest
// discovery; the DSSE payload is the statement file bytes verbatim. --append
// also appends the identical signed line to an existing per-artifact bundle,
// which must be non-empty (a VSA-only bundle is impossible).
//
// The verify subcommand is the verify job's orchestration: it execs the
// sibling ampel binary to evaluate the policy over one subject, fails closed
// unless ampel's exit code AND the VSA it emitted agree the verdict is
// PASSED, then signs the VSA verbatim and appends the signed line to that
// subject's per-artifact bundle.
//
// The assemble subcommand is the attest job's orchestration: it reads the
// newline-separated subjects file, self-digests file subjects, signs every
// discovered manifest per subject with one shared signer, and writes one
// per-artifact bundle (the provenance verbatim + that subject's signed
// lines) plus a file of every newly signed line — all buffered, so validation
// and signing failures write nothing; a write-phase failure exits non-zero and
// a re-run refuses the partially written bundle dir.
//
// Fail closed: a malformed/missing manifest, an unknown predicate-type, a
// missing result file, a malformed subject, or a signing failure aborts with a
// non-zero exit BEFORE any output is written, so a partial/unsigned/corrupt
// bundle is never produced.
package main

import "os"

func main() {
	os.Exit(run(os.Args[1:], os.Stderr))
}
