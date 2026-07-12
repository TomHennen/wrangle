package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// The appended bytes must be the existing bundle verbatim + the signed line +
// '\n' — including when the bundle lacks a trailing newline, where the line
// concatenates onto the seed's last line exactly as a shell `printf '%s\n' >>`
// would.
func TestRunStatementAppendGolden(t *testing.T) {
	line := `{"bundle":"x"}`
	cases := []struct {
		name   string
		bundle string
	}{
		{"bundle with trailing newline", "{\"seed\":1}\n{\"seed\":2}\n"},
		{"bundle without trailing newline", "{\"seed\":1}\n{\"seed\":2}"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rs := &recordingSigner{out: []byte(line)}
			swapSigner(t, func() (statementSigner, func(), error) { return rs, func() {}, nil })

			dir := t.TempDir()
			stmt := filepath.Join(dir, "vsa.intoto.json")
			if err := os.WriteFile(stmt, []byte(`{"a":1}`), 0o644); err != nil {
				t.Fatal(err)
			}
			bundle := filepath.Join(dir, "pkg.intoto.jsonl")
			if err := os.WriteFile(bundle, []byte(tc.bundle), 0o644); err != nil {
				t.Fatal(err)
			}
			out := filepath.Join(dir, "vsa.signed.json")

			var stderr bytes.Buffer
			rc := run([]string{"--sign", "--statement", stmt, "--out", out, "--append", bundle}, &stderr)
			if rc != 0 {
				t.Fatalf("run rc=%d stderr=%s", rc, stderr.String())
			}
			got, err := os.ReadFile(out)
			if err != nil {
				t.Fatal(err)
			}
			if string(got) != line+"\n" {
				t.Fatalf("out = %q, want the signed line + newline", got)
			}
			appended, err := os.ReadFile(bundle)
			if err != nil {
				t.Fatal(err)
			}
			if want := tc.bundle + line + "\n"; string(appended) != want {
				t.Fatalf("append mismatch:\n got: %q\nwant: %q", appended, want)
			}
		})
	}
}

