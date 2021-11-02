package testutil

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func AssertErrorIs(t *testing.T, expectedError, actualError error) {
	if !assert.Error(t, actualError) {
		return
	}
	assert.ErrorIsf(t, actualError, expectedError, "unexpected error type. expected: %v, got: %v", expectedError, actualError)
}
