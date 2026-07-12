//go:build keyless_integration

// Real keyless signing against Fulcio/Rekor with ambient GitHub OIDC. Compiled
// only under -tags keyless_integration and run in the dedicated id-token: write
// CI job — never in the unit suite, so that suite stays hermetic. The bnd push
// github + ampel round-trip is proven by the dispatch e2e (the real validator).
package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/carabiner-dev/signer"
	"github.com/carabiner-dev/signer/options"
	intoto "github.com/in-toto/attestation/go/v1"
	sbundle "github.com/sigstore/sigstore-go/pkg/bundle"
	"google.golang.org/protobuf/encoding/protojson"
)

func TestRunSignKeyless(t *testing.T) {
	// In CI this job has id-token: write; a missing token is a real gap, not a
	// skip — keyless must actually run here.
	if os.Getenv("ACTIONS_ID_TOKEN_REQUEST_URL") == "" {
		t.Fatal("ACTIONS_ID_TOKEN_REQUEST_URL unset; keyless signing needs ambient GitHub OIDC")
	}

	dir := t.TempDir()
	writeFile(t, dir, "meta/wrangle_attestation_metadata.json",
		`{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}`)
	writeFile(t, dir, "meta/sbom.spdx.json", `{"spdxVersion":"SPDX-2.3","name":"keyless"}`)
	out := filepath.Join(dir, "sbom.intoto.jsonl")

	var stderr testWriter
	rc := run([]string{
		"--metadata-root", filepath.Join(dir, "meta"),
		"--subject", testArtifactDigest,
		"--sign",
		"--out", out,
	}, &stderr)
	if rc != 0 {
		t.Fatalf("keyless run rc=%d stderr=%s", rc, stderr.b)
	}

	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}

	// The keyless artifact is a Sigstore bundle carrying the Fulcio cert in
	// verificationMaterial and the in-toto statement in an inner DSSE envelope.
	// Parse it with the upstream sigstore-go bundle type so the shape checks
	// can't drift from the real schema.
	var bundle sbundle.Bundle
	if err := bundle.UnmarshalJSON(data); err != nil {
		t.Fatalf("output is not a Sigstore bundle: %v\n%s", err, data)
	}
	if bundle.GetVerificationMaterial() == nil {
		t.Fatal("bundle carries no verificationMaterial (Fulcio cert)")
	}
	env := bundle.GetDsseEnvelope()
	if env == nil {
		t.Fatal("bundle carries no DSSE envelope")
	}
	if len(env.GetSignatures()) == 0 || len(env.GetSignatures()[0].GetSig()) == 0 {
		t.Fatal("bundle's DSSE envelope carries no signature")
	}
	// The keyless path uses the in-toto media type, NOT the statement URI.
	if got := env.GetPayloadType(); got != "application/vnd.in-toto+json" {
		t.Fatalf("payloadType = %q, want application/vnd.in-toto+json", got)
	}

	var stmt intoto.Statement
	if err := protojson.Unmarshal(env.GetPayload(), &stmt); err != nil {
		t.Fatalf("payload is not the in-toto statement: %v", err)
	}
	if stmt.GetPredicateType() != "https://spdx.dev/Document" {
		t.Fatalf("wrong predicateType: %q", stmt.GetPredicateType())
	}
	if subs := stmt.GetSubject(); len(subs) != 1 || subs[0].GetDigest()["sha256"] == "" {
		t.Fatalf("expected the single sha256 subject, got %+v", stmt.GetSubject())
	}

	// Cryptographically verify the bundle against the Sigstore trust root: the
	// signature must be valid for this Fulcio identity over the signed payload.
	// A tampered payload or signature fails here.
	verifyKeylessBundle(t, data)
}

// TestRunSignKeylessStatement signs an existing statement file via --statement
// and asserts the emitted Sigstore bundle's DSSE payload is the file bytes
// verbatim.
func TestRunSignKeylessStatement(t *testing.T) {
	// In CI this job has id-token: write; a missing token is a real gap, not a
	// skip — keyless must actually run here.
	if os.Getenv("ACTIONS_ID_TOKEN_REQUEST_URL") == "" {
		t.Fatal("ACTIONS_ID_TOKEN_REQUEST_URL unset; keyless signing needs ambient GitHub OIDC")
	}

	dir := t.TempDir()
	stmt := `{"_type":"https://in-toto.io/Statement/v1","subject":[{"name":"artifact","digest":{"sha256":"011b95c8e47c538646a2c01df5373fe703381cd415c847357b3d563563eb1d95"}}],"predicateType":"https://slsa.dev/verification_summary/v1","predicate":{"verificationResult":"PASSED"}}`
	path := filepath.Join(dir, "vsa.intoto.json")
	if err := os.WriteFile(path, []byte(stmt), 0o644); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(dir, "vsa.signed.json")

	var stderr testWriter
	rc := run([]string{"--sign", "--statement", path, "--out", out}, &stderr)
	if rc != 0 {
		t.Fatalf("keyless run rc=%d stderr=%s", rc, stderr.b)
	}

	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	trimmed := bytes.TrimSuffix(data, []byte("\n"))
	if bytes.ContainsRune(trimmed, '\n') || len(trimmed) == len(data) {
		t.Fatalf("expected a single compact bundle line + newline, got %q", data)
	}

	var bundle sbundle.Bundle
	if err := bundle.UnmarshalJSON(data); err != nil {
		t.Fatalf("output is not a Sigstore bundle: %v\n%s", err, data)
	}
	if bundle.GetVerificationMaterial() == nil {
		t.Fatal("bundle carries no verificationMaterial (Fulcio cert)")
	}
	env := bundle.GetDsseEnvelope()
	if env == nil {
		t.Fatal("bundle carries no DSSE envelope")
	}
	if got := env.GetPayloadType(); got != "application/vnd.in-toto+json" {
		t.Fatalf("payloadType = %q, want application/vnd.in-toto+json", got)
	}
	if !bytes.Equal(env.GetPayload(), []byte(stmt)) {
		t.Fatalf("DSSE payload differs from statement file bytes:\n got: %q\nwant: %q", env.GetPayload(), stmt)
	}

	verifyKeylessBundle(t, data)
}

