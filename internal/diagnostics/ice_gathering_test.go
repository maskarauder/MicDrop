package diagnostics

import "testing"

func TestTrickleEvidenceAllowsCandidateFreeNegotiationOnlyInVersionThree(t *testing.T) {
	g := &ICEGathering{Version: 3, Result: "trickle", MediaSections: 1, ReadySections: 0, RelayOnly: true}
	if !g.valid() {
		t.Fatal("candidate-free trickle rejected")
	}
	g.Version = 2
	if g.valid() {
		t.Fatal("trickle accepted by old diagnostic contract")
	}
}

func gatheringFixture() *ICEGathering {
	return &ICEGathering{Version: 1, Result: "deadline_with_candidates", ElapsedMS: 15001,
		RelayOnly: true, RelayCandidates: 1, MediaSections: 1, ReadySections: 1, CandidateErrors: 1, LastErrorCode: 701}
}

func TestGatheringEvidenceAcceptsSetupFailuresAndOptionalReports(t *testing.T) {
	r, end := reportFixture(), terminalFixture()
	r.ICEGathering, end.ICEGathering = gatheringFixture(), gatheringFixture()
	for _, result := range []string{"complete", "deadline_with_candidates", "timed_out", "no_candidates"} {
		r.ICEGathering.Result, end.ICEGathering.Result = result, result
		if !r.Valid() || !end.Valid("connection_failed") {
			t.Fatal("gathering result rejected", result)
		}
	}
	r.ICEGathering.ReadySections, r.ICEGathering.RelayCandidates = 0, 0
	if !r.Valid() {
		t.Fatal("failed allocation must remain reportable")
	}
	r.ICEGathering, end.ICEGathering = nil, nil
	if !r.Valid() || !end.Valid("connection_failed") {
		t.Fatal("legacy report rejected")
	}
}

func TestEarlyRelayEvidenceRequiresNewCapabilityAndReadyRelay(t *testing.T) {
	g := gatheringFixture()
	g.Result, g.ElapsedMS = "candidates_ready", 550
	if g.valid() {
		t.Fatal("early result must not be advertised as version 1")
	}
	g.Version = 2
	if !g.valid() {
		t.Fatal("ready relay rejected")
	}
	g.RelayOnly = false
	if g.valid() {
		t.Fatal("early optimization must be relay-only")
	}
	g.RelayOnly, g.RelayCandidates = true, 0
	if g.valid() {
		t.Fatal("early setup accepted without relay")
	}
}

func TestGatheringEvidenceRejectsPrivateLabelsAndInvalidBounds(t *testing.T) {
	for _, mutate := range []func(*ICEGathering){
		func(g *ICEGathering) { g.Version = 4 },
		func(g *ICEGathering) { g.Result = "private exception" },
		func(g *ICEGathering) { g.ElapsedMS = -1 },
		func(g *ICEGathering) { g.ElapsedMS = 120001 },
		func(g *ICEGathering) { g.HostCandidates = -1 },
		func(g *ICEGathering) { g.ReflexiveCandidates = 65537 },
		func(g *ICEGathering) { g.RelayCandidates = 0 },
		func(g *ICEGathering) { g.OtherCandidates = -1 },
		func(g *ICEGathering) { g.MediaSections = 0 },
		func(g *ICEGathering) { g.ReadySections = 2 },
		func(g *ICEGathering) { g.ReadySections = 0 },
		func(g *ICEGathering) { g.CandidateErrors = 0 },
		func(g *ICEGathering) { g.CandidateErrors = 1_000_001 },
		func(g *ICEGathering) { g.LastErrorCode = 1000 },
	} {
		r, end := reportFixture(), terminalFixture()
		r.ICEGathering = gatheringFixture()
		mutate(r.ICEGathering)
		end.ICEGathering = r.ICEGathering
		if r.Valid() || end.Valid("connection_failed") {
			t.Fatal("unsafe gathering report accepted")
		}
	}
}
