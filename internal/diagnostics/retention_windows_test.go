package diagnostics

import (
	"context"
	"os"
	"testing"
	"time"
)

func TestRetentionDoesNotRemoveLogHeldByAnotherWriter(t *testing.T) {
	dir := t.TempDir()
	old, path, err := CreateInDirectory(dir, DesktopCapture, time.Now().Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	old.Close("test")
	current, _, err := CreateInDirectory(dir, DesktopCapture, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	current.Close("test")
	other, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	if err := pruneLogs(context.Background(), dir, 1); err == nil {
		t.Fatal("expected a bounded deletion failure for the open external file")
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal("removed open external file", err)
	}
	other.Close()
	if err := pruneLogs(context.Background(), dir, 1); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("did not retry after file released", err)
	}
}
