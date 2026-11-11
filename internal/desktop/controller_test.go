package desktop

import (
	"context"
	"errors"
	"testing"
	"time"
)

func testController(t *testing.T, cleanup <-chan struct{}) (*Controller, func(Event), <-chan Command) {
	t.Helper()
	emissions := make(chan func(Event), 1)
	commands := make(chan (<-chan Command), 1)
	c := NewController(Backend{Run: func(ctx context.Context, _ Settings, input <-chan Command, emit func(Event)) error {
		emit(Event{Kind: "ready"})
		emissions <- emit
		commands <- input
		<-ctx.Done()
		if cleanup != nil {
			<-cleanup
		}
		return ctx.Err()
	}})
	if err := c.Start(Defaults()); err != nil {
		t.Fatal(err)
	}
	emit := <-emissions
	input := <-commands
	t.Cleanup(func() {
		select {
		case <-c.Stop():
		case <-time.After(time.Second):
			t.Error("host did not stop")
		}
	})
	return c, emit, input
}
func TestStopOwnsCleanupAndRejectsLateEvents(t *testing.T) {
	cleanup := make(chan struct{})
	c, emit, _ := testController(t, cleanup)
	emit(Event{Kind: "invitation", Link: "private-link", Expires: time.Now().Add(time.Minute)})
	stopped := c.Stop()
	emit(Event{Kind: "ready"})
	emit(Event{Kind: "pending", Pending: Pending{ID: "late"}})
	if err := c.Start(Defaults()); err == nil {
		t.Fatal("new host started before native cleanup")
	}
	if got := c.Snapshot(); got.Phase != "stopping" || got.Link != "" || got.Pending.ID != "" {
		t.Fatal(got)
	}
	if err := c.Command(Command{Action: "pair"}); err == nil {
		t.Fatal("command authorized after Stop")
	}
	close(cleanup)
	<-stopped
	if len(c.Notices()) != 0 {
		t.Fatal("intentional Stop emitted a failure notice")
	}
	if c.Snapshot().Failed {
		t.Fatal("intentional Stop is not a host failure")
	}
	if err := c.Start(Defaults()); err != nil {
		t.Fatal(err)
	}
	emit(Event{Kind: "pending", Pending: Pending{ID: "previous-run"}})
	if c.Snapshot().Pending.ID != "" {
		t.Fatal("old host modified successor")
	}
}
func TestConnectionNotificationsDescribeTransitionsNotPolling(t *testing.T) {
	c, emit, _ := testController(t, nil)
	emit(Event{Kind: "session_begin", Session: 1})
	if len(c.Notices()) != 0 {
		t.Fatal("connecting is not connected")
	}
	for range 10 {
		emit(Event{Kind: "session_status", Session: 1, State: "connected"})
	}
	notices := c.Notices()
	if len(notices) != 1 || notices[0].Title != "Phone connected" {
		t.Fatal(notices)
	}
	emit(Event{Kind: "session_status", Session: 1, State: "disconnected"})
	emit(Event{Kind: "session_status", Session: 1, State: "failed"})
	if len(c.Notices()) != 0 {
		t.Fatal("transient recovery spam")
	}
	for range 3 {
		emit(Event{Kind: "session_status", Session: 1, State: "connected"})
	}
	notices = c.Notices()
	if len(notices) != 1 || notices[0].Title != "Connection restored" {
		t.Fatal(notices)
	}
	emit(Event{Kind: "session_end", Session: 1, Message: "receiver_stop"})
	emit(Event{Kind: "session_status", Session: 1, State: "connected"})
	if len(c.Notices()) != 0 || c.Snapshot().Session != 0 {
		t.Fatal("late Check resurrected stopped media")
	}
	emit(Event{Kind: "session_begin", Session: 2})
	emit(Event{Kind: "session_status", Session: 1, State: "connected"})
	emit(Event{Kind: "session_end", Session: 1, Message: "receiver_failure"})
	if c.Snapshot().Session != 2 || len(c.Notices()) != 0 {
		t.Fatal("old session altered new session")
	}
	emit(Event{Kind: "session_status", Session: 2, State: "connected"})
	c.Notices()
	emit(Event{Kind: "session_end", Session: 2, Message: "receiver_timeout"})
	notices = c.Notices()
	if len(notices) != 1 || !notices[0].Warning {
		t.Fatal(notices)
	}
	emit(Event{Kind: "session_begin", Session: 3})
	emit(Event{Kind: "session_end", Session: 3, Message: "offer_cancelled"})
	if len(c.Notices()) != 0 {
		t.Fatal("cancelling setup emitted a disconnect warning")
	}
}
func TestPairingApprovalIsBoundToCurrentUnexpiredRequest(t *testing.T) {
	c, emit, commands := testController(t, nil)
	emit(Event{Kind: "invitation", Link: "secret", Expires: time.Now().Add(time.Minute)})
	emit(Event{Kind: "pending", Pending: Pending{ID: "first", Key: "key"}})
	emit(Event{Kind: "pending", Pending: Pending{ID: "first", Key: "key"}})
	notices := c.Notices()
	if len(notices) != 1 || notices[0].Message == "secret" {
		t.Fatal(notices)
	}
	emit(Event{Kind: "invitation", Link: "replacement", Expires: time.Now().Add(time.Minute)})
	emit(Event{Kind: "pending", Pending: Pending{ID: "second", Key: "key"}})
	if err := c.Command(Command{Action: "approve", Value: "first"}); err == nil {
		t.Fatal("stale dialog authorized")
	}
	if err := c.Command(Command{Action: "approve", Value: "second"}); err != nil {
		t.Fatal(err)
	}
	if got := <-commands; got.Value != "second" {
		t.Fatal(got)
	}
	emit(Event{Kind: "invitation", Link: "expired", Expires: time.Now().Add(-time.Second)})
	emit(Event{Kind: "pending", Pending: Pending{ID: "expired"}})
	if err := c.Command(Command{Action: "approve", Value: "expired"}); err == nil {
		t.Fatal("expired request authorized")
	}
	if c.Snapshot().Link != "" || c.Snapshot().Pending.ID != "" {
		t.Fatal("expired invitation is displayed")
	}
}
func TestBackendFailureIsVisibleAndDoesNotAutoRestart(t *testing.T) {
	finished := make(chan struct{})
	c := NewController(Backend{Run: func(context.Context, Settings, <-chan Command, func(Event)) error {
		defer close(finished)
		return errors.New("selected adapter unavailable")
	}})
	if err := c.Start(Defaults()); err != nil {
		t.Fatal(err)
	}
	<-finished
	deadline := time.Now().Add(time.Second)
	for c.Snapshot().Phase != "stopped" && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	s := c.Snapshot()
	if s.Phase != "stopped" || !s.Failed || s.Message != "selected adapter unavailable" {
		t.Fatal(s)
	}
	if notices := c.Notices(); len(notices) != 1 || !notices[0].Warning {
		t.Fatal(notices)
	}
}

