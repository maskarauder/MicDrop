package session

import (
	"net/http"
	"strconv"
	"time"
)

const recoveryWindowHeader = "X-MicDrop-Recovery-Window-Ms"
const setupWindowHeader = "X-MicDrop-Setup-Window-Ms"

type connectionTimeouts struct {
	recovery, setup time.Duration
}

// Optional authenticated offer headers preserve old clients and hosts. Validate
// before allocating capture resources; never accept changes on status/retries.
func readConnectionTimeouts(r *http.Request, version int) (connectionTimeouts, bool) {
	result := connectionTimeouts{30 * time.Second, 45 * time.Second}
	for _, field := range []struct {
		name     string
		min, max int
		target   *time.Duration
	}{{recoveryWindowHeader, 5000, 300000, &result.recovery}, {setupWindowHeader, 10000, 120000, &result.setup}} {
		values := r.Header.Values(field.name)
		if len(values) == 0 {
			continue
		}
		if version != 3 || len(values) != 1 || len(values[0]) > 6 {
			return result, false
		}
		for _, c := range values[0] {
			if c < '0' || c > '9' {
				return result, false
			}
		}
		value, err := strconv.Atoi(values[0])
		if err != nil || value < field.min || value > field.max {
			return result, false
		}
		*field.target = time.Duration(value) * time.Millisecond
	}
	return result, true
}

func (s *Server) setupLimit() time.Duration {
	if s.timeouts.setup != 0 {
		return s.timeouts.setup
	}
	return 45 * time.Second
}
func (s *Server) recoveryLimit() time.Duration {
	limit := 30 * time.Second
	if s.timeouts.recovery != 0 {
		limit = s.timeouts.recovery
	}
	if s.recoveryVersion() == 0 && limit > 10*time.Second {
		limit = 10 * time.Second
	}
	return limit
}
