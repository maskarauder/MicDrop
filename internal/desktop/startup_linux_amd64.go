// SPDX-License-Identifier: MPL-2.0
//go:build linux && amd64

package desktop

import (
	"errors"
	"os"
	"path/filepath"
)

func linuxExecutablePath() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	if resolved, linkErr := filepath.EvalSymlinks(exe); linkErr == nil && filepath.IsAbs(resolved) {
		exe = resolved
	}
	return filepath.Abs(exe)
}

func linuxStartupPaths() (string, string, error) {
	configDir, err := os.UserConfigDir()
	if err != nil || !filepath.IsAbs(configDir) {
		return "", "", errors.New("Linux user configuration directory is unavailable")
	}
	exe, err := linuxExecutablePath()
	if err != nil {
		return "", "", err
	}
	return configDir, exe, nil
}

func linuxDataDir() (string, error) {
	if xdgData := os.Getenv("XDG_DATA_HOME"); xdgData != "" && filepath.IsAbs(xdgData) {
		return filepath.Clean(xdgData), nil
	}
	home, err := os.UserHomeDir()
	if err != nil || !filepath.IsAbs(home) {
		return "", errors.New("Linux user home directory is unavailable")
	}
	return filepath.Join(home, ".local", "share"), nil
}

func startupEnabled() (bool, error) {
	configDir, exe, err := linuxStartupPaths()
	if err != nil {
		return false, err
	}
	return autostartEnabledAt(configDir, exe)
}

func setStartup(yes bool) error {
	configDir, exe, err := linuxStartupPaths()
	if err != nil {
		return err
	}
	return setAutostartAt(configDir, exe, yes)
}

func InstallLauncher() (string, error) {
	dataDir, err := linuxDataDir()
	if err != nil {
		return "", err
	}
	exe, err := linuxExecutablePath()
	if err != nil {
		return "", err
	}
	return setLauncherAt(dataDir, exe, true)
}

func UninstallLauncher() (string, error) {
	dataDir, err := linuxDataDir()
	if err != nil {
		return "", err
	}
	return setLauncherAt(dataDir, "", false)
}
