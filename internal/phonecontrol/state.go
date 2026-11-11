package phonecontrol

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"time"
)

const CommandTimeout = 15 * time.Second

// State belongs to one authenticated media session. Its owner serializes access.
// It must never be copied into a successor session.
type State struct {
	snapshot        *Snapshot
	received        time.Time
	pending         *Update
	deadline        time.Time
	lastID          string
	refreshRequired bool
	message         string
}

func (s *State) Receive(snapshot *Snapshot, now time.Time) {
	s.Expire(now)
	s.snapshot = CloneSnapshot(snapshot)
	s.received = now
	s.refreshRequired = false
	if snapshot.Ack != nil && snapshot.Ack.ID == s.lastID {
		s.pending = nil
		s.message = snapshot.Ack.Message
	} else if s.pending != nil && !snapshot.Enabled {
		s.pending = nil
		s.message = "Windows control was disabled on the phone."
	}
}

func (s *State) Queue(edit Edit, now time.Time) (string, error) {
	s.Expire(now)
	if s.snapshot == nil || s.refreshRequired || now.Sub(s.received) >= CommandTimeout {
		return "", errors.New("waiting for current phone settings; reconnect or try again shortly")
	}
	if s.pending != nil {
		return "", errors.New("a phone settings update is awaiting confirmation")
	}
	if err := s.snapshot.ValidateEdit(edit); err != nil {
		return "", err
	}
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", errors.New("could not create a phone settings request")
	}
	id := hex.EncodeToString(random[:])
	s.pending = &Update{ID: id, BaseRevision: edit.BaseRevision, Changes: CloneChanges(edit.Changes)}
	s.lastID, s.deadline = id, now.Add(CommandTimeout)
	s.message = "Waiting for the phone to confirm the settings update…"
	return id, nil
}

func (s *State) Expire(now time.Time) {
	if s.pending != nil && !now.Before(s.deadline) {
		s.pending = nil
		s.refreshRequired = true
		s.message = "The phone did not confirm the update. Reload its settings before trying again."
	}
}

func (s *State) Command(now time.Time) *Update {
	s.Expire(now)
	if s.pending == nil {
		return nil
	}
	result := *s.pending
	result.Changes = CloneChanges(result.Changes)
	return &result
}

func (s *State) View(now time.Time) (*Snapshot, bool, string) {
	s.Expire(now)
	return CloneSnapshot(s.snapshot), s.pending != nil, s.message
}
