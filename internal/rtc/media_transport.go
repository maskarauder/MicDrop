package rtc

// MediaTransport describes the selected audio candidate pair, not all gathered
// candidates. RelayProtocol is this endpoint's TURN hop; its peer must report
// the other hop. No address, URL, identifier, SDP or credential is retained.
type MediaTransport struct {
	Version           int    `json:"version"`
	LocalCandidate    string `json:"local_candidate_type"`
	RemoteCandidate   string `json:"remote_candidate_type"`
	CandidateProtocol string `json:"candidate_protocol"`
	RelayProtocol     string `json:"relay_protocol"`
}

func (m *MediaTransport) Valid() bool {
	if m == nil {
		return true
	}
	oneOf := func(value string, choices ...string) bool {
		for _, c := range choices {
			if value == c {
				return true
			}
		}
		return false
	}
	if m.Version != 1 || !oneOf(m.LocalCandidate, "host", "srflx", "prflx", "relay", "unavailable") ||
		!oneOf(m.RemoteCandidate, "host", "srflx", "prflx", "relay", "unavailable") ||
		!oneOf(m.CandidateProtocol, "udp", "tcp", "unavailable") ||
		!oneOf(m.RelayProtocol, "udp", "tcp", "tls", "not_applicable", "unavailable") {
		return false
	}
	switch m.LocalCandidate {
	case "host", "srflx":
		return m.RelayProtocol == "not_applicable"
	case "relay":
		return m.RelayProtocol != "not_applicable"
	case "unavailable":
		return m.RelayProtocol == "unavailable"
	}
	return true // Peer-reflexive candidates may inherit a local TURN allocation.
}
