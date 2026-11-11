package diagnostics

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"sync"
	"time"
)

var sessionLogName = regexp.MustCompile(`^micdrop-([0-9]{8}T[0-9]{6}Z)-[0-9]+\.jsonl$`)
var openLogs = struct {
	sync.Mutex
	paths map[string]bool
}{paths: make(map[string]bool)}

func trackLog(path string, active bool) {
	openLogs.Lock()
	defer openLogs.Unlock()
	if active {
		openLogs.paths[path] = true
	} else {
		delete(openLogs.paths, path)
	}
}

func logIsOpen(path string) bool {
	openLogs.Lock()
	defer openLogs.Unlock()
	return openLogs.paths[path]
}

// Retention has one worker and coalesces requests. Directory scans/deletes never
// run on the audio thread or inside a session/control callback.
type Retention struct{ requests chan struct{} }

func NewRetention(ctx context.Context, directory string, keep int, warn func(error)) *Retention {
	if keep <= 0 {
		return nil
	}
	r := &Retention{requests: make(chan struct{}, 1)}
	go func() {
		warned := false
		for {
			select {
			case <-ctx.Done():
				return
			case <-r.requests:
				if err := pruneLogs(ctx, directory, keep); err != nil && ctx.Err() == nil && !errors.Is(err, context.Canceled) && !warned {
					warned = true
					if warn != nil {
						warn(err)
					}
				}
			}
		}
	}()
	r.Request()
	return r
}

func (r *Retention) Request() {
	if r != nil {
		select {
		case r.requests <- struct{}{}:
		default:
		}
	}
}

func isSessionLog(path string) bool {
	file, err := os.Open(path)
	if err != nil {
		return false
	}
	defer file.Close()
	line, err := bufio.NewReader(io.LimitReader(file, 16384)).ReadBytes('\n')
	if err != nil {
		return false
	}
	var header struct {
		Type    string `json:"type"`
		Details struct {
			Schema int `json:"schema_version"`
		} `json:"details"`
	}
	return json.Unmarshal(line, &header) == nil && header.Type == "session_start" && header.Details.Schema == 1
}

func pruneLogs(ctx context.Context, directory string, keep int) error {
	if keep <= 0 {
		return nil
	}
	directory, err := filepath.Abs(directory)
	if err != nil {
		return err
	}
	entries, err := os.ReadDir(directory)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	type candidate struct {
		path string
		info os.FileInfo
		date time.Time
	}
	var logs []candidate
	for _, entry := range entries {
		if err := ctx.Err(); err != nil {
			return err
		}
		parts := sessionLogName.FindStringSubmatch(entry.Name())
		if parts == nil || !entry.Type().IsRegular() {
			continue
		}
		date, err := time.Parse("20060102T150405Z", parts[1])
		if err != nil {
			continue
		}
		path := filepath.Join(directory, entry.Name())
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() || (!logIsOpen(path) && !isSessionLog(path)) {
			continue
		}
		logs = append(logs, candidate{path, info, date})
	}
	sort.Slice(logs, func(i, j int) bool {
		if !logs[i].date.Equal(logs[j].date) {
			return logs[i].date.After(logs[j].date)
		}
		if !logs[i].info.ModTime().Equal(logs[j].info.ModTime()) {
			return logs[i].info.ModTime().After(logs[j].info.ModTime())
		}
		return logs[i].path > logs[j].path
	})
	var failure error
	for i := keep; i < len(logs); i++ {
		if err := ctx.Err(); err != nil {
			return err
		}
		file := logs[i]
		if logIsOpen(file.path) {
			continue // Active sessions may temporarily exceed the limit.
		}
		info, err := os.Lstat(file.path)
		if err != nil || !info.Mode().IsRegular() || !os.SameFile(file.info, info) {
			continue
		}
		if err := os.Remove(file.path); err != nil && !errors.Is(err, os.ErrNotExist) {
			failure = err // On Windows, an open log in another host is protected too.
		}
	}
	return failure
}
