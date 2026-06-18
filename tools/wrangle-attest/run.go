package main

import (
	"bytes"
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
// single artifact subject, builds one unsigned Statement per manifest, and
// writes them all to --out as JSONL. The file is written whole (buffer first)
// so a mid-run failure never leaves a half-written line. run_verify.sh signs
// each emitted line in the trusted post-build context.
func run(args []string, stderr io.Writer) int {
	fs := flag.NewFlagSet("wrangle-attest", flag.ContinueOnError)
	fs.SetOutput(stderr)

	var roots metadataRoots
	fs.Var(&roots, "metadata-root", "directory to walk for manifest.json (repeatable)")
	subject := fs.String("subject", "", "artifact subject digest sha256:<hex> every statement binds to")
	commit := fs.String("commit", "", "scanned git commit, woven into the scan/v1 envelope only")
	out := fs.String("out", "", "file the UNSIGNED in-toto JSONL statements are written to")

	if err := fs.Parse(args); err != nil {
		return 2
	}

	if err := validateFlags(roots, *subject, *out); err != nil {
		fmt.Fprintf(stderr, "wrangle-attest: %v\nwrangle-attest: failing closed.\n", err)
		return 2
	}

	subj, err := newSubject(*subject)
	if err != nil {
		fmt.Fprintf(stderr, "wrangle-attest: %v\nwrangle-attest: failing closed.\n", err)
		return 2
	}

	manifests, err := discoverManifests(roots)
	if err != nil {
		fmt.Fprintf(stderr, "wrangle-attest: %v\nwrangle-attest: failing closed.\n", err)
		return 2
	}

	// Build every statement into a buffer first; only touch --out once all
	// succeed, so an error on the Nth manifest can't corrupt the output.
	var buf bytes.Buffer
	for _, m := range manifests {
		stmt, err := buildStatement(m, subj, *commit)
		if err != nil {
			fmt.Fprintf(stderr, "wrangle-attest: %v\nwrangle-attest: failing closed.\n", err)
			return 2
		}
		line, err := marshalStatement(stmt)
		if err != nil {
			fmt.Fprintf(stderr, "wrangle-attest: %v\nwrangle-attest: failing closed.\n", err)
			return 2
		}
		buf.Write(line)
		buf.WriteByte('\n')
	}

	if err := os.WriteFile(*out, buf.Bytes(), 0o644); err != nil {
		fmt.Fprintf(stderr, "wrangle-attest: %v\nwrangle-attest: failing closed.\n", err)
		return 2
	}
	fmt.Fprintf(stderr, "wrangle-attest: wrote %d statement(s) to %s\n", len(manifests), *out)
	return 0
}

func validateFlags(roots []string, subject, out string) error {
	if len(roots) == 0 {
		return fmt.Errorf("at least one --metadata-root is required")
	}
	if subject == "" {
		return fmt.Errorf("--subject is required")
	}
	if out == "" {
		return fmt.Errorf("--out is required")
	}
	return nil
}
