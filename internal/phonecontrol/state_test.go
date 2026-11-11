package phonecontrol

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

func testSnapshot() *Snapshot {
	low, high := 0, 10
	return &Snapshot{Version: Version, Revision: strings.Repeat("a", 64), Enabled: true,
		Fields: []Field{
			{Key: "audio.fast", Label: "Fast recovery", Group: "Audio", Kind: "bool", Value: json.RawMessage("true"), Effect: "next_connection"},
			{Key: "live.volume", Label: "Volume", Group: "Live", Kind: "int", Value: json.RawMessage("5"), Minimum: &low, Maximum: &high, Effect: "live"},
			{Key: "audio.output", Label: "Output", Group: "Audio", Kind: "choice", Value: json.RawMessage(`"default"`), Effect: "next_connection", Choices: []Choice{{"default", "Android default"}, {"headphones", "Headphones"}}},
		}}
}

func TestPatchLimitUsesCompleteSerializedCommand(t *testing.T) {
	snapshot := &Snapshot{Version: Version, Enabled: true, Revision: strings.Repeat("a", 64)}
	edit := Edit{BaseRevision: snapshot.Revision, Changes: make(map[string]json.RawMessage)}
	value := strings.Repeat("a", 256)
	encodedValue, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 64; i++ {
		key := fmt.Sprintf("audio.choice%d", i)
		snapshot.Fields = append(snapshot.Fields, Field{Key: key, Label: "Choice", Group: "Audio", Kind: "choice",
			Value: json.RawMessage(`"default"`), Effect: "next_connection", Choices: []Choice{{"default", "Default"}, {value, "Alternative"}}})
		edit.Changes[key] = encodedValue
	}
	if err := snapshot.Validate(); err != nil {
		t.Fatal("fixture must be a valid bounded advertised schema", err)
	}
	if err := snapshot.ValidateEdit(edit); err != nil {
		t.Fatal("ordinary encoding is within the command limit", err)
	}
	for key := range edit.Changes {
		edit.Changes[key] = json.RawMessage(`"` + strings.Repeat(`\u0061`, 256) + `"`)
	}
	command, err := json.Marshal(Update{ID: strings.Repeat("0", 32), BaseRevision: edit.BaseRevision, Changes: edit.Changes})
	if err != nil || len(command) <= MaxBody {
		t.Fatal("fixture must exceed the serialized command bound", len(command), err)
	}
	if snapshot.ValidateEdit(edit) == nil {
		t.Fatal("accepted escaped command larger than the phone receive limit")
	}
	for i, field := range snapshot.Fields {
		snapshot.Fields[i] = Field{Key: field.Key, Label: "Toggle", Group: "Audio", Kind: "bool", Value: json.RawMessage("true"), Effect: "next_connection"}
		edit.Changes[field.Key] = json.RawMessage(strings.Repeat(" ", 1500) + "false")
	}
	if err := snapshot.ValidateEdit(edit); err != nil {
		t.Fatal("whitespace compacted out of the wire payload should not consume the command budget", err)
	}
}

func testEdit(snapshot *Snapshot) Edit {
	return Edit{BaseRevision: snapshot.Revision, Changes: map[string]json.RawMessage{"audio.fast": json.RawMessage("false")}}
}

