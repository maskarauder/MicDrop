// SPDX-License-Identifier: MPL-2.0
//go:build (darwin && arm64) || (linux && amd64)

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
	index := uiListSelected(idDeviceList)
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
	if uiTextAt(idDeviceCount) != count {
		uiSetText(idDeviceCount, count)
	}
	if display.String() != u.deviceDisplay {
		u.deviceDisplay = display.String()
		u.deviceKeys = nil
		var labels []string
		selection := -1
		if len(state.Connections) != 0 {
			selection = 0
		}
		for i, device := range state.Connections {
			u.deviceKeys = append(u.deviceKeys, device.Key)
			name := []rune(device.Name)
			if len(name) > 22 {
				name = append(name[:21], '…')
			}
			stateLabel := strings.TrimSuffix(connectionStateLabel(device.State), " (last reported)")
			label := string(name) + " · " + stateLabel + " · " + device.Key[:min(8, len(device.Key))]
			labels = append(labels, label)
			if selected == device.Key {
				selection = i
			}
		}
		uiListItems(idDeviceList, labels, selection)
	}
	device, found := deviceByKey(state, u.selectedDeviceKey())
	metrics := "Select a phone to view its connection."
	if found {
		metrics = strings.ReplaceAll(connectionMetricsLabel(device, time.Now()), "\r\n", "\n")
	}
	if uiTextAt(idDeviceMetrics) != metrics {
		uiSetText(idDeviceMetrics, metrics)
	}
	uiEnabled(idDeviceSettings, found && phoneSettingsAvailable(device, time.Now()) && !u.closing)
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
	uiSetText(idPhoneSettingsTitle, "Phone settings — "+device.Name+" · "+device.Key[:min(12, len(device.Key))])
	groups := []string{"Live", "Audio", "Advanced"}
	selection := 0
	for i, group := range groups {
		if e.group == group {
			selection = i
		}
	}
	uiComboItems(idPhoneSettingsGroup, groups, selection)
	u.phoneSettingsGroupChanged()
	u.updatePhoneEditor(u.controller.Snapshot())
}

func (u *desktopWindow) phoneSettingsGroupChanged() {
	e := u.phoneEditor
	if e == nil {
		return
	}
	group := uiComboSelected(idPhoneSettingsGroup)
	if group < 0 || group >= 3 {
		return
	}
	e.group = []string{"Live", "Audio", "Advanced"}[group]
	e.indices = nil
	var labels []string
	selection := -1
	if e.snapshot != nil {
		for i, field := range e.snapshot.Fields {
			if field.Group != e.group {
				continue
			}
			if selection < 0 {
				selection = 0
			}
			e.indices = append(e.indices, i)
			labels = append(labels, field.Label+": "+phoneFieldValue(field))
			if field.Key == e.field {
				selection = len(e.indices) - 1
			}
		}
	}
	uiListItems(idPhoneSettingsList, labels, selection)
	u.phoneSettingSelected()
}

func (u *desktopWindow) selectedPhoneField() *phonecontrol.Field {
	e := u.phoneEditor
	if e == nil || e.snapshot == nil {
		return nil
	}
	selected := uiListSelected(idPhoneSettingsList)
	if selected < 0 || selected >= len(e.indices) {
		return nil
	}
	return &e.snapshot.Fields[e.indices[selected]]
}

func (u *desktopWindow) phoneSettingSelected() {
	field := u.selectedPhoneField()
	if field == nil {
		uiSetText(idPhoneFieldLabel, "No settings in this group.")
		uiSetText(idPhoneFieldEffect, "")
	} else {
		u.phoneEditor.field = field.Key
		uiSetText(idPhoneFieldLabel, field.Label)
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
			uiCheck(idPhoneFieldBool, value)
		case "int":
			uiSetText(idPhoneFieldInt, string(field.Value))
			uiSetMaxLength(idPhoneFieldInt, 12)
			if field.Minimum != nil && field.Maximum != nil {
				effect += fmt.Sprintf("\nAllowed: %d–%d.", *field.Minimum, *field.Maximum)
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
			uiComboItems(idPhoneFieldChoice, labels, selection)
		}
		uiSetText(idPhoneFieldEffect, effect)
	}
	u.phoneEditorVisibility()
	u.updatePhoneEditor(u.controller.Snapshot())
}

