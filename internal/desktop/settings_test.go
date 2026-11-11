package desktop

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSettingsSurviveUpgradeWithoutCredentials(t *testing.T) {
	dir := t.TempDir()
	s, err := LoadSettings(dir)
	if err != nil || s != Defaults() {
		t.Fatal(s, err)
	}
	s.Interface = "Ethernet"
	s.AddressHint = "192.168.1.234"
	s.CaptureDevice = "speaker"
	s.MicrophoneDevice = "cable"
	s.Remote = true
	if err = SaveSettings(dir, s); err != nil {
		t.Fatal(err)
	}
	got, err := LoadSettings(dir)
	if err != nil || got != s {
		t.Fatal(got, err)
	}
	s.Notifications = false
	s.SaveLogs = false
	s.LogRetention = 25
	if err = SaveSettings(dir, s); err != nil {
		t.Fatal(err)
	}
	got, err = LoadSettings(dir)
	if err != nil || got != s {
		t.Fatal(got, err)
	}
	for _, content := range []string{`{"version":2}`, `{"version":1,"port":9844,"token":"secret"}`, `{"version":1,"port":9844} {}`, `broken`} {
		path := filepath.Join(dir, "desktop-v1.json")
		if err = os.WriteFile(path, []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err = LoadSettings(dir); err == nil {
			t.Fatalf("accepted invalid/newer settings: %s", content)
		}
		remaining, _ := os.ReadFile(path)
		if string(remaining) != content {
			t.Fatal("invalid settings overwritten")
		}
	}
}
func TestNetworkResolutionFollowsOnlyChosenAdapter(t *testing.T) {
	s := Defaults()
	s.Interface = "Ethernet"
	s.AddressHint = "192.168.1.72"
	candidates := []Network{{"VMware", "192.168.10.1"}, {"Ethernet", "192.168.1.234"}, {"VPN", "10.1.0.2"}}
	n, err := ResolveNetwork(s, candidates)
	if err != nil || n.Address != "192.168.1.234" {
		t.Fatal(n, err)
	}
	if _, err := ResolveNetwork(s, []Network{candidates[0], candidates[2]}); err == nil {
		t.Fatal("silently selected another adapter")
	}
	candidates = append(candidates, Network{"Ethernet", "192.168.1.235"})
	if _, err := ResolveNetwork(s, candidates); err == nil {
		t.Fatal("ambiguous adapter address guessed")
	}
	s.AddressHint = "192.168.1.235"
	n, err = ResolveNetwork(s, candidates)
	if err != nil || n.Address != s.AddressHint {
		t.Fatal(n, err)
	}
}
func TestMissingAudioSelectionNeverFallsBack(t *testing.T) {
	devices := []AudioDevice{{ID: "speaker", Default: true}, {ID: "cable"}}
	s := Defaults()
	s.MicrophoneDevice = "missing"
	if ValidateDevices(s, devices) == nil {
		t.Fatal("missing cable accepted")
	}
	s.MicrophoneDevice = "speaker"
	if ValidateDevices(s, devices) == nil {
		t.Fatal("default capture feedback accepted")
	}
	s.MicrophoneDevice = "cable"
	if err := ValidateDevices(s, devices); err != nil {
		t.Fatal(err)
	}
	s.CaptureDevice = "missing"
	if ValidateDevices(s, devices) == nil {
		t.Fatal("missing explicit output accepted")
	}
	s.CaptureDevice = "cable"
	if ValidateDevices(s, devices) == nil {
		t.Fatal("explicit capture feedback accepted")
	}
}

func TestLegacyLoggingDefaultsAndRetentionValidation(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "desktop-v1.json")
	if err := os.WriteFile(path, []byte(`{"version":1,"port":9844,"notifications":false}`), 0600); err != nil {
		t.Fatal(err)
	}
	settings, err := LoadSettings(dir)
	if err != nil || !settings.SaveLogs || settings.LogRetention != 0 || settings.Notifications {
		t.Fatal(settings, err)
	}
	for _, limit := range []int{-1, 10001} {
		settings.LogRetention = limit
		if settings.Validate() == nil {
			t.Fatalf("accepted invalid retention %d", limit)
		}
	}
}
