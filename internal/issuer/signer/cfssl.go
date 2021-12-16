package signer

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"

	cfsslissuerapi "gerrit.wikimedia.org/r/operations/software/cfssl-issuer/api/v1alpha1"
	cfsslclient "github.com/cloudflare/cfssl/api/client"
	cfsslauth "github.com/cloudflare/cfssl/auth"
	cfsslinfo "github.com/cloudflare/cfssl/info"
	ctrl "sigs.k8s.io/controller-runtime"
)

var (
	errCfsslAuthProvider = errors.New("failed creating cfssl auth provider")
)

type HealthChecker interface {
	Check() error
}

type HealthCheckerBuilder func(issuerSpec *cfsslissuerapi.IssuerSpec, secretData map[string][]byte) (HealthChecker, error)

type Signer interface {
	Sign(context.Context, []byte) ([]byte, error)
}

type SignerBuilder func(issuerSpec *cfsslissuerapi.IssuerSpec, secretData map[string][]byte) (Signer, error)

// Request body send to CFSSL authsign endpoint.
// While the API defines "label" as optional, we have it mandatory here as
// the IssuerSpec requires it to be set for health check requests anyways.
// https://github.com/cloudflare/cfssl/blob/master/doc/api/endpoint_authsign.txt
type cfsslapiCertificateRequest struct {
	CSR     string `json:"certificate_request"`
	Label   string `json:"label"`
	Profile string `json:"profile,omitempty"`
	Bundle  bool   `json:"bundle,omitempty"`
}

// Request body send to CFSSL info endpoint.
// https://github.com/cloudflare/cfssl/blob/master/doc/api/endpoint_info.txt
type cfsslapiInfoRequest struct {
	Label   string `json:"label"`
	Profile string `json:"profile,omitempty"`
}

// BasicRemote is a stripped down version of cfssl.Remote to make mocking easier
type BasicRemote interface {
	Sign(jsonData []byte) ([]byte, error)
	BundleSign(jsonData []byte) ([]byte, error)
	Info(jsonData []byte) (*cfsslinfo.Resp, error)
}

type cfssl struct {
	client  BasicRemote
	label   string
	profile string
	bundle  bool
}

func newCfssl(issuerSpec *cfsslissuerapi.IssuerSpec, secretData map[string][]byte) (*cfssl, error) {
	rootCAs, _ := x509.SystemCertPool()
	tlsconfig := &tls.Config{
		RootCAs: rootCAs,
	}
	keyStr := string(secretData["key"])
	authProvider, err := cfsslauth.New(keyStr, secretData["additional_data"])
	if err != nil {
		return nil, fmt.Errorf("%w reason: %s", errCfsslAuthProvider, err)
	}

	//FIXME: Because of a bug in cfssl normalizeURL function, issuerSpec.URL must not end in a /
	return &cfssl{
		client:  cfsslclient.NewAuthServer(issuerSpec.URL, tlsconfig, authProvider),
		label:   issuerSpec.Label,
		profile: issuerSpec.Profile,
		bundle:  issuerSpec.Bundle,
	}, nil
}

func NewCfsslSigner(issuerSpec *cfsslissuerapi.IssuerSpec, secretData map[string][]byte) (Signer, error) {
	return newCfssl(issuerSpec, secretData)
}

func NewCfsslHealthChecker(issuerSpec *cfsslissuerapi.IssuerSpec, secretData map[string][]byte) (HealthChecker, error) {
	return newCfssl(issuerSpec, secretData)
}

// Check is called for health checks
func (c *cfssl) Check() error {
	// Unfortunately the /api/v1/cfssl/info endpoint is only available without authentication,
	// so this won't check credentials early.
	infoReq := cfsslapiInfoRequest{
		Label:   c.label,
		Profile: c.profile,
	}
	jsonData, err := json.Marshal(infoReq)
	if err != nil {
		return fmt.Errorf("Failed to json.Marshal CSR: %w", err)
	}
	_, err = c.client.Info(jsonData)
	return err
}

func (c *cfssl) Sign(ctx context.Context, csrBytes []byte) ([]byte, error) {
	log := ctrl.LoggerFrom(ctx)

	// Verify valid CSR
	_, err := parseCSR(csrBytes)
	if err != nil {
		return nil, err
	}

	csr := cfsslapiCertificateRequest{
		CSR:     string(csrBytes),
		Label:   c.label,
		Profile: c.profile,
		Bundle:  c.bundle,
	}
	log.Info("Signing cert with", "label", c.label, "profile", c.profile, "bundle", c.bundle)
	jsonData, err := json.Marshal(csr)
	if err != nil {
		return nil, fmt.Errorf("Failed to json.Marshal CSR: %w", err)
	}

	var resp []byte
	if c.bundle {
		resp, err = c.client.BundleSign(jsonData)
	} else {
		resp, err = c.client.Sign(jsonData)
	}
	if err != nil {
		return nil, fmt.Errorf("Error from cfssl API: %w", err)
	}

	return resp, nil
}
