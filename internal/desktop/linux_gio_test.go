// SPDX-License-Identifier: MPL-2.0
//go:build linux

package desktop

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestLinuxDesktopEntriesLaunchViaGIO(t *testing.T) {
	gioBin, err := exec.LookPath("gio")
	if err != nil {
		t.Skip("gio binary not installed; skipping GIO .desktop launch check")
	}
	pythonBin, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 binary not installed; skipping GIO .desktop launch check")
	}

	cases := []struct {
		subDir  string
		exeName string
	}{
		{
			subDir:  `My Apps $HOME $1 "quoted" 'single' \ ` + "`backtick`",
			exeName: "micdrop-host",
		},
		{
			subDir:  `My Apps $1 "test" \ 100% %f ` + "`bin`",
			exeName: "micdrop-host",
		},
		{
			subDir:  `dir=1 $HOME $1 "quoted" 'single' \ 100% %f ` + "`bin`",
			exeName: "micdrop=host%1",
		},
	}

	for idx, tc := range cases {
		t.Run(fmt.Sprintf("case_%d", idx), func(t *testing.T) {
			root := t.TempDir()
			binDir := filepath.Join(root, tc.subDir)
			if err := os.MkdirAll(binDir, 0700); err != nil {
				t.Fatalf("mkdir special dir: %v", err)
			}
			exePath := filepath.Join(binDir, tc.exeName)
			outFile := filepath.Join(root, "argv.txt")

			// Use an executable Python script so argv[0] and all arguments are captured
			// verbatim without shell word-splitting or variable interpolation.
			script := fmt.Sprintf("#!%s\nimport pathlib, sys\npathlib.Path(%q).write_bytes(b'\\0'.join(a.encode('utf-8') for a in sys.argv))\n", pythonBin, outFile)
			if err := os.WriteFile(exePath, []byte(script), 0700); err != nil {
				t.Fatalf("write stub executable: %v", err)
			}

			verifyLaunch := func(desktopFile string, wantArgs []string) {
				t.Helper()
				_ = os.Remove(outFile)
				cmd := exec.Command(gioBin, "launch", desktopFile)
				// Isolate from D-Bus activation / startup-notification daemons.
				cmd.Env = append(os.Environ(), "DISPLAY=", "WAYLAND_DISPLAY=", "DBUS_SESSION_BUS_ADDRESS=")
				out, err := cmd.CombinedOutput()
				if err != nil {
					t.Fatalf("gio launch %s failed: %v\noutput: %s", desktopFile, err, string(out))
				}

				var raw []byte
				deadline := time.Now().Add(5 * time.Second)
				for {
					raw, err = os.ReadFile(outFile)
					if err == nil && len(raw) > 0 {
						break
					}
					if time.Now().After(deadline) {
						t.Fatalf("launched process did not write %s (gio output: %s)", outFile, string(out))
					}
					time.Sleep(20 * time.Millisecond)
				}
				got := strings.Split(string(raw), "\x00")
				want := append([]string{exePath}, wantArgs...)
				if !reflect.DeepEqual(got, want) {
					t.Fatalf("gio launch argv = %#v, want %#v", got, want)
				}
			}

			dataDir := filepath.Join(root, "xdg-data")
			launcherPath, err := setLauncherAt(dataDir, exePath, true)
			if err != nil {
				t.Fatalf("setLauncherAt failed: %v", err)
			}
			verifyLaunch(launcherPath, []string{"desktop"})

			configDir := filepath.Join(root, "xdg-config")
			if err := setAutostartAt(configDir, exePath, true); err != nil {
				t.Fatalf("setAutostartAt failed: %v", err)
			}
			autoPath, err := autostartPath(configDir)
			if err != nil {
				t.Fatalf("autostartPath failed: %v", err)
			}
			verifyLaunch(autoPath, []string{"desktop", "--background"})
		})
	}
}
