package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The verdict/exit-code matrix must be deterministic and offline, so these
// tests exec a scripted fake ampel; the real CLI contract (flag names, VSA
// shape) is pinned by the bats real-parser test and the dispatch e2e.
// installFakeAmpel writes an executable `ampel` script into its own dir and
// prepends it to PATH.
func installFakeAmpel(t *testing.T, script string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "ampel")
	if err := os.WriteFile(path, []byte("#!/bin/bash\n"+script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("WRANGLE_RETRY_DELAY", "0")
	return dir
}

// fakeVSA renders the minimal VSA statement ampel emits at --results-path.
func fakeVSA(digestHex, verdict string) string {
	return fmt.Sprintf(`{
  "_type": "https://in-toto.io/Statement/v1",
  "subject": [{"digest": {"sha256": "%s"}}],
  "predicateType": "https://slsa.dev/verification_summary/v1",
  "predicate": {"verificationResult": "%s"}
}`, digestHex, verdict)
}

// ampelWritingVSA scripts a fake ampel that writes the given VSA body to
// --results-path, prints a report line, and exits rc.
func ampelWritingVSA(vsa string, rc int) string {
	return fmt.Sprintf(`out=""
for a in "$@"; do case "$a" in --results-path=*) out="${a#--results-path=}";; esac; done
if [[ -n "$out" ]]; then cat > "$out" <<'VSA'
%s
VSA
fi
printf '<report>ampel says hi</report>\n'
exit %d
`, vsa, rc)
}

// stageBundle creates a non-empty append target and returns (bundle, out).
func stageBundle(t *testing.T) (string, string) {
	t.Helper()
	dir := t.TempDir()
	bundle := filepath.Join(dir, "a.tgz.intoto.jsonl")
	if err := os.WriteFile(bundle, []byte(`{"provenance":1}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return bundle, filepath.Join(dir, "vsa.signed.jsonl")
}

func verifyArgs(bundle, out string, extra ...string) []string {
	args := []string{
		"--subject", testArtifactDigest,
		"--policy", "/policies/p.hjson",
		"--bundle", bundle,
		"--out", out,
	}
	return append(args, extra...)
}

const testDigestHex = "011b95c8e47c538646a2c01df5373fe703381cd415c847357b3d563563eb1d95"

func TestVerifyPassSignsAndAppends(t *testing.T) {
	installFakeAmpel(t, ampelWritingVSA(fakeVSA(testDigestHex, "PASSED"), 0))
	rs := &recordingSigner{out: []byte(`{"bundle":"signed-vsa"}`)}
	swapSigner(t, func() (statementSigner, func(), error) { return rs, func() {}, nil })
	bundle, out := stageBundle(t)

	var stdout, stderr bytes.Buffer
	rc := runVerify(verifyArgs(bundle, out), &stdout, &stderr)
	if rc != 0 {
		t.Fatalf("rc=%d stderr=%s", rc, stderr.String())
	}
	// The DSSE payload is the emitted VSA verbatim.
	if !strings.Contains(string(rs.got), `"verificationResult": "PASSED"`) {
		t.Fatalf("signer input is not the VSA: %q", rs.got)
	}
	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != `{"bundle":"signed-vsa"}`+"\n" {
		t.Fatalf("out = %q", data)
	}
	b, err := os.ReadFile(bundle)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != `{"provenance":1}`+"\n"+`{"bundle":"signed-vsa"}`+"\n" {
		t.Fatalf("bundle = %q", b)
	}
	if !strings.Contains(stdout.String(), "<report>ampel says hi</report>") {
		t.Fatalf("report missing from stdout: %q", stdout.String())
	}
}

func TestVerifyFailedVerdictExits1WithoutSigning(t *testing.T) {
	// fail=true: ampel exits 1 and the emitted VSA says FAILED — the verdict
	// path, distinct from a tool error.
	installFakeAmpel(t, ampelWritingVSA(fakeVSA(testDigestHex, "FAILED"), 1))
	rs := &recordingSigner{out: []byte(`{}`)}
	swapSigner(t, func() (statementSigner, func(), error) { return rs, func() {}, nil })
	bundle, out := stageBundle(t)
	before, _ := os.ReadFile(bundle)

	var stdout, stderr bytes.Buffer
	rc := runVerify(verifyArgs(bundle, out), &stdout, &stderr)
	if rc != 1 {
		t.Fatalf("rc=%d, want 1; stderr=%s", rc, stderr.String())
	}
	if rs.got != nil {
		t.Fatal("signer must not run on a FAILED verdict")
	}
	if _, err := os.Stat(out); !os.IsNotExist(err) {
		t.Fatal("out must not be written on a FAILED verdict")
	}
	after, _ := os.ReadFile(bundle)
	if !bytes.Equal(before, after) {
		t.Fatal("bundle must be untouched on a FAILED verdict")
	}
	if !strings.Contains(stderr.String(), "policy verdict FAILED") {
		t.Fatalf("stderr = %q", stderr.String())
	}
	// The report still reaches the step summary on a failed verdict.
	if !strings.Contains(stdout.String(), "<report>") {
		t.Fatalf("report missing from stdout: %q", stdout.String())
	}
}

func TestVerifyFailFalseSignsFailedVerdict(t *testing.T) {
	// fail=false: ampel exits 0 on a FAILED verdict and the FAILED VSA is
	// still signed and delivered (warn mode).
	installFakeAmpel(t, ampelWritingVSA(fakeVSA(testDigestHex, "FAILED"), 0))
	rs := &recordingSigner{out: []byte(`{"warn":"vsa"}`)}
	swapSigner(t, func() (statementSigner, func(), error) { return rs, func() {}, nil })
	bundle, out := stageBundle(t)

	var stdout, stderr bytes.Buffer
	rc := runVerify(verifyArgs(bundle, out, "--fail=false"), &stdout, &stderr)
	if rc != 0 {
		t.Fatalf("rc=%d stderr=%s", rc, stderr.String())
	}
	if !strings.Contains(string(rs.got), `"FAILED"`) {
		t.Fatalf("signer input: %q", rs.got)
	}
}

func TestVerifyExitZeroButFailedVSAFailsClosed(t *testing.T) {
	// THE fail-open guard: a hypothetical ampel that exits 0 while its own VSA
	// says FAILED (e.g. --exit-code mishandled) must never be signed.
	installFakeAmpel(t, ampelWritingVSA(fakeVSA(testDigestHex, "FAILED"), 0))
	rs := &recordingSigner{out: []byte(`{}`)}
	swapSigner(t, func() (statementSigner, func(), error) { return rs, func() {}, nil })
	bundle, out := stageBundle(t)

	var stdout, stderr bytes.Buffer
	rc := runVerify(verifyArgs(bundle, out), &stdout, &stderr)
	if rc != 2 {
		t.Fatalf("rc=%d, want 2", rc)
	}
	if rs.got != nil {
		t.Fatal("signer must not run when exit code and VSA disagree")
	}
	if !strings.Contains(stderr.String(), "refusing to sign") {
		t.Fatalf("stderr = %q", stderr.String())
	}
}

func TestVerifyVSAFailClosedTable(t *testing.T) {
	for _, tc := range []struct {
		name string
		vsa  string
	}{
		{"empty verdict (ampel --pid edge)", fakeVSA(testDigestHex, "")},
		{"SOFTFAIL leaks through verbatim", fakeVSA(testDigestHex, "SOFTFAIL")},
		{"wrong subject digest", fakeVSA(strings.Repeat("ab", 32), "PASSED")},
		{"multi-digest subject", `{"_type":"https://in-toto.io/Statement/v1","subject":[{"digest":{"sha256":"` + testDigestHex + `","sha512":"aa"}}],"predicateType":"https://slsa.dev/verification_summary/v1","predicate":{"verificationResult":"PASSED"}}`},
		{"two subjects", `{"_type":"https://in-toto.io/Statement/v1","subject":[{"digest":{"sha256":"` + testDigestHex + `"}},{"digest":{"sha256":"` + testDigestHex + `"}}],"predicateType":"https://slsa.dev/verification_summary/v1","predicate":{"verificationResult":"PASSED"}}`},
		{"wrong predicateType", `{"_type":"https://in-toto.io/Statement/v1","subject":[{"digest":{"sha256":"` + testDigestHex + `"}}],"predicateType":"https://example.com/other","predicate":{"verificationResult":"PASSED"}}`},
		{"wrong _type", `{"_type":"https://example.com/Statement","subject":[{"digest":{"sha256":"` + testDigestHex + `"}}],"predicateType":"https://slsa.dev/verification_summary/v1","predicate":{"verificationResult":"PASSED"}}`},
		{"not JSON", `not json at all`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			installFakeAmpel(t, ampelWritingVSA(tc.vsa, 0))
			rs := &recordingSigner{out: []byte(`{}`)}
			swapSigner(t, func() (statementSigner, func(), error) { return rs, func() {}, nil })
			bundle, out := stageBundle(t)

			var stdout, stderr bytes.Buffer
			// fail=false too: even warn mode never signs a malformed VSA.
			rc := runVerify(verifyArgs(bundle, out, "--fail=false"), &stdout, &stderr)
			if rc != 2 {
				t.Fatalf("rc=%d, want 2; stderr=%s", rc, stderr.String())
			}
			if rs.got != nil {
				t.Fatal("signer must not run on an invalid VSA")
			}
		})
	}
}

func TestVerifyExitZeroWithoutVSAFailsClosed(t *testing.T) {
	installFakeAmpel(t, "printf 'report\\n'\nexit 0\n")
	rs := &recordingSigner{out: []byte(`{}`)}
	swapSigner(t, func() (statementSigner, func(), error) { return rs, func() {}, nil })
	bundle, out := stageBundle(t)

	var stdout, stderr bytes.Buffer
	rc := runVerify(verifyArgs(bundle, out), &stdout, &stderr)
	if rc != 2 {
		t.Fatalf("rc=%d, want 2", rc)
	}
	if !strings.Contains(stderr.String(), "wrote no VSA") {
		t.Fatalf("stderr = %q", stderr.String())
	}
}

func TestVerifyToolErrorExits2(t *testing.T) {
	// Exit 1 with no VSA is a tool error, not a verdict; both retry attempts run.
	counter := filepath.Join(t.TempDir(), "count")
	installFakeAmpel(t, fmt.Sprintf("echo x >> %q\nprintf 'boom\\n' >&2\nexit 1\n", counter))
	bundle, out := stageBundle(t)

	var stdout, stderr bytes.Buffer
	rc := runVerify(verifyArgs(bundle, out), &stdout, &stderr)
	if rc != 2 {
		t.Fatalf("rc=%d, want 2", rc)
	}
	if !strings.Contains(stderr.String(), "ampel verify failed (exit 1)") {
		t.Fatalf("stderr = %q", stderr.String())
	}
	data, _ := os.ReadFile(counter)
	if got := strings.Count(string(data), "x"); got != 2 {
		t.Fatalf("ampel ran %d times, want 2 (one retry)", got)
	}
}

func TestVerifyRetryRecoversAndEmitsOneReport(t *testing.T) {
	// First attempt fails (transient), second passes; only the surviving
	// attempt's report and VSA are used.
	dir := t.TempDir()
	marker := filepath.Join(dir, "first-attempt")
	script := fmt.Sprintf(`if [[ ! -e %q ]]; then touch %q; printf 'flaky report\n'; exit 1; fi
%s`, marker, marker, ampelWritingVSA(fakeVSA(testDigestHex, "PASSED"), 0))
	installFakeAmpel(t, script)
	rs := &recordingSigner{out: []byte(`{"ok":1}`)}
	swapSigner(t, func() (statementSigner, func(), error) { return rs, func() {}, nil })
	bundle, out := stageBundle(t)

	var stdout, stderr bytes.Buffer
	rc := runVerify(verifyArgs(bundle, out), &stdout, &stderr)
	if rc != 0 {
		t.Fatalf("rc=%d stderr=%s", rc, stderr.String())
	}
	if strings.Contains(stdout.String(), "flaky report") {
		t.Fatalf("failed attempt's report leaked: %q", stdout.String())
	}
	if got := strings.Count(stdout.String(), "<report>"); got != 1 {
		t.Fatalf("want exactly one report, got %d", got)
	}
	if !strings.Contains(stderr.String(), "retrying once") {
		t.Fatalf("stderr = %q", stderr.String())
	}
}

func TestVerifyScrubsSigningTokenFromAmpelEnv(t *testing.T) {
	// ampel parses semi-trusted attestations in the same container as the
	// signing token; the child env must never carry it.
	dir := t.TempDir()
	envDump := filepath.Join(dir, "env")
	installFakeAmpel(t, fmt.Sprintf(`env > %q
%s`, envDump, ampelWritingVSA(fakeVSA(testDigestHex, "PASSED"), 0)))
	rs := &recordingSigner{out: []byte(`{}`)}
	swapSigner(t, func() (statementSigner, func(), error) { return rs, func() {}, nil })
	t.Setenv("SIGSTORE_ID_TOKEN", "SECRET-SIGNING-JWT")
	t.Setenv("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "SECRET-REQUEST-BEARER")
	t.Setenv("ACTIONS_ID_TOKEN_REQUEST_URL", "https://oidc.example")
	t.Setenv("AMPEL_SOURCEREPO", "https://github.com/evil/repo")
	t.Setenv("GITHUB_TOKEN", "registry-token")
	bundle, out := stageBundle(t)

	var stdout, stderr bytes.Buffer
	rc := runVerify(verifyArgs(bundle, out), &stdout, &stderr)
	if rc != 0 {
		t.Fatalf("rc=%d stderr=%s", rc, stderr.String())
	}
	env, err := os.ReadFile(envDump)
	if err != nil {
		t.Fatal(err)
	}
	for _, banned := range []string{"SIGSTORE_ID_TOKEN", "ACTIONS_ID_TOKEN_REQUEST", "AMPEL_"} {
		if strings.Contains(string(env), banned) {
			t.Fatalf("%s leaked into ampel's env", banned)
		}
	}
	// The oci: collector's registry auth must survive the scrub.
	if !strings.Contains(string(env), "GITHUB_TOKEN=registry-token") {
		t.Fatal("GITHUB_TOKEN missing from ampel's env")
	}
}

func TestVerifyAmpelArgVector(t *testing.T) {
	dir := t.TempDir()
	argDump := filepath.Join(dir, "args")
	installFakeAmpel(t, fmt.Sprintf(`printf '%%s\n' "$@" > %q
%s`, argDump, ampelWritingVSA(fakeVSA(testDigestHex, "PASSED"), 0)))
	rs := &recordingSigner{out: []byte(`{}`)}
	swapSigner(t, func() (statementSigner, func(), error) { return rs, func() {}, nil })
	bundle, out := stageBundle(t)

	var stdout, stderr bytes.Buffer
	rc := runVerify(verifyArgs(bundle, out,
		"--collector", "oci:ghcr.io/o/r@sha256:aa",
		"--context", "sourceRepo:https://github.com/o/r",
		"--attestation", "extra.intoto.json",
	), &stdout, &stderr)
	if rc != 0 {
		t.Fatalf("rc=%d stderr=%s", rc, stderr.String())
	}
	got, err := os.ReadFile(argDump)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(got)), "\n")
	want := []string{
		"verify",
		"--subject=" + testArtifactDigest,
		"--collector=jsonl:" + bundle,
		"--collector=oci:ghcr.io/o/r@sha256:aa",
		"--policy=/policies/p.hjson",
		"--exit-code=true",
		"--attest-results",
		"--attest-format=vsa",
		// [8] is --results-path=<engine temp>, asserted by prefix below.
		"--context", "sourceRepo:https://github.com/o/r",
		"--attestation", "extra.intoto.json",
		"--format=html",
	}
	if len(lines) != len(want)+1 {
		t.Fatalf("argv = %q", lines)
	}
	for i, w := range want {
		g := lines[i]
		if i >= 8 {
			g = lines[i+1]
		}
		if g != w {
			t.Fatalf("argv[%d] = %q, want %q (full: %q)", i, g, w, lines)
		}
	}
	if !strings.HasPrefix(lines[8], "--results-path=") {
		t.Fatalf("argv[8] = %q, want --results-path=…", lines[8])
	}
}

func TestVerifyArtifactSubjectSelfDigestsToSubjectHash(t *testing.T) {
	dir := t.TempDir()
	blob := filepath.Join(dir, "app.tgz")
	if err := os.WriteFile(blob, []byte("CONTENT\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte("CONTENT\n"))
	wantHex := hex.EncodeToString(sum[:])

	argDump := filepath.Join(dir, "args")
	installFakeAmpel(t, fmt.Sprintf(`printf '%%s\n' "$@" > %q
%s`, argDump, ampelWritingVSA(fakeVSA(wantHex, "PASSED"), 0)))
	rs := &recordingSigner{out: []byte(`{}`)}
	swapSigner(t, func() (statementSigner, func(), error) { return rs, func() {}, nil })
	bundle, out := stageBundle(t)

	var stdout, stderr bytes.Buffer
	rc := runVerify([]string{
		"--artifact", blob,
		"--policy", "/p.hjson",
		"--bundle", bundle,
		"--out", out,
	}, &stdout, &stderr)
	if rc != 0 {
		t.Fatalf("rc=%d stderr=%s", rc, stderr.String())
	}
	got, err := os.ReadFile(argDump)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(got), "--subject-hash=sha256:"+wantHex+"\n") {
		t.Fatalf("argv = %q, want --subject-hash=sha256:%s", got, wantHex)
	}
	if strings.Contains(string(got), "--subject=") {
		t.Fatalf("file subject must not use --subject: %q", got)
	}
}

func TestVerifyFlagFailClosedTable(t *testing.T) {
	bundle, out := stageBundle(t)
	empty := filepath.Join(t.TempDir(), "empty.jsonl")
	if err := os.WriteFile(empty, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name string
		args []string
	}{
		{"missing policy", []string{"--subject", testArtifactDigest, "--bundle", bundle, "--out", out}},
		{"missing bundle", []string{"--subject", testArtifactDigest, "--policy", "p", "--out", out}},
		{"missing out", []string{"--subject", testArtifactDigest, "--policy", "p", "--bundle", bundle}},
		{"missing subject", []string{"--policy", "p", "--bundle", bundle, "--out", out}},
		{"subject and artifact", []string{"--subject", testArtifactDigest, "--artifact", "f", "--policy", "p", "--bundle", bundle, "--out", out}},
		{"non-sha256 subject", []string{"--subject", "sha512:abcd", "--policy", "p", "--bundle", bundle, "--out", out}},
		{"short digest", []string{"--subject", "sha256:abcd", "--policy", "p", "--bundle", bundle, "--out", out}},
		{"missing artifact file", []string{"--artifact", "/nonexistent.tgz", "--policy", "p", "--bundle", bundle, "--out", out}},
		{"out aliases bundle", []string{"--subject", testArtifactDigest, "--policy", "p", "--bundle", bundle, "--out", bundle}},
		{"missing bundle file", []string{"--subject", testArtifactDigest, "--policy", "p", "--bundle", "/nonexistent.jsonl", "--out", out}},
		{"empty bundle file", []string{"--subject", testArtifactDigest, "--policy", "p", "--bundle", empty, "--out", out}},
		{"positional arg", []string{"stray", "--subject", testArtifactDigest, "--policy", "p", "--bundle", bundle, "--out", out}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			// Any ampel invocation would be a bug: these all fail pre-exec.
			installFakeAmpel(t, "echo SHOULD-NOT-RUN >&2; exit 97\n")
			var stdout, stderr bytes.Buffer
			rc := runVerify(tc.args, &stdout, &stderr)
			if rc != 2 {
				t.Fatalf("rc=%d, want 2; stderr=%s", rc, stderr.String())
			}
			if strings.Contains(stderr.String(), "SHOULD-NOT-RUN") {
				t.Fatal("ampel ran despite invalid flags")
			}
		})
	}
}

func TestRunDispatchesVerify(t *testing.T) {
	var stderr bytes.Buffer
	rc := run([]string{"verify"}, &stderr)
	if rc != 2 {
		t.Fatalf("rc=%d, want 2", rc)
	}
	if !strings.Contains(stderr.String(), "required") {
		t.Fatalf("stderr = %q", stderr.String())
	}
}
