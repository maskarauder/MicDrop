package rtc

import (
	"fmt"
	"strings"
	"testing"
)

func iceSDP(user string, count int) string {
	s := "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\na=ice-ufrag:" + user + "\r\n"
	for i := 0; i < count; i++ {
		s += fmt.Sprintf("a=candidate:%d 1 udp 123 192.0.2.1 %d typ host\r\n", i, 5000+i)
	}
	return s
}

func TestTricklePreservesOrderingAndRetriesLostAcknowledgment(t *testing.T) {
	a, b := &ICEExchange{}, &ICEExchange{}
	a.RemoteSections, _, _ = ParseICE(iceSDP("phone", 0))
	b.RemoteSections, _, _ = ParseICE(iceSDP("host", 0))
	if a.Observe(iceSDP("host", 35), true) != nil || b.Observe(iceSDP("phone", 2), true) != nil {
		t.Fatal("snapshot")
	}
	appliedA, appliedB := 0, 0
	applyA := func(ICECandidate) error { appliedA++; return nil }
	applyB := func(ICECandidate) error { appliedB++; return nil }
	first := a.Delta()
	if len(first.Candidates) != 16 || first.Complete {
		t.Fatal("unbounded/premature batch")
	}
	if b.Accept(first, applyB) != nil || b.Accept(first, applyB) != nil || appliedB != 16 {
		t.Fatal("lost response replay")
	}
	for i := 0; i < 4; i++ {
		if a.Accept(b.Delta(), applyA) != nil || b.Accept(a.Delta(), applyB) != nil {
			t.Fatal("exchange")
		}
	}
	if appliedA != 2 || appliedB != 35 || a.Ack != 35 || b.Ack != 2 || !a.RemoteComplete || !b.RemoteComplete {
		t.Fatal("incomplete exchange")
	}
}

func TestTrickleRejectsStaleConflictingAndUnboundedCandidatesBeforeNativeWork(t *testing.T) {
	sections, cs, _ := ParseICE(iceSDP("phone", 1))
	for _, mutate := range []func(*ICEDelta){
		func(d *ICEDelta) { d.Version = 2 }, func(d *ICEDelta) { d.Generation = 1 }, func(d *ICEDelta) { d.Offset = 1 },
		func(d *ICEDelta) { d.Ack = 1 }, func(d *ICEDelta) { d.Candidates[0].Ufrag = "old" },
		func(d *ICEDelta) { d.Candidates[0].MID = "wrong" }, func(d *ICEDelta) { d.Candidates[0].Index = 1 },
		func(d *ICEDelta) { d.Candidates[0].Candidate += " ufrag old" },
		func(d *ICEDelta) { d.Candidates[0].Candidate += "\r\na=private" },
		func(d *ICEDelta) { d.Candidates[0].Candidate = strings.Repeat("x", 2049) },
		func(d *ICEDelta) {
			for len(d.Candidates) <= ICEBatchSize {
				d.Candidates = append(d.Candidates, cs[0])
			}
		},
	} {
		x := &ICEExchange{RemoteSections: sections}
		d := ICEDelta{Version: 1, Candidates: append([]ICECandidate(nil), cs...)}
		mutate(&d)
		n := 0
		if x.Accept(d, func(ICECandidate) error { n++; return nil }) == nil || n != 0 {
			t.Fatal("invalid batch reached native")
		}
	}
	x := &ICEExchange{RemoteSections: sections, RelayOnly: true}
	if x.Accept(ICEDelta{Version: 1, Candidates: cs}, func(ICECandidate) error { t.Fatal("direct escaped forced relay"); return nil }) == nil {
		t.Fatal("relay")
	}
}

func TestTrickleCompletionAndGenerationCannotBeReopened(t *testing.T) {
	x := &ICEExchange{}
	if x.Observe(iceSDP("host", 1), true) != nil || x.Observe(iceSDP("host", 1), true) != nil {
		t.Fatal("complete snapshot")
	}
	if x.Observe(iceSDP("host", 2), true) == nil || x.Observe(iceSDP("new", 1), true) == nil {
		t.Fatal("reopened local generation")
	}
	x.RemoteSections, _, _ = ParseICE(iceSDP("phone", 0))
	if x.Accept(ICEDelta{Version: 1, Complete: true}, func(ICECandidate) error { return nil }) != nil {
		t.Fatal("empty complete")
	}
	_, cs, _ := ParseICE(iceSDP("phone", 1))
	if x.Accept(ICEDelta{Version: 1, Candidates: cs}, func(ICECandidate) error { t.Fatal("after end"); return nil }) == nil {
		t.Fatal("reopened remote generation")
	}
}

func TestTrickleMemoryAndMalformedSDPAreBounded(t *testing.T) {
	for _, sdp := range []string{"", "v=0\n", iceSDP("host", 129), iceSDP("host", 0) + strings.Repeat("x", 65536), strings.ReplaceAll(iceSDP("host", 1), "5000", "0")} {
		if _, _, err := ParseICE(sdp); err == nil {
			t.Fatal("invalid SDP")
		}
	}
	x := &ICEExchange{}
	if x.Observe(iceSDP("host", 128), false) != nil {
		t.Fatal("maximum count")
	}
	if x.Observe(iceSDP("host", 128), false) != nil || len(x.Local) != 128 {
		t.Fatal("duplicates grew buffer")
	}
}
