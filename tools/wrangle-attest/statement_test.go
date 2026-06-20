package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// goldenStatement asserts that building a statement from a manifest + the fixed
// subject produces exactly the golden JSON. Golden files pin the on-the-wire
// shape both consumers (policy CEL) and the later SARIF-producer PRs depend on;
// regenerate with -update when the contract intentionally changes.
func TestBuildStatementGolden(t *testing.T) {
	cases := []struct {
		name       string
		manifest   string
		resultName string
		result     string
		golden     string
	}{
		{
			name:       "sbom passthrough",
			manifest:   `{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}`,
			resultName: "sbom.spdx.json",
			result:     `{"spdxVersion":"SPDX-2.3","name":"test","SPDXID":"SPDXRef-DOCUMENT","packages":[{"name":"pkg","SPDXID":"SPDXRef-pkg"}]}`,
			golden:     "testdata/sbom.statement.json",
		},
		{
			name:       "scorecard passthrough",
			manifest:   `{"predicate-type":"https://scorecard.dev/result/v0.1","result-file":"output.json"}`,
			resultName: "output.json",
			result:     `{"date":"2026-06-20T00:00:00Z","repo":{"name":"github.com/TomHennen/wrangle"},"score":7.4,"checks":[{"name":"Branch-Protection","score":3,"reason":"not maximal"}]}`,
			golden:     "testdata/scorecard.statement.json",
		},
		{
			name:       "scan/v1 sarif envelope",
			manifest:   `{"predicate-type":"https://github.com/TomHennen/wrangle/attestation/scan/v1","result-file":"output.sarif","tool":{"name":"zizmor","version":"1.13.0"},"result":"findings"}`,
			resultName: "output.sarif",
			result:     `{"version":"2.1.0","$schema":"https://json.schemastore.org/sarif-2.1.0.json","runs":[{"tool":{"driver":{"name":"zizmor"}},"results":[]}]}`,
			golden:     "testdata/scan.statement.json",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			writeFile(t, dir, "wrangle_attestation_metadata.json", tc.manifest)
			writeFile(t, dir, tc.resultName, tc.result)
			m, err := parseManifest(filepath.Join(dir, "wrangle_attestation_metadata.json"))
			if err != nil {
				t.Fatal(err)
			}
			subj, err := newSubject(testArtifactDigest)
			if err != nil {
				t.Fatal(err)
			}
			stmt, err := buildStatement(m, subj, "5741a1afbdffa5eb9ab95dd212ce8c310631e355")
			if err != nil {
				t.Fatal(err)
			}
			got, err := marshalStatement(stmt)
			if err != nil {
				t.Fatal(err)
			}
			assertGolden(t, tc.golden, got)
		})
	}
}

// Scorecard's value is the score; verify the passthrough predicate carries
// predicateType and predicate.score verbatim (a downstream tenet gates on it).
func TestBuildStatementScorecardScore(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "wrangle_attestation_metadata.json", `{"predicate-type":"https://scorecard.dev/result/v0.1","result-file":"output.json"}`)
	writeFile(t, dir, "output.json", `{"score":7.4,"checks":[{"name":"Branch-Protection","score":3}]}`)
	m, err := parseManifest(filepath.Join(dir, "wrangle_attestation_metadata.json"))
	if err != nil {
		t.Fatal(err)
	}
	subj, err := newSubject(testArtifactDigest)
	if err != nil {
		t.Fatal(err)
	}
	stmt, err := buildStatement(m, subj, "")
	if err != nil {
		t.Fatal(err)
	}
	got, err := marshalStatement(stmt)
	if err != nil {
		t.Fatal(err)
	}
	var parsed struct {
		PredicateType string `json:"predicateType"`
		Predicate     struct {
			Score float64 `json:"score"`
		} `json:"predicate"`
	}
	if err := json.Unmarshal(got, &parsed); err != nil {
		t.Fatal(err)
	}
	if parsed.PredicateType != predicateScorecard {
		t.Fatalf("predicateType = %q, want %q", parsed.PredicateType, predicateScorecard)
	}
	if parsed.Predicate.Score != 7.4 {
		t.Fatalf("predicate.score = %v, want 7.4", parsed.Predicate.Score)
	}
}

func TestBuildStatementFailClosed(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "wrangle_attestation_metadata.json", `{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}`)
	m, err := parseManifest(filepath.Join(dir, "wrangle_attestation_metadata.json"))
	if err != nil {
		t.Fatal(err)
	}
	subj, _ := newSubject(testArtifactDigest)

	// Missing result file.
	if _, err := buildStatement(m, subj, ""); err == nil {
		t.Fatal("expected error for missing result file")
	}

	// A predicate that is a JSON array, not an object, must fail.
	writeFile(t, dir, "sbom.spdx.json", `[1,2,3]`)
	if _, err := buildStatement(m, subj, ""); err == nil {
		t.Fatal("expected error for non-object predicate")
	}
}

// assertGolden compares got to the golden file, normalizing both through a
// generic JSON round-trip so formatting differences don't cause spurious fails.
// Run `go test -update` to (re)write golden files.
func assertGolden(t *testing.T, path string, got []byte) {
	t.Helper()
	if *update {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		pretty := mustIndent(t, got)
		if err := os.WriteFile(path, pretty, 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read golden %s: %v (run go test -update)", path, err)
	}
	if !jsonEqual(t, got, want) {
		t.Fatalf("statement mismatch for %s:\ngot:  %s\nwant: %s", path, mustIndent(t, got), want)
	}
}

func jsonEqual(t *testing.T, a, b []byte) bool {
	t.Helper()
	var av, bv any
	if err := json.Unmarshal(a, &av); err != nil {
		t.Fatalf("unmarshal got: %v", err)
	}
	if err := json.Unmarshal(b, &bv); err != nil {
		t.Fatalf("unmarshal want: %v", err)
	}
	ab, _ := json.Marshal(av)
	bb, _ := json.Marshal(bv)
	return string(ab) == string(bb)
}

func mustIndent(t *testing.T, raw []byte) []byte {
	t.Helper()
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	out, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	return append(out, '\n')
}
