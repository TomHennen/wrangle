package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	sdsse "github.com/sigstore/protobuf-specs/gen/pb-go/dsse"
	"google.golang.org/protobuf/encoding/protojson"
)

// recordingSigner captures the exact bytes handed to sign, proving the DSSE
// payload is the statement file verbatim.
type recordingSigner struct {
	got []byte
	out []byte
}

func (r *recordingSigner) sign(statement []byte) ([]byte, error) {
	r.got = append([]byte(nil), statement...)
	return r.out, nil
}

func TestRunStatementSignsFileBytesVerbatim(t *testing.T) {
	rs := &recordingSigner{out: []byte(`{"bundle":"x"}`)}
	swapSigner(t, func() (statementSigner, func(), error) { return rs, func() {}, nil })

	dir := t.TempDir()
	// Indentation and the trailing newline must reach the signer untouched.
	stmt := "{\n  \"_type\": \"https://in-toto.io/Statement/v1\",\n  \"predicateType\": \"https://example.com/v1\"\n}\n"
	path := filepath.Join(dir, "vsa.intoto.json")
	if err := os.WriteFile(path, []byte(stmt), 0o644); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(dir, "vsa.signed.json")

	var stderr bytes.Buffer
	rc := run([]string{"--sign", "--statement", path, "--out", out}, &stderr)
	if rc != 0 {
		t.Fatalf("run rc=%d stderr=%s", rc, stderr.String())
	}
	if !bytes.Equal(rs.got, []byte(stmt)) {
		t.Fatalf("signer input differs from file bytes:\n got: %q\nwant: %q", rs.got, stmt)
	}
	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != `{"bundle":"x"}`+"\n" {
		t.Fatalf("out = %q, want the signer's single line + newline", data)
	}
}

func TestRunStatementLocalKeyPayloadRoundTrip(t *testing.T) {
	ks := newLocalKeySigner(t)
	swapSigner(t, func() (statementSigner, func(), error) { return ks, func() {}, nil })

	dir := t.TempDir()
	stmt := `{"_type":"https://in-toto.io/Statement/v1","subject":[{"name":"a","digest":{"sha256":"011b95c8e47c538646a2c01df5373fe703381cd415c847357b3d563563eb1d95"}}],"predicateType":"https://example.com/v1","predicate":{"verdict":"pass"}}`
	path := filepath.Join(dir, "vsa.intoto.json")
	if err := os.WriteFile(path, []byte(stmt), 0o644); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(dir, "vsa.signed.json")

	var stderr bytes.Buffer
	rc := run([]string{"--sign", "--statement", path, "--out", out}, &stderr)
	if rc != 0 {
		t.Fatalf("run rc=%d stderr=%s", rc, stderr.String())
	}
	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	var env sdsse.Envelope
	if err := protojson.Unmarshal(bytes.TrimSpace(data), &env); err != nil {
		t.Fatalf("signed output is not a DSSE envelope: %v", err)
	}
	if !bytes.Equal(env.GetPayload(), []byte(stmt)) {
		t.Fatalf("DSSE payload differs from statement file bytes:\n got: %q\nwant: %q", env.GetPayload(), stmt)
	}
	if len(env.GetSignatures()) == 0 || len(env.GetSignatures()[0].GetSig()) == 0 {
		t.Fatalf("envelope carries no signature: %+v", env.GetSignatures())
	}
}

// A signing failure must leave a pre-existing --out byte-unchanged — --out is
// only written after signing succeeds.
func TestRunStatementSignFailureLeavesOutUntouched(t *testing.T) {
	swapSigner(t, func() (statementSigner, func(), error) { return failingSigner{}, func() {}, nil })

	dir := t.TempDir()
	path := filepath.Join(dir, "stmt.json")
	if err := os.WriteFile(path, []byte(`{"a":1}`), 0o644); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(dir, "out.json")
	prior := []byte("pre-existing content\n")
	if err := os.WriteFile(out, prior, 0o644); err != nil {
		t.Fatal(err)
	}

	var stderr bytes.Buffer
	if rc := run([]string{"--sign", "--statement", path, "--out", out}, &stderr); rc != 2 {
		t.Fatalf("rc=%d, want fail-closed 2; stderr=%s", rc, stderr.String())
	}
	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(data, prior) {
		t.Fatalf("pre-existing --out changed on signing failure: %q", data)
	}
}

func TestRunStatementFailClosed(t *testing.T) {
	rs := &recordingSigner{out: []byte(`{}`)}
	swapSigner(t, func() (statementSigner, func(), error) { return rs, func() {}, nil })

	dir := t.TempDir()
	good := filepath.Join(dir, "stmt.json")
	if err := os.WriteFile(good, []byte(`{"a":1}`), 0o644); err != nil {
		t.Fatal(err)
	}
	write := func(name, content string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		return p
	}
	empty := write("empty.json", "")
	blank := write("blank.json", " \n\t\n")
	out := filepath.Join(dir, "out.json")

	cases := []struct {
		name string
		args []string
	}{
		{"missing file", []string{"--sign", "--statement", filepath.Join(dir, "nope.json"), "--out", out}},
		{"empty file", []string{"--sign", "--statement", empty, "--out", out}},
		{"whitespace-only file", []string{"--sign", "--statement", blank, "--out", out}},
		{"no --sign", []string{"--statement", good, "--out", out}},
		{"no --out", []string{"--sign", "--statement", good}},
		{"with --metadata-root", []string{"--sign", "--statement", good, "--metadata-root", dir, "--out", out}},
		{"with --subject", []string{"--sign", "--statement", good, "--subject", testArtifactDigest, "--out", out}},
		{"with --artifact", []string{"--sign", "--statement", good, "--artifact", good, "--out", out}},
		{"with --commit", []string{"--sign", "--statement", good, "--commit", "deadbeef", "--out", out}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var stderr bytes.Buffer
			if rc := run(tc.args, &stderr); rc != 2 {
				t.Fatalf("rc=%d, want fail-closed 2; stderr=%s", rc, stderr.String())
			}
			if _, err := os.Stat(out); !os.IsNotExist(err) {
				t.Fatalf("expected no output file after failure, stat err=%v", err)
			}
		})
	}
}
