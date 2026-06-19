package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var update = flag.Bool("update", false, "regenerate golden files")

func TestRunWritesSBOMStatement(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "meta/wrangle_attestation_metadata.json",
		`{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}`)
	writeFile(t, dir, "meta/sbom.spdx.json", `{"spdxVersion":"SPDX-2.3","name":"x"}`)
	out := filepath.Join(dir, "sbom.intoto.jsonl")

	var stderr bytes.Buffer
	rc := run([]string{
		"--metadata-root", filepath.Join(dir, "meta"),
		"--subject", testArtifactDigest,
		"--out", out,
	}, &stderr)
	if rc != 0 {
		t.Fatalf("run rc=%d stderr=%s", rc, stderr.String())
	}

	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) != 1 {
		t.Fatalf("expected 1 statement line, got %d:\n%s", len(lines), data)
	}

	var stmt struct {
		Type          string `json:"_type"`
		PredicateType string `json:"predicateType"`
		Subject       []struct {
			Digest map[string]string `json:"digest"`
		} `json:"subject"`
	}
	if err := json.Unmarshal([]byte(lines[0]), &stmt); err != nil {
		t.Fatalf("statement is not valid JSON: %v", err)
	}
	if stmt.PredicateType != "https://spdx.dev/Document" {
		t.Fatalf("wrong predicateType: %q", stmt.PredicateType)
	}
	// Single sha256 subject — the store rejects multi-digest.
	if len(stmt.Subject) != 1 || len(stmt.Subject[0].Digest) != 1 ||
		stmt.Subject[0].Digest["sha256"] != "011b95c8e47c538646a2c01df5373fe703381cd415c847357b3d563563eb1d95" {
		t.Fatalf("expected single sha256 subject, got %+v", stmt.Subject)
	}
}

// A scan/<tool>/ manifest under the metadata-root is discovered and produces a
// scan/v1 envelope statement with the threaded scannedCommit — the same
// unsigned-build path the SBOM uses, no separate handling.
func TestRunWritesScanStatement(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "meta/scan/osv/wrangle_attestation_metadata.json",
		`{"predicate-type":"https://github.com/TomHennen/wrangle/attestation/scan/v1","result-file":"output.sarif","tool":{"name":"osv-scanner","version":"1.0"},"result":"clean"}`)
	writeFile(t, dir, "meta/scan/osv/output.sarif", `{"version":"2.1.0","runs":[]}`)
	out := filepath.Join(dir, "out.jsonl")

	var stderr bytes.Buffer
	rc := run([]string{
		"--metadata-root", filepath.Join(dir, "meta"),
		"--subject", testArtifactDigest,
		"--commit", "deadbeef",
		"--out", out,
	}, &stderr)
	if rc != 0 {
		t.Fatalf("run rc=%d stderr=%s", rc, stderr.String())
	}
	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	var stmt struct {
		PredicateType string `json:"predicateType"`
		Predicate     struct {
			ScannedCommit string `json:"scannedCommit"`
			Result        string `json:"result"`
			Tool          struct {
				Name string `json:"name"`
			} `json:"tool"`
		} `json:"predicate"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(string(data))), &stmt); err != nil {
		t.Fatal(err)
	}
	if stmt.PredicateType != predicateScanV1 {
		t.Fatalf("wrong predicateType: %q", stmt.PredicateType)
	}
	if stmt.Predicate.ScannedCommit != "deadbeef" || stmt.Predicate.Result != "clean" ||
		stmt.Predicate.Tool.Name != "osv-scanner" {
		t.Fatalf("scan/v1 envelope not populated: %+v", stmt.Predicate)
	}
}

// --artifact self-digests the file into the subject; the bound digest must be
// a plain sha256 of the artifact bytes (the same the VSA binds to).
func TestRunArtifactSelfDigest(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "meta/wrangle_attestation_metadata.json",
		`{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}`)
	writeFile(t, dir, "meta/sbom.spdx.json", `{"spdxVersion":"SPDX-2.3","name":"x"}`)
	artifact := filepath.Join(dir, "pkg.tgz")
	if err := os.WriteFile(artifact, []byte("PKGBYTES"), 0o644); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte("PKGBYTES"))
	want := hex.EncodeToString(sum[:])
	out := filepath.Join(dir, "out.jsonl")

	var stderr bytes.Buffer
	rc := run([]string{
		"--metadata-root", filepath.Join(dir, "meta"),
		"--artifact", artifact,
		"--out", out,
	}, &stderr)
	if rc != 0 {
		t.Fatalf("run rc=%d stderr=%s", rc, stderr.String())
	}
	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	var stmt struct {
		Subject []struct {
			Digest map[string]string `json:"digest"`
		} `json:"subject"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(string(data))), &stmt); err != nil {
		t.Fatal(err)
	}
	if len(stmt.Subject) != 1 || stmt.Subject[0].Digest["sha256"] != want {
		t.Fatalf("expected self-digest %q, got %+v", want, stmt.Subject)
	}
}

