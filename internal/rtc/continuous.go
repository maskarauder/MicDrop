package rtc

import (
	"errors"
	"slices"
	"sort"
	"strings"
)

const (
	ContinuousHeader     = "X-MicDrop-Continuous-ICE"
	MaxCurrentCandidates = 64
	MaxCurrentICEBytes   = 32768
	MaxICERevision       = 1_000_000_000
)

// A snapshot replaces the current set. Nil Candidates means an acknowledged,
// unchanged revision; a pointer to an empty slice explicitly removes the set.
// No growing event history, candidate IDs or addresses enter diagnostics.
type ICESnapshot struct {
	Version    int             `json:"version"`
	Generation uint64          `json:"generation"`
	Revision   uint64          `json:"revision"`
	Ack        uint64          `json:"ack"`
	Candidates *[]ICECandidate `json:"candidates,omitempty"`
}

type ContinuousPeer interface {
	TricklePeer
	ContinuousICE() bool
	ForceRelay() bool
	RemoveICE(ICECandidate) error
}

type ContinuousStatus struct {
	Version        int    `json:"version"`
	Generation     uint64 `json:"generation"`
	Revision       uint64 `json:"local_revision"`
	Acknowledged   uint64 `json:"acknowledged_revision"`
	RemoteRevision uint64 `json:"remote_revision"`
	Local          int    `json:"local_candidates"`
	Remote         int    `json:"remote_candidates"`
}

// Owned by the session lock. Each ICE restart allocates a new exchange only
// after the new offer exists; status cannot apply anything while its answer is pending.
type ContinuousICE struct {
	Generation                    uint64
	RelayOnly                     bool
	LocalSections, RemoteSections []ICESection
	Local, Remote                 []ICECandidate
	Revision, RemoteRevision, Ack uint64
}

func currentCandidates(cs []ICECandidate, sections []ICESection, relay bool) ([]ICECandidate, error) {
	if len(cs) > MaxCurrentCandidates || iceBytes(cs) > MaxCurrentICEBytes {
		return nil, errors.New("ICE snapshot limit")
	}
	result := append([]ICECandidate{}, cs...)
	for _, c := range result {
		// Keep the entire escaped snapshot, metadata and report within 96 KiB.
		if !c.Valid(sections, relay) || strings.ContainsAny(c.MID+c.Ufrag+c.Candidate, "\"\\<>&") {
			return nil, errors.New("invalid ICE snapshot")
		}
		for _, ch := range c.Candidate {
			if ch < 32 || ch > 126 {
				return nil, errors.New("invalid ICE snapshot")
			}
		}
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].Index != result[j].Index {
			return result[i].Index < result[j].Index
		}
		return result[i].Candidate < result[j].Candidate
	})
	for i := 1; i < len(result); i++ {
		if result[i] == result[i-1] {
			return nil, errors.New("duplicate ICE candidate")
		}
	}
	return result, nil
}

func (x *ContinuousICE) Observe(sdp string) error {
	sections, cs, err := ParseICE(sdp)
	if err != nil {
		return err
	}
	if x.LocalSections != nil && !sameSections(x.LocalSections, sections) {
		return errors.New("ICE generation changed")
	}
	cs, err = currentCandidates(cs, sections, x.RelayOnly)
	if err != nil {
		return err
	}
	if x.Revision == 0 || !slices.Equal(x.Local, cs) {
		if x.Revision == MaxICERevision {
			return errors.New("ICE revision limit")
		}
		x.Revision++
		x.Local = cs
	}
	x.LocalSections = sections
	return nil
}

func (x *ContinuousICE) SetRemote(sdp string) error {
	sections, cs, err := ParseICE(sdp)
	if err != nil {
		return err
	}
	cs, err = currentCandidates(cs, sections, x.RelayOnly)
	if err != nil {
		return err
	}
	x.RemoteSections, x.Remote = sections, cs
	return nil
}

func (x *ContinuousICE) Snapshot() ICESnapshot {
	d := ICESnapshot{Version: 1, Generation: x.Generation, Revision: x.Revision, Ack: x.RemoteRevision}
	if x.Ack != x.Revision {
		cs := append([]ICECandidate{}, x.Local...)
		d.Candidates = &cs
	}
	return d
}

func (x *ContinuousICE) Accept(d ICESnapshot, add, remove func(ICECandidate) error) error {
	bad := errors.New("invalid ICE snapshot")
	if d.Version != 1 || d.Generation != x.Generation || d.Revision < x.RemoteRevision || d.Revision == 0 ||
		d.Revision > MaxICERevision || d.Ack < x.Ack || d.Ack > x.Revision || x.RemoteSections == nil {
		return bad
	}
	if d.Candidates == nil {
		if d.Revision != x.RemoteRevision {
			return bad
		}
	} else {
		cs, err := currentCandidates(*d.Candidates, x.RemoteSections, x.RelayOnly)
		if err != nil {
			return err
		}
		if d.Revision == x.RemoteRevision && !slices.Equal(cs, x.Remote) {
			return bad
		}
		// Validate the whole replacement before native work. Remove departed
		// candidates before additions, bounding the native set too. Retained
		// selected routes and tracks are never removed just to prefer another.
		for _, c := range x.Remote {
			if !slices.Contains(cs, c) {
				if err := remove(c); err != nil {
					return err
				}
			}
		}
		for _, c := range cs {
			if !slices.Contains(x.Remote, c) {
				if err := add(c); err != nil {
					return err
				}
			}
		}
		x.Remote = cs
	}
	x.RemoteRevision, x.Ack = d.Revision, d.Ack
	return nil
}

func (x *ContinuousICE) Status() *ContinuousStatus {
	return &ContinuousStatus{1, x.Generation, x.Revision, x.Ack, x.RemoteRevision, len(x.Local), len(x.Remote)}
}
