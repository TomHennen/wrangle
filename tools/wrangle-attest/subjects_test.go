package main

import "testing"

const testArtifactDigest = "sha256:011b95c8e47c538646a2c01df5373fe703381cd415c847357b3d563563eb1d95"

func TestNewSubject(t *testing.T) {
	d, err := newSubject(testArtifactDigest)
	if err != nil {
		t.Fatal(err)
	}
	if got := d.Digest["sha256"]; got != "011b95c8e47c538646a2c01df5373fe703381cd415c847357b3d563563eb1d95" {
		t.Fatalf("subject digest wrong: %q", got)
	}
	// Exactly one algorithm — the store rejects multi-digest subjects.
	if len(d.Digest) != 1 {
		t.Fatalf("expected a single-digest subject, got %d entries", len(d.Digest))
	}
}

func TestNewSubjectFailClosed(t *testing.T) {
	cases := []string{
		"",
		"sha256:",
		"011b95c8e47c538646a2c01df5373fe703381cd415c847357b3d563563eb1d95", // no algo prefix
		"sha512:011b95c8e47c538646a2c01df5373fe703381cd415c847357b3d563563eb1d95",
		"sha256:nothex",
		"sha256:011b95c8", // too short
	}
	for _, c := range cases {
		t.Run(c, func(t *testing.T) {
			if _, err := newSubject(c); err == nil {
				t.Fatalf("expected error for subject %q", c)
			}
		})
	}
}
