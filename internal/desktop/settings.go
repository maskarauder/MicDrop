// Package desktop owns the desktop host's preferences and lifecycle.
// It does not process audio, store credentials, or authorize phone capture.
package desktop

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

type Settings struct {
	Version          int    `json:"version"`
	Interface        string `json:"interface"`
	AddressHint      string `json:"address_hint"`
	Port             int    `json:"port"`
	CaptureDevice    string `json:"capture_device"`
	MicrophoneDevice string `json:"microphone_device"`
	Remote           bool   `json:"remote"`
	Notifications    bool   `json:"notifications"`
	SaveLogs         bool   `json:"save_logs"`
	LogRetention     int    `json:"log_retention"`
}

func Defaults() Settings {
	return Settings{Version: 1, Port: 9844, Notifications: true, SaveLogs: true}
}

func Directory() (string, error) {
	base, err := os.UserCacheDir()
	if err != nil || !filepath.IsAbs(base) {
		return "", errors.New("user data directory is unavailable")
	}
	return filepath.Join(base, "MicDrop"), nil
}

func (s Settings) Validate() error {
	if s.Version != 1 {
		return errors.New("unsupported desktop settings version; the existing file was not replaced")
	}
	if s.Port < 1 || s.Port > 65535 {
		return errors.New("LAN port must be between 1 and 65535")
	}
	if s.LogRetention < 0 || s.LogRetention > 10000 {
		return errors.New("keep between 1 and 10000 connection logs, or use 0 to keep all")
	}
	for _, text := range []string{s.Interface, s.AddressHint, s.CaptureDevice, s.MicrophoneDevice} {
		if len(text) > 1023 || !utf8.ValidString(text) || strings.ContainsRune(text, 0) {
			return errors.New("invalid desktop setting")
		}
	}
	if s.AddressHint != "" {
		ip := net.ParseIP(s.AddressHint)
		if ip == nil || ip.To4() == nil || !ip.IsPrivate() {
			return errors.New("select a private IPv4 network address")
		}
	}
	return nil
}

func LoadSettings(directory string) (Settings, error) {
	path := filepath.Join(directory, "desktop-v1.json")
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return Defaults(), nil
	}
	if err != nil {
		return Settings{}, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > 16*1024 {
		return Settings{}, errors.New("invalid desktop settings file")
	}
	s := Settings{SaveLogs: true} // Only new fields get migration defaults.
	decoder := json.NewDecoder(io.LimitReader(file, 16*1024+1))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&s); err != nil {
		return Settings{}, fmt.Errorf("cannot read desktop settings: %w", err)
	}
	if decoder.Decode(new(any)) != io.EOF {
		return Settings{}, errors.New("invalid trailing desktop settings")
	}
	return s, s.Validate()
}

func SaveSettings(directory string, s Settings) error {
	if err := s.Validate(); err != nil {
		return err
	}
	if !filepath.IsAbs(directory) {
		return errors.New("desktop settings require an absolute directory")
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	path := filepath.Join(directory, "desktop-v1.json")
	if info, err := os.Lstat(path); err == nil && !info.Mode().IsRegular() {
		return errors.New("desktop settings must be a regular file")
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	file, err := os.CreateTemp(directory, ".desktop-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	writeErr := json.NewEncoder(file).Encode(s)
	syncErr := file.Sync()
	closeErr := file.Close()
	if writeErr != nil {
		return writeErr
	}
	if syncErr != nil {
		return syncErr
	}
	if closeErr != nil {
		return closeErr
	}
	return replaceSettings(file.Name(), path)
}

type Network struct{ Interface, Address string }

func (n Network) Label() string { return n.Interface + " — " + n.Address }

func Networks() ([]Network, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, err
	}
	var result []Network
	for _, adapter := range interfaces {
		if adapter.Flags&net.FlagUp == 0 || adapter.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, err := adapter.Addrs()
		if err != nil {
			continue
		}
		for _, address := range addresses {
			ip, _, err := net.ParseCIDR(address.String())
			if err == nil && ip.To4() != nil && ip.IsPrivate() {
				result = append(result, Network{adapter.Name, ip.String()})
			}
		}
	}
	return result, nil
}

// ResolveNetwork follows DHCP changes on the explicitly selected adapter only.
// A missing adapter or ambiguous replacement never selects a VPN/VM interface.
func ResolveNetwork(s Settings, networks []Network) (Network, error) {
	var matches []Network
	for _, n := range networks {
		if n.Interface != s.Interface || n.Interface == "" {
			continue
		}
		if n.Address == s.AddressHint {
			return n, nil
		}
		matches = append(matches, n)
	}
	if len(matches) == 1 {
		return matches[0], nil
	}
	if len(matches) > 1 {
		return Network{}, errors.New("the selected adapter has several addresses; refresh and choose its LAN address")
	}
	return Network{}, errors.New("the selected network adapter is unavailable; refresh and choose your LAN adapter")
}

type AudioDevice struct {
	ID, Name string
	Default  bool
}

func ValidateDevices(s Settings, devices []AudioDevice) error {
	for _, selection := range []struct{ id, name string }{{s.CaptureDevice, "desktop audio output"}, {s.MicrophoneDevice, "microphone return destination"}} {
		if selection.id == "" {
			continue
		}
		found := false
		for _, d := range devices {
			if d.ID == selection.id {
				found = true
				break
			}
		}
		if !found {
			return fmt.Errorf("the selected %s is unavailable; refresh and explicitly select a replacement", selection.name)
		}
	}
	capture := s.CaptureDevice
	if capture == "" {
		for _, d := range devices {
			if d.Default {
				capture = d.ID
				break
			}
		}
	}
	if s.MicrophoneDevice != "" && capture == s.MicrophoneDevice {
		return errors.New("desktop capture and microphone return must use different endpoints to avoid a feedback loop")
	}
	return nil
}
