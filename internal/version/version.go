// Package version shares release identity with Android, the installer and CI.
package version

import (
	_ "embed"
	"fmt"
	"regexp"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
)

//go:embed version.properties
var properties string

type Info struct {
	Version            string `json:"version"`
	AndroidVersionCode int    `json:"android_version_code"`
}

var current = func() Info {
	info, err := parse(properties)
	if err != nil {
		panic(err)
	}
	return info
}()

func Current() Info { return current }

func parse(text string) (Info, error) {
	values := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(text), "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), "=")
		if !ok || values[key] != "" || (key != "version" && key != "android_version_code") {
			return Info{}, fmt.Errorf("invalid version metadata")
		}
		values[key] = value
	}
	pattern := regexp.MustCompile(`^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(?:alpha|beta|rc)\.[1-9][0-9]*)?$`)
	parts := pattern.FindStringSubmatch(values["version"])
	if parts == nil || len(values["version"]) > 64 {
		return Info{}, fmt.Errorf("invalid release version")
	}
	for _, part := range parts[1:4] {
		if _, err := strconv.ParseUint(part, 10, 16); err != nil {
			return Info{}, fmt.Errorf("version exceeds Windows numeric version limits")
		}
	}
	code, err := strconv.Atoi(values["android_version_code"])
	if err != nil || code < 1 || code > 2100000000 || strconv.Itoa(code) != values["android_version_code"] {
		return Info{}, fmt.Errorf("invalid Android version code")
	}
	return Info{Version: values["version"], AndroidVersionCode: code}, nil
}

type BuildInfo struct {
	Info
	Revision string `json:"revision"`
	Modified bool   `json:"modified"`
	Platform string `json:"platform"`
}

func Build() BuildInfo {
	result := BuildInfo{Info: Current(), Revision: "unavailable", Platform: runtime.GOOS + "/" + runtime.GOARCH}
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, setting := range info.Settings {
			switch setting.Key {
			case "vcs.revision":
				result.Revision = setting.Value
			case "vcs.modified":
				result.Modified = setting.Value == "true"
			}
		}
	}
	return result
}
