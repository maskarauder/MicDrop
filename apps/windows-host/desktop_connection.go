package main

import (
	"github.com/maskarauder/MicDrop/internal/desktop"
	"github.com/maskarauder/MicDrop/internal/rtc"
	"github.com/maskarauder/MicDrop/internal/session"
)

func desktopPhoneState(phone *session.PhoneStatus, native *rtc.Status) desktop.DeviceConnection {
	row := desktop.DeviceConnection{
		Key: phone.Client, UpdatedAt: phone.UpdatedAt, MetricsAt: phone.ReportAt,
		Settings: phone.Control, SettingsSupported: phone.ControlNegotiated, SettingsPending: phone.Pending, SettingsMessage: phone.Message,
	}
	if native != nil {
		switch native.Direction {
		case "duplex":
			row.Mode = "Duplex"
		case "phone_microphone":
			row.Mode = "Phone microphone"
		default:
			row.Mode = "Desktop playback"
		}
	}
	if report := phone.Report; report != nil {
		row.Metrics.RTTMS = report.Metrics["rtt_ms"]
		row.Metrics.JitterMS = report.Metrics["jitter_ms"]
		row.Metrics.PlaybackBufferMS = report.Metrics["buffer_ms"]
		if report.Output != nil {
			row.Metrics.OutputQueueMS = report.Output.EstimatedQueueMS
		}
		if report.Microphone != nil && report.Microphone.State == "muted" {
			row.Mode += " · microphone muted"
		}
	}
	return row
}

// Only authenticated offer metadata reaches the desktop; the resume reason is
// one of the host's fixed labels, never raw header text.
func desktopSessionBegin(id uint64, offer session.OfferOptions) desktop.Event {
	return desktop.Event{Kind: "session_begin", Session: id, PhoneKey: offer.ClientKey, Resuming: offer.Resuming, ResumeReason: offer.ResumeReason}
}
