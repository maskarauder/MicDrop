package rtc

import (
	"errors"
	"strconv"
	"strings"
)

// Candidate contents are private signaling, never diagnostics. One generation
// is bounded by count and bytes, with ordered, idempotent batches over TLS.
const (
	MaxICECandidates = 128
	MaxICEBytes      = 65536
	ICEBatchSize     = 16
)

type ICECandidate struct {
	MID       string `json:"mid"`
	Index     int    `json:"index"`
	Ufrag     string `json:"ufrag"`
	Candidate string `json:"candidate"`
}

type ICEDelta struct {
	Version    int            `json:"version"`
	Generation uint64         `json:"generation"`
	Ack        int            `json:"ack"`
	Offset     int            `json:"offset"`
	Candidates []ICECandidate `json:"candidates"`
	Complete   bool           `json:"complete"`
}

type ICESection struct {
	MID, Ufrag string
	Index      int
}

func iceToken(s string, limit int) bool {
	if len(s) == 0 || len(s) > limit {
		return false
	}
	for _, c := range s {
		if c < 33 || c > 126 {
			return false
		}
	}
	return true
}

func (c ICECandidate) Valid(sections []ICESection, relayOnly bool) bool {
	if c.Index < 0 || c.Index >= len(sections) || !iceToken(c.MID, 64) || !iceToken(c.Ufrag, 256) ||
		len(c.Candidate) == 0 || len(c.Candidate) > 2048 || strings.ContainsAny(c.Candidate, "\r\n\x00") {
		return false
	}
	s := sections[c.Index]
	if c.MID != s.MID || c.Ufrag != s.Ufrag {
		return false
	}
	f := strings.Fields(c.Candidate)
	if len(f) < 8 || !strings.HasPrefix(f[0], "candidate:") || f[6] != "typ" ||
		(f[1] != "1" && f[1] != "2") || (strings.ToLower(f[2]) != "udp" && strings.ToLower(f[2]) != "tcp") {
		return false
	}
	p, err := strconv.Atoi(f[5])
	if err != nil || p < 1 || p > 65535 {
		return false
	}
	if f[7] != "host" && f[7] != "srflx" && f[7] != "prflx" && f[7] != "relay" {
		return false
	}
	if relayOnly && f[7] != "relay" {
		return false
	}
	for i := 8; i+1 < len(f); i += 2 {
		if f[i] == "ufrag" && f[i+1] != c.Ufrag {
			return false
		}
	}
	return true
}

// Parse the SDK's bounded SDP to retain m-line/credential ownership. Rejected
// sections are unusable. Session-level ufrag is inherited where appropriate.
func ParseICE(sdp string) ([]ICESection, []ICECandidate, error) {
	bad := errors.New("invalid ICE description")
	if len(sdp) == 0 || len(sdp) > MaxICEBytes || strings.ContainsRune(sdp, 0) {
		return nil, nil, bad
	}
	var sections []ICESection
	var raw [][]string
	global := ""
	for _, line := range strings.Split(strings.ReplaceAll(sdp, "\r\n", "\n"), "\n") {
		i := len(sections) - 1
		switch {
		case strings.HasPrefix(line, "m="):
			if len(sections) >= 8 {
				return nil, nil, bad
			}
			sections = append(sections, ICESection{Index: len(sections), Ufrag: global})
			raw = append(raw, nil)
		case strings.HasPrefix(line, "a=mid:") && i >= 0:
			sections[i].MID = strings.TrimPrefix(line, "a=mid:")
		case strings.HasPrefix(line, "a=ice-ufrag:"):
			u := strings.TrimPrefix(line, "a=ice-ufrag:")
			if i < 0 {
				global = u
			} else {
				sections[i].Ufrag = u
			}
		case strings.HasPrefix(line, "a=candidate:") && i >= 0:
			raw[i] = append(raw[i], line[2:])
		}
	}
	if len(sections) == 0 {
		return nil, nil, bad
	}
	var candidates []ICECandidate
	for i, s := range sections {
		if !iceToken(s.MID, 64) || !iceToken(s.Ufrag, 256) {
			return nil, nil, bad
		}
		for _, line := range raw[i] {
			c := ICECandidate{s.MID, i, s.Ufrag, line}
			if !c.Valid(sections, false) || len(candidates) >= MaxICECandidates {
				return nil, nil, bad
			}
			candidates = append(candidates, c)
		}
	}
	return sections, candidates, nil
}

