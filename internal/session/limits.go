package session

import (
	"net/http"
	"sync"
	"time"
)

// Owned by the listener, so a new stream cannot reset the request budget.
type requestLimits struct {
	gate     chan struct{}
	mu       sync.Mutex
	window   time.Time
	requests int
}

func newRequestLimits() *requestLimits { return &requestLimits{gate: make(chan struct{}, 4)} }
func (l *requestLimits) leave()        { <-l.gate }
func checkRequest(w http.ResponseWriter, r *http.Request) bool {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if r.TLS == nil {
		http.Error(w, "TLS required", 426)
		return false
	}
	if r.URL.RawQuery != "" || r.Header.Get("Origin") != "" {
		http.Error(w, "Unsupported request", 400)
		return false
	}
	return true
}

func (l *requestLimits) acquire(w http.ResponseWriter, now time.Time) bool {
	select {
	case l.gate <- struct{}{}:
	default:
		http.Error(w, "Busy", 503)
		return false
	}
	l.mu.Lock()
	if now.Sub(l.window) >= time.Minute {
		l.window = now
		l.requests = 0
	}
	l.requests++
	limited := l.requests > 120
	l.mu.Unlock()
	if limited {
		l.leave()
		http.Error(w, "Request limit", 429)
		return false
	}
	return true
}

func (l *requestLimits) enter(w http.ResponseWriter, r *http.Request, now time.Time) bool {
	return checkRequest(w, r) && l.acquire(w, now)
}