func TestRunArtifactAndSubjectConflict(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "meta/wrangle_attestation_metadata.json",
		`{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}`)
	writeFile(t, dir, "meta/sbom.spdx.json", `{"spdxVersion":"SPDX-2.3"}`)
	artifact := filepath.Join(dir, "pkg.tgz")
	if err := os.WriteFile(artifact, []byte("X"), 0o644); err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	rc := run([]string{
		"--metadata-root", filepath.Join(dir, "meta"),
		"--subject", testArtifactDigest,
		"--artifact", artifact,
		"--out", filepath.Join(dir, "out.jsonl"),
	}, &stderr)
	if rc == 0 {
		t.Fatal("expected error when both --subject and --artifact are passed")
	}
}

func TestRunFlagValidation(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "meta/wrangle_attestation_metadata.json",
		`{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}`)
	writeFile(t, dir, "meta/sbom.spdx.json", `{"spdxVersion":"SPDX-2.3"}`)
	meta := filepath.Join(dir, "meta")
	out := filepath.Join(dir, "b.jsonl")

	cases := []struct {
		name string
		args []string
	}{
		{"no metadata-root", []string{"--subject", testArtifactDigest, "--out", out}},
		{"no subject", []string{"--metadata-root", meta, "--out", out}},
		{"no out", []string{"--metadata-root", meta, "--subject", testArtifactDigest}},
		{"bad subject", []string{"--metadata-root", meta, "--subject", "notadigest", "--out", out}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var stderr bytes.Buffer
			if rc := run(tc.args, &stderr); rc == 0 {
				t.Fatalf("expected non-zero exit, got 0")
			}
		})
	}
}

// A failure on any manifest must not leave a partially-written --out file.
func TestRunFailClosedNoOutput(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "ok/wrangle_attestation_metadata.json",
		`{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}`)
	writeFile(t, dir, "ok/sbom.spdx.json", `{"spdxVersion":"SPDX-2.3"}`)
	// Second root's canonical manifest names a result file that does not exist -> build fails.
	writeFile(t, dir, "broken/wrangle_attestation_metadata.json",
		`{"predicate-type":"https://spdx.dev/Document","result-file":"missing.json"}`)
	out := filepath.Join(dir, "out.jsonl")

	var stderr bytes.Buffer
	rc := run([]string{
		"--metadata-root", filepath.Join(dir, "ok"),
		"--metadata-root", filepath.Join(dir, "broken"),
		"--subject", testArtifactDigest,
		"--out", out,
	}, &stderr)
	if rc == 0 {
		t.Fatal("expected fail-closed exit")
	}
	if _, err := os.Stat(out); !os.IsNotExist(err) {
		t.Fatalf("expected no output file on a failed run, stat err=%v", err)
	}
}
