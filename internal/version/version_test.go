package version

import "testing"

func TestReleaseIdentityRejectsUnusableVersions(t *testing.T) {
	for _, input := range []string{
		"version=01.2.3\nandroid_version_code=2",
		"version=65536.2.3\nandroid_version_code=2",
		"version=1.2.3-beta.0\nandroid_version_code=2",
		"version=1.2.3\nandroid_version_code=0",
		"version=1.2.3\nandroid_version_code=2100000001",
		"version=1.2.3\nandroid_version_code=02",
		"version=1.2.3\nversion=1.2.4\nandroid_version_code=2",
	} {
		if _, err := parse(input); err == nil {
			t.Fatalf("accepted invalid metadata %q", input)
		}
	}
	for _, name := range []string{"0.1.0-beta.1", "1.0.0", "1.2.3-rc.2"} {
		if _, err := parse("version=" + name + "\nandroid_version_code=2\n"); err != nil {
			t.Fatal(err)
		}
	}
}
