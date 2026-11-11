package rtc

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

func continuousPair(t *testing.T) (*ContinuousICE, *ContinuousICE) {
	t.Helper()
	a, b := &ContinuousICE{Generation: 2}, &ContinuousICE{Generation: 2}
	for _, err := range []error{a.Observe(iceSDP("host", 1)), a.SetRemote(iceSDP("phone", 0)),
		b.Observe(iceSDP("phone", 1)), b.SetRemote(iceSDP("host", 0))} {
		if err != nil {
			t.Fatal(err)
		}
	}
	return a, b
}

func TestContinuousSnapshotsReplaceRemoveAndRetryWithoutHistory(t *testing.T) {
	a, b := continuousPair(t)
	native := map[ICECandidate]bool{}
	adds, removes := 0, 0
	add := func(c ICECandidate) error {
		if native[c] {
			t.Fatal("duplicate native addition")
		}
		native[c] = true
		adds++
		return nil
	}
	remove := func(c ICECandidate) error {
		if !native[c] {
			t.Fatal("duplicate native removal")
		}
		delete(native, c)
		removes++
		return nil
	}
	noop := func(ICECandidate) error { return nil }
	for i := 0; i < 1000; i++ {
		sdp := strings.ReplaceAll(iceSDP("host", 1), "5000", fmt.Sprint(5000+i))
		if err := a.Observe(sdp); err != nil {
			t.Fatal(err)
		}
		d := a.Snapshot()
		// A lost response repeats the full snapshot, never native application.
		if err := b.Accept(d, add, remove); err != nil {
			t.Fatal(err)
		}
		if err := b.Accept(d, add, remove); err != nil {
			t.Fatal(err)
		}
		if err := a.Accept(b.Snapshot(), noop, noop); err != nil {
			t.Fatal(err)
		}
		if len(a.Local) != 1 || len(b.Remote) != 1 || len(native) != 1 || a.Ack != a.Revision {
			t.Fatal("unbounded/stalled exchange")
		}
		if a.Snapshot().Candidates != nil {
			t.Fatal("acknowledged set retransmitted")
		}
	}
	if adds != 1000 || removes != 999 {
		t.Fatal(adds, removes)
	}
	if err := a.Observe(iceSDP("host", 0)); err != nil {
		t.Fatal(err)
	}
	empty := a.Snapshot()
	wire, _ := json.Marshal(empty)
	if !strings.Contains(string(wire), `"candidates":[]`) {
		t.Fatal("empty set must be explicit")
	}
	if err := b.Accept(empty, add, remove); err != nil || len(native) != 0 {
		t.Fatal("removal", err)
	}
	diagnostics, _ := json.Marshal(b.Status())
	if strings.Contains(string(diagnostics), "192.0.2") || strings.Contains(string(diagnostics), "phone") {
		t.Fatal("private snapshot logged")
	}
}

func TestContinuousRejectsWrongGenerationReplayAndBoundsBeforeNative(t *testing.T) {
	for _, mutate := range []func(*ICESnapshot){
		func(d *ICESnapshot) { d.Generation = 1 }, func(d *ICESnapshot) { d.Version = 2 },
		func(d *ICESnapshot) { d.Ack = 99 }, func(d *ICESnapshot) { d.Revision = 0 },
		func(d *ICESnapshot) { d.Revision = MaxICERevision + 1 }, func(d *ICESnapshot) { d.Candidates = nil },
		func(d *ICESnapshot) { (*d.Candidates)[0].Ufrag = "stale" },
		func(d *ICESnapshot) { (*d.Candidates)[0].Candidate += " ufrag stale" },
		func(d *ICESnapshot) { *d.Candidates = append(*d.Candidates, (*d.Candidates)[0]) },
		func(d *ICESnapshot) { _, cs, _ := ParseICE(iceSDP("host", 65)); d.Candidates = &cs },
		func(d *ICESnapshot) {
			_, cs, _ := ParseICE(iceSDP("host", 20))
			for i := range cs {
				cs[i].Candidate += " " + strings.Repeat("x", 1800)
			}
			d.Candidates = &cs
		},
	} {
		a, b := continuousPair(t)
		d := a.Snapshot()
		mutate(&d)
		fail := func(ICECandidate) error { t.Fatal("invalid batch reached native"); return nil }
		if b.Accept(d, fail, fail) == nil {
			t.Fatal("invalid accepted")
		}
	}
	a, b := continuousPair(t)
	noop := func(ICECandidate) error { return nil }
	old := a.Snapshot()
	if b.Accept(old, noop, noop) != nil {
		t.Fatal("first")
	}
	a.Observe(iceSDP("host", 2))
	changed := a.Snapshot()
	changed.Revision = old.Revision
	if b.Accept(changed, noop, noop) == nil {
		t.Fatal("conflicting replay")
	}
	if b.Accept(a.Snapshot(), noop, noop) != nil || b.Accept(old, noop, noop) == nil {
		t.Fatal("stale revision")
	}
	b.RelayOnly = true
	if b.Accept(a.Snapshot(), noop, noop) == nil {
		t.Fatal("direct candidate escaped relay policy")
	}
	if a.Observe(iceSDP("renewed", 1)) == nil {
		t.Fatal("local generation reopened")
	}
}

func TestContinuousSnapshotAndDiagnosticsFitTransport(t *testing.T) {
	x := &ContinuousICE{}
	if x.Observe(iceSDP(strings.Repeat("a", 256), 64)) != nil {
		t.Fatal("bounded maximum")
	}
	for i := range x.Local {
		x.Local[i].MID = strings.Repeat("m", 64)
		x.Local[i].Candidate += strings.Repeat("x", 400)
	}
	if iceBytes(x.Local) > MaxCurrentICEBytes {
		t.Fatal("fixture")
	}
	body, _ := json.Marshal(map[string]any{"version": 3, "continuous_ice": x.Snapshot(), "android": strings.Repeat("r", 16*1024)})
	if len(body) > 96*1024 {
		t.Fatal("snapshot exceeds status envelope")
	}
}
