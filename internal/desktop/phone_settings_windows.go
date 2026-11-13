//go:build windows

package desktop

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/maskarauder/MicDrop/internal/phonecontrol"
)

type phoneSettingsEditor struct {
	key, group, field, lastAck, baselineMessage string
	session                                     uint64
	snapshot                                    *phonecontrol.Snapshot
	indices                                     []int
	awaiting, stale                             bool
	queuedAt                                    time.Time
}

func (u *desktopWindow) selectedDeviceKey() string {
	index := int(int32(send(u.controls[idDeviceList].handle, 0x188, 0, 0)))
	if index >= 0 && index < len(u.deviceKeys) {
		return u.deviceKeys[index]
	}
	return ""
}

func deviceByKey(state Snapshot, key string) (DeviceConnection, bool) {
	for _, device := range state.Connections {
		if device.Key == key {
			return device, true
		}
	}
	return DeviceConnection{}, false
}

func (u *desktopWindow) renderConnections(state Snapshot) {
	if u.controls[idDeviceList].handle == 0 {
		return
	}
	selected := u.selectedDeviceKey()
	var display strings.Builder
	connected, paused := 0, 0
	for _, device := range state.Connections {
		fmt.Fprintf(&display, "%s\x00%s\x00%s\n", device.Key, device.Name, device.State)
		if device.State == "connected" {
			connected++
		} else if device.State == "paused" || device.State == "interrupted" {
			paused++
		}
	}
	count := fmt.Sprintf("%d devices connected", connected)
	if connected == 1 {
		count = "1 device connected"
	}
	if paused != 0 {
		count += fmt.Sprintf(" · %d paused", paused)
	}
	if textAt(u.controls[idDeviceCount].handle) != count {
		setText(u.controls[idDeviceCount].handle, count)
	}
	if display.String() != u.deviceDisplay {
		u.deviceDisplay = display.String()
		u.deviceKeys = nil
		send(u.controls[idDeviceList].handle, 0x184, 0, 0)
		selection := 0
		for i, device := range state.Connections {
			u.deviceKeys = append(u.deviceKeys, device.Key)
			name := []rune(device.Name)
			if len(name) > 22 {
				name = append(name[:21], '…')
			}
			stateLabel := strings.TrimSuffix(connectionStateLabel(device.State), " (last reported)")
			label := string(name) + " · " + stateLabel + " · " + device.Key[:min(8, len(device.Key))]
			sendText(u.controls[idDeviceList].handle, 0x180, 0, label)
			if selected == device.Key {
				selection = i
			}
		}
		if len(u.deviceKeys) != 0 {
			send(u.controls[idDeviceList].handle, 0x186, uintptr(selection), 0)
		}
	}
	device, found := deviceByKey(state, u.selectedDeviceKey())
	metrics := "Select a phone to view its connection."
	if found {
		metrics = connectionMetricsLabel(device, time.Now())
	}
	if textAt(u.controls[idDeviceMetrics].handle) != metrics {
		setText(u.controls[idDeviceMetrics].handle, metrics)
	}
	enabled(u.controls[idDeviceSettings].handle, found && phoneSettingsAvailable(device, time.Now()) && !u.closing)
	u.updatePhoneEditor(state)
}

func (u *desktopWindow) openPhoneSettings() {
	key := u.selectedDeviceKey()
	if key == "" {
		return
	}
	if u.phoneEditor == nil || u.phoneEditor.key != key {
		u.phoneEditor = &phoneSettingsEditor{key: key, group: "Live"}
	}
	u.reloadPhoneSettings()
	u.selectPage(4)
}

func (u *desktopWindow) reloadPhoneSettings() {
	if u.phoneEditor == nil || u.phoneEditor.awaiting {
		return
	}
	device, found := deviceByKey(u.controller.Snapshot(), u.phoneEditor.key)
	if !found {
		return
	}
	u.loadPhoneSettings(device)
}

func (u *desktopWindow) loadPhoneSettings(device DeviceConnection) {
	e := u.phoneEditor
	e.snapshot = phonecontrol.CloneSnapshot(device.Settings)
	e.session = u.controller.Snapshot().Session
	e.stale = false
	e.lastAck = ""
	if e.snapshot != nil && e.snapshot.Ack != nil {
		e.lastAck = e.snapshot.Ack.ID
	}
	setText(u.controls[idPhoneSettingsTitle].handle, "Phone settings — "+device.Name+" · "+device.Key[:min(12, len(device.Key))])
	groups := []string{"Live", "Audio", "Advanced"}
	selection := 0
	for i, group := range groups {
		if e.group == group {
			selection = i
		}
	}
	comboItems(u.controls[idPhoneSettingsGroup].handle, groups, selection)
	u.phoneSettingsGroupChanged()
	u.updatePhoneEditor(u.controller.Snapshot())
}

