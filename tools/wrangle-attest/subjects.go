package main

import (
	"fmt"
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
	hex := strings.TrimPrefix(subject, "sha256:")
	return &intoto.ResourceDescriptor{
		Digest: map[string]string{"sha256": hex},
	}, nil
}