// The host forwards only its fixed resume labels; an absent or unknown reason is
// the generic resume, as for phones that predate the reason header.
var resumeReasons = []struct{ reason, message string }{
	{"", "Resuming the phone connection…"},
	{"manual", "Resuming the phone connection…"},
	{"automatic", "The phone is reconnecting to apply a change…"},
	{"focus_regain", "The phone's audio interruption ended. Resuming…"},
	{"future_reason", "Resuming the phone connection…"},
}

func TestPhonePauseAndFocusInterruptionDoNotWarnAndCanResume(t *testing.T) {
	for _, reason := range []string{"receiver_pause", "receiver_focus_lost", "receiver_focus_lost_transient", "receiver_focus_lost_permanent"} {
		for _, resume := range resumeReasons {
			t.Run(reason+"/"+resume.reason, func(t *testing.T) {
				c, emit, _ := testController(t, nil)
				emit(Event{Kind: "session_begin", Session: 1, PhoneKey: "phone"})
				emit(Event{Kind: "session_status", Session: 1, State: "connected"})
				c.Notices()
				emit(Event{Kind: "session_status", Session: 1, State: "disconnected"})
				emit(Event{Kind: "session_end", Session: 1, Message: reason})
				if len(c.Notices()) != 0 || c.Snapshot().Phase != "ready" {
					t.Fatal("normal pause/interrupt was reported as failure", c.Snapshot())
				}
				if s := c.Snapshot(); s.PhoneKey != "phone" || (s.SessionState != "paused" && s.SessionState != "interrupted") {
					t.Fatal("paused phone identity/state was lost", s)
				}
				emit(Event{Kind: "session_begin", Session: 2, PhoneKey: "phone", Resuming: true, ResumeReason: resume.reason})
				if got := c.Snapshot().Message; got != resume.message {
					t.Fatal("resume retained stale pause guidance or ignored its reason", got)
				}
				emit(Event{Kind: "session_status", Session: 2, State: "connected"})
				if got := c.Snapshot().Message; got != "Phone connected." {
					t.Fatal("resumed connection retained stale guidance", got)
				}
				if notices := c.Notices(); len(notices) != 0 {
					t.Fatal("resuming the paused phone emitted another connection notice", notices)
				}
				emit(Event{Kind: "session_end", Session: 2, Message: "receiver_failure"})
				if notices := c.Notices(); len(notices) != 1 || !notices[0].Warning {
					t.Fatal("actual failure no longer warns", notices)
				}
			})
		}
	}
}

