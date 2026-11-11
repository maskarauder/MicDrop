// Package phonecontrol describes the optional, authenticated phone preference
// exchange. It never carries pairing credentials or grants microphone consent.
package phonecontrol

import "encoding/json"

const Version = 1
const Header = "X-MicDrop-Phone-Control"
const MaxBody = 64 * 1024

type Choice struct {
	Value string `json:"value"`
	Label string `json:"label"`
}

type Field struct {
	Key     string          `json:"key"`
	Label   string          `json:"label"`
	Group   string          `json:"group"`
	Kind    string          `json:"kind"` // bool, int, choice
	Value   json.RawMessage `json:"value"`
	Effect  string          `json:"effect"` // live, next_connection
	Minimum *int            `json:"minimum,omitempty"`
	Maximum *int            `json:"maximum,omitempty"`
	Choices []Choice        `json:"choices,omitempty"`
}

type Ack struct {
	ID      string `json:"id"`
	Status  string `json:"status"` // applied, rejected
	Message string `json:"message"`
}

type Snapshot struct {
	Version  int     `json:"version"`
	Revision string  `json:"revision"`
	Enabled  bool    `json:"enabled"`
	Fields   []Field `json:"fields"`
	Ack      *Ack    `json:"ack,omitempty"`
}

type Edit struct {
	BaseRevision string                     `json:"base_revision"`
	Changes      map[string]json.RawMessage `json:"changes"`
}

type Update struct {
	ID           string                     `json:"id"`
	BaseRevision string                     `json:"base_revision"`
	Changes      map[string]json.RawMessage `json:"changes"`
}
