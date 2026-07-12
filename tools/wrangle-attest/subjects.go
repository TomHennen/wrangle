package main

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/carabiner-dev/hasher"
	intoto "github.com/in-toto/attestation/go/v1"
)

// The artifact subject is a single sha256 digest. The GitHub attestation store
// (bnd push github) keys by subject digest and rejects a multi-digest subject,
// so sha256 is the only algorithm the engine binds to. run_verify.sh already
// computes this same digest for the VSA subject, so the SBOM and the VSA share
// one subject and a policy resolving by artifact digest finds both.
var sha256DigestRe = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

// sha256Hasher hashes sha256 only: hasher's default set is sha256+sha512, which
// would bind a multi-digest subject the store rejects.
func sha256Hasher() *hasher.Hasher {
	h := hasher.New()
	h.Options.Algorithms = []intoto.HashAlgorithm{intoto.AlgorithmSHA256}
	return h
}

// newSubject parses the single --subject digest (sha256:<hex>) into the
// in-toto descriptor every statement is bound to. A malformed digest fails
// closed rather than producing an unbound or wrongly-bound attestation.
func newSubject(subject string) (*intoto.ResourceDescriptor, error) {
	if !sha256DigestRe.MatchString(subject) {
		return nil, fmt.Errorf("subject %q must be sha256:<64-hex>", subject)
	}
	hs := hasher.NewHashSet(map[string]string{
		string(intoto.AlgorithmSHA256): strings.TrimPrefix(subject, "sha256:"),
	})
	// The digest-only descriptor: the plural FileHashSet helper also sets Uri
	// and Name, leaking local paths into the signed statement.
	return hs.ToResourceDescriptor(), nil
}

// digestArtifact hashes a file to sha256:<hex>, the same digest run_verify.sh
// binds the VSA to. A missing/unreadable file fails closed.
func digestArtifact(path string) (string, error) {
	fhs, err := sha256Hasher().HashFiles([]string{path})
	if err != nil {
		return "", fmt.Errorf("artifact: %w", err)
	}
	hs, ok := (*fhs)[path]
	if !ok {
		return "", fmt.Errorf("artifact: no hash produced for %s", path)
	}
	digest, ok := hs[intoto.AlgorithmSHA256]
	if !ok || digest == "" {
		return "", fmt.Errorf("artifact: no sha256 digest produced for %s", path)
	}
	return "sha256:" + digest, nil
}
