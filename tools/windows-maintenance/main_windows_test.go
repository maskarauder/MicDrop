package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestScopeAndIdentityDoNotMatchUnrelatedExecutables(t *testing.T) {
	for _, test := range []struct {
		path, scope string
		want        bool
	}{
		{`C:\fixture\portable\MicDrop.exe`, `c:\fixture`, true},
		{`C:\fixture-other\MicDrop.exe`, `C:\fixture`, false},
		{`C:\fixture\..\other\MicDrop.exe`, `C:\fixture`, false},
		{`D:\fixture\MicDrop.exe`, `C:\fixture`, false},
	} {
		if got := withinScope(test.path, test.scope); got != test.want {
			t.Fatalf("scope %q path %q: %v", test.scope, test.path, got)
		}
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "MicDrop.exe")
	if err := os.WriteFile(path, []byte("a matching filename is not proof of MicDrop"), 0600); err != nil {
		t.Fatal(err)
	}
	if trustedHost(path, dir) {
		t.Fatal("trusted an unrelated executable by filename alone")
	}
}
