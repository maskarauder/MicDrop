// SPDX-License-Identifier: MPL-2.0

package desktop

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLinuxDesktopEntryQuotingAndValidation(t *testing.T) {
	for _, invalid := range []string{
		"",
		"/",
		"relative/micdrop-host",
		"/opt/../opt/micdrop-host",
		"/opt/micdrop\nhost",
		"/opt/micdrop\x00host",
		"/opt/" + strings.Repeat("a", 1030),
	} {
		if _, err := desktopEntryAutostart(invalid); err == nil {
			t.Fatalf("accepted invalid executable path %q", invalid)
		}
	}

	specialPath := `/home/alice/My Apps $1 "test" \ 100% ` + "`bin`" + `/micdrop-host`
	data, err := desktopEntryAutostart(specialPath)
	if err != nil {
		t.Fatalf("desktopEntryAutostart failed: %v", err)
	}
	text := string(data)
	wantExec := `Exec="/home/alice/My Apps \$1 \"test\" \\ 100%% \` + "`bin\\`/micdrop-host\" desktop --background\n"
	if !strings.Contains(text, wantExec) {
		t.Fatalf("unexpected Exec line in:\n%s\nwant substring:\n%s", text, wantExec)
	}
	if !strings.Contains(text, "Icon=audio-input-microphone\n") {
		t.Fatalf("missing themed microphone icon in:\n%s", text)
	}

	launcher, err := desktopEntryLauncher("/opt/MicDrop/micdrop-host")
	if err != nil {
		t.Fatalf("desktopEntryLauncher failed: %v", err)
	}
	if !strings.Contains(string(launcher), `Exec="/opt/MicDrop/micdrop-host" desktop`+"\n") {
		t.Fatalf("unexpected launcher entry:\n%s", string(launcher))
	}
}

func TestLinuxAutostartAndLauncherPersistence(t *testing.T) {
	configDir := filepath.Join(t.TempDir(), "config")
	dataDir := filepath.Join(t.TempDir(), "data")
	exePath := "/opt/MicDrop/micdrop-host"

	enabled, err := autostartEnabledAt(configDir, exePath)
	if err != nil || enabled {
		t.Fatalf("initial autostart = (%v, %v), want (false, nil)", enabled, err)
	}

	if err := setAutostartAt(configDir, exePath, true); err != nil {
		t.Fatalf("enable autostart failed: %v", err)
	}
	enabled, err = autostartEnabledAt(configDir, exePath)
	if err != nil || !enabled {
		t.Fatalf("enabled autostart = (%v, %v), want (true, nil)", enabled, err)
	}
	otherEnabled, err := autostartEnabledAt(configDir, "/usr/local/bin/micdrop-host")
	if err != nil || otherEnabled {
		t.Fatalf("mismatched path autostart = (%v, %v), want (false, nil)", otherEnabled, err)
	}

	if err := setAutostartAt(configDir, exePath, false); err != nil {
		t.Fatalf("disable autostart failed: %v", err)
	}
	enabled, err = autostartEnabledAt(configDir, exePath)
	if err != nil || enabled {
		t.Fatalf("disabled autostart = (%v, %v), want (false, nil)", enabled, err)
	}

	launcherFile, err := setLauncherAt(dataDir, exePath, true)
	if err != nil {
		t.Fatalf("install launcher failed: %v", err)
	}
	if _, err := os.Stat(launcherFile); err != nil {
		t.Fatalf("launcher file missing: %v", err)
	}
	if _, err := setLauncherAt(dataDir, "", false); err != nil {
		t.Fatalf("uninstall launcher failed: %v", err)
	}
	if _, err := os.Stat(launcherFile); !os.IsNotExist(err) {
		t.Fatalf("launcher file still exists: %v", err)
	}
}
