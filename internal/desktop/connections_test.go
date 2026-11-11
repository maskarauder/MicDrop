package desktop

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/phonecontrol"
)

func controlSnapshot() *phonecontrol.Snapshot {
	return &phonecontrol.Snapshot{Version: 1, Revision: strings.Repeat("a", 64), Enabled: true,
		Fields: []phonecontrol.Field{{Key: "audio.fast_recovery", Label: "Fast recovery", Group: "Audio", Kind: "bool", Value: json.RawMessage("true"), Effect: "next_connection"}}}
}

func TestPersistentConnectionsFollowIdentityAndPreservePausedRow(t *testing.T) {
	c, emit, _ := testController(t, nil)
	emit(Event{Kind: "phones", Phones: []Phone{{Name: "Pixel", Key: "pixel"}, {Name: "Other phone", Key: "other"}}})
	emit(Event{Kind: "session_begin", Session: 1, PhoneKey: "pixel"})
	emit(Event{Kind: "session_status", Session: 1, State: "connected"})
	rtt := 12.0
	row := DeviceConnection{Key: "pixel", UpdatedAt: time.Now(), MetricsAt: time.Now(), Metrics: ConnectionMetrics{RTTMS: &rtt}, Settings: controlSnapshot()}
	emit(Event{Kind: "phone_state", Session: 1, Connection: &row})
	c.Notices()
	snapshot := c.Snapshot()
	if len(snapshot.Connections) != 2 || snapshot.Connections[0].Key != "pixel" || snapshot.Connections[0].State != "connected" || snapshot.Connections[0].Name != "Pixel" {
		t.Fatal(snapshot.Connections)
	}
	// Incoming events and returned snapshots must not share mutable UI data.
	row.Settings.Fields[0].Value[0] = 'f'
	*snapshot.Connections[0].Metrics.RTTMS = 999
	snapshot.Connections[0].Settings.Fields[0].Value[0] = 'f'
	if got := c.Snapshot().Connections[0]; *got.Metrics.RTTMS != 12 || string(got.Settings.Fields[0].Value) != "true" {
		t.Fatal(got)
	}
	emit(Event{Kind: "session_end", Session: 1, Message: "receiver_pause"})
	if got := c.Snapshot().Connections[0]; got.Key != "pixel" || got.State != "paused" || got.SettingsPending {
		t.Fatal(got)
	}
	emit(Event{Kind: "phone_state", Session: 1, Connection: &row})
	if c.Snapshot().Connections[0].State != "paused" {
		t.Fatal("late report revived ended stream")
	}
	emit(Event{Kind: "phones", Phones: []Phone{{Name: "Other phone", Key: "other"}}})
	if got := c.Snapshot().Connections; len(got) != 1 || got[0].Key != "other" {
		t.Fatal("revoked phone retained", got)
	}
}

func TestPhoneSettingsCommandRequiresFreshSelectedSessionAndCopiesPatch(t *testing.T) {
	c, emit, input := testController(t, nil)
	emit(Event{Kind: "phones", Phones: []Phone{{Name: "Pixel", Key: "pixel"}}})
	emit(Event{Kind: "session_begin", Session: 9, PhoneKey: "pixel"})
	emit(Event{Kind: "session_status", Session: 9, State: "connected"})
	row := DeviceConnection{Key: "pixel", UpdatedAt: time.Now(), Settings: controlSnapshot()}
	emit(Event{Kind: "phone_state", Session: 9, Connection: &row})
	edit := phonecontrol.Edit{BaseRevision: row.Settings.Revision, Changes: map[string]json.RawMessage{"audio.fast_recovery": json.RawMessage("false")}}
	if err := c.Command(Command{Action: "phone_settings", Value: "other", Settings: &edit}); err == nil {
		t.Fatal("wrong phone accepted")
	}
	if err := c.Command(Command{Action: "phone_settings", Value: "pixel", Session: 8, Settings: &edit}); err == nil {
		t.Fatal("editor from prior session accepted")
	}
	stale := edit
	stale.BaseRevision = strings.Repeat("b", 64)
	if err := c.Command(Command{Action: "phone_settings", Value: "pixel", Settings: &stale}); err == nil {
		t.Fatal("stale edit accepted")
	}
	if err := c.Command(Command{Action: "phone_settings", Value: "pixel", Settings: &edit}); err != nil {
		t.Fatal(err)
	}
	edit.Changes["audio.fast_recovery"][0] = 't'
	queued := <-input
	if queued.Session != 9 || string(queued.Settings.Changes["audio.fast_recovery"]) != "false" {
		t.Fatal(queued)
	}
	if !c.Snapshot().Connections[0].SettingsPending {
		t.Fatal("missing pending state")
	}
	// A watchdog snapshot taken before the host consumes the command must not
	// make the editor claim that an in-flight request has already failed.
	emit(Event{Kind: "phone_state", Session: 9, Connection: &row})
	if !c.Snapshot().Connections[0].SettingsPending {
		t.Fatal("old watchdog snapshot cleared queued command")
	}
	emit(Event{Kind: "phone_settings_queued", Session: 8, PhoneKey: "pixel"})
	emit(Event{Kind: "phone_state", Session: 9, Connection: &row})
	if !c.Snapshot().Connections[0].SettingsPending {
		t.Fatal("old queue acceptance cleared current command")
	}
	emit(Event{Kind: "phone_settings_queued", Session: 9, PhoneKey: "pixel"})
	if err := c.Command(Command{Action: "phone_settings", Value: "pixel", Settings: queued.Settings}); err == nil {
		t.Fatal("overlapping edit accepted")
	}
	emit(Event{Kind: "phone_settings_error", Session: 8, PhoneKey: "pixel", Message: "old error"})
	if !c.Snapshot().Connections[0].SettingsPending {
		t.Fatal("old session cleared pending change")
	}
	emit(Event{Kind: "phone_settings_error", Session: 9, PhoneKey: "pixel", Message: "Phone declined"})
	if got := c.Snapshot().Connections[0]; got.SettingsPending || got.SettingsMessage != "Phone declined" {
		t.Fatal(got)
	}
	row.UpdatedAt = time.Now().Add(-11 * time.Second)
	emit(Event{Kind: "phone_state", Session: 9, Connection: &row})
	if err := c.Command(Command{Action: "phone_settings", Value: "pixel", Settings: queued.Settings}); err == nil {
		t.Fatal("stale phone presence accepted")
	}
	row.UpdatedAt = time.Now()
	row.Settings.Enabled = false
	emit(Event{Kind: "phone_state", Session: 9, Connection: &row})
	if err := c.Command(Command{Action: "phone_settings", Value: "pixel", Settings: queued.Settings}); err == nil {
		t.Fatal("phone opt-out ignored")
	}
	emit(Event{Kind: "session_end", Session: 9, Message: "receiver_pause"})
	if err := c.Command(Command{Action: "phone_settings", Value: "pixel", Settings: queued.Settings}); err == nil {
		t.Fatal("paused edit queued")
	}
	<-c.Stop()
	if got := c.Snapshot().Connections[0]; got.State != "disconnected" || got.SettingsPending {
		t.Fatal(got)
	}
}