func TestRunStatementAppendFailClosed(t *testing.T) {
	dir := t.TempDir()
	stmt := filepath.Join(dir, "vsa.intoto.json")
	if err := os.WriteFile(stmt, []byte(`{"a":1}`), 0o644); err != nil {
		t.Fatal(err)
	}
	const bundleContent = "{\"seed\":1}\n"
	newBundle := func(t *testing.T) string {
		bundle := filepath.Join(t.TempDir(), "pkg.intoto.jsonl")
		if err := os.WriteFile(bundle, []byte(bundleContent), 0o644); err != nil {
			t.Fatal(err)
		}
		return bundle
	}
	// A failing case must leave --out uncreated and the --append bundle
	// byte-identical.
	assertUntouched := func(t *testing.T, out, bundle string) {
		t.Helper()
		if _, err := os.Stat(out); !os.IsNotExist(err) {
			t.Fatalf("expected no --out file after failure, stat err=%v", err)
		}
		got, err := os.ReadFile(bundle)
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != bundleContent {
			t.Fatalf("append target modified on failure: %q", got)
		}
	}

	// A post-signing append failure (the directory passes the up-front stat
	// gate but O_APPEND open fails) must remove the just-written --out.
	t.Run("append target is a directory", func(t *testing.T) {
		rs := &recordingSigner{out: []byte(`{"bundle":"x"}`)}
		swapSigner(t, func() (statementSigner, func(), error) { return rs, func() {}, nil })
		out := filepath.Join(t.TempDir(), "out.json")
		var stderr bytes.Buffer
		if rc := run([]string{"--sign", "--statement", stmt, "--out", out,
			"--append", t.TempDir()}, &stderr); rc != 2 {
			t.Fatalf("rc=%d, want 2; stderr=%s", rc, stderr.String())
		}
		if _, err := os.Stat(out); !os.IsNotExist(err) {
			t.Fatalf("expected --out removed after a failed append, stat err=%v", err)
		}
	})

	t.Run("append same file as out", func(t *testing.T) {
		rs := &recordingSigner{out: []byte(`{"bundle":"x"}`)}
		swapSigner(t, func() (statementSigner, func(), error) { return rs, func() {}, nil })
		bundle := newBundle(t)
		unclean := filepath.Dir(bundle) + "/./" + filepath.Base(bundle)
		for _, appendArg := range []string{bundle, unclean} {
			var stderr bytes.Buffer
			if rc := run([]string{"--sign", "--statement", stmt, "--out", bundle,
				"--append", appendArg}, &stderr); rc != 2 {
				t.Fatalf("append %q: rc=%d, want 2; stderr=%s", appendArg, rc, stderr.String())
			}
			got, err := os.ReadFile(bundle)
			if err != nil || string(got) != bundleContent {
				t.Fatalf("append %q: bundle modified: %q err=%v", appendArg, got, err)
			}
			if len(rs.got) != 0 {
				t.Fatalf("append %q: signer ran despite --append == --out", appendArg)
			}
		}
	})

	t.Run("append target missing", func(t *testing.T) {
		rs := &recordingSigner{out: []byte(`{"bundle":"x"}`)}
		swapSigner(t, func() (statementSigner, func(), error) { return rs, func() {}, nil })
		out := filepath.Join(t.TempDir(), "out.json")
		var stderr bytes.Buffer
		if rc := run([]string{"--sign", "--statement", stmt, "--out", out,
			"--append", filepath.Join(dir, "nope.jsonl")}, &stderr); rc != 2 {
			t.Fatalf("rc=%d, want 2; stderr=%s", rc, stderr.String())
		}
		if len(rs.got) != 0 {
			t.Fatal("signer ran despite a missing append target")
		}
		if _, err := os.Stat(out); !os.IsNotExist(err) {
			t.Fatalf("expected no --out file after failure, stat err=%v", err)
		}
	})

	t.Run("append target empty", func(t *testing.T) {
		rs := &recordingSigner{out: []byte(`{"bundle":"x"}`)}
		swapSigner(t, func() (statementSigner, func(), error) { return rs, func() {}, nil })
		empty := filepath.Join(t.TempDir(), "empty.jsonl")
		if err := os.WriteFile(empty, nil, 0o644); err != nil {
			t.Fatal(err)
		}
		out := filepath.Join(t.TempDir(), "out.json")
		var stderr bytes.Buffer
		if rc := run([]string{"--sign", "--statement", stmt, "--out", out, "--append", empty}, &stderr); rc != 2 {
			t.Fatalf("rc=%d, want 2; stderr=%s", rc, stderr.String())
		}
		if len(rs.got) != 0 {
			t.Fatal("signer ran despite an empty append target")
		}
	})

	t.Run("append without statement", func(t *testing.T) {
		rs := &recordingSigner{out: []byte(`{"bundle":"x"}`)}
		swapSigner(t, func() (statementSigner, func(), error) { return rs, func() {}, nil })
		bundle := newBundle(t)
		out := filepath.Join(t.TempDir(), "out.json")
		cases := [][]string{
			{"--sign", "--append", bundle, "--out", out},
			{"--sign", "--metadata-root", dir, "--subject", testArtifactDigest, "--append", bundle, "--out", out},
		}
		for _, args := range cases {
			var stderr bytes.Buffer
			if rc := run(args, &stderr); rc != 2 {
				t.Fatalf("args %v: rc=%d, want 2; stderr=%s", args, rc, stderr.String())
			}
			assertUntouched(t, out, bundle)
		}
	})

	t.Run("signing failure touches neither file", func(t *testing.T) {
		t.Setenv("WRANGLE_RETRY_DELAY", "0")
		swapSigner(t, func() (statementSigner, func(), error) { return failingSigner{}, func() {}, nil })
		bundle := newBundle(t)
		out := filepath.Join(t.TempDir(), "out.json")
		var stderr bytes.Buffer
		if rc := run([]string{"--sign", "--statement", stmt, "--out", out, "--append", bundle}, &stderr); rc != 2 {
			t.Fatalf("rc=%d, want 2; stderr=%s", rc, stderr.String())
		}
		assertUntouched(t, out, bundle)
	})

	t.Run("empty signed line touches neither file", func(t *testing.T) {
		for _, empty := range []string{"", " \n"} {
			rs := &recordingSigner{out: []byte(empty)}
			swapSigner(t, func() (statementSigner, func(), error) { return rs, func() {}, nil })
			bundle := newBundle(t)
			out := filepath.Join(t.TempDir(), "out.json")
			var stderr bytes.Buffer
			if rc := run([]string{"--sign", "--statement", stmt, "--out", out, "--append", bundle}, &stderr); rc != 2 {
				t.Fatalf("signer output %q: rc=%d, want 2; stderr=%s", empty, rc, stderr.String())
			}
			assertUntouched(t, out, bundle)
		}
	})

	t.Run("bad statement touches neither file", func(t *testing.T) {
		rs := &recordingSigner{out: []byte(`{"bundle":"x"}`)}
		swapSigner(t, func() (statementSigner, func(), error) { return rs, func() {}, nil })
		bundle := newBundle(t)
		out := filepath.Join(t.TempDir(), "out.json")
		var stderr bytes.Buffer
		if rc := run([]string{"--sign", "--statement", filepath.Join(dir, "nope.json"),
			"--out", out, "--append", bundle}, &stderr); rc != 2 {
			t.Fatalf("rc=%d, want 2; stderr=%s", rc, stderr.String())
		}
		assertUntouched(t, out, bundle)
	})
}
