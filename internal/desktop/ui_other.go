// SPDX-License-Identifier: MPL-2.0
//go:build !windows && !(darwin && arm64)

package desktop

import "errors"

func Run(Backend, string, bool) error {
	return errors.New("the desktop app requires Windows 11 x64 or macOS 14.2+ arm64")
}

func ShowError(error) {}
