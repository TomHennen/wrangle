//go:build keyless_integration

// Real keyless signing against Fulcio/Rekor with ambient GitHub OIDC. Compiled
// only under -tags keyless_integration and run in the dedicated id-token: write
// CI job — never in the unit suite, so that suite stays hermetic. The bnd push
// github + ampel round-trip is proven by the dispatch e2e (the real validator).
package main

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
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

	// The keyless artifact is a Sigstore bundle: one compact line carrying a
	// verificationMaterial (the Fulcio cert) and the inner DSSE envelope.
	var bundle struct {
		MediaType            string          `json:"mediaType"`
		VerificationMaterial json.RawMessage `json:"verificationMaterial"`
		DSSEEnvelope         struct {
			Payload     string `json:"payload"`
			PayloadType string `json:"payloadType"`
			Signatures  []struct {
				Sig string `json:"sig"`
			} `json:"signatures"`
		} `json:"dsseEnvelope"`
	}
	if err := json.Unmarshal(data, &bundle); err != nil {
		t.Fatalf("output is not a Sigstore bundle: %v\n%s", err, data)
	}
	if len(bundle.VerificationMaterial) == 0 {
		t.Fatal("bundle carries no verificationMaterial (Fulcio cert)")
	}
	if len(bundle.DSSEEnvelope.Signatures) == 0 || bundle.DSSEEnvelope.Signatures[0].Sig == "" {
		t.Fatal("bundle's DSSE envelope carries no signature")
	}
	// The keyless path uses the in-toto media type, NOT the statement URI.
	if got := bundle.DSSEEnvelope.PayloadType; got != "application/vnd.in-toto+json" {
		t.Fatalf("payloadType = %q, want application/vnd.in-toto+json", got)
	}

	payload, err := base64.StdEncoding.DecodeString(bundle.DSSEEnvelope.Payload)
	if err != nil {
		t.Fatalf("payload not base64: %v", err)
	}
	var stmt struct {
		PredicateType string `json:"predicateType"`
		Subject       []struct {
			Digest map[string]string `json:"digest"`
		} `json:"subject"`
	}
	if err := json.Unmarshal(payload, &stmt); err != nil {
		t.Fatalf("payload is not the in-toto statement: %v", err)
	}
	if stmt.PredicateType != "https://spdx.dev/Document" {
		t.Fatalf("wrong predicateType: %q", stmt.PredicateType)
	}
	if len(stmt.Subject) != 1 || stmt.Subject[0].Digest["sha256"] == "" {
		t.Fatalf("expected the single sha256 subject, got %+v", stmt.Subject)
	}
}

type testWriter struct{ b []byte }

func (w *testWriter) Write(p []byte) (int, error) { w.b = append(w.b, p...); return len(p), nil }
