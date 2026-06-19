package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"

	intoto "github.com/in-toto/attestation/go/v1"
)

// The artifact subject is a single sha256 digest. The GitHub attestation store
// (bnd push github) keys by subject digest and rejects a multi-digest subject,
// so sha256 is the only algorithm the engine binds to. run_verify.sh already
// computes this same digest for the VSA subject, so the SBOM and the VSA share
// one subject and a policy resolving by artifact digest finds both.
var sha256DigestRe = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

// newSubject parses the single --subject digest (sha256:<hex>) into the
// in-toto descriptor every statement is bound to. A malformed digest fails
// closed rather than producing an unbound or wrongly-bound attestation.
func newSubject(subject string) (*intoto.ResourceDescriptor, error) {
	if !sha256DigestRe.MatchString(subject) {
		return nil, fmt.Errorf("subject %q must be sha256:<64-hex>", subject)
	}
	h := strings.TrimPrefix(subject, "sha256:")
	return &intoto.ResourceDescriptor{
		Digest: map[string]string{"sha256": h},
	}, nil
}

// digestArtifact hashes a file to sha256:<hex>, the same digest run_verify.sh
// binds the VSA to. A missing/unreadable file fails closed.
func digestArtifact(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("artifact: %w", err)
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", fmt.Errorf("hashing artifact: %w", err)
	}
	return "sha256:" + hex.EncodeToString(h.Sum(nil)), nil
}
