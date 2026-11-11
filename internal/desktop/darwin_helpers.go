// SPDX-License-Identifier: MPL-2.0

package desktop

import (
	"bytes"
	"encoding/xml"
	"errors"
	"os"
	"path/filepath"
	"unicode/utf8"
)

const launchAgentLabel = "com.maskarauder.micdrop.host"

func launchAgentPlist(exePath string) ([]byte, error) {
	if !filepath.IsAbs(exePath) {
		return nil, errors.New("startup requires an absolute application path")
	}
	if len(exePath) > 1024 || !utf8.ValidString(exePath) {
		return nil, errors.New("the app path is invalid or too long for macOS login startup")
	}
	for _, r := range exePath {
		if r < 0x20 || r == 0x7f {
			return nil, errors.New("the app path contains unsupported control characters")
		}
	}
	var escaped bytes.Buffer
	if err := xml.EscapeText(&escaped, []byte(exePath)); err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	buf.WriteString(`<?xml version="1.0" encoding="UTF-8"?>` + "\n")
	buf.WriteString(`<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">` + "\n")
	buf.WriteString(`<plist version="1.0">` + "\n")
	buf.WriteString("<dict>\n")
	buf.WriteString("\t<key>Label</key>\n")
	buf.WriteString("\t<string>" + launchAgentLabel + "</string>\n")
	buf.WriteString("\t<key>LimitLoadToSessionType</key>\n")
	buf.WriteString("\t<string>Aqua</string>\n")
	buf.WriteString("\t<key>ProcessType</key>\n")
	buf.WriteString("\t<string>Interactive</string>\n")
	buf.WriteString("\t<key>ProgramArguments</key>\n")
	buf.WriteString("\t<array>\n")
	buf.WriteString("\t\t<string>" + escaped.String() + "</string>\n")
	buf.WriteString("\t\t<string>desktop</string>\n")
	buf.WriteString("\t\t<string>--background</string>\n")
	buf.WriteString("\t</array>\n")
	buf.WriteString("\t<key>RunAtLoad</key>\n")
	buf.WriteString("\t<true/>\n")
	buf.WriteString("</dict>\n")
	buf.WriteString("</plist>\n")
	return buf.Bytes(), nil
}

func launchAgentPath(agentsDir string) (string, error) {
	if !filepath.IsAbs(agentsDir) {
		return "", errors.New("LaunchAgents directory must be an absolute path")
	}
	if info, err := os.Lstat(agentsDir); err == nil && info.Mode()&os.ModeSymlink != 0 {
		return "", errors.New("LaunchAgents directory must not be a symbolic link")
	}
	return filepath.Join(agentsDir, launchAgentLabel+".plist"), nil
}

func launchAgentEnabledAt(agentsDir, exePath string) (bool, error) {
	expected, err := launchAgentPlist(exePath)
	if err != nil {
		return false, err
	}
	path, err := launchAgentPath(agentsDir)
	if err != nil {
		return false, err
	}
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !info.Mode().IsRegular() || info.Size() > 16*1024 {
		return false, errors.New("invalid LaunchAgent configuration file")
	}
	actual, err := os.ReadFile(path)
	if err != nil {
		return false, err
	}
	return bytes.Equal(actual, expected), nil
}

func setLaunchAgentAt(agentsDir, exePath string, yes bool) error {
	path, err := launchAgentPath(agentsDir)
	if err != nil {
		return err
	}
	if info, err := os.Lstat(path); err == nil && !info.Mode().IsRegular() {
		return errors.New("LaunchAgent configuration must be a regular file")
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if !yes {
		err := os.Remove(path)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	expected, err := launchAgentPlist(exePath)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(agentsDir, 0700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(agentsDir, ".micdrop-agent-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	_ = tmp.Chmod(0600)
	writeErr := error(nil)
	if _, err := tmp.Write(expected); err != nil {
		writeErr = err
	}
	syncErr := tmp.Sync()
	closeErr := tmp.Close()
	if writeErr != nil {
		return writeErr
	}
	if syncErr != nil {
		return syncErr
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(tmp.Name(), path)
}

// renderQRBitmapRGBA renders a square RGBA8 pixel buffer with crisp integer-scaled
// modules and a white quiet zone so AppKit displays sharp QR codes at Retina DPI.
func renderQRBitmapRGBA(qr [][]bool, targetPx int) ([]byte, int) {
	modules := len(qr)
	if modules == 0 || targetPx < modules+4 {
		return nil, 0
	}
	for _, row := range qr {
		if len(row) != modules {
			return nil, 0
		}
	}
	pad := min(targetPx/12, 24)
	scale := (targetPx - 2*pad) / modules
	if scale < 1 {
		pad = 0
		scale = targetPx / modules
	}
	if scale < 1 {
		return nil, 0
	}
	size := targetPx
	pixels := make([]byte, size*size*4)
	for i := 0; i < len(pixels); i += 4 {
		pixels[i] = 255
		pixels[i+1] = 255
		pixels[i+2] = 255
		pixels[i+3] = 255
	}
	grid := modules * scale
	offset := (size - grid) / 2
	for r := 0; r < modules; r++ {
		for c := 0; c < modules; c++ {
			if !qr[r][c] {
				continue
			}
			y0 := offset + r*scale
			x0 := offset + c*scale
			for dy := 0; dy < scale; dy++ {
				rowStart := ((y0 + dy) * size * 4) + x0*4
				for dx := 0; dx < scale; dx++ {
					idx := rowStart + dx*4
					pixels[idx] = 0
					pixels[idx+1] = 0
					pixels[idx+2] = 0
					pixels[idx+3] = 255
				}
			}
		}
	}
	return pixels, size
}
