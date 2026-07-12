package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	intoto "github.com/in-toto/attestation/go/v1"
)

// shellDigestRe mirrors the subject classifier in lib/sign_metadata.sh: a match
// is digest-form, anything else is a file path to self-digest. A digest-form
// subject must then be a valid sha256 digest — a sha512: (or malformed) digest
// errors, it is never reinterpreted as a file path.
var shellDigestRe = regexp.MustCompile(`^[a-z0-9]+:[a-f0-9]+$`)

var blankLineRe = regexp.MustCompile(`^[[:space:]]*$`)

// provenancePredicate is the predicate --seed-referrers filters to, so a re-run
// drops prior VSA referrers and rebuilds the same seed (idempotent round-trip).
const provenancePredicate = "https://slsa.dev/provenance/v1"

// runAssemble is the attest job's orchestration: sign every subject's
// build-metadata statements with one shared signer and assemble one
// per-artifact <artifact>.intoto.jsonl bundle (the provenance seed verbatim +
// that subject's signed lines) under --bundle-dir, plus every newly signed
// line to --statements-out. Everything is buffered and validated first —
// subjects, digests, bundle-name collisions, the seed, every signature — so a
// validation or signing failure (including on the last statement) writes
// nothing; a write-phase failure exits non-zero and a re-run refuses the
// partially written --bundle-dir via the pre-existence check.
//
// The "seed" is the one SLSA provenance bundle the build emits over ALL
// subjects at once. Consumers fetch a single <artifact>.intoto.jsonl per
// artifact, so that shared bundle is copied verbatim as each bundle's first
// line, and the artifact's own signed statements follow it (verify appends the
// VSA later). --seed provides it as a bundle file; --seed-referrers is the
// container path, taking raw `cosign attestation-download` output and filtering
// it to the provenancePredicate line. Verbatim: the seed's bytes are never
// re-encoded, so its signature keeps verifying.
func runAssemble(args []string, stderr io.Writer) int {
	fs := flag.NewFlagSet("wrangle-attest assemble", flag.ContinueOnError)
	fs.SetOutput(stderr)

	var roots metadataRoots
	fs.Var(&roots, "metadata-root", "directory holding a top-level wrangle_attestation_metadata.json (repeatable)")
	subjectsFile := fs.String("subjects-file", "", "file of newline-separated subjects (dist file paths / sha256:<hex> digests)")
	seed := fs.String("seed", "", "provenance seed bundle copied verbatim into every per-artifact bundle")
	seedReferrers := fs.String("seed-referrers", "", "raw cosign attestation-download output to filter to the SLSA provenance seed")
	commit := fs.String("commit", "", "scanned git commit, woven into the scan/v1 envelope only")
	sign := fs.Bool("sign", false, "keyless-sign each statement (required)")
	bundleDir := fs.String("bundle-dir", "", "directory the per-artifact <artifact>.intoto.jsonl bundles are written to")
	statementsOut := fs.String("statements-out", "", "file every newly signed line is written to, in bundle order")

	if err := fs.Parse(args); err != nil {
		return 2
	}
	if err := validateAssembleFlags(roots, *subjectsFile, *seed, *seedReferrers, *sign, *bundleDir, *statementsOut); err != nil {
		return failClosed(stderr, err)
	}

	subjects, err := readSubjectsFile(*subjectsFile)
	if err != nil {
		return failClosed(stderr, err)
	}
	specs, err := resolveBundleSpecs(subjects, *bundleDir)
	if err != nil {
		return failClosed(stderr, err)
	}

	seedBytes, err := loadSeed(*seed, *seedReferrers)
	if err != nil {
		return failClosed(stderr, err)
	}

	manifests, err := discoverManifests(roots)
	if err != nil {
		return failClosed(stderr, err)
	}
	// Manifest mode tolerates zero manifests; assemble must not — the release
	// SBOM is always present, so an empty set means a wiring bug.
	if len(manifests) == 0 {
		return failClosed(stderr, fmt.Errorf("no signed metadata produced for %s", specs[0].subject))
	}

	sg, closeFn, err := newSigner()
	if err != nil {
		return failClosed(stderr, err)
	}
	defer closeFn()

	bundles := make([]*bytes.Buffer, len(specs))
	var stmtsOut bytes.Buffer
	for i, spec := range specs {
		buf := &bytes.Buffer{}
		buf.Write(seedBytes)
		for _, m := range manifests {
			stmt, err := buildStatement(m, spec.descriptor, *commit)
			if err != nil {
				return failClosed(stderr, err)
			}
			line, err := marshalStatement(stmt)
			if err != nil {
				return failClosed(stderr, err)
			}
			line, err = sg.sign(line)
			if err != nil {
				return failClosed(stderr, err)
			}
			if len(bytes.TrimSpace(line)) == 0 {
				return failClosed(stderr, fmt.Errorf("signing produced no output for %s", spec.subject))
			}
			buf.Write(line)
			buf.WriteByte('\n')
			stmtsOut.Write(line)
			stmtsOut.WriteByte('\n')
		}
		bundles[i] = buf
	}

	if err := os.MkdirAll(*bundleDir, 0o755); err != nil {
		return failClosed(stderr, err)
	}
	for i, spec := range specs {
		if err := os.WriteFile(filepath.Join(*bundleDir, spec.name), bundles[i].Bytes(), 0o644); err != nil {
			return failClosed(stderr, err)
		}
	}
	if err := os.WriteFile(*statementsOut, stmtsOut.Bytes(), 0o644); err != nil {
		return failClosed(stderr, err)
	}
	fmt.Fprintf(stderr, "wrangle-attest: assembled %d bundle(s) into %s\n", len(specs), *bundleDir)
	return 0
}

