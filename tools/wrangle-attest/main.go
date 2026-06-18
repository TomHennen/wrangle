// Command wrangle-attest is the shared attestation engine: it turns the inert
// result files that scan/build tools leave behind into UNSIGNED in-toto v1
// Statements, ready for `bnd` to sign in the trusted post-build context
// (actions/verify). It is the single producer-side engine: adding the Nth
// attestation type is a new manifest + (for a novel predicate shape) a new case
// here, never new signing code.
//
// Tools declare, the engine decides. Each producer writes a manifest.json next
// to its native result (sbom.spdx.json, results.json, output.sarif, …):
//
//	{
//	  "predicate-type": "<URI>",           // required; implies the result format
//	  "result-file":    "<relative-path>", // required; relative to the manifest dir
//	  "tool":   {"name": "<str>", "version": "<str>"}, // .../scan/v1 only
//	  "result": "clean" | "findings"                    // .../scan/v1 only
//	}
//
// The engine walks --metadata-root for manifest.json files and builds one
// Statement per manifest:
//   - passthrough predicates (SPDX, OSV, scorecard) embed the result file
//     verbatim as the predicate;
//   - the wrangle scan predicate (.../wrangle/attestation/scan/v1) wraps SARIF
//     in a thin envelope {tool, scannedCommit, result, sarif} so policy can
//     filter on predicate.tool.name / predicate.result without parsing SARIF.
//
// The engine OWNS the subject: every statement is bound to the SINGLE sha256
// subject passed via --subject (the same artifact digest the run's VSA binds
// to). The GitHub attestation store rejects a multi-digest subject, so a single
// sha256 is the only shape that round-trips through `bnd push github`. Binding
// the scanned commit as a second subject is deferred to the source-scan PRs.
//
// All output is UNSIGNED. Signing stays in actions/verify/run_verify.sh, which
// bnd-signs each emitted statement in the same trusted process as the VSA — so
// this engine has no Sigstore code and is fully offline-unit-testable.
//
// Fail closed: a malformed/missing manifest, an unknown predicate-type, a
// missing result file, or a malformed subject aborts with a non-zero exit
// BEFORE any output is written, so a partial/corrupt bundle is never produced.
package main

import "os"

func main() {
	os.Exit(run(os.Args[1:], os.Stderr))
}
