package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/carabiner-dev/signer"
	"github.com/carabiner-dev/signer/key"
	"github.com/carabiner-dev/signer/options"
)

// localKeySigner signs with an ephemeral local key (DSSE envelope backend),
// exercising the same SignStatement/WriteTo path as keyless without any
// network, OIDC, or Fulcio.
type localKeySigner struct {
	sg  *signer.Signer
	key key.PrivateKeyProvider
}

func newLocalKeySigner(t *testing.T) *localKeySigner {
	t.Helper()
	k, err := key.NewGenerator().GenerateKeyPair()
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}
	return &localKeySigner{sg: signer.NewSigner(), key: k}
}

func (l *localKeySigner) sign(statement []byte) ([]byte, error) {
	art, err := l.sg.SignStatement(statement, options.WithKey(l.key))
	if err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	if _, err := art.WriteTo(&buf); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func TestRunSignEmitsSignedStatement(t *testing.T) {
	ks := newLocalKeySigner(t)
	swapSigner(t, func() (statementSigner, func(), error) { return ks, func() {}, nil })

	dir := t.TempDir()
	writeFile(t, dir, "meta/wrangle_attestation_metadata.json",
		`{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}`)
	writeFile(t, dir, "meta/sbom.spdx.json", `{"spdxVersion":"SPDX-2.3","name":"x"}`)
	out := filepath.Join(dir, "sbom.intoto.jsonl")

	var stderr bytes.Buffer
	rc := run([]string{
		"--metadata-root", filepath.Join(dir, "meta"),
		"--subject", testArtifactDigest,
		"--sign",
		"--out", out,
	}, &stderr)
	if rc != 0 {
		t.Fatalf("run rc=%d stderr=%s", rc, stderr.String())
	}

	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	// The local-key backend emits a single DSSE envelope (indented protojson);
	// keyless emits a compact bundle. Parse the whole artifact as one object.
	var env struct {
		Payload     string `json:"payload"`
		PayloadType string `json:"payloadType"`
		Signatures  []struct {
			Sig string `json:"sig"`
		} `json:"signatures"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(data), &env); err != nil {
		t.Fatalf("signed output is not a DSSE envelope: %v", err)
	}
	if len(env.Signatures) == 0 || env.Signatures[0].Sig == "" {
		t.Fatalf("envelope carries no signature: %+v", env.Signatures)
	}

	payload, err := base64.StdEncoding.DecodeString(env.Payload)
	if err != nil {
		t.Fatalf("payload is not base64: %v", err)
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

// A signing failure on any statement must leave no output (no partial/unsigned
// bundle) — the buffer-then-write fail-closed discipline must hold for --sign.
func TestRunSignFailClosedNoOutput(t *testing.T) {
	swapSigner(t, func() (statementSigner, func(), error) {
		return failingSigner{}, func() {}, nil
	})

	dir := t.TempDir()
	writeFile(t, dir, "meta/wrangle_attestation_metadata.json",
		`{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}`)
	writeFile(t, dir, "meta/sbom.spdx.json", `{"spdxVersion":"SPDX-2.3"}`)
	out := filepath.Join(dir, "out.jsonl")

	var stderr bytes.Buffer
	rc := run([]string{
		"--metadata-root", filepath.Join(dir, "meta"),
		"--subject", testArtifactDigest,
		"--sign",
		"--out", out,
	}, &stderr)
	if rc == 0 {
		t.Fatal("expected fail-closed exit on a signing failure")
	}
	if _, err := os.Stat(out); !os.IsNotExist(err) {
		t.Fatalf("expected no output file after a signing failure, stat err=%v", err)
	}
}

type failingSigner struct{}

func (failingSigner) sign([]byte) ([]byte, error) { return nil, errors.New("boom") }

func swapSigner(t *testing.T, fn func() (statementSigner, func(), error)) {
	t.Helper()
	orig := newSigner
	newSigner = fn
	t.Cleanup(func() { newSigner = orig })
}
