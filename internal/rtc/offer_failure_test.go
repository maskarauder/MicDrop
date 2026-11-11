package rtc

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestOfferFailureExplainsNativeGatheringWithoutCopyingPrivateErrors(t *testing.T) {
	for _, tc := range []struct{ message, code string }{
		{"ICE candidate gathering timed out", "ice_gathering_timeout"},
		{"LAN candidate gathering timed out", "ice_gathering_timeout"},
		{"ICE gathering finished without usable candidates", "ice_candidates_unavailable"},
		{"WebRTC description failed or timed out", "description_failed_or_timed_out"},
		{"Session description unavailable", "description_unavailable"},
	} {
		if got := DescribeOfferFailure(errors.New(tc.message)); got.Code != tc.code {
			t.Fatalf("%q classified as %q", tc.message, got.Code)
		}
	}
	private := errors.New("https://private-host/ice?secret=private-token\nprivate-sdp")
	for _, err := range []error{private,
		&offerError{stage: "ice_configuration_fetch", cause: private},
		&offerError{stage: "ice_configuration_apply", cause: private},
	} {
		data, marshalErr := json.Marshal(DescribeOfferFailure(err))
		if marshalErr != nil || strings.Contains(string(data), "private-") || strings.Contains(string(data), "https:") {
			t.Fatal("untrusted offer error leaked into diagnostics")
		}
	}
	if got := DescribeOfferFailure(&offerError{stage: "ice_configuration_fetch", cause: private}); got.Code != "ice_configuration_unavailable" {
		t.Fatal("configuration fetch failure lost its stage")
	}
}
