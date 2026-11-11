package desktop

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"time"

	"github.com/maskarauder/MicDrop/internal/phonecontrol"
)

type Command struct {
	Action, Value string
	Session       uint64
	Settings      *phonecontrol.Edit
}
type Phone struct{ Name, Key string }
type Pending struct{ ID, Name, Key string }
type Event struct {
	Kind         string
	Message      string
	Session      uint64
	PhoneKey     string
	Resuming     bool
	ResumeReason string // Host-validated label; meaningful only with Resuming.
	State        string
	Link         string
	Expires      time.Time
	Pending      Pending
	Phones       []Phone
	Connection   *DeviceConnection
}
type Backend struct {
	Run          func(context.Context, Settings, <-chan Command, func(Event)) error
	Devices      func() ([]AudioDevice, error)
	RemoteStatus func() (string, error)
	ImportRemote func(string) error
	ForgetRemote func() error
}
type Notice struct {
	Title, Message string
	Warning        bool
}
type Snapshot struct {
	Phase        string
	Status       string
	Message      string
	Failed       bool
	Session      uint64
	PhoneKey     string
	SessionState string
	Link         string
	Expires      time.Time
	Pending      Pending
	Phones       []Phone
	Connections  []DeviceConnection
	Revision     uint64
}

// Controller serializes host ownership. Stop cancels immediately, but a new
// Start cannot run until the old host has closed media, listeners and its lock.
// Host callbacks never call Win32 or wait for the UI thread.
type Controller struct {
	mu             sync.Mutex
	backend        Backend
	state          Snapshot
	generation     uint64
	cancel         context.CancelFunc
	done           chan struct{}
	commands       chan Command
	notices        []Notice
	connected      bool
	interrupted    bool
	pausedPhone    string
	resuming       bool
	connections    map[string]DeviceConnection
	settingsQueued bool
}