func (u *desktopWindow) phoneEditorVisibility() {
	field := u.selectedPhoneField()
	for _, item := range []struct {
		id   int
		kind string
	}{
		{idPhoneFieldBool, "bool"},
		{idPhoneFieldInt, "int"},
		{idPhoneFieldChoice, "choice"},
	} {
		uiSetVisible(item.id, u.page == 4 && field != nil && field.Kind == item.kind)
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
		e.stale = true
	}
	if available && e.snapshot == nil && !e.awaiting {
		u.loadPhoneSettings(device)
		return
	}
	stale := e.stale || e.session != state.Session || e.snapshot == nil || device.Settings == nil || device.Settings.Revision != e.snapshot.Revision
	message := "Only the selected setting is sent. Microphone consent and phone permissions stay on the phone."
	switch {
	case !available:
		message = strings.ReplaceAll(unavailable, "with Windows", "with MicDrop desktop")
	case !device.Settings.Enabled:
		message = "On the phone, enable ‘Allow Windows to change phone settings’ to allow changes here."
	case e.awaiting || device.SettingsPending:
		message = "Waiting for the phone to confirm the change…"
	case stale:
		message = "Settings changed or confirmation was not received. Reload before making another change."
	case device.SettingsMessage != "":
		message = device.SettingsMessage
	}
	uiSetText(idPhoneSettingsStatus, message)
	editable := available && device.Settings.Enabled && !stale && !e.awaiting && !device.SettingsPending && !u.closing
	uiEnabled(idPhoneFieldBool, editable)
	uiEnabled(idPhoneFieldChoice, editable)
	uiReadOnly(idPhoneFieldInt, !editable)
	uiEnabled(idPhoneSettingsApply, editable && u.selectedPhoneField() != nil)
	uiEnabled(idPhoneSettingsReload, available && !e.awaiting && !device.SettingsPending)
}

func (u *desktopWindow) applyPhoneSetting() {
	e := u.phoneEditor
	field := u.selectedPhoneField()
	if e == nil || e.snapshot == nil || field == nil || !uiIsEnabled(idPhoneSettingsApply) {
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
		value, _ = json.Marshal(uiChecked(idPhoneFieldBool))
	case "int":
		number, err := strconv.Atoi(strings.TrimSpace(uiTextAt(idPhoneFieldInt)))
		if err != nil || field.Minimum == nil || field.Maximum == nil || number < *field.Minimum || number > *field.Maximum {
			uiSetText(idPhoneSettingsStatus, "Enter a whole number within the displayed range.")
			return
		}
		value, _ = json.Marshal(number)
	case "choice":
		index := uiComboSelected(idPhoneFieldChoice)
		if index < 0 || index >= len(field.Choices) {
			return
		}
		value, _ = json.Marshal(field.Choices[index].Value)
	default:
		return
	}
	if bytes.Equal(bytes.TrimSpace(field.Value), value) {
		uiSetText(idPhoneSettingsStatus, "This setting already has that value.")
		return
	}
	command := Command{
		Action:  "phone_settings",
		Value:   e.key,
		Session: e.session,
		Settings: &phonecontrol.Edit{
			BaseRevision: e.snapshot.Revision,
			Changes:      map[string]json.RawMessage{field.Key: value},
		},
	}
	if err := u.controller.Command(command); err != nil {
		uiSetText(idPhoneSettingsStatus, err.Error())
		return
	}
	device, _ := deviceByKey(u.controller.Snapshot(), e.key)
	e.awaiting = true
	e.queuedAt = time.Now()
	e.baselineMessage = device.SettingsMessage
	u.updatePhoneEditor(u.controller.Snapshot())
}