func (u *desktopWindow) phoneSettingsGroupChanged() {
	e := u.phoneEditor
	if e == nil {
		return
	}
	group := int(int32(send(u.controls[idPhoneSettingsGroup].handle, 0x147, 0, 0)))
	if group < 0 || group >= 3 {
		return
	}
	e.group = []string{"Live", "Audio", "Advanced"}[group]
	e.indices = nil
	send(u.controls[idPhoneSettingsList].handle, 0x184, 0, 0)
	selection := 0
	if e.snapshot != nil {
		for i, field := range e.snapshot.Fields {
			if field.Group != e.group {
				continue
			}
			e.indices = append(e.indices, i)
			label := field.Label + ": " + phoneFieldValue(field)
			sendText(u.controls[idPhoneSettingsList].handle, 0x180, 0, label)
			if field.Key == e.field {
				selection = len(e.indices) - 1
			}
		}
	}
	if len(e.indices) != 0 {
		send(u.controls[idPhoneSettingsList].handle, 0x186, uintptr(selection), 0)
	}
	u.phoneSettingSelected()
}

func (u *desktopWindow) selectedPhoneField() *phonecontrol.Field {
	e := u.phoneEditor
	if e == nil || e.snapshot == nil {
		return nil
	}
	selected := int(int32(send(u.controls[idPhoneSettingsList].handle, 0x188, 0, 0)))
	if selected < 0 || selected >= len(e.indices) {
		return nil
	}
	return &e.snapshot.Fields[e.indices[selected]]
}

func (u *desktopWindow) phoneSettingSelected() {
	field := u.selectedPhoneField()
	if field == nil {
		setText(u.controls[idPhoneFieldLabel].handle, "No settings in this group.")
		setText(u.controls[idPhoneFieldEffect].handle, "")
	} else {
		u.phoneEditor.field = field.Key
		setText(u.controls[idPhoneFieldLabel].handle, field.Label)
		effect := "Saved for the next connection."
		if field.Effect == "live" {
			effect = "Applies to the current connection."
		}
		if strings.Contains(strings.ToLower(field.Key), "volume") {
			effect += " Changes Android system volume."
		}
		switch field.Kind {
		case "bool":
			var value bool
			_ = json.Unmarshal(field.Value, &value)
			check(u.controls[idPhoneFieldBool].handle, value)
		case "int":
			setText(u.controls[idPhoneFieldInt].handle, string(field.Value))
			send(u.controls[idPhoneFieldInt].handle, 0xC5, 12, 0) // EM_LIMITTEXT
			if field.Minimum != nil && field.Maximum != nil {
				effect += fmt.Sprintf("\r\nAllowed: %d–%d.", *field.Minimum, *field.Maximum)
			}
		case "choice":
			var value string
			_ = json.Unmarshal(field.Value, &value)
			labels := make([]string, 0, len(field.Choices))
			selection := -1
			for i, choice := range field.Choices {
				labels = append(labels, choice.Label)
				if choice.Value == value {
					selection = i
				}
			}
			comboItems(u.controls[idPhoneFieldChoice].handle, labels, selection)
		}
		setText(u.controls[idPhoneFieldEffect].handle, effect)
	}
	u.phoneEditorVisibility()
	u.updatePhoneEditor(u.controller.Snapshot())
}

func (u *desktopWindow) phoneEditorVisibility() {
	field := u.selectedPhoneField()
	for _, item := range []struct {
		id   int
		kind string
	}{{idPhoneFieldBool, "bool"}, {idPhoneFieldInt, "int"}, {idPhoneFieldChoice, "choice"}} {
		show := uintptr(0)
		if u.page == 4 && field != nil && field.Kind == item.kind {
			show = 5
		}
		if u.controls[item.id].handle != 0 {
			showWindow.Call(u.controls[item.id].handle, show)
		}
	}
}

