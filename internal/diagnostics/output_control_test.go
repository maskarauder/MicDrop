package diagnostics

import "testing"

func outputControlFixture() *OutputControl {
	return &OutputControl{Version: 1, Selection: "bluetooth", RequestedEnabled: true, Phase: "restoring",
		Pause: "selected_bluetooth", SystemRouteKnown: true, Transfers: 1, TransferResult: "requested",
		PlayoutRecreations: 1, NearbyPermission: pointer(true)}
}

func TestOutputControlAcceptedInPeriodicAndTerminalReports(t *testing.T) {
	r, end := reportFixture(), terminalFixture()
	r.OutputControl, end.OutputControl = outputControlFixture(), outputControlFixture()
	if !r.Valid() || !end.Valid("connection_failed") {
		t.Fatal("bounded output control rejected")
	}
	r.OutputControl.Selection, r.OutputControl.DefaultMatches = "default", pointer(false)
	if !r.Valid() {
		t.Fatal("unknown/mismatching Android default must remain reportable")
	}
	r.OutputControl, end.OutputControl = nil, nil
	if !r.Valid() || !end.Valid("connection_failed") {
		t.Fatal("legacy reports rejected")
	}
}

func TestOutputControlRejectsPrivateTextUnknownVersionsAndUnboundedCounts(t *testing.T) {
	for _, mutate := range []func(*OutputControl){
		func(o *OutputControl) { o.Version = 2 },
		func(o *OutputControl) { o.Selection = "private-headset-name" },
		func(o *OutputControl) { o.Phase = "exception text" },
		func(o *OutputControl) { o.Pause = "device-address" },
		func(o *OutputControl) { o.TransferResult = "opaque-route-id" },
		func(o *OutputControl) { o.Transfers = -1 },
		func(o *OutputControl) { o.Transfers = 1_000_001 },
		func(o *OutputControl) { o.PlayoutRecreations = -1 },
		func(o *OutputControl) { o.PlayoutRecreations = 1_000_001 },
		func(o *OutputControl) { o.DefaultMatches = pointer(true) },
	} {
		r, end := reportFixture(), terminalFixture()
		r.OutputControl = outputControlFixture()
		mutate(r.OutputControl)
		end.OutputControl = r.OutputControl
		if r.Valid() || end.Valid("connection_failed") {
			t.Fatal("unsafe output control accepted")
		}
	}
}
