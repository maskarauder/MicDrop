// SPDX-License-Identifier: MPL-2.0
package phonecontrol

import (
	"encoding/json"
	"testing"
	"time"
)

// The phone supplies settings snapshots and the desktop UI supplies edits.
// Validation must handle any decodable input without panicking, and a session
// may only queue an edit that the current snapshot accepts.
// Without -fuzz the seeds run as ordinary tests.

func FuzzSnapshotAndEdit(f *testing.F) {
	for _, snapshot := range []*Snapshot{testSnapshot(), iPhoneSnapshot()} {
		if err := snapshot.Validate(); err != nil {
			f.Fatal(err)
		}
		seed, err := json.Marshal(snapshot)
		if err != nil {
			f.Fatal(err)
		}
		edit, err := json.Marshal(Edit{BaseRevision: snapshot.Revision,
			Changes: map[string]json.RawMessage{snapshot.Fields[0].Key: snapshot.Fields[0].Value}})
		if err != nil {
			f.Fatal(err)
		}
		f.Add(string(seed), string(edit))
		f.Add(string(seed), `{"base_revision":"","changes":{"missing":null}}`)
	}
	f.Add(`{"version":1,"fields":[{}]}`, `{}`)
	f.Fuzz(func(t *testing.T, body, change string) {
		var snapshot Snapshot
		if json.Unmarshal([]byte(body), &snapshot) != nil || snapshot.Validate() != nil {
			return
		}
		if clone := CloneSnapshot(&snapshot); clone == nil || clone.Validate() != nil {
			t.Fatal("clone of an accepted snapshot is rejected")
		}
		var edit Edit
		if json.Unmarshal([]byte(change), &edit) != nil {
			return
		}
		accepted := snapshot.ValidateEdit(edit) == nil
		now := time.Unix(1_700_000_000, 0)
		var state State
		state.Receive(&snapshot, now)
		id, err := state.Queue(edit, now)
		if (err == nil) != accepted {
			t.Fatalf("queueing disagrees with validation: accepted=%v err=%v", accepted, err)
		}
		command := state.Command(now)
		if accepted != (command != nil) {
			t.Fatalf("pending command does not match validation: accepted=%v", accepted)
		}
		if command != nil && (command.ID != id || command.BaseRevision != edit.BaseRevision) {
			t.Fatal("queued command does not carry the accepted edit")
		}
		if state.Command(now.Add(CommandTimeout)) != nil {
			t.Fatal("unconfirmed command survived its timeout")
		}
	})
}
