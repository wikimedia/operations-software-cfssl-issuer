package signer

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	cfsslissuerapi "gerrit.wikimedia.org/r/operations/software/cfssl-issuer/api/v1alpha1"
	"gerrit.wikimedia.org/r/operations/software/cfssl-issuer/internal/testutil"
	cfsslinfo "github.com/cloudflare/cfssl/info"
	"github.com/stretchr/testify/assert"
)

var (
	errTestClientLabels   = errors.New("Labels do not match")
	errTestClientProfiles = errors.New("Profiles do not match")
	errTestClientBundle   = errors.New("Unexpected value for bundle parameter")
	validIssuerSpec       = &cfsslissuerapi.IssuerSpec{
		URL:            "https://api.signer1.tld",
		AuthSecretName: "signer1",
		Label:          "signer1-label",
		Profile:        "signer1-profile",
		Bundle:         true,
	}
	validCSR = []byte(`-----BEGIN CERTIFICATE REQUEST-----
MIIBZjCCAQwCAQAwWTEPMA0GA1UEChMGU2ltcGxlMRkwFwYDVQQLExBTaW1wbGUg
Q0ZTU0wgQVBJMSswKQYDVQQDEyJhcGkuc2ltcGxlLWNmc3NsLnN2Yy5jbHVzdGVy
LmxvY2FsMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE8ViNotrUB0RFUl0sFLm/
qrzHu6uQE2SoLq9sEeHDkiHjkSlzBZhJ1CWCvpGzghzRHhBK2pW8PSMbaw8EWIUB
kKBRME8GCSqGSIb3DQEJDjFCMEAwPgYDVR0RBDcwNYIJbG9jYWxob3N0giJhcGku
c2ltcGxlLWNmc3NsLnN2Yy5jbHVzdGVyLmxvY2FshwR/AAABMAoGCCqGSM49BAMC
A0gAMEUCIQCyhfLmHrCw4V4J3r5F5bwlhFLE5VbgsPAIifR6oBU9+wIgHIf2gbkV
yENwRHy2nk7/gUm2wbj9cC7KrS6Cb5UXsRk=
-----END CERTIFICATE REQUEST-----`)
)

type TestClient struct {
	expectLabel   string
	expectProfile string
	expectBundle  bool
}

func (c *TestClient) assertLabelAndProfile(label, profile string) error {
	if label != c.expectLabel {
		return errTestClientLabels
	}
	if profile != c.expectProfile {
		return errTestClientProfiles
	}
	return nil
}
func (c *TestClient) sign(jsonData []byte) ([]byte, error) {
	certReq := &cfsslapiCertificateRequest{}
	if err := json.Unmarshal(jsonData, certReq); err != nil {
		return nil, err
	}
	if err := c.assertLabelAndProfile(certReq.Label, certReq.Profile); err != nil {
		return nil, err
	}
	if certReq.Bundle != c.expectBundle {
		return nil, errTestClientBundle
	}
	// Just return the CSR bytes to compare in test cases
	return []byte(certReq.CSR), nil
}
func (c *TestClient) Sign(jsonData []byte) ([]byte, error) {
	return c.sign(jsonData)
}
func (c *TestClient) BundleSign(jsonData []byte) ([]byte, error) {
	return c.sign(jsonData)
}
func (c *TestClient) Info(jsonData []byte) (*cfsslinfo.Resp, error) {
	infoReq := &cfsslapiInfoRequest{}
	if err := json.Unmarshal(jsonData, infoReq); err != nil {
		return nil, err
	}
	if err := c.assertLabelAndProfile(infoReq.Label, infoReq.Profile); err != nil {
		return nil, err
	}
	return &cfsslinfo.Resp{}, nil
}

func TestNewCfssl(t *testing.T) {
	type testCase struct {
		issuerSpec     *cfsslissuerapi.IssuerSpec
		secretData     map[string][]byte
		expectedResult *cfssl
		expectedError  error
	}
	tests := map[string]testCase{
		"success-signer": {
			issuerSpec:    validIssuerSpec,
			secretData:    map[string][]byte{"key": []byte("b8093a819f367241a8e0f55125589e25")},
			expectedError: nil,
		},
		"signer-non-hex-key": {
			issuerSpec:    validIssuerSpec,
			secretData:    map[string][]byte{"key": []byte("foo")},
			expectedError: errCfsslAuthProvider,
		},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			_, err := newCfssl(tc.issuerSpec, tc.secretData)
			if tc.expectedError != nil {
				testutil.AssertErrorIs(t, tc.expectedError, err)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

func TestCfsslCheck(t *testing.T) {
	type testCase struct {
		cfssl         *cfssl
		expectedError error
	}
	tests := map[string]testCase{
		"success-check": {
			cfssl: &cfssl{
				client: &TestClient{
					expectLabel:   "signer1-label",
					expectProfile: "signer1-profile",
				},
				label:   "signer1-label",
				profile: "signer1-profile",
			},
			expectedError: nil,
		},
		"error-check": {
			cfssl: &cfssl{
				client: &TestClient{
					expectLabel:   "foo-label",
					expectProfile: "signer1-profile",
				},
				label:   "signer1-label",
				profile: "signer1-profile",
			},
			expectedError: errTestClientLabels,
		},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			err := tc.cfssl.Check()
			if tc.expectedError != nil {
				testutil.AssertErrorIs(t, tc.expectedError, err)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

func TestCfsslSign(t *testing.T) {
	type testCase struct {
		cfssl         *cfssl
		csrBytes      []byte
		expectedError error
	}
	tests := map[string]testCase{
		"success-sign": {
			cfssl: &cfssl{
				client: &TestClient{
					expectLabel:   "signer1-label",
					expectProfile: "signer1-profile",
					expectBundle:  true,
				},
				label:   "signer1-label",
				profile: "signer1-profile",
				bundle:  true,
			},
			csrBytes:      validCSR,
			expectedError: nil,
		},
		"error-sign-label-missmatch": {
			cfssl: &cfssl{
				client: &TestClient{
					expectLabel:   "foo-label",
					expectProfile: "signer1-profile",
				},
				label:   "signer1-label",
				profile: "signer1-profile",
			},
			csrBytes:      validCSR,
			expectedError: errTestClientLabels,
		},
		"error-sign-invalid-csr": {
			cfssl: &cfssl{
				client: &TestClient{
					expectLabel:   "signer1-label",
					expectProfile: "signer1-profile",
				},
				label:   "signer1-label",
				profile: "signer1-profile",
			},
			csrBytes:      []byte(`dsfjdsjfskjfld`),
			expectedError: errInvalidCSR,
		},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			result, err := tc.cfssl.Sign(context.Background(), tc.csrBytes)
			if tc.expectedError != nil {
				testutil.AssertErrorIs(t, tc.expectedError, err)
			} else {
				assert.NoError(t, err)
				assert.Equal(t, tc.csrBytes, result, "unexpected result")
			}
		})
	}
}