func TestLifecycleMessagesReplaceOldGuidanceWithoutErasingActionErrorsOnPolls(t *testing.T) {
	c, emit, _ := testController(t, nil)
	emit(Event{Kind: "invitation", Link: "pairing-link", Expires: time.Now().Add(time.Minute)})
	emit(Event{Kind: "session_begin", Session: 1, PhoneKey: "phone"})
	if got := c.Snapshot().Message; got != "Connecting to the phone…" {
		t.Fatal("session setup retained pairing instructions", got)
	}
	emit(Event{Kind: "session_status", Session: 1, State: "connected"})
	if got := c.Snapshot().Message; got != "Phone connected." {
		t.Fatal("connected session retained setup guidance", got)
	}
	emit(Event{Kind: "message", Message: "The selected setting could not be saved."})
	for range 3 {
		emit(Event{Kind: "session_status", Session: 1, State: "connected"})
	}
	if got := c.Snapshot().Message; got != "The selected setting could not be saved." {
		t.Fatal("steady connected polls erased an action error", got)
	}
	emit(Event{Kind: "session_status", Session: 1, State: "disconnected"})
	if got := c.Snapshot().Message; got != "Connection interrupted. Trying to reconnect…" {
		t.Fatal("recovery retained connected guidance", got)
	}
	emit(Event{Kind: "message", Message: "Pairing could not be opened."})
	for _, state := range []string{"checking", "failed", "disconnected"} {
		emit(Event{Kind: "session_status", Session: 1, State: state})
	}
	if got := c.Snapshot().Message; got != "Pairing could not be opened." {
		t.Fatal("ongoing recovery polls erased an action error", got)
	}
	emit(Event{Kind: "session_status", Session: 1, State: "connected"})
	if got := c.Snapshot().Message; got != "Phone connection restored." {
		t.Fatal("restored connection retained interruption guidance", got)
	}
}

func TestPauseResumeHintDoesNotHideFreshOrDifferentPhoneConnections(t *testing.T) {
	for _, tc := range []struct {
		name, firstPhone, nextPhone, ended string
		connected, resuming                bool
	}{
		{"explicit Connect after Stop while paused", "phone", "phone", "receiver_pause", true, false},
		{"different phone", "phone", "other", "receiver_pause", true, true},
		{"unidentified phone", "", "", "receiver_pause", true, true},
		{"first connection after pausing setup", "phone", "phone", "receiver_pause", false, true},
		{"ordinary Stop", "phone", "phone", "receiver_stop", true, true},
		{"genuine failure", "phone", "phone", "receiver_failure", true, true},
	} {
		for _, resume := range resumeReasons {
			t.Run(tc.name+"/"+resume.reason, func(t *testing.T) {
				c, emit, _ := testController(t, nil)
				emit(Event{Kind: "session_begin", Session: 1, PhoneKey: tc.firstPhone})
				if tc.connected {
					emit(Event{Kind: "session_status", Session: 1, State: "connected"})
				}
				emit(Event{Kind: "session_end", Session: 1, Message: tc.ended})
				c.Notices()
				emit(Event{Kind: "session_begin", Session: 2, PhoneKey: tc.nextPhone, Resuming: tc.resuming, ResumeReason: resume.reason})
				if got := c.Snapshot().Message; got != "Connecting to the phone…" {
					t.Fatal("a resume reason worded a fresh connection", got)
				}
				emit(Event{Kind: "session_status", Session: 2, State: "connected"})
				if notices := c.Notices(); len(notices) != 1 || notices[0].Title != "Phone connected" {
					t.Fatal("fresh connection notification was hidden", notices)
				}
			})
		}
	}
}

func TestResumeIsQuietOnlyOnceAndHostRestartClearsPause(t *testing.T) {
	for _, resume := range resumeReasons {
		t.Run(resume.reason, func(t *testing.T) {
			c, emit, _ := testController(t, nil)
			emit(Event{Kind: "session_begin", Session: 1, PhoneKey: "phone"})
			emit(Event{Kind: "session_status", Session: 1, State: "connected"})
			emit(Event{Kind: "session_end", Session: 1, Message: "receiver_pause"})
			c.Notices()
			emit(Event{Kind: "session_begin", Session: 2, PhoneKey: "phone", Resuming: true, ResumeReason: resume.reason})
			emit(Event{Kind: "session_status", Session: 2, State: "connected"})
			if notices := c.Notices(); len(notices) != 0 {
				t.Fatal(notices)
			}
			emit(Event{Kind: "session_status", Session: 2, State: "disconnected"})
			emit(Event{Kind: "session_status", Session: 2, State: "connected"})
			if notices := c.Notices(); len(notices) != 1 || notices[0].Title != "Connection restored" {
				t.Fatal("later network recovery was silenced", notices)
			}
			emit(Event{Kind: "session_end", Session: 2, Message: "receiver_pause"})
			<-c.Stop()
			if err := c.Start(Defaults()); err != nil {
				t.Fatal(err)
			}
			// Use this run's generation; late callbacks from the previous host must
			// remain rejected, independently of the remembered phone identity.
			c.mu.Lock()
			generation := c.generation
			c.mu.Unlock()
			c.publish(generation, Event{Kind: "session_begin", Session: 1, PhoneKey: "phone", Resuming: true, ResumeReason: resume.reason})
			c.publish(generation, Event{Kind: "session_status", Session: 1, State: "connected"})
			if notices := c.Notices(); len(notices) != 1 || notices[0].Title != "Phone connected" {
				t.Fatal("host restart inherited a pause notification exemption", notices)
			}
		})
	}
}
