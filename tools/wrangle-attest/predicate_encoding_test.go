package main

import (
	"encoding/json"
	"testing"
)

// The predicate is a protobuf Struct (a map), so a passthrough result file is
// re-encoded rather than byte-preserved. Consumers must compare the predicate as
// JSON, never as bytes. Pinned here because SPEC.md claimed "verbatim" for a
// long time and the claim reads plausibly.
func TestPassthroughPredicateIsReEncodedNotBytePreserved(t *testing.T) {
	dir := t.TempDir()
	// Keys deliberately out of alphabetical order.
	raw := `{"zzz_last":"z","spdxVersion":"SPDX-2.3","aaa_first":"a","name":"x"}`
	writeFile(t, dir, "sbom.spdx.json", raw)
	writeFile(t, dir, "wrangle_attestation_metadata.json",
		`{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}`)

	m, err := parseManifest(dir + "/wrangle_attestation_metadata.json")
	if err != nil {
		t.Fatalf("parseManifest: %v", err)
	}
	pred, err := buildPredicate(m, "")
	if err != nil {
		t.Fatalf("buildPredicate: %v", err)
	}
	got, err := pred.MarshalJSON()
	if err != nil {
		t.Fatalf("MarshalJSON: %v", err)
	}

	if string(got) == raw {
		t.Fatal("predicate is byte-identical to the result file; the re-encoding this test pins has changed — update SPEC.md, which documents that it is NOT byte-preserved")
	}

	// Semantically identical is the invariant that DOES hold.
	var want, have map[string]any
	if err := json.Unmarshal([]byte(raw), &want); err != nil {
		t.Fatalf("unmarshal raw: %v", err)
	}
	if err := json.Unmarshal(got, &have); err != nil {
		t.Fatalf("unmarshal predicate: %v", err)
	}
	if len(want) != len(have) {
		t.Fatalf("key count: got %d, want %d", len(have), len(want))
	}
	for k, v := range want {
		if have[k] != v {
			t.Errorf("key %q: got %v, want %v", k, have[k], v)
		}
	}
}