type TricklePeer interface {
	Peer
	TrickleOffer() (string, error)
	LocalICE() (sdp string, complete bool, err error)
	AddICE(ICECandidate) error
}

// Only bounded counters enter logs; candidates and credentials never do.
type TrickleStatus struct {
	Version        int  `json:"version"`
	Sent           int  `json:"local_candidates"`
	Acknowledged   int  `json:"acknowledged"`
	Received       int  `json:"remote_candidates"`
	LocalComplete  bool `json:"local_complete"`
	RemoteComplete bool `json:"remote_complete"`
	Active         bool `json:"active"`
}

// ICEExchange is owned by the session lock. It retains at most one bounded
// generation; duplicate delivery cannot reapply a candidate or extend a timer.
type ICEExchange struct {
	Local, Remote                 []ICECandidate
	LocalSections, RemoteSections []ICESection
	Ack                           int
	LocalComplete, RemoteComplete bool
	RelayOnly                     bool
}

func (x *ICEExchange) Observe(sdp string, complete bool) error {
	sections, candidates, err := ParseICE(sdp)
	if err != nil {
		return err
	}
	if x.LocalSections != nil && !sameSections(x.LocalSections, sections) {
		return errors.New("ICE generation changed")
	}
	x.LocalSections = sections
	for _, c := range candidates {
		found := false
		for _, old := range x.Local {
			if old == c {
				found = true
				break
			}
		}
		if found {
			continue
		}
		if x.LocalComplete || !c.Valid(sections, x.RelayOnly) || len(x.Local) >= MaxICECandidates || iceBytes(x.Local)+len(c.Candidate) > MaxICEBytes {
			return errors.New("ICE candidate limit")
		}
		x.Local = append(x.Local, c)
	}
	x.LocalComplete = x.LocalComplete || complete
	return nil
}

func sameSections(a, b []ICESection) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
func iceBytes(cs []ICECandidate) int {
	n := 0
	for _, c := range cs {
		n += len(c.Candidate)
	}
	return n
}

func (x *ICEExchange) Accept(d ICEDelta, apply func(ICECandidate) error) error {
	bad := errors.New("invalid ICE update")
	if d.Version != 1 || d.Generation != 0 || d.Ack < x.Ack || d.Ack > len(x.Local) || d.Offset < 0 || d.Offset > len(x.Remote) ||
		len(d.Candidates) > ICEBatchSize || d.Offset+len(d.Candidates) > MaxICECandidates {
		return bad
	}
	bytes := iceBytes(x.Remote)
	for i, c := range d.Candidates {
		at := d.Offset + i
		if !c.Valid(x.RemoteSections, x.RelayOnly) {
			return bad
		}
		if at < len(x.Remote) {
			if c != x.Remote[at] {
				return bad
			}
		} else {
			bytes += len(c.Candidate)
			if x.RemoteComplete || bytes > MaxICEBytes {
				return bad
			}
		}
	}
	if d.Complete && d.Offset+len(d.Candidates) < len(x.Remote) {
		return bad
	}
	for i, c := range d.Candidates {
		if d.Offset+i < len(x.Remote) {
			continue
		}
		if err := apply(c); err != nil {
			return err
		}
		x.Remote = append(x.Remote, c)
	}
	x.Ack = d.Ack
	x.RemoteComplete = x.RemoteComplete || d.Complete
	return nil
}

func (x *ICEExchange) Delta() ICEDelta {
	end := min(len(x.Local), x.Ack+ICEBatchSize)
	return ICEDelta{Version: 1, Ack: len(x.Remote), Offset: x.Ack, Candidates: x.Local[x.Ack:end], Complete: x.LocalComplete && end == len(x.Local)}
}
