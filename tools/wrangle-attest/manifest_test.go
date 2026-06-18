package main

import (
	"os"
	"path/filepath"
	"testing"
)

func writeFile(t *testing.T, dir, name, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(filepath.Join(dir, name)), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestParseManifestFailClosed(t *testing.T) {
	cases := []struct {
		name    string
		content string
		wantErr bool
	}{
		{
			name:    "valid spdx passthrough",
			content: `{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}`,
		},
		{
			name:    "valid scan/v1 with tool and result",
			content: `{"predicate-type":"https://github.com/TomHennen/wrangle/attestation/scan/v1","result-file":"output.sarif","tool":{"name":"zizmor","version":"1.0"},"result":"findings"}`,
		},
		{
			name:    "missing predicate-type",
			content: `{"result-file":"sbom.spdx.json"}`,
			wantErr: true,
		},
		{
			name:    "missing result-file",
			content: `{"predicate-type":"https://spdx.dev/Document"}`,
			wantErr: true,
		},
		{
			name:    "unknown predicate-type",
			content: `{"predicate-type":"https://evil.example/x","result-file":"r.json"}`,
			wantErr: true,
		},
		{
			name:    "scan/v1 missing tool",
			content: `{"predicate-type":"https://github.com/TomHennen/wrangle/attestation/scan/v1","result-file":"output.sarif","result":"clean"}`,
			wantErr: true,
		},
		{
			name:    "scan/v1 invalid result value",
			content: `{"predicate-type":"https://github.com/TomHennen/wrangle/attestation/scan/v1","result-file":"output.sarif","tool":{"name":"z"},"result":"maybe"}`,
			wantErr: true,
		},
		{
			name:    "result-file path traversal",
			content: `{"predicate-type":"https://spdx.dev/Document","result-file":"../../etc/passwd"}`,
			wantErr: true,
		},
		{
			name:    "result-file nested traversal",
			content: `{"predicate-type":"https://spdx.dev/Document","result-file":"sub/../../etc/passwd"}`,
			wantErr: true,
		},
		{
			name:    "result-file absolute path",
			content: `{"predicate-type":"https://spdx.dev/Document","result-file":"/etc/passwd"}`,
			wantErr: true,
		},
		{
			name:    "unknown manifest field",
			content: `{"predicate-type":"https://spdx.dev/Document","result-file":"r.json","format":"spdx"}`,
			wantErr: true,
		},
		{
			name:    "malformed json",
			content: `{not json`,
			wantErr: true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			writeFile(t, dir, "manifest.json", tc.content)
			_, err := parseManifest(filepath.Join(dir, "manifest.json"))
			if tc.wantErr && err == nil {
				t.Fatalf("expected error, got nil")
			}
			if !tc.wantErr && err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
		})
	}
}

func TestDiscoverManifestsSortedAndFailClosed(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "go/b/manifest.json", `{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}`)
	writeFile(t, root, "go/a/manifest.json", `{"predicate-type":"https://ossf.github.io/osv-schema/results","result-file":"results.json"}`)
	got, err := discoverManifests([]string{root})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 manifests, got %d", len(got))
	}
	// Deterministic order: a before b.
	if filepath.Base(got[0].dir) != "a" || filepath.Base(got[1].dir) != "b" {
		t.Fatalf("manifests not sorted by dir: %s, %s", got[0].dir, got[1].dir)
	}

	// A second malformed manifest fails the whole walk.
	writeFile(t, root, "go/c/manifest.json", `{"bad`)
	if _, err := discoverManifests([]string{root}); err == nil {
		t.Fatal("expected discovery to fail closed on a malformed manifest")
	}
}

func TestDiscoverManifestsMissingRoot(t *testing.T) {
	if _, err := discoverManifests([]string{filepath.Join(t.TempDir(), "nope")}); err == nil {
		t.Fatal("expected error for missing metadata-root")
	}
}