func TestSnapshotAndPatchRejectInvalidValues(t *testing.T) {
	good := testSnapshot()
	if err := good.Validate(); err != nil {
		t.Fatal(err)
	}
	for _, change := range []func(*Snapshot){
		func(s *Snapshot) { s.Version++ },
		func(s *Snapshot) { s.Revision = "not a revision" },
		func(s *Snapshot) { s.Fields = append(s.Fields, s.Fields[0]) },
		func(s *Snapshot) { s.Fields[0].Value = json.RawMessage("null") },
		func(s *Snapshot) { s.Fields[0].Value = json.RawMessage(`"false"`) },
		func(s *Snapshot) { s.Fields[0].Label = "label\nsecond line" },
		func(s *Snapshot) { s.Fields[0].Kind = "script" },
		func(s *Snapshot) { s.Fields[0].Group = "Permissions" },
		func(s *Snapshot) { s.Fields[1].Value = json.RawMessage("1.5") },
		func(s *Snapshot) { s.Fields[1].Maximum = nil },
		func(s *Snapshot) { s.Fields[2].Value = json.RawMessage(`"missing"`) },
		func(s *Snapshot) { s.Fields[2].Choices = append(s.Fields[2].Choices, s.Fields[2].Choices[0]) },
		func(s *Snapshot) { s.Ack = &Ack{ID: "bad", Status: "applied", Message: "Done"} },
	} {
		s := CloneSnapshot(good)
		change(s)
		if s.Validate() == nil {
			t.Fatalf("accepted invalid snapshot: %+v", s)
		}
	}
	for key, values := range map[string][]string{
		"audio.fast":       {"null", `"false"`, "0", "{}"},
		"live.volume":      {"-1", "11", "1.5", "1e1", "null"},
		"audio.output":     {`"missing"`, "false", "null"},
		"start_microphone": {"true"},
	} {
		for _, value := range values {
			edit := Edit{BaseRevision: good.Revision, Changes: map[string]json.RawMessage{key: json.RawMessage(value)}}
			if good.ValidateEdit(edit) == nil {
				t.Fatalf("accepted %s=%s", key, value)
			}
		}
	}
	if good.ValidateEdit(Edit{BaseRevision: strings.Repeat("b", 64), Changes: testEdit(good).Changes}) == nil {
		t.Fatal("stale edit accepted")
	}
	good.Enabled = false
	// The opt-in is named, not located: its section differs between phones.
	if err := good.ValidateEdit(testEdit(good)); err == nil || !strings.Contains(err.Error(), "‘Allow Windows to change phone settings’ on the phone") {
		t.Fatal("phone opt-in bypassed or not named", err)
	}
}

