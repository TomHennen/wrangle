package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const retryNoticeText = "retrying once for transient Sigstore I/O"

// flakySigner fails the first `failures` sign calls, then succeeds.
type flakySigner struct {
	failures int
	calls    int
	out      []byte
}

func (f *flakySigner) sign([]byte) ([]byte, error) {
	f.calls++
	if f.calls <= f.failures {
		return nil, errors.New("transient sigstore blip")
	}
	return f.out, nil
}

func writeSignFixture(t *testing.T) (metaDir, out string) {
	t.Helper()
	dir := t.TempDir()
	writeFile(t, dir, "meta/wrangle_attestation_metadata.json",
		`{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}`)
	writeFile(t, dir, "meta/sbom.spdx.json", `{"spdxVersion":"SPDX-2.3"}`)
	return filepath.Join(dir, "meta"), filepath.Join(dir, "out.jsonl")
}

func TestRetrySignRecoversFromOneFailure(t *testing.T) {
	t.Setenv("WRANGLE_RETRY_DELAY", "0")
	fs := &flakySigner{failures: 1, out: []byte(`{"bundle":"x"}`)}
	swapSigner(t, func() (statementSigner, func(), error) { return fs, func() {}, nil })
	meta, out := writeSignFixture(t)

	var stderr bytes.Buffer
	rc := run([]string{"--metadata-root", meta, "--subject", testArtifactDigest, "--sign", "--out", out}, &stderr)
	if rc != 0 {
		t.Fatalf("run rc=%d stderr=%s", rc, stderr.String())
	}
	if fs.calls != 2 {
		t.Fatalf("sign calls = %d, want 2 (one retry)", fs.calls)
	}
	if got := strings.Count(stderr.String(), retryNoticeText); got != 1 {
		t.Fatalf("retry notices = %d, want 1; stderr=%s", got, stderr.String())
	}
	if data, err := os.ReadFile(out); err != nil || string(data) != `{"bundle":"x"}`+"\n" {
		t.Fatalf("out = %q (err %v), want the signed line", data, err)
	}
}

func TestRetrySignFailsAfterSecondFailure(t *testing.T) {
	t.Setenv("WRANGLE_RETRY_DELAY", "0")
	fs := &flakySigner{failures: 2, out: []byte(`{"bundle":"x"}`)}
	swapSigner(t, func() (statementSigner, func(), error) { return fs, func() {}, nil })
	meta, out := writeSignFixture(t)

	var stderr bytes.Buffer
	rc := run([]string{"--metadata-root", meta, "--subject", testArtifactDigest, "--sign", "--out", out}, &stderr)
	if rc != 2 {
		t.Fatalf("rc=%d, want fail-closed 2; stderr=%s", rc, stderr.String())
	}
	if fs.calls != 2 {
		t.Fatalf("sign calls = %d, want exactly 2 (retry once, never more)", fs.calls)
	}
	if _, err := os.Stat(out); !os.IsNotExist(err) {
		t.Fatalf("expected no output file after failure, stat err=%v", err)
	}
}

func TestRetrySignerConstructionRecoversFromOneFailure(t *testing.T) {
	t.Setenv("WRANGLE_RETRY_DELAY", "0")
	rs := &recordingSigner{out: []byte(`{"bundle":"x"}`)}
	attempts := 0
	swapSigner(t, func() (statementSigner, func(), error) {
		attempts++
		if attempts == 1 {
			return nil, nil, errors.New("transient OIDC blip")
		}
		return rs, func() {}, nil
	})
	meta, out := writeSignFixture(t)

	var stderr bytes.Buffer
	rc := run([]string{"--metadata-root", meta, "--subject", testArtifactDigest, "--sign", "--out", out}, &stderr)
	if rc != 0 {
		t.Fatalf("run rc=%d stderr=%s", rc, stderr.String())
	}
	if attempts != 2 {
		t.Fatalf("construction attempts = %d, want 2", attempts)
	}
	if got := strings.Count(stderr.String(), retryNoticeText); got != 1 {
		t.Fatalf("retry notices = %d, want 1; stderr=%s", got, stderr.String())
	}
}

func TestRetrySignerConstructionFailsAfterSecondFailure(t *testing.T) {
	t.Setenv("WRANGLE_RETRY_DELAY", "0")
	attempts := 0
	swapSigner(t, func() (statementSigner, func(), error) {
		attempts++
		return nil, nil, errors.New("persistent OIDC failure")
	})
	meta, out := writeSignFixture(t)

	var stderr bytes.Buffer
	rc := run([]string{"--metadata-root", meta, "--subject", testArtifactDigest, "--sign", "--out", out}, &stderr)
	if rc != 2 {
		t.Fatalf("rc=%d, want fail-closed 2; stderr=%s", rc, stderr.String())
	}
	if attempts != 2 {
		t.Fatalf("construction attempts = %d, want exactly 2", attempts)
	}
	if _, err := os.Stat(out); !os.IsNotExist(err) {
		t.Fatalf("expected no output file after failure, stat err=%v", err)
	}
}

// A deterministic non-Sigstore failure (a manifest naming a missing result
// file) must fail without ever reaching the signer or emitting a retry notice.
func TestRetryNotAppliedToDeterministicErrors(t *testing.T) {
	t.Setenv("WRANGLE_RETRY_DELAY", "0")
	fs := &flakySigner{out: []byte(`{"bundle":"x"}`)}
	swapSigner(t, func() (statementSigner, func(), error) { return fs, func() {}, nil })
	dir := t.TempDir()
	writeFile(t, dir, "meta/wrangle_attestation_metadata.json",
		`{"predicate-type":"https://spdx.dev/Document","result-file":"missing.json"}`)
	out := filepath.Join(dir, "out.jsonl")

	var stderr bytes.Buffer
	rc := run([]string{"--metadata-root", filepath.Join(dir, "meta"),
		"--subject", testArtifactDigest, "--sign", "--out", out}, &stderr)
	if rc != 2 {
		t.Fatalf("rc=%d, want fail-closed 2; stderr=%s", rc, stderr.String())
	}
	if fs.calls != 0 {
		t.Fatalf("sign calls = %d, want 0 for a deterministic failure", fs.calls)
	}
	if strings.Contains(stderr.String(), retryNoticeText) {
		t.Fatalf("deterministic failure was retried: %s", stderr.String())
	}
}

func TestRetrySignStatementModeRecoversFromOneFailure(t *testing.T) {
	t.Setenv("WRANGLE_RETRY_DELAY", "0")
	fs := &flakySigner{failures: 1, out: []byte(`{"bundle":"x"}`)}
	swapSigner(t, func() (statementSigner, func(), error) { return fs, func() {}, nil })
	dir := t.TempDir()
	stmt := filepath.Join(dir, "vsa.intoto.json")
	if err := os.WriteFile(stmt, []byte(`{"a":1}`), 0o644); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(dir, "out.json")

	var stderr bytes.Buffer
	rc := run([]string{"--sign", "--statement", stmt, "--out", out}, &stderr)
	if rc != 0 {
		t.Fatalf("run rc=%d stderr=%s", rc, stderr.String())
	}
	if fs.calls != 2 {
		t.Fatalf("sign calls = %d, want 2 (one retry)", fs.calls)
	}
	if got := strings.Count(stderr.String(), retryNoticeText); got != 1 {
		t.Fatalf("retry notices = %d, want 1; stderr=%s", got, stderr.String())
	}
}
