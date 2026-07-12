package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// seqSigner emits a distinct line per sign call so bundle content and order
// are byte-checkable, recording each input statement.
type seqSigner struct {
	calls    int
	inputs   [][]byte
	failFrom int
}

func (s *seqSigner) sign(stmt []byte) ([]byte, error) {
	s.calls++
	s.inputs = append(s.inputs, append([]byte(nil), stmt...))
	if s.failFrom > 0 && s.calls >= s.failFrom {
		return nil, errors.New("transient sigstore blip")
	}
	return []byte(fmt.Sprintf(`{"signed":%d}`, s.calls)), nil
}

// writeAssembleMeta lays out a metadata root with the release SBOM manifest
// plus one scan/<tool>/ manifest (discovery order: root, then scan/osv).
func writeAssembleMeta(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	writeFile(t, dir, "wrangle_attestation_metadata.json",
		`{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}`)
	writeFile(t, dir, "sbom.spdx.json", `{"spdxVersion":"SPDX-2.3","name":"x"}`)
	writeFile(t, dir, "scan/osv/wrangle_attestation_metadata.json",
		`{"predicate-type":"https://github.com/TomHennen/wrangle/attestation/scan/v1","result-file":"output.sarif","tool":{"name":"osv-scanner","version":"1.0"},"result":"clean"}`)
	writeFile(t, dir, "scan/osv/output.sarif", `{"version":"2.1.0","runs":[]}`)
	return dir
}

// assembleArgs builds a full valid assemble arg vector; callers override
// fields by reslicing or appending.
func assembleArgs(meta, subjectsFile, provenance, bundleDir, statementsOut string) []string {
	return []string{"assemble",
		"--metadata-root", meta,
		"--subjects-file", subjectsFile,
		"--provenance", provenance,
		"--sign",
		"--bundle-dir", bundleDir,
		"--statements-out", statementsOut,
	}
}

