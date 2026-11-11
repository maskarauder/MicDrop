package phonecontrol

import (
	"bytes"
	"encoding/json"
	"errors"
	"regexp"
	"unicode"
	"unicode/utf8"
)

var fieldKey = regexp.MustCompile(`^[a-z][a-z0-9_.]{0,63}$`)
var revision = regexp.MustCompile(`^[0-9a-f]{64}$`)
var commandID = regexp.MustCompile(`^[0-9a-f]{32}$`)

func boundedText(value string, maximum int, empty bool) bool {
	if (!empty && value == "") || len(value) > maximum || !utf8.ValidString(value) {
		return false
	}
	for _, r := range value {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

func validValue(field Field, value json.RawMessage) bool {
	if len(value) == 0 || len(value) > 2048 || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
		return false
	}
	switch field.Kind {
	case "bool":
		var v bool
		return json.Unmarshal(value, &v) == nil
	case "int":
		var v int
		return field.Minimum != nil && field.Maximum != nil && json.Unmarshal(value, &v) == nil && v >= *field.Minimum && v <= *field.Maximum
	case "choice":
		var v string
		if json.Unmarshal(value, &v) != nil {
			return false
		}
		for _, choice := range field.Choices {
			if choice.Value == v {
				return true
			}
		}
	}
	return false
}

func (s Snapshot) Validate() error {
	if s.Version != Version || !revision.MatchString(s.Revision) || len(s.Fields) == 0 || len(s.Fields) > 64 {
		return errors.New("invalid phone settings snapshot")
	}
	seen := make(map[string]bool, len(s.Fields))
	for _, f := range s.Fields {
		if !fieldKey.MatchString(f.Key) || seen[f.Key] || !boundedText(f.Label, 160, false) ||
			(f.Group != "Audio" && f.Group != "Advanced" && f.Group != "Live") ||
			(f.Effect != "live" && f.Effect != "next_connection") {
			return errors.New("invalid phone settings field")
		}
		seen[f.Key] = true
		switch f.Kind {
		case "bool":
			if f.Minimum != nil || f.Maximum != nil || len(f.Choices) != 0 {
				return errors.New("invalid boolean settings field")
			}
		case "int":
			if f.Minimum == nil || f.Maximum == nil || *f.Minimum > *f.Maximum || *f.Minimum < -2147483648 || *f.Maximum > 2147483647 || len(f.Choices) != 0 {
				return errors.New("invalid integer settings field")
			}
		case "choice":
			if f.Minimum != nil || f.Maximum != nil || len(f.Choices) == 0 || len(f.Choices) > 32 {
				return errors.New("invalid choice settings field")
			}
			choices := make(map[string]bool, len(f.Choices))
			for _, c := range f.Choices {
				if !boundedText(c.Value, 256, true) || !boundedText(c.Label, 160, false) || choices[c.Value] {
					return errors.New("invalid settings choice")
				}
				choices[c.Value] = true
			}
		default:
			return errors.New("unknown phone settings field type")
		}
		if !validValue(f, f.Value) {
			return errors.New("invalid phone settings value")
		}
	}
	if s.Ack != nil && (!commandID.MatchString(s.Ack.ID) || (s.Ack.Status != "applied" && s.Ack.Status != "rejected") || !boundedText(s.Ack.Message, 300, false)) {
		return errors.New("invalid phone settings acknowledgment")
	}
	encoded, err := json.Marshal(s)
	if err != nil || len(encoded) > MaxBody {
		return errors.New("phone settings snapshot is too large")
	}
	return nil
}

func (s Snapshot) ValidateEdit(edit Edit) error {
	if !s.Enabled {
		return errors.New("enable ‘Allow Windows to change phone settings’ on the phone first")
	}
	if edit.BaseRevision != s.Revision {
		return errors.New("phone settings changed; reload them before saving")
	}
	if len(edit.Changes) == 0 || len(edit.Changes) > 64 {
		return errors.New("select at least one valid phone setting to change")
	}
	fields := make(map[string]Field, len(s.Fields))
	for _, f := range s.Fields {
		fields[f.Key] = f
	}
	for key, value := range edit.Changes {
		f, ok := fields[key]
		if !ok || !validValue(f, value) {
			return errors.New("a phone setting is unavailable or outside its allowed range")
		}
	}
	// The phone limits the complete command, not just its changes map. Marshal
	// exactly that envelope: RawMessage may contain lengthy escaped strings,
	// while insignificant JSON whitespace is compacted by the encoder.
	encoded, err := json.Marshal(Update{ID: "00000000000000000000000000000000", BaseRevision: edit.BaseRevision, Changes: edit.Changes})
	if err != nil || len(encoded) > MaxBody {
		return errors.New("phone settings update is too large; save fewer changes at once")
	}
	return nil
}

func ValidateEdit(snapshot *Snapshot, edit Edit) error {
	if snapshot == nil {
		return errors.New("waiting for current phone settings")
	}
	return snapshot.ValidateEdit(edit)
}

func CloneSnapshot(s *Snapshot) *Snapshot {
	if s == nil {
		return nil
	}
	result := *s
	result.Fields = make([]Field, len(s.Fields))
	for i, f := range s.Fields {
		result.Fields[i] = f
		result.Fields[i].Value = append(json.RawMessage(nil), f.Value...)
		result.Fields[i].Choices = append([]Choice(nil), f.Choices...)
		if f.Minimum != nil {
			v := *f.Minimum
			result.Fields[i].Minimum = &v
		}
		if f.Maximum != nil {
			v := *f.Maximum
			result.Fields[i].Maximum = &v
		}
	}
	if s.Ack != nil {
		ack := *s.Ack
		result.Ack = &ack
	}
	return &result
}

func CloneChanges(changes map[string]json.RawMessage) map[string]json.RawMessage {
	result := make(map[string]json.RawMessage, len(changes))
	for key, value := range changes {
		result[key] = append(json.RawMessage(nil), value...)
	}
	return result
}