// iPhoneSnapshot mirrors the 31 keys an iPhone advertises in a duplex session:
// Android's without live.volume and audio.le_stereo, with 31 listed inputs
// plus the saved one.
func iPhoneSnapshot() *Snapshot {
	toggle := func(key, label string) Field {
		return Field{Key: key, Label: label, Group: "Audio", Kind: "bool", Value: json.RawMessage("true"), Effect: "next_connection"}
	}
	number := func(key, label string, value, minimum, maximum int) Field {
		return Field{Key: key, Label: label, Group: "Advanced", Kind: "int", Value: json.RawMessage(fmt.Sprint(value)), Effect: "next_connection", Minimum: &minimum, Maximum: &maximum}
	}
	var inputs []Choice
	for i := 0; i < 31; i++ {
		inputs = append(inputs, Choice{fmt.Sprintf("%064x", i), fmt.Sprintf("USB microphone %d", i)})
	}
	inputs = append(inputs, Choice{fmt.Sprintf("%064x", 31), "Bluetooth headset (saved)"})
	orders := []Choice{{"LAN_FIRST", "LAN → rendezvous"}, {"RENDEZVOUS_FIRST", "Rendezvous → LAN"}}
	fields := []Field{
		toggle("audio.fast_recovery", "Faster recovery after audio interruptions"),
		toggle("audio.echo_cancellation", "Reduce microphone echo (experimental)"),
		toggle("audio.noise_reduction", "Reduce microphone background noise"),
		toggle("audio.keep_microphone_active", "Keep microphone active while muted in background"),
		{Key: "audio.input", Label: "Microphone input", Group: "Audio", Kind: "choice", Value: json.RawMessage(fmt.Sprintf(`"%064x"`, 31)), Effect: "next_connection", Choices: inputs},
		{Key: "audio.output", Label: "Media output", Group: "Audio", Kind: "choice", Value: json.RawMessage(fmt.Sprintf(`"%064x"`, 40)), Effect: "next_connection",
			Choices: []Choice{{fmt.Sprintf("%064x", 40), "iPhone media output"}, {fmt.Sprintf("%064x", 41), "iPhone speaker"}}},
		{Key: "advanced.initial_order", Label: "Initial connection order", Group: "Advanced", Kind: "choice", Value: json.RawMessage(`"LAN_FIRST"`), Effect: "next_connection", Choices: orders},
		{Key: "advanced.recovery_order", Label: "Recovery connection order", Group: "Advanced", Kind: "choice", Value: json.RawMessage(`"RENDEZVOUS_FIRST"`), Effect: "next_connection", Choices: orders},
		number("advanced.max_restarts", "Maximum ICE restarts per interruption", 2, 1, 10),
	}
	for _, timeout := range []struct {
		name                    string
		value, minimum, maximum int
	}{
		{"recovery", 30000, 5000, 300000}, {"setup", 45000, 10000, 120000}, {"busy_host", 5000, 0, 30000},
		{"restart_delay", 1000, 0, 10000}, {"restart_interval", 8000, 5000, 60000}, {"lan_probe", 1500, 250, 5000},
		{"lan_status", 2000, 250, 15000}, {"lan_request", 8000, 1000, 30000}, {"remote_request", 8000, 1000, 30000},
		{"ice_service", 8000, 1000, 30000}, {"lan_stop", 2000, 500, 10000}, {"remote_stop", 5000, 500, 15000},
		{"initial_offer", 40000, 1000, 60000}, {"cancel_offer", 5000, 500, 15000}, {"initial_ice", 15000, 1000, 30000},
		{"initial_sdp", 15000, 1000, 30000}, {"recovery_ice", 8000, 1000, 30000}, {"recovery_offer", 18000, 1000, 30000},
		{"recovery_answer", 5000, 1000, 30000},
	} {
		fields = append(fields, number("advanced."+timeout.name, timeout.name+" (ms)", timeout.value, timeout.minimum, timeout.maximum))
	}
	fields = append(fields, number("advanced.bluetooth_recovery", "Bluetooth route recovery (ms)", 20000, 5000, 120000),
		Field{Key: "live.output_enabled", Label: "Audio output enabled", Group: "Live", Kind: "bool", Value: json.RawMessage("true"), Effect: "live"},
		Field{Key: "live.microphone_muted", Label: "Microphone muted", Group: "Live", Kind: "bool", Value: json.RawMessage("true"), Effect: "live"})
	return &Snapshot{Version: Version, Revision: strings.Repeat("c", 64), Enabled: true, Fields: fields}
}

func TestIPhoneSnapshotIsValidWithoutVolumeOrLEStereo(t *testing.T) {
	snapshot := iPhoneSnapshot()
	if err := snapshot.Validate(); err != nil || len(snapshot.Fields) != 31 {
		t.Fatal("iPhone-shaped snapshot rejected", len(snapshot.Fields), err)
	}
	edit := func(key, value string) Edit {
		return Edit{BaseRevision: snapshot.Revision, Changes: map[string]json.RawMessage{key: json.RawMessage(value)}}
	}
	for _, change := range [][2]string{
		{"advanced.bluetooth_recovery", "5000"}, {"advanced.bluetooth_recovery", "120000"},
		{"audio.input", fmt.Sprintf(`"%064x"`, 0)}, {"live.microphone_muted", "false"},
	} {
		if err := snapshot.ValidateEdit(edit(change[0], change[1])); err != nil {
			t.Fatal(change, err)
		}
	}
	// Windows cannot send a setting the iPhone does not advertise.
	for _, change := range [][2]string{
		{"live.volume", "5"}, {"audio.le_stereo", "true"}, {"audio.le_stereo", "false"},
		{"advanced.bluetooth_recovery", "4999"}, {"advanced.bluetooth_recovery", "120001"}, {"audio.input", fmt.Sprintf(`"%064x"`, 32)},
	} {
		if err := snapshot.ValidateEdit(edit(change[0], change[1])); err == nil || err.Error() != "a phone setting is unavailable or outside its allowed range" {
			t.Fatal(change, err)
		}
	}
	snapshot.Fields[4].Choices = append(snapshot.Fields[4].Choices, Choice{fmt.Sprintf("%064x", 32), "USB microphone 31"})
	if snapshot.Validate() == nil {
		t.Fatal("more than 32 input choices accepted")
	}
}

