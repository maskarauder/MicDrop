package main

import (
	"bytes"
	"encoding/json"
	"io"
	"runtime"
	"testing"
)

func TestIdentityCommandsValidateArguments(t *testing.T) {
	for _, args := range [][]string{{"identity"}, {"identity", "export"}, {"identity", "init", "extra"}, {"identity", "status", "--unknown"}} {
		if code := run(args, io.Discard, io.Discard); code != 2 {
			t.Fatalf("%v returned %d", args, code)
		}
	}
	supported := runtime.GOOS == "windows" || runtime.GOOS == "linux" || runtime.GOOS == "darwin"
	if !supported && run([]string{"identity", "init", "--state-dir", t.TempDir()}, io.Discard, io.Discard) != 1 {
		t.Fatal("unsupported platform initialized identity")
	}
}

func TestWindowsIdentityCommandsExposeOnlyPublicStatus(t *testing.T) {
	if runtime.GOOS != "windows" && runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("requires protected host identity storage")
	}
	directory := t.TempDir()
	var output, stderr bytes.Buffer
	args := func(action string) []string { return []string{"identity", action, "--state-dir", directory} }
	if run(args("status"), &output, &stderr) != 1 || output.Len() != 0 {
		t.Fatal("status created missing identity")
	}
	var fingerprint string
	for index, action := range []string{"init", "status", "init"} {
		output.Reset()
		stderr.Reset()
		if run(args(action), &output, &stderr) != 0 {
			t.Fatal(stderr.String())
		}
		var report struct {
			Fingerprint string `json:"public_key_sha256"`
			Created     bool   `json:"created"`
			Pairing     bool   `json:"pairing_available"`
		}
		if json.Unmarshal(output.Bytes(), &report) != nil || len(report.Fingerprint) != 64 || report.Created != (index == 0) || !report.Pairing {
			t.Fatal("invalid public status", output.String())
		}
		if fingerprint == "" {
			fingerprint = report.Fingerprint
		}
		if fingerprint != report.Fingerprint || bytes.Contains(output.Bytes(), []byte("private_key")) {
			t.Fatal("identity changed or key exposed")
		}
	}
}
