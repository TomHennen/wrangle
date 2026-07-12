package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	intoto "github.com/in-toto/attestation/go/v1"
)

const vsaPredicateType = "https://slsa.dev/verification_summary/v1"

// collectors accumulates repeated --collector flags.
type collectors []string

func (c *collectors) String() string { return fmt.Sprint([]string(*c)) }
func (c *collectors) Set(v string) error {
	*c = append(*c, v)
	return nil
}

// verifyOpts is the parsed verify-subcommand invocation.
type verifyOpts struct {
	subject     string // digest-form subject as given (sha256:<hex>), or ""
	artifact    string // file subject to self-digest, or ""
	policy      string
	bundle      string // per-artifact bundle: jsonl collector + append target
	extra       collectors
	context     string
	attestation string
	fail        bool
	out         string
}

// runVerify implements the verify subcommand: evaluate the policy over one
// subject by exec-ing the sibling ampel binary, fail closed unless ampel's
// exit code AND the VSA it emitted agree on the verdict, then keyless-sign the
// VSA verbatim, write the signed line to --out, and append it to --bundle.
// ampel's report (stdout) passes through to stdout; everything the engine says
// goes to stderr. Exit 0 = verified and delivered; 1 = the policy verdict is
// FAILED (with --fail=true); 2 = any other failure, signing untouched.
func runVerify(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("wrangle-attest verify", flag.ContinueOnError)
	fs.SetOutput(stderr)

	o := verifyOpts{}
	fs.StringVar(&o.subject, "subject", "", "artifact subject digest sha256:<hex> the VSA binds to")
	fs.StringVar(&o.artifact, "artifact", "", "file to self-digest into the sha256 subject (alternative to --subject)")
	fs.StringVar(&o.policy, "policy", "", "ampel PolicySet path or locator")
	fs.StringVar(&o.bundle, "bundle", "", "attest-assembled per-artifact bundle: fed to the policy as the jsonl collector and appended with the signed VSA")
	fs.Var(&o.extra, "collector", "additional ampel collector (repeatable, e.g. the container's oci: referrers)")
	fs.StringVar(&o.context, "context", "", "ampel policy context (KEY:VALUE, comma-separated)")
	fs.StringVar(&o.attestation, "attestation", "", "explicit attestation file loaded in addition to the collectors")
	fs.BoolVar(&o.fail, "fail", true, "when true a FAILED verdict exits 1 and nothing is signed; when false a FAILED VSA is still signed and delivered")
	fs.StringVar(&o.out, "out", "", "file the single signed VSA line is written to")

	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() > 0 {
		return failClosed(stderr, fmt.Errorf("verify: unexpected argument %q", fs.Arg(0)))
	}

	subjectArg, err := resolveSubject(o.subject, o.artifact)
	if err != nil {
		return failClosed(stderr, err)
	}
	if err := validateVerifyOpts(&o, subjectArg); err != nil {
		return failClosed(stderr, err)
	}

	resultsDir, err := os.MkdirTemp("", "wrangle-verify")
	if err != nil {
		return failClosed(stderr, err)
	}
	defer os.RemoveAll(resultsDir)
	resultsPath := filepath.Join(resultsDir, "vsa.intoto.json")

	report, rc := runAmpel(ampelVerifyArgs(&o, subjectArg, resultsPath), resultsPath, stderr)
	// The report reaches stdout (the step summary) whatever the verdict.
	if _, err := stdout.Write(report); err != nil {
		return failClosed(stderr, fmt.Errorf("writing report: %w", err))
	}

	raw, readErr := os.ReadFile(resultsPath)
	if rc != 0 {
		// ampel overloads exit 1 for both a FAILED verdict and a tool error;
		// the emitted VSA (written on FAIL, absent on error) tells them apart.
		if o.fail && readErr == nil && vsaVerdict(raw) == "FAILED" {
			fmt.Fprintf(stderr, "wrangle-attest: policy verdict FAILED for %s\n", subjectArg)
			return 1
		}
		return failClosed(stderr, fmt.Errorf("ampel verify failed (exit %d)", rc))
	}
	if readErr != nil {
		return failClosed(stderr, fmt.Errorf("ampel exited 0 but wrote no VSA: %w", readErr))
	}
	if err := validateVSA(raw, subjectArg, o.fail); err != nil {
		return failClosed(stderr, err)
	}

	return signAndDeliver(raw, o.out, o.bundle, stderr)
}

// validateVerifyOpts fail-closes everything checkable before ampel runs: the
// required flags, the subject shape, and the append target (must exist
// non-empty — a VSA-only bundle is impossible — and must not alias --out).
func validateVerifyOpts(o *verifyOpts, subjectArg string) error {
	switch {
	case o.policy == "":
		return fmt.Errorf("--policy is required")
	case o.bundle == "":
		return fmt.Errorf("--bundle is required")
	case o.out == "":
		return fmt.Errorf("--out is required")
	case subjectArg == "":
		return fmt.Errorf("--subject or --artifact is required")
	}
	if !sha256DigestRe.MatchString(subjectArg) {
		return fmt.Errorf("subject %q must be sha256:<64-hex>", subjectArg)
	}
	if filepath.Clean(o.bundle) == filepath.Clean(o.out) {
		return fmt.Errorf("--out must not be the same file as --bundle")
	}
	info, err := os.Stat(o.bundle)
	if err != nil {
		return fmt.Errorf("bundle: %w", err)
	}
	if info.Size() == 0 {
		return fmt.Errorf("bundle %s is empty", o.bundle)
	}
	return nil
}

