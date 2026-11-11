package diagnostics

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestRetentionKeepsNewestConnectionsAndProtectsActiveAndUnrelatedFiles(t *testing.T) {
	dir := t.TempDir()
	var paths []string
	for i := 0; i < 4; i++ {
		log, path, err := CreateInDirectory(dir, DesktopCapture, time.Date(2026, 10, 25, 12, i, 0, 0, time.UTC))
		if err != nil {
			t.Fatal(err)
		}
		if err := log.Close("test"); err != nil {
			t.Fatal(err)
		}
		paths = append(paths, path)
	}
	// A still-running older session is retained even if it temporarily exceeds X.
	active, activePath, err := CreateInDirectory(dir, DuplexCapture, time.Date(2026, 10, 25, 11, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	defer active.Close("test")
	unrelated := filepath.Join(dir, "micdrop-20261025T100000Z-123.jsonl")
	if err := os.WriteFile(unrelated, []byte("unrelated user file\n"), 0600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "micdrop-20261025T090000Z-123.jsonl")
	linkCreated := os.Symlink(paths[3], link) == nil // Requires developer mode on Windows.
	if err := pruneLogs(context.Background(), dir, 2); err != nil {
		t.Fatal(err)
	}
	for i, path := range paths {
		_, err := os.Stat(path)
		if (i < 2 && !os.IsNotExist(err)) || (i >= 2 && err != nil) {
			t.Fatalf("incorrect retention for connection %d: %v", i, err)
		}
	}
	for _, path := range []string{unrelated, activePath} {
		if _, err := os.Stat(path); err != nil {
			t.Fatal("removed protected file", path, err)
		}
	}
	if linkCreated {
		if _, err := os.Lstat(link); err != nil {
			t.Fatal("removed symbolic link", err)
		}
	}
	if err := active.Close("test"); err != nil {
		t.Fatal(err)
	}
	if err := pruneLogs(context.Background(), dir, 2); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(activePath); !os.IsNotExist(err) {
		t.Fatal("closed old session was not pruned", err)
	}
}

func TestRetentionUnlimitedAndCancellationDoNotDelete(t *testing.T) {
	dir := t.TempDir()
	log, path, err := CreateInDirectory(dir, DesktopCapture, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	log.Close("test")
	if err := pruneLogs(context.Background(), dir, 0); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := pruneLogs(ctx, dir, 1); err == nil {
		t.Fatal("ignored cancellation")
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal(err)
	}
	warned := make(chan error, 1)
	workerCtx, workerCancel := context.WithCancel(context.Background())
	r := NewRetention(workerCtx, dir, 1, func(err error) { warned <- err })
	workerCancel()
	r.Request()
	select {
	case err := <-warned:
		t.Fatalf("shutdown cancellation triggered false warning: %v", err)
	case <-time.After(50 * time.Millisecond):
	}
}
