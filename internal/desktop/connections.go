package desktop

import (
	"sort"
	"time"

	"github.com/maskarauder/MicDrop/internal/phonecontrol"
)

// ConnectionMetrics are transport/buffer observations, not end-to-end latency.
type ConnectionMetrics struct {
	RTTMS, JitterMS, PlaybackBufferMS, OutputQueueMS *float64
}

type DeviceConnection struct {
	Key, Name, State, Mode string
	UpdatedAt              time.Time
	MetricsAt              time.Time
	Metrics                ConnectionMetrics
	Settings               *phonecontrol.Snapshot
	SettingsSupported      bool
	SettingsPending        bool
	SettingsMessage        string
}

func copyNumber(value *float64) *float64 {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}

func copyConnection(value DeviceConnection) DeviceConnection {
	value.Metrics = ConnectionMetrics{
		RTTMS: copyNumber(value.Metrics.RTTMS), JitterMS: copyNumber(value.Metrics.JitterMS),
		PlaybackBufferMS: copyNumber(value.Metrics.PlaybackBufferMS), OutputQueueMS: copyNumber(value.Metrics.OutputQueueMS),
	}
	value.Settings = phonecontrol.CloneSnapshot(value.Settings)
	return value
}

func (c *Controller) connection(key string) DeviceConnection {
	if row, ok := c.connections[key]; ok {
		return row
	}
	row := DeviceConnection{Key: key, Name: "Paired phone", State: "disconnected"}
	for _, phone := range c.state.Phones {
		if phone.Key == key {
			row.Name = phone.Name
			break
		}
	}
	return row
}

func (c *Controller) connectionState(key, state string) {
	if key == "" {
		return
	}
	row := c.connection(key)
	row.State = state
	if state != "connected" {
		row.SettingsPending = false
		row.SettingsMessage = ""
	}
	c.connections[key] = row
}

func (c *Controller) disconnectAll() {
	for key, row := range c.connections {
		row.State = "disconnected"
		row.SettingsPending = false
		row.SettingsMessage = ""
		c.connections[key] = row
	}
}

func (c *Controller) syncPhones() {
	allowed := make(map[string]bool, len(c.state.Phones))
	for _, phone := range c.state.Phones {
		allowed[phone.Key] = true
		row := c.connection(phone.Key)
		row.Name = phone.Name
		c.connections[phone.Key] = row
	}
	for key := range c.connections {
		if !allowed[key] {
			delete(c.connections, key)
		}
	}
}

func (c *Controller) connectionSnapshot() []DeviceConnection {
	result := make([]DeviceConnection, 0, len(c.connections))
	for _, value := range c.connections {
		result = append(result, copyConnection(value))
	}
	sort.Slice(result, func(i, j int) bool {
		activeI, activeJ := result[i].State != "disconnected", result[j].State != "disconnected"
		if activeI != activeJ {
			return activeI
		}
		if result[i].Name != result[j].Name {
			return result[i].Name < result[j].Name
		}
		return result[i].Key < result[j].Key
	})
	return result
}
