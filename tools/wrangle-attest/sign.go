package main

import (
	"bytes"
	"fmt"

	"github.com/carabiner-dev/signer"
	"github.com/carabiner-dev/signer/options"
)

// statementSigner signs one in-toto statement and returns its canonical
// serialized bundle/envelope bytes. Mirrors `bnd statement`: one shared
// Signer across statements so the OIDC + Fulcio flow runs once.
type statementSigner interface {
	sign(statement []byte) ([]byte, error)
}

// newSigner builds the shared signer for --sign and a closer to release it.
// Overridden by the hermetic unit test with a local-key signer.
var newSigner = func() (statementSigner, func(), error) {
	ks, err := newKeylessSigner()
	if err != nil {
		return nil, nil, err
	}
	return ks, func() { _ = ks.close() }, nil
}

// keylessSigner is the production sigstore backend: ambient GitHub OIDC ->
// Fulcio cert -> Rekor, producing a Sigstore bundle byte-identical to
// `bnd statement`.
type keylessSigner struct {
	sg *signer.Signer
}

// newKeylessSigner builds the shared sigstore signer from the bnd defaults.
func newKeylessSigner() (*keylessSigner, error) {
	sg, err := signer.NewSignerFromSet(options.DefaultSignerSet())
	if err != nil {
		return nil, fmt.Errorf("building signer: %w", err)
	}
	return &keylessSigner{sg: sg}, nil
}

func (k *keylessSigner) sign(statement []byte) ([]byte, error) {
	art, err := k.sg.SignStatement(statement)
	if err != nil {
		return nil, fmt.Errorf("signing statement: %w", err)
	}
	var buf bytes.Buffer
	if _, err := art.WriteTo(&buf); err != nil {
		return nil, fmt.Errorf("serializing signed statement: %w", err)
	}
	return buf.Bytes(), nil
}

func (k *keylessSigner) close() error { return k.sg.Close() }
