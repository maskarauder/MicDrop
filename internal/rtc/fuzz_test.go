// SPDX-License-Identifier: MPL-2.0
package rtc

import (
	"encoding/json"
	"testing"
)

// The phone supplies SDP fragments and trickle or continuous ICE messages over
// the paired session. These targets check that arbitrary input is either
// rejected before native work or applied within the documented bounds.
// Without -fuzz they run their seed corpus as ordinary tests.

func FuzzParseICE(f *testing.F) {
	for _, seed := range []string{
		iceSDP("phone", 0), iceSDP("phone", 3), iceSDP("host", MaxICECandidates),
		"v=0\na=ice-ufrag:shared\nm=audio 9 UDP/TLS/RTP/SAVPF 111\na=mid:0\n" +
			"m=application 9 UDP/DTLS/SCTP webrtc-datachannel\na=mid:1\n" +
			"a=candidate:1 2 TCP 1 192.0.2.7 9 typ relay\n",
		"m=audio\na=mid:0\n",
		"a=candidate:1 1 udp 1 192.0.2.1 9 typ host\n",
	} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, sdp string) {
		sections, candidates, err := ParseICE(sdp)
		if err != nil {
			if sections != nil || candidates != nil {
				t.Fatal("rejected description returned data")
			}
			return
		}
		if len(sections) == 0 || len(sections) > 8 || len(candidates) > MaxICECandidates {
			t.Fatalf("accepted %d sections and %d candidates", len(sections), len(candidates))
		}
		for _, c := range candidates {
			if !c.Valid(sections, false) {
				t.Fatalf("accepted candidate fails its own validation: %#v", c)
			}
		}
	})
}

func FuzzICEExchangeAccept(f *testing.F) {
	// Seed with every update of a real two-sided exchange.
	host, phone := &ICEExchange{}, &ICEExchange{}
	host.RemoteSections, _, _ = ParseICE(iceSDP("phone", 0))
	phone.RemoteSections, _, _ = ParseICE(iceSDP("host", 0))
	if host.Observe(iceSDP("host", 20), true) != nil || phone.Observe(iceSDP("phone", 2), true) != nil {
		f.Fatal("seed exchange")
	}
	noop := func(ICECandidate) error { return nil }
	for i := 0; i < 3; i++ {
		d := host.Delta()
		seed, err := json.Marshal(d)
		if err != nil {
			f.Fatal(err)
		}
		f.Add(iceSDP("host", 0), string(seed))
		if phone.Accept(d, noop) != nil || host.Accept(phone.Delta(), noop) != nil {
			f.Fatal("seed exchange")
		}
	}
	f.Add(iceSDP("host", 0), `{"version":2}`)
	f.Add(iceSDP("host", 0), `{"version":1,"offset":-1}`)
	f.Fuzz(func(t *testing.T, remote, update string) {
		sections, _, err := ParseICE(remote)
		if err != nil {
			return
		}
		var d ICEDelta
		if json.Unmarshal([]byte(update), &d) != nil {
			return
		}
		x := &ICEExchange{RemoteSections: sections}
		applied := 0
		apply := func(ICECandidate) error { applied++; return nil }
		if x.Accept(d, apply) != nil {
			if applied != 0 || len(x.Remote) != 0 {
				t.Fatal("rejected update reached native work")
			}
			return
		}
		if applied != len(d.Candidates) || len(x.Remote) != applied || applied > ICEBatchSize {
			t.Fatalf("applied %d of %d candidates, kept %d", applied, len(d.Candidates), len(x.Remote))
		}
		// A lost response repeats the same update; nothing may be applied twice.
		if err := x.Accept(d, apply); err != nil || applied != len(x.Remote) {
			t.Fatalf("replay applied %d candidates for %d kept: %v", applied, len(x.Remote), err)
		}
	})
}

func FuzzContinuousICEAccept(f *testing.F) {
	peer := &ContinuousICE{Generation: 2}
	if peer.Observe(iceSDP("host", 2)) != nil || peer.SetRemote(iceSDP("phone", 0)) != nil {
		f.Fatal("seed snapshot")
	}
	seed, err := json.Marshal(peer.Snapshot())
	if err != nil {
		f.Fatal(err)
	}
	f.Add(iceSDP("phone", 1), iceSDP("host", 0), uint64(2), string(seed))
	f.Add(iceSDP("phone", 1), iceSDP("host", 1), uint64(2), `{"version":1,"generation":2,"revision":1,"ack":0,"candidates":[]}`)
	f.Add(iceSDP("phone", 1), iceSDP("host", 0), uint64(0), `{"version":1,"generation":0,"revision":1,"ack":1}`)
	f.Fuzz(func(t *testing.T, local, remote string, generation uint64, snapshot string) {
		var d ICESnapshot
		if json.Unmarshal([]byte(snapshot), &d) != nil {
			return
		}
		x := &ContinuousICE{Generation: generation}
		if x.Observe(local) != nil || x.SetRemote(remote) != nil {
			return
		}
		// The native peer already holds the candidates of the remote description.
		native := map[ICECandidate]bool{}
		for _, c := range x.Remote {
			native[c] = true
		}
		add := func(c ICECandidate) error {
			if native[c] {
				t.Fatal("duplicate native addition")
			}
			native[c] = true
			return nil
		}
		remove := func(c ICECandidate) error {
			if !native[c] {
				t.Fatal("native removal of an unknown candidate")
			}
			delete(native, c)
			return nil
		}
		if x.Accept(d, add, remove) != nil {
			return
		}
		if len(native) != len(x.Remote) || len(x.Remote) > MaxCurrentCandidates {
			t.Fatalf("native set holds %d candidates for %d current", len(native), len(x.Remote))
		}
		for _, c := range x.Remote {
			if !native[c] {
				t.Fatalf("current candidate missing from the native set: %#v", c)
			}
		}
		// A lost response repeats the full snapshot, never native application.
		if err := x.Accept(d, add, remove); err != nil || len(native) != len(x.Remote) {
			t.Fatalf("replay changed the native set: %v", err)
		}
	})
}
