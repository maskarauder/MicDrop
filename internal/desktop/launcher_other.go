// SPDX-License-Identifier: MPL-2.0
//go:build !(linux && amd64)

package desktop

import "errors"

func InstallLauncher() (string, error) {
	return "", errors.New("--install-launcher is only supported on Linux x64")
}

func UninstallLauncher() (string, error) {
	return "", errors.New("--uninstall-launcher is only supported on Linux x64")
}
