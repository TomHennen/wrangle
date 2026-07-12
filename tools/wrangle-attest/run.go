package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
)

// metadataRoots collects repeated --metadata-root flags.
type metadataRoots []string

func (r *metadataRoots) String() string { return fmt.Sprint([]string(*r)) }
func (r *metadataRoots) Set(v string) error {
	*r = append(*r, v)
	return nil
}

// run is the testable entry point. It discovers manifests, binds each to the
// single artifact subject, builds one Statement per manifest, and writes them
// all to --out as JSONL. With --sign each statement is keyless-signed (one
// shared signer, so the OIDC+Fulcio flow runs once) and the Sigstore bundle is
// emitted; without it the statements are emitted unsigned. With --statement it
// instead signs one existing statement file verbatim. The file is written
// whole (buffer first) so a mid-run failure — including a Fulcio error on the
// Nth statement — never leaves a partial/unsigned bundle on disk.
func run(args []string, stderr io.Writer) int {
	fs := flag.NewFlagSet("wrangle-attest", flag.ContinueOnError)
	fs.SetOutput(stderr)

	var roots metadataRoots
	fs.Var(&roots, "metadata-root", "directory holding a top-level wrangle_attestation_metadata.json (repeatable)")
	subject := fs.String("subject", "", "artifact subject digest sha256:<hex> every statement binds to")
	artifact := fs.String("artifact", "", "file to self-digest into the sha256 subject (alternative to --subject)")
	commit := fs.String("commit", "", "scanned git commit, woven into the scan/v1 envelope only")
	sign := fs.Bool("sign", false, "keyless-sign each statement and emit the Sigstore bundle")
	statement := fs.String("statement", "", "existing in-toto statement file to sign verbatim (requires --sign)")
	out := fs.String("out", "", "file the in-toto JSONL statements are written to")

	if err := fs.Parse(args); err != nil {
		return 2
	}

	if *statement != "" {
		if err := validateStatementMode(roots, *subject, *artifact, *commit, *sign, *out); err != nil {
			return failClosed(stderr, err)
		}
		return signStatementFile(*statement, *out, stderr)
	}

	subjectArg, err := resolveSubject(*subject, *artifact)
	if err != nil {
		return failClosed(stderr, err)
	}
	if err := validateFlags(roots, subjectArg, *out); err != nil {
		return failClosed(stderr, err)
	}

	subj, err := newSubject(subjectArg)
	if err != nil {
		return failClosed(stderr, err)
	}

	manifests, err := discoverManifests(roots)
	if err != nil {
		return failClosed(stderr, err)
	}

	var sg statementSigner
	if *sign {
		s, closeFn, err := newSigner()
		if err != nil {
			return failClosed(stderr, err)
		}
		defer closeFn()
		sg = s
	}

	// Build (and sign) every statement into a buffer first; only touch --out
	// once all succeed, so an error on the Nth manifest — including a Fulcio
	// signing failure — can't corrupt or partially write the output.
	var buf bytes.Buffer
	for _, m := range manifests {
		stmt, err := buildStatement(m, subj, *commit)
		if err != nil {
			return failClosed(stderr, err)
		}
		line, err := marshalStatement(stmt)
		if err != nil {
			return failClosed(stderr, err)
		}
		if sg != nil {
			line, err = sg.sign(line)
			if err != nil {
				return failClosed(stderr, err)
			}
		}
		buf.Write(line)
		buf.WriteByte('\n')
	}

	if err := os.WriteFile(*out, buf.Bytes(), 0o644); err != nil {
		return failClosed(stderr, err)
	}
	fmt.Fprintf(stderr, "wrangle-attest: wrote %d statement(s) to %s\n", len(manifests), *out)
	return 0
}

func failClosed(stderr io.Writer, err error) int {
	fmt.Fprintf(stderr, "wrangle-attest: %v\nwrangle-attest: failing closed.\n", err)
	return 2
}

// resolveSubject yields the sha256 subject from exactly one of --subject (a
// passed digest, e.g. a container image) or --artifact (a file we self-digest).
func resolveSubject(subject, artifact string) (string, error) {
	switch {
	case subject != "" && artifact != "":
		return "", fmt.Errorf("pass only one of --subject or --artifact")
	case artifact != "":
		return digestArtifact(artifact)
	default:
		return subject, nil
	}
}

func validateFlags(roots []string, subject, out string) error {
	if len(roots) == 0 {
		return fmt.Errorf("at least one --metadata-root is required")
	}
	if subject == "" {
		return fmt.Errorf("--subject or --artifact is required")
	}
	if out == "" {
		return fmt.Errorf("--out is required")
	}
	return nil
}

func validateStatementMode(roots []string, subject, artifact, commit string, sign bool, out string) error {
	if len(roots) > 0 || subject != "" || artifact != "" || commit != "" {
		return fmt.Errorf("--statement cannot be combined with --metadata-root, --subject, --artifact, or --commit")
	}
	if !sign {
		return fmt.Errorf("--statement requires --sign")
	}
	if out == "" {
		return fmt.Errorf("--out is required")
	}
	return nil
}

// signStatementFile signs an existing statement file. The raw file bytes are
// the DSSE payload verbatim — never re-marshaled or normalized.
func signStatementFile(path, out string, stderr io.Writer) int {
	raw, err := os.ReadFile(path)
	if err != nil {
		return failClosed(stderr, fmt.Errorf("statement: %w", err))
	}
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 {
		return failClosed(stderr, fmt.Errorf("statement file is empty: %s", path))
	}
	if trimmed[0] != '{' || !json.Valid(raw) {
		return failClosed(stderr, fmt.Errorf("statement file is not a JSON object: %s", path))
	}

	sg, closeFn, err := newSigner()
	if err != nil {
		return failClosed(stderr, err)
	}
	defer closeFn()

	line, err := sg.sign(raw)
	if err != nil {
		return failClosed(stderr, err)
	}

	var buf bytes.Buffer
	buf.Write(line)
	buf.WriteByte('\n')
	if err := os.WriteFile(out, buf.Bytes(), 0o644); err != nil {
		return failClosed(stderr, err)
	}
	fmt.Fprintf(stderr, "wrangle-attest: wrote signed statement to %s\n", out)
	return 0
}