// verifyKeylessBundle verifies the signed bundle bytes with the upstream
// carabiner-dev/signer verifier against the embedded Sigstore trust root,
// asserting the GitHub Actions OIDC identity and proving the signature is
// valid. It re-verifies a tampered copy to confirm the check actually fails.
func verifyKeylessBundle(t *testing.T, bundleBytes []byte) {
	t.Helper()

	verifier, err := signer.NewVerifierFromSet(options.DefaultVerifierSet())
	if err != nil {
		t.Fatalf("building verifier: %v", err)
	}

	// The signer is the GitHub Actions OIDC identity of this workflow run;
	// match the well-known issuer and constrain the SAN to this repo's actions.
	issuerRegex := `^https://token\.actions\.githubusercontent\.com$`
	sanRegex := `^https://github\.com/TomHennen/wrangle/`
	res, err := verifier.VerifyInlineBundle(bundleBytes,
		options.WithExpectedIdentityRegex(issuerRegex, sanRegex))
	if err != nil {
		t.Fatalf("verifying keyless bundle: %v", err)
	}
	if res == nil {
		t.Fatal("verification returned no result")
	}

	// A flipped byte in the signed payload must fail verification — proves the
	// assertion above is load-bearing, not a no-op.
	tampered := tamperPayload(t, bundleBytes)
	if _, err := verifier.VerifyInlineBundle(tampered,
		options.WithExpectedIdentityRegex(issuerRegex, sanRegex)); err == nil {
		t.Fatal("tampered bundle verified; signature check is not load-bearing")
	}
}

// tamperPayload flips one byte of the DSSE payload and returns the re-serialized
// bundle, which no longer matches its signature.
func tamperPayload(t *testing.T, bundleBytes []byte) []byte {
	t.Helper()
	var b sbundle.Bundle
	if err := b.UnmarshalJSON(bundleBytes); err != nil {
		t.Fatalf("re-parsing bundle to tamper: %v", err)
	}
	payload := b.GetDsseEnvelope().GetPayload()
	if len(payload) == 0 {
		t.Fatal("no payload to tamper")
	}
	payload[0] ^= 0xff
	out, err := protojson.Marshal(&b)
	if err != nil {
		t.Fatalf("re-marshaling tampered bundle: %v", err)
	}
	return out
}

type testWriter struct{ b []byte }

func (w *testWriter) Write(p []byte) (int, error) { w.b = append(w.b, p...); return len(p), nil }

// The keyless (sigstore) backend — the only backend wrangle signs with —
// rejects a payload that is not an in-toto statement before it reaches Fulcio.
// This is the signer's own check, not one of ours: the engine passes the file
// bytes through untouched, so a valid JSON object that is merely not a
// statement must still fail closed with --out untouched.
func TestRunSignKeylessRejectsNonStatement(t *testing.T) {
	if os.Getenv("ACTIONS_ID_TOKEN_REQUEST_URL") == "" {
		t.Fatal("ACTIONS_ID_TOKEN_REQUEST_URL unset; keyless signing needs ambient GitHub OIDC")
	}

	dir := t.TempDir()
	prior := []byte("PRE-EXISTING\n")
	for _, tc := range []struct{ name, content string }{
		{"valid JSON object that is not an in-toto statement", `{"hello":"world"}`},
		{"JSON array", `[{"a":1}]`},
		{"JSON null", `null`},
		{"truncated JSON object", `{"a":`},
		{"not JSON at all", `not json`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(dir, "stmt.json")
			if err := os.WriteFile(path, []byte(tc.content), 0o644); err != nil {
				t.Fatal(err)
			}
			out := filepath.Join(dir, "out.json")
			if err := os.WriteFile(out, prior, 0o644); err != nil {
				t.Fatal(err)
			}

			var stderr testWriter
			if rc := run([]string{"--sign", "--statement", path, "--out", out}, &stderr); rc != 2 {
				t.Fatalf("rc=%d, want fail-closed 2; stderr=%s", rc, stderr.b)
			}
			data, err := os.ReadFile(out)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(data, prior) {
				t.Fatalf("pre-existing --out changed on a rejected statement: %q", data)
			}
		})
	}
}
