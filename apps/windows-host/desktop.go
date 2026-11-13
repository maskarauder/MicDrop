package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/maskarauder/MicDrop/internal/desktop"
	"github.com/maskarauder/MicDrop/internal/pairing"
	"github.com/maskarauder/MicDrop/internal/session"
	windowsaudio "github.com/maskarauder/MicDrop/native/platform/windows"
)

type desktopStream struct {
	Commands <-chan desktop.Command
	Emit     func(desktop.Event)
}

func (d *desktopStream) emit(event desktop.Event) {
	if d != nil {
		d.Emit(event)
	}
}
func (d *desktopStream) phones(manager *pairing.Manager) {
	if d == nil {
		return
	}
	var phones []desktop.Phone
	for _, p := range manager.Devices() {
		phones = append(phones, desktop.Phone{Name: p.Label, Key: p.Fingerprint})
	}
	d.emit(desktop.Event{Kind: "phones", Phones: phones})
}
func (d *desktopStream) command(command desktop.Command, manager *pairing.Manager, control *session.Host, host string, port int, format func(string) string) {
	var err error
	switch command.Action {
	case "phone_settings":
		if command.Settings == nil {
			err = errors.New("no phone settings changes were supplied")
		} else {
			_, err = control.QueuePhoneSettings(command.Value, command.Session, *command.Settings)
		}
		if err != nil {
			d.emit(desktop.Event{Kind: "phone_settings_error", PhoneKey: command.Value, Session: command.Session, Message: err.Error()})
		} else {
			d.emit(desktop.Event{Kind: "phone_settings_queued", PhoneKey: command.Value, Session: command.Session})
		}
		return
	case "pair":
		var invitation pairing.Invitation
		invitation, err = manager.Open(host, port)
		if err == nil {
			link := invitation.Link()
			if format != nil {
				link = format(link)
			}
			d.emit(desktop.Event{Kind: "invitation", Link: link, Expires: time.Unix(invitation.ExpiresAt, 0)})
		}
	case "approve":
		err = manager.Approve(command.Value)
		if err == nil {
			d.emit(desktop.Event{Kind: "pairing_closed", Message: "Phone approved. Connect from the phone when ready."})
		}
	case "reject":
		err = manager.Reject(command.Value)
		if err == nil {
			d.emit(desktop.Event{Kind: "pairing_closed", Message: "Pairing request rejected."})
		}
	case "revoke":
		err = manager.Revoke(command.Value)
		control.Revoke(command.Value) // Persistence failure also fails closed.
		d.emit(desktop.Event{Kind: "pairing_closed", Message: "Phone removed. Pair it again to allow another connection."})
	default:
		err = errors.New("unknown desktop operation")
	}
	if err != nil {
		d.emit(desktop.Event{Kind: "message", Message: err.Error()})
	}
	d.phones(manager)
}

func runDesktop(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("desktop", flag.ContinueOnError)
	flags.SetOutput(stderr)
	background := flags.Bool("background", false, "start the saved host in the notification area")
	installLauncher := flags.Bool("install-launcher", false, "install XDG application launcher entry (Linux)")
	uninstallLauncher := flags.Bool("uninstall-launcher", false, "remove XDG application launcher entry (Linux)")
	if flags.Parse(args) != nil || flags.NArg() != 0 {
		return 2
	}
	if (*installLauncher && *uninstallLauncher) || ((*installLauncher || *uninstallLauncher) && *background) {
		fmt.Fprintln(stderr, "desktop --install-launcher, --uninstall-launcher, and --background cannot be combined")
		return 2
	}
	if *installLauncher {
		path, err := desktop.InstallLauncher()
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		fmt.Fprintf(stdout, "Installed desktop launcher %s\n", path)
		return 0
	}
	if *uninstallLauncher {
		path, err := desktop.UninstallLauncher()
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		fmt.Fprintf(stdout, "Removed desktop launcher %s\n", path)
		return 0
	}
	directory, err := desktop.Directory()
	if err == nil {
		err = desktop.Run(desktopBackend(directory), directory, *background)
	}
	if err != nil {
		fmt.Fprintln(stderr, err)
		desktop.ShowError(err)
		return 1
	}
	return 0
}

func desktopAudioDevices() ([]desktop.AudioDevice, error) {
	devices, err := windowsaudio.Devices()
	if err != nil {
		return nil, err
	}
	result := make([]desktop.AudioDevice, 0, len(devices))
	for _, d := range devices {
		result = append(result, desktop.AudioDevice{ID: d.ID, Name: d.Name, Default: d.DefaultMultimedia})
	}
	return result, nil
}
func desktopBackend(directory string) desktop.Backend {
	return desktop.Backend{
		Run: func(ctx context.Context, settings desktop.Settings, commands <-chan desktop.Command, emit func(desktop.Event)) error {
			if err := ctx.Err(); err != nil {
				return err
			}
			networks, err := desktop.Networks()
			if err != nil {
				return err
			}
			network, err := desktop.ResolveNetwork(settings, networks)
			if err != nil {
				return err
			}
			devices, err := desktopAudioDevices()
			if err != nil {
				return err
			}
			if err = desktop.ValidateDevices(settings, devices); err != nil {
				return err
			}
			args := []string{"--paired", "--host", network.Address, "--port", strconv.Itoa(settings.Port), "--log-dir", filepath.Join(directory, "logs")}
			args = append(args, "--log-retention", strconv.Itoa(settings.LogRetention))
			if !settings.SaveLogs {
				args = append(args, "--no-log")
			}
			if settings.CaptureDevice != "" {
				args = append(args, "--device", settings.CaptureDevice)
			}
			if settings.MicrophoneDevice != "" {
				args = append(args, "--microphone-device", settings.MicrophoneDevice)
			}
			if settings.Remote {
				args = append(args, "--remote")
			}
			output := &desktopErrors{}
			code := runStreamControlled(ctx, args, io.Discard, output, &desktopStream{Commands: commands, Emit: emit})
			if code != 0 {
				return fmt.Errorf("host stopped: %s", strings.TrimSpace(output.text))
			}
			return nil
		},
		Devices: desktopAudioDevices,
		RemoteStatus: func() (string, error) {
			c, err := loadRemote("")
			if err != nil {
				return "No remote configuration imported", err
			}
			suffix := ""
			if c.ForceRelay {
				suffix = " (force relay enabled)"
			}
			return c.URL + suffix, nil
		},
		ImportRemote: func(path string) error {
			output := &desktopErrors{}
			if runRemote([]string{"import", "--config", path}, io.Discard, output) != 0 {
				return errors.New(strings.TrimSpace(output.text))
			}
			return nil
		},
		ForgetRemote: func() error {
			output := &desktopErrors{}
			if runRemote([]string{"forget"}, io.Discard, output) != 0 {
				return errors.New(strings.TrimSpace(output.text))
			}
			return nil
		},
	}
}

// The UI displays bounded stderr only. stdout contains private invitations and
// goes to io.Discard; a GUI must never scrape console text to drive authorization.
type desktopErrors struct{ text string }

func (e *desktopErrors) Write(p []byte) (int, error) {
	e.text += string(p)
	if len(e.text) > 8192 {
		e.text = e.text[len(e.text)-8192:]
	}
	return len(p), nil
}