func validateAssembleFlags(roots []string, subjectsFile, seed, seedReferrers string, sign bool, bundleDir, statementsOut string) error {
	if len(roots) == 0 {
		return fmt.Errorf("at least one --metadata-root is required")
	}
	if subjectsFile == "" {
		return fmt.Errorf("--subjects-file is required")
	}
	if (seed == "") == (seedReferrers == "") {
		return fmt.Errorf("exactly one of --seed or --seed-referrers is required")
	}
	if !sign {
		return fmt.Errorf("assemble requires --sign")
	}
	if bundleDir == "" {
		return fmt.Errorf("--bundle-dir is required")
	}
	if statementsOut == "" {
		return fmt.Errorf("--statements-out is required")
	}
	return nil
}

// readSubjectsFile splits the subjects file into lines, dropping blank
// (whitespace-only) lines. An empty set fails closed: a release subject is
// always present, so zero means a wiring bug.
//
// One subject per line — either a dist file path (self-digested) or an
// already-known sha256 digest (the container image):
//
//	dist/example_0.1.0_linux_amd64.tar.gz
//	dist/example_0.1.0_darwin_arm64.tar.gz
//	sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08
func readSubjectsFile(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("subjects-file: %w", err)
	}
	var kept []string
	for _, line := range strings.Split(string(data), "\n") {
		if blankLineRe.MatchString(line) {
			continue
		}
		kept = append(kept, line)
	}
	if len(kept) == 0 {
		return nil, fmt.Errorf("no subjects to sign in %s", path)
	}
	return kept, nil
}

// bundleSpec is one subject resolved to the descriptor its statements bind to
// and its bundle filename.
type bundleSpec struct {
	subject    string
	descriptor *intoto.ResourceDescriptor
	name       string
}

// resolveBundleSpecs classifies each subject (digest form vs. file to
// self-digest) and derives its bundle name, failing closed on a non-sha256
// digest, an unreadable file, an in-set bundle-name collision, or a name
// already present under bundleDir.
//
//	dist/example_0.1.0_linux_amd64.tar.gz  self-digested  -> example_0.1.0_linux_amd64.tar.gz.intoto.jsonl
//	sha256:9f86d081…0a08                   passes through -> sha256-9f86d081…0a08.intoto.jsonl
func resolveBundleSpecs(subjects []string, bundleDir string) ([]bundleSpec, error) {
	specs := make([]bundleSpec, 0, len(subjects))
	seen := make(map[string]bool, len(subjects))
	for _, subject := range subjects {
		digest, err := classifySubject(subject)
		if err != nil {
			return nil, err
		}
		desc, err := newSubject(digest)
		if err != nil {
			return nil, err
		}
		name := bundleName(subject)
		if seen[name] {
			return nil, fmt.Errorf("duplicate bundle basename %s — refusing to clobber", name)
		}
		seen[name] = true
		if _, err := os.Stat(filepath.Join(bundleDir, name)); err == nil {
			return nil, fmt.Errorf("bundle %s already exists under %s — refusing to clobber", name, bundleDir)
		} else if !errors.Is(err, fs.ErrNotExist) {
			return nil, fmt.Errorf("bundle-dir: %w", err)
		}
		specs = append(specs, bundleSpec{subject: subject, descriptor: desc, name: name})
	}
	return specs, nil
}

