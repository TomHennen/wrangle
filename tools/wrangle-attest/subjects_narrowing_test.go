package main

// The engine's subject rule is deliberately NARROWER than in-toto's: sha256
// only, lowercase hex, exactly one digest. in-toto's ResourceDescriptor.Validate
// accepts custom/unsupported algorithms outright and hex-decodes uppercase, so
// upstream validation is spec conformance, not our policy. These tests exist to
// prove that refactors onto upstream primitives (hasher, in-toto) never widen
// the rule back out.

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	intoto "github.com/in-toto/attestation/go/v1"
)

const (
	loHex64 = "011b95c8e47c538646a2c01df5373fe703381cd415c847357b3d563563eb1d95"
	hex128  = loHex64 + loHex64
	hex96   = loHex64 + "011b95c8e47c538646a2c01df5373fe703381cd415c847357b"
)

// narrowingCases are subjects in-toto would tolerate (or that are otherwise
// digest-shaped) which the engine MUST reject.
var narrowingCases = []struct {
	name    string
	subject string
}{
	{"sha512 valid per in-toto", "sha512:" + hex128},
	{"sha384 valid per in-toto", "sha384:" + hex96},
	{"sha256 uppercase hex (hex.DecodeString would accept)", "sha256:" + strings.ToUpper(loHex64)},
	{"sha256 one hex char short", "sha256:" + loHex64[:63]},
	{"sha256 one hex char long", "sha256:" + loHex64 + "a"},
	{"custom algo (in-toto allows unsupported algos)", "foo:deadbeef"},
	{"multi-digest subject", "sha256:" + loHex64 + ",sha512:" + hex128},
}

// Proof that the quirks above are real: these subjects pass in-toto's own
// descriptor validation, so our regex — not upstream — is what rejects them.
func TestInTotoValidateIsLooserThanOurs(t *testing.T) {
	cases := []struct {
		name   string
		digest map[string]string
	}{
		{"custom algo", map[string]string{"foo": "whatever"}},
		{"uppercase sha256", map[string]string{"sha256": strings.ToUpper(loHex64)}},
		{"multi-digest", map[string]string{"sha256": loHex64, "sha512": hex128}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rd := &intoto.ResourceDescriptor{Digest: tc.digest}
			if err := rd.Validate(); err != nil {
				t.Fatalf("in-toto rejected %v (%v); this test's premise — that our narrowing is load-bearing — needs rechecking", tc.digest, err)
			}
		})
	}
}

// The --subject path must reject every narrowing case.
func TestNewSubjectNarrowingHolds(t *testing.T) {
	for _, tc := range narrowingCases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := newSubject(tc.subject); err == nil {
				t.Fatalf("subject %q accepted; the sha256-only narrowing has regressed", tc.subject)
			}
		})
	}
}

// The same narrowing must hold end-to-end through run(), writing nothing.
func TestRunSubjectNarrowingFailsClosed(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "meta/wrangle_attestation_metadata.json",
		`{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}`)
	writeFile(t, dir, "meta/sbom.spdx.json", `{"spdxVersion":"SPDX-2.3"}`)

	for _, tc := range narrowingCases {
		t.Run(tc.name, func(t *testing.T) {
			out := filepath.Join(t.TempDir(), "out.jsonl")
			var stderr bytes.Buffer
			rc := run([]string{"--metadata-root", filepath.Join(dir, "meta"),
				"--subject", tc.subject, "--out", out}, &stderr)
			if rc != 2 {
				t.Fatalf("subject %q: rc=%d, want fail-closed 2; stderr=%s", tc.subject, rc, stderr.String())
			}
			if _, err := os.Stat(out); !os.IsNotExist(err) {
				t.Fatalf("subject %q: output written despite rejection", tc.subject)
			}
		})
	}
}

// assemble's --subjects-file path must reject the same set. An uppercase-hex or
// otherwise non-matching subject falls through to the file branch, where the
// (nonexistent) path fails closed — never a silently mis-bound digest.
func TestAssembleSubjectNarrowingFailsClosed(t *testing.T) {
	meta := writeAssembleMeta(t)
	provenance := writeTempFile(t, "provenance.jsonl", "{\"provenance\":true}\n")

	for _, tc := range narrowingCases {
		t.Run(tc.name, func(t *testing.T) {
			ss := &seqSigner{}
			swapSigner(t, func() (statementSigner, func(), error) { return ss, func() {}, nil })
			subjects := writeTempFile(t, "subjects", tc.subject+"\n")
			out := t.TempDir()
			bundleDir := filepath.Join(out, "bundles")
			stmtsOut := filepath.Join(out, "statements.jsonl")

			var stderr bytes.Buffer
			rc := run(assembleArgs(meta, subjects, provenance, bundleDir, stmtsOut), &stderr)
			if rc != 2 {
				t.Fatalf("subject %q: rc=%d, want fail-closed 2; stderr=%s", tc.subject, rc, stderr.String())
			}
			if _, err := os.Stat(bundleDir); !os.IsNotExist(err) {
				t.Fatalf("subject %q: bundle dir created despite rejection", tc.subject)
			}
			if _, err := os.Stat(stmtsOut); !os.IsNotExist(err) {
				t.Fatalf("subject %q: statements-out written despite rejection", tc.subject)
			}
			if ss.calls != 0 {
				t.Fatalf("subject %q: signer ran on a rejected subject", tc.subject)
			}
		})
	}
}

// hasher must never hand back a non-sha256 or Uri/Name-bearing descriptor: its
// default algorithm set is sha256+sha512, and its FileHashSet helper stamps the
// local path into Uri/Name.
func TestSubjectDescriptorIsSha256AndDigestOnly(t *testing.T) {
	artifact := filepath.Join(t.TempDir(), "pkg.tgz")
	if err := os.WriteFile(artifact, []byte("PKGBYTES"), 0o644); err != nil {
		t.Fatal(err)
	}
	digest, err := digestArtifact(artifact)
	if err != nil {
		t.Fatal(err)
	}
	if !sha256DigestRe.MatchString(digest) {
		t.Fatalf("digestArtifact returned %q, want sha256:<64 lowercase hex>", digest)
	}

	for name, subject := range map[string]string{
		"self-digested artifact": digest,
		"passed digest":          testArtifactDigest,
	} {
		t.Run(name, func(t *testing.T) {
			rd, err := newSubject(subject)
			if err != nil {
				t.Fatal(err)
			}
			if len(rd.GetDigest()) != 1 || rd.GetDigest()["sha256"] == "" {
				t.Fatalf("descriptor must carry exactly one sha256 digest, got %v", rd.GetDigest())
			}
			// Uri/Name would leak local filesystem paths into signed statements.
			if rd.GetUri() != "" || rd.GetName() != "" {
				t.Fatalf("descriptor must be digest-only, got uri=%q name=%q", rd.GetUri(), rd.GetName())
			}
		})
	}
}
