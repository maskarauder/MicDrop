// SPDX-License-Identifier: MPL-2.0

package desktop

import (
	"bytes"
	"errors"
	"os"
	"path"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

const linuxDesktopEntryFilename = "micdrop.desktop"

func quoteDesktopExecArg(arg string) (string, error) {
	if arg == "" || !utf8.ValidString(arg) {
		return "", errors.New("desktop entry argument is invalid")
	}
	for _, r := range arg {
		if r < 0x20 || r == 0x7f {
			return "", errors.New("desktop entry argument contains unsupported control characters")
		}
	}
	var out strings.Builder
	out.WriteByte('"')
	for _, r := range arg {
		switch r {
		case '"', '`', '$', '\\':
			out.WriteByte('\\')
			out.WriteRune(r)
		case '%':
			out.WriteString("%%")
		default:
			out.WriteRune(r)
		}
	}
	out.WriteByte('"')
	return out.String(), nil
}

func validateLinuxExecutablePath(exePath string) (string, error) {
	if !path.IsAbs(exePath) || exePath == "/" || path.Clean(exePath) != exePath {
		return "", errors.New("startup requires an absolute application path")
	}
	if len(exePath) > 1024 || !utf8.ValidString(exePath) {
		return "", errors.New("the app path is invalid or too long for Linux desktop integration")
	}
	return quoteDesktopExecArg(exePath)
}

func desktopEntryAutostart(exePath string) ([]byte, error) {
	quotedExe, err := validateLinuxExecutablePath(exePath)
	if err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	buf.WriteString("[Desktop Entry]\n")
	buf.WriteString("Type=Application\n")
	buf.WriteString("Version=1.0\n")
	buf.WriteString("Name=MicDrop\n")
	buf.WriteString("Comment=Encrypted phone-to-desktop audio and microphone host\n")
	buf.WriteString("Icon=audio-input-microphone\n")
	buf.WriteString("Exec=" + quotedExe + " desktop --background\n")
	buf.WriteString("Terminal=false\n")
	buf.WriteString("Categories=AudioVideo;Audio;Network;\n")
	buf.WriteString("StartupNotify=false\n")
	buf.WriteString("StartupWMClass=micdrop\n")
	buf.WriteString("X-GNOME-Autostart-enabled=true\n")
	return buf.Bytes(), nil
}

func desktopEntryLauncher(exePath string) ([]byte, error) {
	quotedExe, err := validateLinuxExecutablePath(exePath)
	if err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	buf.WriteString("[Desktop Entry]\n")
	buf.WriteString("Type=Application\n")
	buf.WriteString("Version=1.0\n")
	buf.WriteString("Name=MicDrop\n")
	buf.WriteString("Comment=Encrypted phone-to-desktop audio and microphone host\n")
	buf.WriteString("Icon=audio-input-microphone\n")
	buf.WriteString("Exec=" + quotedExe + " desktop\n")
	buf.WriteString("Terminal=false\n")
	buf.WriteString("Categories=AudioVideo;Audio;Network;\n")
	buf.WriteString("StartupNotify=true\n")
	buf.WriteString("StartupWMClass=micdrop\n")
	return buf.Bytes(), nil
}

func checkedDesktopDir(baseDir, subDir, label string) (string, string, error) {
	if !filepath.IsAbs(baseDir) {
		return "", "", errors.New(label + " base directory must be an absolute path")
	}
	if info, err := os.Lstat(baseDir); err == nil && info.Mode()&os.ModeSymlink != 0 {
		return "", "", errors.New(label + " base directory must not be a symbolic link")
	}
	dir := filepath.Join(baseDir, subDir)
	if info, err := os.Lstat(dir); err == nil && info.Mode()&os.ModeSymlink != 0 {
		return "", "", errors.New(label + " directory must not be a symbolic link")
	}
	return dir, filepath.Join(dir, linuxDesktopEntryFilename), nil
}

func autostartPath(configDir string) (string, error) {
	_, entryPath, err := checkedDesktopDir(configDir, "autostart", "XDG autostart")
	return entryPath, err
}

func autostartEnabledAt(configDir, exePath string) (bool, error) {
	expected, err := desktopEntryAutostart(exePath)
	if err != nil {
		return false, err
	}
	entryPath, err := autostartPath(configDir)
	if err != nil {
		return false, err
	}
	info, err := os.Lstat(entryPath)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !info.Mode().IsRegular() || info.Size() > 16*1024 {
		return false, errors.New("invalid XDG autostart configuration file")
	}
	actual, err := os.ReadFile(entryPath)
	if err != nil {
		return false, err
	}
	return bytes.Equal(actual, expected), nil
}

func writeDesktopEntryAt(dir, entryPath string, content []byte, yes bool, label string) error {
	if info, err := os.Lstat(entryPath); err == nil && !info.Mode().IsRegular() {
		return errors.New(label + " configuration must be a regular file")
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if !yes {
		err := os.Remove(entryPath)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".micdrop-desktop-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	_ = tmp.Chmod(0600)
	writeErr := error(nil)
	if _, err := tmp.Write(content); err != nil {
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
	return os.Rename(tmp.Name(), entryPath)
}

func setAutostartAt(configDir, exePath string, yes bool) error {
	dir, entryPath, err := checkedDesktopDir(configDir, "autostart", "XDG autostart")
	if err != nil {
		return err
	}
	var content []byte
	if yes {
		content, err = desktopEntryAutostart(exePath)
		if err != nil {
			return err
		}
	}
	return writeDesktopEntryAt(dir, entryPath, content, yes, "XDG autostart")
}

func setLauncherAt(dataDir, exePath string, yes bool) (string, error) {
	dir, entryPath, err := checkedDesktopDir(dataDir, "applications", "XDG applications")
	if err != nil {
		return "", err
	}
	var content []byte
	if yes {
		content, err = desktopEntryLauncher(exePath)
		if err != nil {
			return "", err
		}
	}
	if err := writeDesktopEntryAt(dir, entryPath, content, yes, "XDG desktop launcher"); err != nil {
		return "", err
	}
	return entryPath, nil
}
