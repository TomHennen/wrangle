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
			name:    "valid scorecard passthrough",
			content: `{"predicate-type":"https://scorecard.dev/result/v0.1","result-file":"output.json"}`,
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
			writeFile(t, dir, "wrangle_attestation_metadata.json", tc.content)
			_, err := parseManifest(filepath.Join(dir, "wrangle_attestation_metadata.json"))
			if tc.wantErr && err == nil {
				t.Fatalf("expected error, got nil")
			}
			if !tc.wantErr && err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
		})
	}
}

func TestDiscoverManifestsCanonicalOnly(t *testing.T) {
	rootA := t.TempDir()
	rootB := t.TempDir()
	writeFile(t, rootA, "wrangle_attestation_metadata.json", `{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}`)
	writeFile(t, rootB, "wrangle_attestation_metadata.json", `{"predicate-type":"https://ossf.github.io/osv-schema/results","result-file":"results.json"}`)
	got, err := discoverManifests([]string{rootB, rootA})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 manifests, got %d", len(got))
	}
	// Deterministic order by dir regardless of root order.
	if got[0].dir > got[1].dir {
		t.Fatalf("manifests not sorted by dir: %s, %s", got[0].dir, got[1].dir)
	}
}

// A wrangle_attestation_metadata.json planted below the root (e.g. by a build-time dependency) is
// ignored — not signed and not an error — while the canonical top-level
// manifest is still honored.
func TestDiscoverManifestsIgnoresStrays(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "wrangle_attestation_metadata.json", `{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}`)
	writeFile(t, root, "sub/wrangle_attestation_metadata.json", `{"predicate-type":"https://evil.example/x","result-file":"r.json"}`)
	writeFile(t, root, "other/wrangle_attestation_metadata.json", `{"predicate-type":"https://evil.example/y","result-file":"r.json"}`)
	got, err := discoverManifests([]string{root})
	if err != nil {
		t.Fatalf("strays must not cause an error: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("expected only the canonical manifest, got %d", len(got))
	}
	if got[0].PredicateType != predicateSPDX {
		t.Fatalf("expected canonical SPDX manifest, got %q", got[0].PredicateType)
	}
}

// A scan/<tool>/wrangle_attestation_metadata.json is discovered alongside the
// top-level SBOM manifest (the bounded one-level lookup under <root>/scan/).
func TestDiscoverManifestsScanSubdir(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "wrangle_attestation_metadata.json", `{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}`)
	writeFile(t, root, "scan/osv/wrangle_attestation_metadata.json", `{"predicate-type":"https://github.com/TomHennen/wrangle/attestation/scan/v1","result-file":"output.sarif","tool":{"name":"osv-scanner","version":"1.0"},"result":"clean"}`)
	got, err := discoverManifests([]string{root})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("expected the SBOM + scan manifests, got %d", len(got))
	}
	var sawScan bool
	for _, m := range got {
		if m.PredicateType == predicateScanV1 {
			sawScan = true
		}
	}
	if !sawScan {
		t.Fatal("scan/osv manifest was not discovered")
	}
}

// The scan lookup is one level only: a manifest under scan/<tool>/sub/ is too
// deep and a top-level non-scan stray (e.g. evil/) is outside the honored
// locations — both ignored, neither an error.
func TestDiscoverManifestsScanBounded(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "wrangle_attestation_metadata.json", `{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}`)
	writeFile(t, root, "scan/osv/sub/wrangle_attestation_metadata.json", `{"predicate-type":"https://evil.example/x","result-file":"r.json"}`)
	writeFile(t, root, "evil/wrangle_attestation_metadata.json", `{"predicate-type":"https://evil.example/y","result-file":"r.json"}`)
	got, err := discoverManifests([]string{root})
	if err != nil {
		t.Fatalf("strays must not cause an error: %v", err)
	}
	if len(got) != 1 || got[0].PredicateType != predicateSPDX {
		t.Fatalf("expected only the canonical SBOM manifest, got %d", len(got))
	}
}

