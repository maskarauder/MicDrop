package diagnostics

// Initial Android gathering only. The fixed vocabulary and bounded counts
// deliberately exclude SDP, candidate addresses, URLs and native error text.
type ICEGathering struct {
	Version             int    `json:"version"`
	Result              string `json:"result"`
	ElapsedMS           int64  `json:"elapsed_ms"`
	RelayOnly           bool   `json:"relay_only"`
	HostCandidates      int    `json:"host_candidates"`
	ReflexiveCandidates int    `json:"reflexive_candidates"`
	RelayCandidates     int    `json:"relay_candidates"`
	OtherCandidates     int    `json:"other_candidates"`
	MediaSections       int    `json:"media_sections"`
	ReadySections       int    `json:"ready_sections"`
	CandidateErrors     int    `json:"candidate_errors"`
	LastErrorCode       int    `json:"last_error_code"`
}

func (g *ICEGathering) valid() bool {
	if g == nil {
		return true
	}
	if (g.Version < 1 || g.Version > 3) || !member(g.Result, "complete|trickle|candidates_ready|deadline_with_candidates|timed_out|no_candidates") ||
		g.ElapsedMS < 0 || g.ElapsedMS > 120000 || g.CandidateErrors < 0 || g.CandidateErrors > 1_000_000 ||
		g.LastErrorCode < 0 || g.LastErrorCode > 999 || (g.CandidateErrors == 0 && g.LastErrorCode != 0) {
		return false
	}
	if g.Result == "trickle" && g.Version != 3 {
		return false
	}
	if g.Result == "candidates_ready" && (g.Version != 2 || !g.RelayOnly) {
		return false
	}
	for _, n := range []int{g.HostCandidates, g.ReflexiveCandidates, g.RelayCandidates, g.OtherCandidates, g.MediaSections, g.ReadySections} {
		if n < 0 || n > 65536 {
			return false
		}
	}
	if g.ReadySections > g.MediaSections {
		return false
	}
	if g.Result == "complete" || g.Result == "candidates_ready" || g.Result == "deadline_with_candidates" {
		return g.MediaSections > 0 && g.ReadySections == g.MediaSections &&
			(g.HostCandidates+g.ReflexiveCandidates+g.RelayCandidates > 0) && (!g.RelayOnly || g.RelayCandidates > 0)
	}
	return true
}
