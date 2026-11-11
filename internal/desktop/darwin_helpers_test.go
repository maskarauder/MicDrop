// SPDX-License-Identifier: MPL-2.0

package desktop

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	qrcode "github.com/skip2/go-qrcode"
)

func TestLaunchAgentLifecycleAndSafety(t *testing.T) {
	agentsDir := filepath.Join(t.TempDir(), "Library", "LaunchAgents")
	exe := "/Applications/MicDrop & Co.app/Contents/MacOS/MicDrop"

	enabled, err := launchAgentEnabledAt(agentsDir, exe)
	if err != nil || enabled {
		t.Fatalf("expected disabled initially: enabled=%v err=%v", enabled, err)
	}
	if err := setLaunchAgentAt(agentsDir, exe, true); err != nil {
		t.Fatal(err)
	}
	enabled, err = launchAgentEnabledAt(agentsDir, exe)
	if err != nil || !enabled {
		t.Fatalf("expected enabled after set: enabled=%v err=%v", enabled, err)
	}
	raw, err := os.ReadFile(filepath.Join(agentsDir, launchAgentLabel+".plist"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), "MicDrop &amp; Co.app") || !strings.Contains(string(raw), "--background") {
		t.Fatalf("unexpected plist XML:\n%s", string(raw))
	}
	// Moving the app bundle makes the previous LaunchAgent stale until re-saved.
	movedEnabled, err := launchAgentEnabledAt(agentsDir, "/Users/test/Desktop/MicDrop.app/Contents/MacOS/MicDrop")
	if err != nil || movedEnabled {
		t.Fatalf("expected false when executable moved: enabled=%v err=%v", movedEnabled, err)
	}
	if err := setLaunchAgentAt(agentsDir, exe, false); err != nil {
		t.Fatal(err)
	}
	enabled, err = launchAgentEnabledAt(agentsDir, exe)
	if err != nil || enabled {
		t.Fatalf("expected disabled after removal: enabled=%v err=%v", enabled, err)
	}
	// Disabling again is idempotent.
	if err := setLaunchAgentAt(agentsDir, exe, false); err != nil {
		t.Fatal(err)
	}
	// Relative and control-character paths must be rejected.
	for _, bad := range []string{"relative/MicDrop", "/Applications/MicDrop\nEvil", "/Applications/MicDrop\x00"} {
		if _, err := launchAgentPlist(bad); err == nil {
			t.Fatalf("accepted invalid executable path %q", bad)
		}
	}
}

func TestLaunchAgentRejectsSymlinkTarget(t *testing.T) {
	base := t.TempDir()
	agentsDir := filepath.Join(base, "LaunchAgents")
	if err := os.MkdirAll(agentsDir, 0700); err != nil {
		t.Fatal(err)
	}
	secret := filepath.Join(base, "secret.txt")
	if err := os.WriteFile(secret, []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	plistLink := filepath.Join(agentsDir, launchAgentLabel+".plist")
	if err := os.Symlink(secret, plistLink); err != nil {
		t.Skip("symlinks unavailable")
	}
	if err := setLaunchAgentAt(agentsDir, "/Applications/MicDrop.app/Contents/MacOS/MicDrop", true); err == nil {
		t.Fatal("overwrote symlink target")
	}
	if err := setLaunchAgentAt(agentsDir, "/Applications/MicDrop.app/Contents/MacOS/MicDrop", false); err == nil {
		t.Fatal("removed symlink plist")
	}
	got, err := os.ReadFile(secret)
	if err != nil || string(got) != "keep" {
		t.Fatalf("symlink target modified: %q %v", string(got), err)
	}
}

func TestRenderQRBitmapRGBA(t *testing.T) {
	code, err := qrcode.New("micdrop://pair/v1/test-fixture-not-a-credential", qrcode.Low)
	if err != nil {
		t.Fatal(err)
	}
	pixels, size := renderQRBitmapRGBA(code.Bitmap(), 520)
	if size != 520 || len(pixels) != 520*520*4 {
		t.Fatalf("unexpected QR RGBA buffer: size=%d len=%d", size, len(pixels))
	}
	// Top-left border pixel must be opaque white quiet zone.
	if pixels[0] != 255 || pixels[1] != 255 || pixels[2] != 255 || pixels[3] != 255 {
		t.Fatalf("quiet zone is not white: %v", pixels[:4])
	}
	hasBlack := false
	for i := 0; i < len(pixels); i += 4 {
		if pixels[i] == 0 && pixels[i+1] == 0 && pixels[i+2] == 0 && pixels[i+3] == 255 {
			hasBlack = true
			break
		}
	}
	if !hasBlack {
		t.Fatal("rendered QR code has no dark modules")
	}
	if nilPixels, nilSize := renderQRBitmapRGBA(nil, 520); nilPixels != nil || nilSize != 0 {
		t.Fatal("expected nil buffer for empty QR")
	}
}
