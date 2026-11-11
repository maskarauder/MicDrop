//go:build !windows

package desktop

import "errors"

func Run(Backend, string, bool) error { return errors.New("the desktop app requires Windows 11 x64") }

func ShowError(error) {}
