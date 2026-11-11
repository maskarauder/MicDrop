package rtc

import "testing"

func TestMediaTransportAllowsOnlyBoundedSelectedPairObservations(t *testing.T) {
	if !(*MediaTransport)(nil).Valid() {
		t.Fatal("old native status rejected")
	}
	for _, local := range []string{"host", "srflx", "prflx", "relay", "unavailable"} {
		for _, hop := range []string{"udp", "tcp", "tls", "not_applicable", "unavailable"} {
			m := MediaTransport{1, local, "relay", "udp", hop}
			want := local == "prflx" || (local == "relay" && hop != "not_applicable") ||
				((local == "host" || local == "srflx") && hop == "not_applicable") ||
				(local == "unavailable" && hop == "unavailable")
			if m.Valid() != want {
				t.Fatalf("local=%s hop=%s valid=%t", local, hop, m.Valid())
			}
		}
	}
	for _, change := range []func(*MediaTransport){
		func(m *MediaTransport) { m.Version = 2 },
		func(m *MediaTransport) { m.LocalCandidate = "private-address" },
		func(m *MediaTransport) { m.RemoteCandidate = "private-address" },
		func(m *MediaTransport) { m.CandidateProtocol = "tls" },
		func(m *MediaTransport) { m.RelayProtocol = "turns:private-server" },
		func(m *MediaTransport) { m.RelayProtocol = "" },
	} {
		m := MediaTransport{1, "relay", "host", "udp", "tls"}
		change(&m)
		if m.Valid() {
			t.Fatal("invalid/private observation accepted")
		}
	}
}
