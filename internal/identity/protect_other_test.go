//go:build !windows

package identity

import (
	"errors"
	"testing"
)

func TestUnsupportedPlatformsHaveNoProtectionFallback(t *testing.T) {
	if _, err := NewStore(t.TempDir()); !errors.Is(err, ErrUnsupported) {
		t.Fatal(err)
	}
	if _, err := DefaultDirectory(); !errors.Is(err, ErrUnsupported) {
		t.Fatal(err)
	}
}
