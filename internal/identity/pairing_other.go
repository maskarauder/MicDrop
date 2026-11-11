//go:build !windows

package identity

import (
	"io"
	"os"
)

// Production state is Windows-only. Rename is used by the injected-protector
// storage tests on other platforms; there is no production plaintext fallback.
func lockPairing(string) (io.Closer, error) { return nil, ErrUnsupported }
func replacePairing(from, to string) error  { return os.Rename(from, to) }