func writeTempFile(t *testing.T, name, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestAssembleGoldenBundles(t *testing.T) {
	ss := &seqSigner{}
	swapSigner(t, func() (statementSigner, func(), error) { return ss, func() {}, nil })

	meta := writeAssembleMeta(t)
	dist := writeTempFile(t, "pkg.tgz", "PKGBYTES")
	sum := sha256.Sum256([]byte("PKGBYTES"))
	distDigest := hex.EncodeToString(sum[:])
	subjects := writeTempFile(t, "subjects", dist+"\n"+testArtifactDigest+"\n")
	const provenanceContent = "{\"provenance\":true}\n"
	provenance := writeTempFile(t, "provenance.jsonl", provenanceContent)
	out := t.TempDir()
	bundleDir := filepath.Join(out, "bundles")
	stmtsOut := filepath.Join(out, "statements.jsonl")

	var stderr bytes.Buffer
	rc := run(append(assembleArgs(meta, subjects, provenance, bundleDir, stmtsOut),
		"--commit", "deadbeef"), &stderr)
	if rc != 0 {
		t.Fatalf("run rc=%d stderr=%s", rc, stderr.String())
	}

	// Statement order: subjects in input order, manifests in discovery order
	// (root SBOM before scan/osv).
	lines := []string{`{"signed":1}`, `{"signed":2}`, `{"signed":3}`, `{"signed":4}`}
	wantBundles := map[string]string{
		"pkg.tgz.intoto.jsonl": provenanceContent + lines[0] + "\n" + lines[1] + "\n",
		"sha256-011b95c8e47c538646a2c01df5373fe703381cd415c847357b3d563563eb1d95.intoto.jsonl": provenanceContent + lines[2] + "\n" + lines[3] + "\n",
	}
	for name, want := range wantBundles {
		got, err := os.ReadFile(filepath.Join(bundleDir, name))
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != want {
			t.Fatalf("bundle %s mismatch:\n got: %q\nwant: %q", name, got, want)
		}
	}
	got, err := os.ReadFile(stmtsOut)
	if err != nil {
		t.Fatal(err)
	}
	if want := strings.Join(lines, "\n") + "\n"; string(got) != want {
		t.Fatalf("statements-out mismatch:\n got: %q\nwant: %q", got, want)
	}

	// The file subject self-digests; the digest subject passes through; the
	// scan/v1 statements carry the woven commit.
	if len(ss.inputs) != 4 {
		t.Fatalf("sign calls = %d, want 4", len(ss.inputs))
	}
	for i, wantDigest := range []string{distDigest, distDigest,
		strings.TrimPrefix(testArtifactDigest, "sha256:"), strings.TrimPrefix(testArtifactDigest, "sha256:")} {
		if !bytes.Contains(ss.inputs[i], []byte(wantDigest)) {
			t.Fatalf("statement %d not bound to %s: %s", i, wantDigest, ss.inputs[i])
		}
	}
	for _, i := range []int{1, 3} {
		if !bytes.Contains(ss.inputs[i], []byte(`"scannedCommit":"deadbeef"`)) {
			t.Fatalf("scan statement %d missing woven commit: %s", i, ss.inputs[i])
		}
	}
}

// A provenance without a trailing newline must be reproduced verbatim: the first
// signed line concatenates onto the provenance's last line, exactly as the shell's
// cp + `printf '%s\n' >>` would.
func TestAssembleProvenanceWithoutTrailingNewline(t *testing.T) {
	ss := &seqSigner{}
	swapSigner(t, func() (statementSigner, func(), error) { return ss, func() {}, nil })

	meta := writeAssembleMeta(t)
	subjects := writeTempFile(t, "subjects", testArtifactDigest+"\n")
	provenance := writeTempFile(t, "provenance.jsonl", `{"provenance":true}`)
	out := t.TempDir()
	bundleDir := filepath.Join(out, "bundles")
	stmtsOut := filepath.Join(out, "statements.jsonl")

	var stderr bytes.Buffer
	if rc := run(assembleArgs(meta, subjects, provenance, bundleDir, stmtsOut), &stderr); rc != 0 {
		t.Fatalf("run rc=%d stderr=%s", rc, stderr.String())
	}
	got, err := os.ReadFile(filepath.Join(bundleDir,
		"sha256-011b95c8e47c538646a2c01df5373fe703381cd415c847357b3d563563eb1d95.intoto.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"provenance":true}{"signed":1}` + "\n" + `{"signed":2}` + "\n"; string(got) != want {
		t.Fatalf("bundle mismatch:\n got: %q\nwant: %q", got, want)
	}
}

func TestAssembleSubjectsBlankLinesDropped(t *testing.T) {
	ss := &seqSigner{}
	swapSigner(t, func() (statementSigner, func(), error) { return ss, func() {}, nil })

	meta := writeAssembleMeta(t)
	subjects := writeTempFile(t, "subjects", "\n \t\n"+testArtifactDigest+"\n\n   \n")
	provenance := writeTempFile(t, "provenance.jsonl", "{\"provenance\":true}\n")
	out := t.TempDir()
	bundleDir := filepath.Join(out, "bundles")

	var stderr bytes.Buffer
	if rc := run(assembleArgs(meta, subjects, provenance, bundleDir,
		filepath.Join(out, "statements.jsonl")), &stderr); rc != 0 {
		t.Fatalf("run rc=%d stderr=%s", rc, stderr.String())
	}
	entries, err := os.ReadDir(bundleDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("bundle count = %d, want 1 (blank subject lines dropped)", len(entries))
	}
}

func TestAssembleFailClosed(t *testing.T) {
	newFixture := func(t *testing.T) (meta, provenance string) {
		return writeAssembleMeta(t), writeTempFile(t, "provenance.jsonl", "{\"provenance\":true}\n")
	}

	// Every failing case must leave the bundle dir uncreated and the
	// statements file unwritten.
	runWantFail := func(t *testing.T, args []string, wantErr string) {
		t.Helper()
		ss := &seqSigner{}
		swapSigner(t, func() (statementSigner, func(), error) { return ss, func() {}, nil })
		out := t.TempDir()
		bundleDir := filepath.Join(out, "bundles")
		stmtsOut := filepath.Join(out, "statements.jsonl")
		full := append(args, "--bundle-dir", bundleDir, "--statements-out", stmtsOut)
		var stderr bytes.Buffer
		if rc := run(full, &stderr); rc != 2 {
			t.Fatalf("rc=%d, want fail-closed 2; stderr=%s", rc, stderr.String())
		}
		if wantErr != "" && !strings.Contains(stderr.String(), wantErr) {
			t.Fatalf("stderr %q does not mention %q", stderr.String(), wantErr)
		}
		if _, err := os.Stat(bundleDir); !os.IsNotExist(err) {
			t.Fatalf("bundle dir created despite failure, stat err=%v", err)
		}
		if _, err := os.Stat(stmtsOut); !os.IsNotExist(err) {
			t.Fatalf("statements-out written despite failure, stat err=%v", err)
		}
	}

	t.Run("empty subjects file", func(t *testing.T) {
		meta, provenance := newFixture(t)
		subjects := writeTempFile(t, "subjects", "\n  \n\t\n")
		runWantFail(t, []string{"assemble", "--metadata-root", meta,
			"--subjects-file", subjects, "--provenance", provenance, "--sign"}, "no subjects to sign")
	})

	t.Run("missing subjects file", func(t *testing.T) {
		meta, provenance := newFixture(t)
		runWantFail(t, []string{"assemble", "--metadata-root", meta,
			"--subjects-file", filepath.Join(t.TempDir(), "nope"), "--provenance", provenance, "--sign"}, "")
	})

	t.Run("subject classification", func(t *testing.T) {
		meta, provenance := newFixture(t)
		sha512Hex := strings.Repeat("ab", 64)
		cases := []struct {
			name    string
			subject string
			wantErr string
		}{
			{"sha512 digest", "sha512:" + sha512Hex, "must be sha256:<64-hex>"},
			{"short sha256 digest", "sha256:abcd", "must be sha256:<64-hex>"},
			{"missing file", filepath.Join(t.TempDir(), "nope.tgz"), "artifact"},
		}
		for _, tc := range cases {
			t.Run(tc.name, func(t *testing.T) {
				subjects := writeTempFile(t, "subjects", tc.subject+"\n")
				runWantFail(t, []string{"assemble", "--metadata-root", meta,
					"--subjects-file", subjects, "--provenance", provenance, "--sign"}, tc.wantErr)
			})
		}
	})

	t.Run("duplicate bundle basename in set", func(t *testing.T) {
		meta, provenance := newFixture(t)
		a := filepath.Join(t.TempDir(), "pkg.tgz")
		b := filepath.Join(t.TempDir(), "pkg.tgz")
		for _, p := range []string{a, b} {
			if err := os.WriteFile(p, []byte("X"), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		subjects := writeTempFile(t, "subjects", a+"\n"+b+"\n")
		runWantFail(t, []string{"assemble", "--metadata-root", meta,
			"--subjects-file", subjects, "--provenance", provenance, "--sign"}, "duplicate bundle basename")
	})

	t.Run("zero manifests", func(t *testing.T) {
		_, provenance := newFixture(t)
		subjects := writeTempFile(t, "subjects", testArtifactDigest+"\n")
		runWantFail(t, []string{"assemble", "--metadata-root", t.TempDir(),
			"--subjects-file", subjects, "--provenance", provenance, "--sign"}, "no signed metadata produced for")
	})

	t.Run("missing provenance", func(t *testing.T) {
		meta, _ := newFixture(t)
		subjects := writeTempFile(t, "subjects", testArtifactDigest+"\n")
		runWantFail(t, []string{"assemble", "--metadata-root", meta,
			"--subjects-file", subjects, "--provenance", filepath.Join(t.TempDir(), "nope"), "--sign"}, "provenance")
	})

	t.Run("empty provenance", func(t *testing.T) {
		meta, _ := newFixture(t)
		subjects := writeTempFile(t, "subjects", testArtifactDigest+"\n")
		runWantFail(t, []string{"assemble", "--metadata-root", meta,
			"--subjects-file", subjects, "--provenance", writeTempFile(t, "provenance", ""), "--sign"}, "empty")
	})

	t.Run("signer fails on last statement", func(t *testing.T) {
		meta, provenance := newFixture(t)
		dist := writeTempFile(t, "pkg.tgz", "PKGBYTES")
		subjects := writeTempFile(t, "subjects", dist+"\n"+testArtifactDigest+"\n")
		// 2 subjects x 2 manifests: calls 1-3 succeed, the last one fails.
		ss := &seqSigner{failFrom: 4}
		swapSigner(t, func() (statementSigner, func(), error) { return ss, func() {}, nil })
		out := t.TempDir()
		bundleDir := filepath.Join(out, "bundles")
		stmtsOut := filepath.Join(out, "statements.jsonl")
		var stderr bytes.Buffer
		if rc := run([]string{"assemble", "--metadata-root", meta,
			"--subjects-file", subjects, "--provenance", provenance, "--sign",
			"--bundle-dir", bundleDir, "--statements-out", stmtsOut}, &stderr); rc != 2 {
			t.Fatalf("rc=%d, want fail-closed 2; stderr=%s", rc, stderr.String())
		}
		if ss.calls != 4 {
			t.Fatalf("sign calls = %d, want 4", ss.calls)
		}
		if _, err := os.Stat(bundleDir); !os.IsNotExist(err) {
			t.Fatalf("bundle dir created despite failure, stat err=%v", err)
		}
		if _, err := os.Stat(stmtsOut); !os.IsNotExist(err) {
			t.Fatalf("statements-out written despite failure, stat err=%v", err)
		}
	})
}

// An uppercase-hex digest-looking subject does not match the shell classifier
// and is treated as a file path — created on disk here, so it self-digests.
func TestAssembleUppercaseDigestIsFilePath(t *testing.T) {
	ss := &seqSigner{}
	swapSigner(t, func() (statementSigner, func(), error) { return ss, func() {}, nil })

	meta := writeAssembleMeta(t)
	dir := t.TempDir()
	name := "sha256:" + strings.ToUpper("011b95c8e47c538646a2c01df5373fe703381cd415c847357b3d563563eb1d95")
	subjectFile := filepath.Join(dir, name)
	if err := os.WriteFile(subjectFile, []byte("FILEBYTES"), 0o644); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte("FILEBYTES"))
	subjects := writeTempFile(t, "subjects", subjectFile+"\n")
	provenance := writeTempFile(t, "provenance.jsonl", "{\"provenance\":true}\n")
	out := t.TempDir()
	bundleDir := filepath.Join(out, "bundles")

	var stderr bytes.Buffer
	if rc := run(assembleArgs(meta, subjects, provenance, bundleDir,
		filepath.Join(out, "statements.jsonl")), &stderr); rc != 0 {
		t.Fatalf("run rc=%d stderr=%s", rc, stderr.String())
	}
	if _, err := os.Stat(filepath.Join(bundleDir, strings.ReplaceAll(name, ":", "-")+".intoto.jsonl")); err != nil {
		t.Fatalf("expected bundle named from the file basename: %v", err)
	}
	if !bytes.Contains(ss.inputs[0], []byte(hex.EncodeToString(sum[:]))) {
		t.Fatalf("statement not bound to the file's self-digest: %s", ss.inputs[0])
	}
}

func TestAssembleRefusesPreexistingBundle(t *testing.T) {
	ss := &seqSigner{}
	swapSigner(t, func() (statementSigner, func(), error) { return ss, func() {}, nil })

	meta := writeAssembleMeta(t)
	subjects := writeTempFile(t, "subjects", testArtifactDigest+"\n")
	provenance := writeTempFile(t, "provenance.jsonl", "{\"provenance\":true}\n")
	out := t.TempDir()
	bundleDir := filepath.Join(out, "bundles")
	const bundleName = "sha256-011b95c8e47c538646a2c01df5373fe703381cd415c847357b3d563563eb1d95.intoto.jsonl"
	writeFile(t, bundleDir, bundleName, "already here\n")
	stmtsOut := filepath.Join(out, "statements.jsonl")

	var stderr bytes.Buffer
	if rc := run(assembleArgs(meta, subjects, provenance, bundleDir, stmtsOut), &stderr); rc != 2 {
		t.Fatalf("rc=%d, want fail-closed 2; stderr=%s", rc, stderr.String())
	}
	if !strings.Contains(stderr.String(), "refusing to clobber") {
		t.Fatalf("stderr %q does not refuse to clobber", stderr.String())
	}
	got, err := os.ReadFile(filepath.Join(bundleDir, bundleName))
	if err != nil || string(got) != "already here\n" {
		t.Fatalf("pre-existing bundle modified: %q err=%v", got, err)
	}
	if ss.calls != 0 {
		t.Fatalf("sign calls = %d, want 0 (collision detected before signing)", ss.calls)
	}
}

func referrerLine(t *testing.T, predicateType, marker string) string {
	t.Helper()
	payload := base64.StdEncoding.EncodeToString(
		[]byte(fmt.Sprintf(`{"predicateType":%q,"predicate":{}}`, predicateType)))
	// Deliberate whitespace: byte-equality below proves raw passthrough, not a
	// re-marshal.
	return fmt.Sprintf(`{"dsseEnvelope": {"payload": %q},  "marker": %q}`, payload, marker)
}

func TestAssembleProvenanceReferrers(t *testing.T) {
	ss := &seqSigner{}
	swapSigner(t, func() (statementSigner, func(), error) { return ss, func() {}, nil })

	meta := writeAssembleMeta(t)
	subjects := writeTempFile(t, "subjects", testArtifactDigest+"\n")
	prov1 := referrerLine(t, "https://slsa.dev/provenance/v1", "prov-1")
	vsa := referrerLine(t, "https://slsa.dev/verification_summary/v1", "vsa")
	prov2 := referrerLine(t, "https://slsa.dev/provenance/v1", "prov-2")
	referrers := writeTempFile(t, "referrers.jsonl", prov1+"\n"+vsa+"\n"+prov2+"\n")
	out := t.TempDir()
	bundleDir := filepath.Join(out, "bundles")
	stmtsOut := filepath.Join(out, "statements.jsonl")

	var stderr bytes.Buffer
	rc := run([]string{"assemble", "--metadata-root", meta, "--subjects-file", subjects,
		"--provenance-referrers", referrers, "--sign",
		"--bundle-dir", bundleDir, "--statements-out", stmtsOut}, &stderr)
	if rc != 0 {
		t.Fatalf("run rc=%d stderr=%s", rc, stderr.String())
	}
	got, err := os.ReadFile(filepath.Join(bundleDir,
		"sha256-011b95c8e47c538646a2c01df5373fe703381cd415c847357b3d563563eb1d95.intoto.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	want := prov1 + "\n" + prov2 + "\n" + `{"signed":1}` + "\n" + `{"signed":2}` + "\n"
	if string(got) != want {
		t.Fatalf("bundle mismatch:\n got: %q\nwant: %q", got, want)
	}
}

func TestAssembleProvenanceReferrersFailClosed(t *testing.T) {
	meta := writeAssembleMeta(t)
	prov := referrerLine(t, "https://slsa.dev/provenance/v1", "prov")

	cases := []struct {
		name    string
		content string
		wantErr string
	}{
		{"no provenance match", referrerLine(t, "https://slsa.dev/verification_summary/v1", "vsa") + "\n",
			"no SLSA provenance referrer"},
		{"empty file", "", "no SLSA provenance referrer"},
		{"bad envelope JSON", "not json\n" + prov + "\n", "malformed DSSE envelope"},
		{"bad payload base64", `{"dsseEnvelope":{"payload":"%%%"}}` + "\n" + prov + "\n",
			"malformed DSSE payload base64"},
		{"bad payload JSON", `{"dsseEnvelope":{"payload":"` +
			base64.StdEncoding.EncodeToString([]byte("not json")) + `"}}` + "\n" + prov + "\n",
			"malformed DSSE payload JSON"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ss := &seqSigner{}
			swapSigner(t, func() (statementSigner, func(), error) { return ss, func() {}, nil })
			subjects := writeTempFile(t, "subjects", testArtifactDigest+"\n")
			referrers := writeTempFile(t, "referrers.jsonl", tc.content)
			out := t.TempDir()
			bundleDir := filepath.Join(out, "bundles")
			var stderr bytes.Buffer
			rc := run([]string{"assemble", "--metadata-root", meta, "--subjects-file", subjects,
				"--provenance-referrers", referrers, "--sign",
				"--bundle-dir", bundleDir, "--statements-out", filepath.Join(out, "statements.jsonl")}, &stderr)
			if rc != 2 {
				t.Fatalf("rc=%d, want fail-closed 2; stderr=%s", rc, stderr.String())
			}
			if !strings.Contains(stderr.String(), tc.wantErr) {
				t.Fatalf("stderr %q does not mention %q", stderr.String(), tc.wantErr)
			}
			if _, err := os.Stat(bundleDir); !os.IsNotExist(err) {
				t.Fatalf("bundle dir created despite failure, stat err=%v", err)
			}
			if ss.calls != 0 {
				t.Fatalf("sign calls = %d, want 0 (provenance validated before signing)", ss.calls)
			}
		})
	}
}

func TestAssembleFlagValidation(t *testing.T) {
	ss := &seqSigner{}
	swapSigner(t, func() (statementSigner, func(), error) { return ss, func() {}, nil })

	meta := writeAssembleMeta(t)
	subjects := writeTempFile(t, "subjects", testArtifactDigest+"\n")
	provenance := writeTempFile(t, "provenance.jsonl", "{\"provenance\":true}\n")
	out := t.TempDir()
	bundleDir := filepath.Join(out, "bundles")
	stmtsOut := filepath.Join(out, "statements.jsonl")

	base := func() []string { return assembleArgs(meta, subjects, provenance, bundleDir, stmtsOut) }
	drop := func(flag string) []string {
		var args []string
		src := base()
		for i := 0; i < len(src); i++ {
			if src[i] == flag {
				if flag != "--sign" {
					i++
				}
				continue
			}
			args = append(args, src[i])
		}
		return args
	}

	cases := []struct {
		name string
		args []string
	}{
		{"no metadata-root", drop("--metadata-root")},
		{"no subjects-file", drop("--subjects-file")},
		{"no provenance at all", drop("--provenance")},
		{"both provenance and provenance-referrers", append(base(), "--provenance-referrers", provenance)},
		{"no sign", drop("--sign")},
		{"no bundle-dir", drop("--bundle-dir")},
		{"no statements-out", drop("--statements-out")},
		{"rejects --subject", append(base(), "--subject", testArtifactDigest)},
		{"rejects --artifact", append(base(), "--artifact", provenance)},
		{"rejects --statement", append(base(), "--statement", provenance)},
		{"rejects --out", append(base(), "--out", stmtsOut)},
		{"rejects --append", append(base(), "--append", provenance)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var stderr bytes.Buffer
			if rc := run(tc.args, &stderr); rc != 2 {
				t.Fatalf("rc=%d, want 2; stderr=%s", rc, stderr.String())
			}
			if _, err := os.Stat(bundleDir); !os.IsNotExist(err) {
				t.Fatalf("bundle dir created despite failure, stat err=%v", err)
			}
			if ss.calls != 0 {
				t.Fatalf("sign calls = %d, want 0", ss.calls)
			}
		})
	}
}
