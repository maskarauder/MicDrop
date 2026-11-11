//go:build !windows

package desktop

import "os"

func replaceSettings(from, to string) error { return os.Rename(from, to) }