func NewController(backend Backend) *Controller {
	return &Controller{backend: backend, state: Snapshot{Phase: "stopped", Status: "Stopped"}, connections: make(map[string]DeviceConnection)}
}
func (c *Controller) Snapshot() Snapshot {
	c.mu.Lock()
	defer c.mu.Unlock()
	s := c.state
	s.Phones = append([]Phone(nil), s.Phones...)
	s.Connections = c.connectionSnapshot()
	if !s.Expires.IsZero() && !time.Now().Before(s.Expires) {
		s.Link = ""
		s.Pending = Pending{}
	}
	return s
}
func (c *Controller) Notices() []Notice {
	c.mu.Lock()
	defer c.mu.Unlock()
	result := c.notices
	c.notices = nil
	return result
}
func (c *Controller) notice(title, message string, warning bool) {
	if len(c.notices) >= 8 {
		c.notices = c.notices[1:]
	}
	c.notices = append(c.notices, Notice{title, message, warning})
}
func (c *Controller) Start(settings Settings) error {
	if err := settings.Validate(); err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.state.Phase != "stopped" {
		return errors.New("wait until the current host has stopped")
	}
	ctx, cancel := context.WithCancel(context.Background())
	c.cancel = cancel
	c.done = make(chan struct{})
	c.commands = make(chan Command, 8)
	c.generation++
	generation := c.generation
	c.state = Snapshot{Phase: "starting", Status: "Starting…", Revision: c.state.Revision + 1}
	c.connected = false
	c.interrupted = false
	c.pausedPhone = ""
	c.resuming = false
	c.notices = nil
	c.connections = make(map[string]DeviceConnection)
	c.settingsQueued = false
	done, commands := c.done, c.commands
	go func() {
		err := c.backend.Run(ctx, settings, commands, func(event Event) { c.publish(generation, event) })
		c.mu.Lock()
		stopping := c.state.Phase == "stopping"
		c.state.Phase = "stopped"
		c.state.Status = "Stopped"
		c.state.Link = ""
		c.state.Pending = Pending{}
		c.state.Session = 0
		c.state.PhoneKey = ""
		c.state.SessionState = ""
		c.disconnectAll()
		c.settingsQueued = false
		c.state.Revision++
		if err != nil && !stopping {
			c.state.Message = err.Error()
			c.state.Failed = true
			c.notice("MicDrop could not start or continue", "Open MicDrop for details. Your saved pairing is unchanged.", true)
		}
		c.cancel = nil
		close(done)
		c.mu.Unlock()
		cancel()
	}()
	return nil
}
func (c *Controller) Stop() <-chan struct{} {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.cancel != nil {
		c.state.Phase = "stopping"
		c.state.Status = "Stopping…"
		c.state.Link = ""
		c.state.Pending = Pending{}
		c.disconnectAll()
		c.state.Revision++
		c.notices = nil
		c.cancel()
		return c.done
	}
	done := make(chan struct{})
	close(done)
	return done
}
func (c *Controller) Command(command Command) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.state.Phase != "ready" {
		return errors.New("start the host before managing phones")
	}
	switch command.Action {
	case "pair":
	case "phone_settings":
		if command.Session != 0 && command.Session != c.state.Session {
			return errors.New("the phone connection changed; reload its settings before saving")
		}
		row, ok := c.connections[command.Value]
		if !ok || command.Value != c.state.PhoneKey || c.state.Session == 0 || row.State != "connected" || row.UpdatedAt.IsZero() || time.Since(row.UpdatedAt) > 10*time.Second {
			return errors.New("connect the selected phone before changing its settings")
		}
		if row.SettingsPending {
			return errors.New("wait for the phone to confirm the previous change")
		}
		if command.Settings == nil {
			return errors.New("no phone settings changes were supplied")
		}
		if err := phonecontrol.ValidateEdit(row.Settings, *command.Settings); err != nil {
			return err
		}
		copy := *command.Settings
		copy.Changes = make(map[string]json.RawMessage, len(command.Settings.Changes))
		for key, value := range command.Settings.Changes {
			copy.Changes[key] = append(json.RawMessage(nil), value...)
		}
		command.Settings = &copy
		command.Session = c.state.Session
	case "approve", "reject":
		if command.Value == "" || c.state.Pending.ID != command.Value || !time.Now().Before(c.state.Expires) {
			return errors.New("that pairing request is no longer current")
		}
	case "revoke":
		found := false
		for _, p := range c.state.Phones {
			if p.Key == command.Value {
				found = true
			}
		}
		if !found {
			return errors.New("select a paired phone")
		}
	default:
		return errors.New("unknown desktop command")
	}
	select {
	case c.commands <- command:
		if command.Action == "phone_settings" {
			c.settingsQueued = true
			row := c.connections[command.Value]
			row.SettingsPending = true
			row.SettingsMessage = "Waiting for the phone to confirm…"
			c.connections[command.Value] = row
			c.state.Revision++
		}
		return nil
	default:
		return errors.New("a phone operation is still pending; try again shortly")
	}
}
func (c *Controller) publish(generation uint64, e Event) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if generation != c.generation || c.state.Phase == "stopping" || c.state.Phase == "stopped" {
		return
	}
	c.state.Revision++
	switch e.Kind {
	case "ready":
		c.state.Phase = "ready"
		c.state.Status = "Ready for a paired phone"
		c.state.Message = e.Message
	case "phones":
		c.state.Phones = append([]Phone(nil), e.Phones...)
		c.syncPhones()
	case "phone_state":
		if e.Session != c.state.Session || c.state.Session == 0 || e.Connection == nil || e.Connection.Key != c.state.PhoneKey {
			return
		}
		row := copyConnection(*e.Connection)
		previous := c.connection(row.Key)
		row.Name, row.State = previous.Name, previous.State
		if c.settingsQueued {
			row.SettingsPending, row.SettingsMessage = previous.SettingsPending, previous.SettingsMessage
		}
		c.connections[row.Key] = row
	case "phone_settings_queued":
		if e.PhoneKey == c.state.PhoneKey && e.Session == c.state.Session {
			c.settingsQueued = false
		}
	case "phone_settings_error":
		if e.PhoneKey != c.state.PhoneKey || e.Session != c.state.Session {
			return
		}
		row := c.connection(e.PhoneKey)
		c.settingsQueued = false
		row.SettingsPending = false
		row.SettingsMessage = e.Message
		c.connections[e.PhoneKey] = row
	case "invitation":
		c.state.Link = e.Link
		c.state.Expires = e.Expires
		c.state.Pending = Pending{}
		c.state.Message = "Scan the QR code on your phone, then tap Connect."
	case "pending":
		if c.state.Pending.ID != e.Pending.ID {
			c.notice("Pairing approval requested", "Open MicDrop and compare the request ID shown on your phone.", false)
		}
		c.state.Pending = e.Pending
	case "pairing_closed":
		c.state.Link = ""
		c.state.Pending = Pending{}
		c.state.Message = e.Message
	case "message":
		c.state.Message = e.Message
	case "session_begin":
		c.disconnectAll()
		c.settingsQueued = false
		c.state.Session = e.Session
		c.state.PhoneKey = e.PhoneKey
		// Pausing closes the media transport. Only an explicit resume from the
		// same authenticated phone continues that interaction without a toast.
		// A fresh Connect after Stop is still a new connection, even if Stop
		// occurred while paused and there was no live transport to notify us.
		c.resuming = e.Resuming && e.PhoneKey != "" && e.PhoneKey == c.pausedPhone
		c.pausedPhone = ""
		c.state.SessionState = "connecting"
		c.state.Status = "Phone connecting…"
		c.state.Message = "Connecting to the phone…"
		if c.resuming {
			// The reason only words the resume; "manual" also covers accessory
			// and OS Play, so no text claims that a person pressed Play.
			switch e.ResumeReason {
			case "focus_regain":
				c.state.Message = "The phone's audio interruption ended. Resuming…"
			case "automatic":
				c.state.Message = "The phone is reconnecting to apply a change…"
			default:
				c.state.Message = "Resuming the phone connection…"
			}
		}
		c.connected = false
		c.interrupted = false
		c.connectionState(e.PhoneKey, "connecting")
	case "session_status":
		if e.Session != c.state.Session || c.state.Session == 0 {
			return
		}
		c.state.SessionState = e.State
		switch e.State {
		case "connected":
			c.connectionState(c.state.PhoneKey, "connected")
			// Refresh lifecycle guidance only on a transition. Routine status
			// polls must not erase a later settings/pairing action error.
			if !c.connected {
				c.state.Message = "Phone connected."
			} else if c.interrupted {
				c.state.Message = "Phone connection restored."
			}
			if !c.connected && !c.resuming {
				c.notice("Phone connected", "A paired phone is connected to MicDrop.", false)
			} else if c.connected && c.interrupted {
				c.notice("Connection restored", "The phone connection has recovered.", false)
			}
			c.resuming = false
			c.connected = true
			c.interrupted = false
			c.state.Status = "Phone connected"
		case "disconnected", "failed", "checking":
			state := "connecting"
			if c.connected || e.State != "checking" {
				state = "reconnecting"
			}
			c.connectionState(c.state.PhoneKey, state)
			if c.connected {
				if !c.interrupted {
					c.state.Message = "Connection interrupted. Trying to reconnect…"
				}
				c.interrupted = true
				c.state.Status = "Restoring phone connection…"
			}
		}
	case "session_end":
		if e.Session != c.state.Session || c.state.Session == 0 {
			return
		}
		c.state.Session = 0
		c.settingsQueued = false
		c.state.SessionState = ""
		c.state.Status = "Ready for a paired phone"
		c.state.Message = "Last session: " + e.Message
		c.pausedPhone = ""
		switch e.Message {
		case "receiver_pause":
			if c.connected {
				c.pausedPhone = c.state.PhoneKey
			}
			c.state.SessionState = "paused"
			c.state.Status = "Phone paused"
			c.state.Message = "Paused on the phone. Tap Play on the phone to resume."
		case "receiver_focus_lost", "receiver_focus_lost_transient", "receiver_focus_lost_permanent":
			if c.connected {
				c.pausedPhone = c.state.PhoneKey
			}
			c.state.SessionState = "interrupted"
			c.state.Status = "Phone interrupted"
			c.state.Message = "Playback interrupted on the phone. Resume there when ready."
		case "receiver_stop", "offer_cancelled", "host_stopped", "device_revoked":
			// Intentional lifecycle transitions are not connection failures.
		default:
			c.notice("Phone connection ended", "The connection could not continue. Open MicDrop or the phone report for details.", true)
		}
		c.connected = false
		c.interrupted = false
		c.resuming = false
		state := c.state.SessionState
		if state == "" {
			state = "disconnected"
		}
		c.connectionState(c.state.PhoneKey, state)
	}
}
