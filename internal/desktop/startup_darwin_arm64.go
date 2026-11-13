// SPDX-License-Identifier: MPL-2.0
//go:build darwin && arm64

package desktop

import (
	"errors"
	"os"
	"path/filepath"
)

func darwinStartupPaths() (string, string, error) {
	home, err := os.UserHomeDir()
	if err != nil || !filepath.IsAbs(home) {
		return "", "", errors.New("macOS user home directory is unavailable")
	}
	exe, err := os.Executable()
	if err != nil {
		return "", "", err
	}
	if resolved, linkErr := filepath.EvalSymlinks(exe); linkErr == nil && filepath.IsAbs(resolved) {
		exe = resolved
	}
	exe, err = filepath.Abs(exe)
	if err != nil {
		return "", "", err
	}
	return filepath.Join(home, "Library", "LaunchAgents"), exe, nil
}

func startupEnabled() (bool, error) {
	agentsDir, exe, err := darwinStartupPaths()
	if err != nil {
		return false, err
	}
	return launchAgentEnabledAt(agentsDir, exe)
}

func setStartup(yes bool) error {
	agentsDir, exe, err := darwinStartupPaths()
	if err != nil {
		return err
	}
	return setLaunchAgentAt(agentsDir, exe, yes)
}