// A scan/<faketool>/ dir outside the allowlist is ignored — not signed, not an
// error — while an allowlisted sibling is still honored. Closes the "plant
// scan/evil/wrangle_attestation_metadata.json at a canonical-shaped path" forge.
func TestDiscoverManifestsScanAllowlist(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "scan/zizmor/wrangle_attestation_metadata.json", `{"predicate-type":"https://github.com/TomHennen/wrangle/attestation/scan/v1","result-file":"output.sarif","tool":{"name":"zizmor","version":"1.0"},"result":"clean"}`)
	writeFile(t, root, "scan/evil/wrangle_attestation_metadata.json", `{"predicate-type":"https://evil.example/x","result-file":"r.json"}`)
	got, err := discoverManifests([]string{root})
	if err != nil {
		t.Fatalf("a non-allowlisted scan dir must not cause an error: %v", err)
	}
	if len(got) != 1 || got[0].PredicateType != predicateScanV1 {
		t.Fatalf("expected only the allowlisted zizmor manifest, got %d", len(got))
	}
}

// A result-file symlinked out of its manifest dir is rejected at read time, even
// though it is lexically local. Closes the "symlink result-file to a sibling
// artifact / arbitrary file and get its content signed" forge.
func TestResultPathSymlinkEscape(t *testing.T) {
	root := t.TempDir()
	outside := filepath.Join(t.TempDir(), "secret.json")
	if err := os.WriteFile(outside, []byte(`{"x":1}`), 0o644); err != nil {
		t.Fatal(err)
	}
	mdir := filepath.Join(root, "md")
	if err := os.MkdirAll(mdir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(mdir, "sbom.spdx.json")); err != nil {
		t.Fatal(err)
	}
	m := manifest{PredicateType: predicateSPDX, ResultFile: "sbom.spdx.json", dir: mdir}
	if _, err := m.resultPath(); err == nil {
		t.Fatal("expected symlinked result-file to be rejected")
	}
}

// A result-file symlink that stays within the manifest dir resolves normally —
// the containment check rejects escapes, not all symlinks.
func TestResultPathSymlinkInDir(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "real.json"), []byte(`{"x":1}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("real.json", filepath.Join(dir, "sbom.spdx.json")); err != nil {
		t.Fatal(err)
	}
	m := manifest{PredicateType: predicateSPDX, ResultFile: "sbom.spdx.json", dir: dir}
	got, err := m.resultPath()
	if err != nil {
		t.Fatalf("an in-dir symlink must resolve: %v", err)
	}
	if want, _ := filepath.EvalSymlinks(filepath.Join(dir, "real.json")); got != want {
		t.Fatalf("resultPath = %q, want %q", got, want)
	}
}

// A malformed manifest at an honored scan/<tool>/ location fails closed.
func TestDiscoverManifestsScanFailClosed(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "scan/osv/wrangle_attestation_metadata.json", `{"bad`)
	if _, err := discoverManifests([]string{root}); err == nil {
		t.Fatal("expected discovery to fail closed on a malformed scan manifest")
	}
}

// A malformed canonical manifest fails the whole run (fail closed).
func TestDiscoverManifestsFailClosed(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "wrangle_attestation_metadata.json", `{"bad`)
	if _, err := discoverManifests([]string{root}); err == nil {
		t.Fatal("expected discovery to fail closed on a malformed canonical manifest")
	}
}

// A root with no canonical manifest contributes none and is not an error.
func TestDiscoverManifestsEmptyRoot(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "sub/wrangle_attestation_metadata.json", `{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}`)
	got, err := discoverManifests([]string{root})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Fatalf("expected no manifests, got %d", len(got))
	}
}

func TestDiscoverManifestsMissingRoot(t *testing.T) {
	if _, err := discoverManifests([]string{filepath.Join(t.TempDir(), "nope")}); err == nil {
		t.Fatal("expected error for missing metadata-root")
	}
}