// classifySubject resolves a subject to its sha256 digest: digest-form passes
// through (after the sha256 rule), anything else is a file to self-digest.
func classifySubject(subject string) (string, error) {
	if shellDigestRe.MatchString(subject) {
		if !sha256DigestRe.MatchString(subject) {
			return "", fmt.Errorf("subject %q must be sha256:<64-hex>", subject)
		}
		return subject, nil
	}
	return digestArtifact(subject)
}

// bundleName maps a subject (dist path or algo:hex digest) to its bundle
// filename: basename with every ':' replaced by '-'.
func bundleName(subject string) string {
	base := subject
	if i := strings.LastIndexByte(base, '/'); i >= 0 {
		base = base[i+1:]
	}
	return strings.ReplaceAll(base, ":", "-") + ".intoto.jsonl"
}

// loadSeed returns the provenance seed bytes: --seed verbatim (never
// re-encoded or newline-normalized), or --seed-referrers filtered to the SLSA
// provenance envelopes. A missing/empty/malformed seed fails closed — every
// bundle starts from it.
func loadSeed(seedPath, referrersPath string) ([]byte, error) {
	if seedPath != "" {
		data, err := os.ReadFile(seedPath)
		if err != nil {
			return nil, fmt.Errorf("seed: %w", err)
		}
		if len(data) == 0 {
			return nil, fmt.Errorf("provenance seed %s is empty", seedPath)
		}
		return data, nil
	}
	return filterProvenanceReferrers(referrersPath)
}

// filterProvenanceReferrers keeps the SLSA provenance envelopes from raw
// cosign-download output (which emits all referrers, including prior VSAs),
// emitting each surviving line's ORIGINAL bytes — never a re-marshal. Zero
// matches or any malformed line fails closed.
func filterProvenanceReferrers(path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("seed-referrers: %w", err)
	}
	var out bytes.Buffer
	kept := 0
	for _, line := range strings.Split(string(data), "\n") {
		if blankLineRe.MatchString(line) {
			continue
		}
		predicateType, err := referrerPredicateType(line)
		if err != nil {
			return nil, fmt.Errorf("seed-referrers %s: %w", path, err)
		}
		if predicateType != provenancePredicate {
			continue
		}
		out.WriteString(line)
		out.WriteByte('\n')
		kept++
	}
	if kept == 0 {
		return nil, fmt.Errorf("no SLSA provenance referrer in %s", path)
	}
	return out.Bytes(), nil
}

// referrerPredicateType extracts predicateType from one DSSE-envelope line of
// cosign-download output.
func referrerPredicateType(line string) (string, error) {
	var env struct {
		DsseEnvelope struct {
			Payload string `json:"payload"`
		} `json:"dsseEnvelope"`
	}
	if err := json.Unmarshal([]byte(line), &env); err != nil {
		return "", fmt.Errorf("malformed DSSE envelope: %w", err)
	}
	payload, err := base64.StdEncoding.DecodeString(env.DsseEnvelope.Payload)
	if err != nil {
		return "", fmt.Errorf("malformed DSSE payload base64: %w", err)
	}
	var stmt struct {
		PredicateType string `json:"predicateType"`
	}
	if err := json.Unmarshal(payload, &stmt); err != nil {
		return "", fmt.Errorf("malformed DSSE payload JSON: %w", err)
	}
	return stmt.PredicateType, nil
}
