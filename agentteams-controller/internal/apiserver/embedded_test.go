package apiserver

import "testing"

func TestServiceAccountMaxTokenExpirationArg(t *testing.T) {
	const want = "--service-account-max-token-expiration=87600h0m0s"
	if got := serviceAccountMaxTokenExpirationArg(); got != want {
		t.Fatalf("serviceAccountMaxTokenExpirationArg()=%q, want %q", got, want)
	}
}
