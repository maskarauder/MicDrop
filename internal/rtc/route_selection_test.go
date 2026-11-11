package rtc

import "testing"

func TestRouteSelectionChecksNegotiationAndBounds(t *testing.T) {
	if !(*RouteSelection)(nil).Valid() {
		t.Fatal("legacy status rejected")
	}
	for _, local := range []bool{false, true} {
		for _, remote := range []bool{false, true} {
			r := RouteSelection{Version: 1, LocalRenomination: local, RemoteRenomination: remote, Negotiated: local && remote}
			if !r.Valid() {
				t.Fatal("valid capability rejected")
			}
			r.Negotiated = !r.Negotiated
			if r.Valid() {
				t.Fatal("inconsistent negotiation accepted")
			}
		}
	}
	for _, r := range []RouteSelection{{Version: 2}, {Version: 1, Generation: 1000001}, {Version: 1, ObservedSwitches: 1000001}} {
		if r.Valid() {
			t.Fatal("unbounded or unknown route observation accepted")
		}
	}
}
