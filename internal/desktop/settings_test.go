package desktop

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
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

func TestDirectoryUsesPersistentStorageRoot(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, ".config"))
	t.Setenv("XDG_CACHE_HOME", filepath.Join(home, ".cache"))
	t.Setenv("LocalAppData", filepath.Join(home, "AppData", "Local"))
	t.Setenv("AppData", filepath.Join(home, "AppData", "Roaming"))
	_ = os.MkdirAll(filepath.Join(home, "Library", "Application Support"), 0o700)
	_ = os.MkdirAll(filepath.Join(home, "Library", "Caches"), 0o700)

	winRoot, err := userDataRootForOS("windows")
	if wantCache, cacheErr := os.UserCacheDir(); cacheErr == nil && (err != nil || winRoot != wantCache) {
		t.Fatalf("windows root = %q (%v), want %q", winRoot, err, wantCache)
	}
	unixRoot, err := userDataRootForOS("linux")
	if wantConfig, cfgErr := os.UserConfigDir(); cfgErr == nil && (err != nil || unixRoot != wantConfig) {
		t.Fatalf("unix root = %q (%v), want %q", unixRoot, err, wantConfig)
	}

	if runtime.GOOS == "windows" {
		return
	}
	cacheRoot, err := os.UserCacheDir()
	if err != nil {
		t.Fatal(err)
	}
	dir, err := Directory()
	if err != nil {
		t.Fatal(err)
	}
	if strings.HasPrefix(dir, filepath.Clean(cacheRoot)+string(filepath.Separator)) || dir == filepath.Clean(cacheRoot) {
		t.Fatalf("Directory() resolved inside cache dir: %q (cache=%q)", dir, cacheRoot)
	}
	saved := Defaults()
	saved.Interface = "en0"
	saved.AddressHint = "192.168.1.42"
	if err := SaveSettings(dir, saved); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(cacheRoot, "MicDrop"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(cacheRoot); err != nil {
		t.Fatal(err)
	}
	loaded, err := LoadSettings(dir)
	if err != nil || loaded != saved {
		t.Fatalf("cache cleanup lost desktop settings: got=%+v err=%v", loaded, err)
	}
}