func TestCommandsAreBoundedSessionLocalAndAcknowledged(t *testing.T) {
	now := time.Now()
	var state State
	snapshot := testSnapshot()
	state.Receive(snapshot, now)
	id, err := state.Queue(testEdit(snapshot), now)
	if err != nil || !commandID.MatchString(id) {
		t.Fatal(id, err)
	}
	if _, err := state.Queue(testEdit(snapshot), now); err == nil {
		t.Fatal("second in-flight update accepted")
	}
	first := state.Command(now)
	first.Changes["audio.fast"][0] = 'x'
	second := state.Command(now)
	if second.ID != id || string(second.Changes["audio.fast"]) != "false" {
		t.Fatal("retry changed command or caller mutated queued bytes")
	}
	// Both caller-owned inputs and views are isolated.
	snapshot.Fields[0].Value[0] = 'x'
	view, pending, _ := state.View(now)
	if !pending || string(view.Fields[0].Value) != "true" {
		t.Fatal("caller changed accepted snapshot")
	}
	view.Fields[0].Value[0] = 'x'
	view, _, _ = state.View(now)
	if string(view.Fields[0].Value) != "true" {
		t.Fatal("view aliases internal data")
	}
	view.Ack = &Ack{ID: strings.Repeat("0", 32), Status: "applied", Message: "Unrelated old acknowledgment"}
	state.Receive(view, now.Add(time.Second))
	if state.Command(now) == nil {
		t.Fatal("unrelated acknowledgment cleared command")
	}
	view.Revision = strings.Repeat("b", 64)
	view.Fields[0].Value = json.RawMessage("false")
	view.Ack = &Ack{ID: id, Status: "applied", Message: "Saved for the next connection."}
	state.Receive(view, now.Add(2*time.Second))
	current, pending, message := state.View(now.Add(2 * time.Second))
	if pending || state.Command(now) != nil || current.Revision != view.Revision || message != view.Ack.Message {
		t.Fatal("acknowledgment not reflected", current, pending, message)
	}
}

func TestTimeoutRequiresNewSnapshotAndOptOutCancels(t *testing.T) {
	now := time.Now()
	var state State
	snapshot := testSnapshot()
	if _, err := state.Queue(testEdit(snapshot), now); err == nil {
		t.Fatal("queued without a phone snapshot")
	}
	state.Receive(snapshot, now)
	state.Queue(testEdit(snapshot), now)
	later := now.Add(CommandTimeout)
	if state.Command(later) != nil {
		t.Fatal("expired command still delivered")
	}
	if _, err := state.Queue(testEdit(snapshot), later); err == nil {
		t.Fatal("timeout permitted retry from old data")
	}
	state.Receive(snapshot, later)
	if _, err := state.Queue(testEdit(snapshot), later); err != nil {
		t.Fatal("fresh snapshot did not restore editing", err)
	}
	snapshot.Enabled = false
	state.Receive(snapshot, later.Add(time.Second))
	if state.Command(later.Add(time.Second)) != nil {
		t.Fatal("opt-out did not cancel delivery")
	}
	if _, err := state.Queue(testEdit(snapshot), later.Add(time.Second)); err == nil {
		t.Fatal("opt-out still accepted edits")
	}
	var nextSession State
	if nextSession.Command(later) != nil {
		t.Fatal("command leaked into fresh state")
	}
}