func (u *desktopWindow) updatePhoneEditor(state Snapshot) {
	e := u.phoneEditor
	if e == nil {
		return
	}
	device, found := deviceByKey(state, e.key)
	unavailable := phoneSettingsUnavailableMessage(device, found, time.Now())
	available := unavailable == ""
	if e.awaiting && e.session != state.Session {
		e.awaiting = false
		e.stale = true
	}
	if e.awaiting && device.Settings != nil && device.Settings.Ack != nil && device.Settings.Ack.ID != e.lastAck {
		e.awaiting = false
		u.loadPhoneSettings(device)
		return
	}
	if e.awaiting && !device.SettingsPending && (device.SettingsMessage != e.baselineMessage || time.Since(e.queuedAt) > 20*time.Second) {
		e.awaiting = false
		e.stale = true // An unconfirmed command is never resubmitted automatically.
	}
	if available && e.snapshot == nil && !e.awaiting {
		u.loadPhoneSettings(device) // The first snapshot after the waiting message; no fields were shown.
		return
	}
	stale := e.stale || e.session != state.Session || e.snapshot == nil || device.Settings == nil || device.Settings.Revision != e.snapshot.Revision
	message := "Only the selected setting is sent. Microphone consent and phone permissions stay on the phone."
	switch {
	case !available:
		message = unavailable
	case !device.Settings.Enabled:
		message = "On the phone, enable ‘Allow Windows to change phone settings’ to allow changes here."
	case e.awaiting || device.SettingsPending:
		message = "Waiting for the phone to confirm the change…"
	case stale:
		message = "Settings changed or confirmation was not received. Reload before making another change."
	case device.SettingsMessage != "":
		message = device.SettingsMessage
	}
	setText(u.controls[idPhoneSettingsStatus].handle, message)
	editable := available && device.Settings.Enabled && !stale && !e.awaiting && !device.SettingsPending && !u.closing
	enabled(u.controls[idPhoneFieldBool].handle, editable)
	enabled(u.controls[idPhoneFieldChoice].handle, editable)
	readOnly(u.controls[idPhoneFieldInt].handle, !editable)
	enabled(u.controls[idPhoneSettingsApply].handle, editable && u.selectedPhoneField() != nil)
	enabled(u.controls[idPhoneSettingsReload].handle, available && !e.awaiting && !device.SettingsPending)
}

func (u *desktopWindow) applyPhoneSetting() {
	e := u.phoneEditor
	field := u.selectedPhoneField()
	if e == nil || e.snapshot == nil || field == nil || !themeEnabled(u.controls[idPhoneSettingsApply].handle) {
		return
	}
	state := u.controller.Snapshot()
	if e.session != state.Session || e.key != state.PhoneKey {
		e.stale = true
		u.updatePhoneEditor(state)
		return
	}
	var value json.RawMessage
	switch field.Kind {
	case "bool":
		value, _ = json.Marshal(checked(u.controls[idPhoneFieldBool].handle))
	case "int":
		number, err := strconv.Atoi(strings.TrimSpace(textAt(u.controls[idPhoneFieldInt].handle)))
		if err != nil || field.Minimum == nil || field.Maximum == nil || number < *field.Minimum || number > *field.Maximum {
			setText(u.controls[idPhoneSettingsStatus].handle, "Enter a whole number within the displayed range.")
			return
		}
		value, _ = json.Marshal(number)
	case "choice":
		index := int(int32(send(u.controls[idPhoneFieldChoice].handle, 0x147, 0, 0)))
		if index < 0 || index >= len(field.Choices) {
			return
		}
		value, _ = json.Marshal(field.Choices[index].Value)
	default:
		return
	}
	if bytes.Equal(bytes.TrimSpace(field.Value), value) {
		setText(u.controls[idPhoneSettingsStatus].handle, "This setting already has that value.")
		return
	}
	command := Command{Action: "phone_settings", Value: e.key, Session: e.session, Settings: &phonecontrol.Edit{BaseRevision: e.snapshot.Revision, Changes: map[string]json.RawMessage{field.Key: value}}}
	if err := u.controller.Command(command); err != nil {
		setText(u.controls[idPhoneSettingsStatus].handle, err.Error())
		return
	}
	device, _ := deviceByKey(u.controller.Snapshot(), e.key)
	e.awaiting = true
	e.queuedAt = time.Now()
	e.baselineMessage = device.SettingsMessage
	u.updatePhoneEditor(u.controller.Snapshot())
}