// ampelVerifyArgs builds the ampel argv. A digest-form --subject passes
// through; a file subject was self-digested, and the precomputed hash goes
// via --subject-hash so the VSA subject stays single-sha256 (ampel's own file
// hasher would bind sha256+sha512, which the attestation store rejects).
func ampelVerifyArgs(o *verifyOpts, digest, resultsPath string) []string {
	args := []string{"verify"}
	if o.subject != "" {
		args = append(args, "--subject="+o.subject)
	} else {
		args = append(args, "--subject-hash="+digest)
	}
	args = append(args, "--collector=jsonl:"+o.bundle)
	for _, c := range o.extra {
		args = append(args, "--collector="+c)
	}
	args = append(args,
		"--policy="+o.policy,
		"--exit-code="+strconv.FormatBool(o.fail),
		"--attest-results",
		"--attest-format=vsa",
		"--results-path="+resultsPath)
	if o.context != "" {
		args = append(args, "--context", o.context)
	}
	if o.attestation != "" {
		args = append(args, "--attestation", o.attestation)
	}
	return append(args, "--format=html")
}

// runAmpel execs the sibling ampel binary, retrying once so a transient
// collector/locator fetch can't block a release. Each attempt starts from a
// removed results file and a fresh report buffer, so only the surviving
// attempt's VSA and report are ever evaluated or emitted.
func runAmpel(argv []string, resultsPath string, stderr io.Writer) ([]byte, int) {
	var report bytes.Buffer
	for attempt := 0; ; attempt++ {
		report.Reset()
		if err := os.Remove(resultsPath); err != nil && !os.IsNotExist(err) {
			fmt.Fprintf(stderr, "wrangle-attest: removing stale results: %v\n", err)
			return report.Bytes(), 2
		}
		cmd := exec.Command("ampel", argv...)
		cmd.Stdout = &report
		cmd.Stderr = stderr
		cmd.Env = ampelEnv(os.Environ())
		err := cmd.Run()
		if err == nil {
			return report.Bytes(), 0
		}
		rc := 2
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			rc = exitErr.ExitCode()
		} else {
			fmt.Fprintf(stderr, "wrangle-attest: exec ampel: %v\n", err)
		}
		if attempt > 0 {
			return report.Bytes(), rc
		}
		fmt.Fprintf(stderr, "wrangle-attest: ampel failed (exit %d); retrying once for transient I/O\n", rc)
		time.Sleep(retryDelay())
	}
}

// retryDelay honors WRANGLE_RETRY_DELAY (seconds) like lib/retry.sh; tests
// set it to 0.
func retryDelay() time.Duration {
	if v := os.Getenv("WRANGLE_RETRY_DELAY"); v != "" {
		if secs, err := strconv.Atoi(v); err == nil && secs >= 0 {
			return time.Duration(secs) * time.Second
		}
	}
	return 5 * time.Second
}

// ampelEnv strips the signing token (and the mint-anything request vars) from
// the child env: ampel parses semi-trusted attestations and policy and must
// never hold signing material. AMPEL_* is dropped too — ampel resolves policy
// context keys from AMPEL_<KEY> env vars, so a stray variable could steer the
// verdict.
func ampelEnv(env []string) []string {
	kept := make([]string, 0, len(env))
	for _, kv := range env {
		name, _, _ := strings.Cut(kv, "=")
		switch {
		case name == "SIGSTORE_ID_TOKEN",
			strings.HasPrefix(name, "ACTIONS_ID_TOKEN_REQUEST_"),
			strings.HasPrefix(name, "AMPEL_"):
			continue
		}
		kept = append(kept, kv)
	}
	return kept
}

// vsaStatement is the slice of the emitted VSA the verdict protocol reads.
type vsaStatement struct {
	Type          string `json:"_type"`
	PredicateType string `json:"predicateType"`
	Subject       []struct {
		Digest map[string]string `json:"digest"`
	} `json:"subject"`
	Predicate struct {
		VerificationResult string `json:"verificationResult"`
	} `json:"predicate"`
}

// vsaVerdict extracts predicate.verificationResult, or "" if raw is not a VSA.
func vsaVerdict(raw []byte) string {
	var stmt vsaStatement
	if err := json.Unmarshal(raw, &stmt); err != nil {
		return ""
	}
	return stmt.Predicate.VerificationResult
}

// validateVSA is the fail-closed half of the verdict protocol: ampel's exit
// code alone is not a safe PASS signal (exit 0 also covers SOFTFAIL and other
// non-FAIL statuses), so the emitted VSA must independently agree. The
// statement must be a VSA bound to exactly the requested single-sha256
// subject, and its verificationResult must be PASSED — or, with fail=false
// (where a FAILED verdict is still signed and delivered), explicitly FAILED.
func validateVSA(raw []byte, subjectArg string, failMode bool) error {
	var stmt vsaStatement
	if err := json.Unmarshal(raw, &stmt); err != nil {
		return fmt.Errorf("VSA is not valid JSON: %w", err)
	}
	if stmt.Type != intoto.StatementTypeUri {
		return fmt.Errorf("VSA _type is %q, want %q", stmt.Type, intoto.StatementTypeUri)
	}
	if stmt.PredicateType != vsaPredicateType {
		return fmt.Errorf("VSA predicateType is %q, want %q", stmt.PredicateType, vsaPredicateType)
	}
	wantHex := strings.TrimPrefix(subjectArg, "sha256:")
	if len(stmt.Subject) != 1 || len(stmt.Subject[0].Digest) != 1 ||
		stmt.Subject[0].Digest["sha256"] != wantHex {
		return fmt.Errorf("VSA subject is not the single sha256 digest %s", subjectArg)
	}
	switch v := stmt.Predicate.VerificationResult; {
	case v == "PASSED":
		return nil
	case v == "FAILED" && !failMode:
		return nil
	default:
		return fmt.Errorf("VSA verificationResult is %q but ampel exited 0 — refusing to sign", v)
	}
}
