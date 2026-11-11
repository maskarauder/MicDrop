package rendezvous

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

const (
	Subprotocol           = "micdrop-tls-v1"
	Ready                 = "micdrop-tls-v1 ready"
	MaxFrameBytes         = 64 * 1024
	MaxBytesPerDirection  = 64 * 1024 * 1024
	MaxConnectionsPerRole = 4
)

type bucket struct {
	available, capacity, perSecond float64
	last                           time.Time
}

func newBucket(capacity, rate float64) bucket {
	return bucket{available: capacity, capacity: capacity, perSecond: rate}
}
func (b *bucket) allow(now time.Time, amount float64) bool {
	if !b.last.IsZero() && now.After(b.last) {
		b.available = min(b.capacity, b.available+now.Sub(b.last).Seconds()*b.perSecond)
	}
	b.last = now
	if b.available < amount {
		return false
	}
	b.available -= amount
	return true
}

type principal struct {
	route         *routeState
	role          int
	requests, ice bucket
}
type routeState struct {
	count   [2]int
	waiting [2][]*endpoint
}
type endpoint struct {
	conn      *websocket.Conn
	ctx       context.Context
	cancel    context.CancelFunc
	ready     chan struct{}
	data      chan relayMessage
	readDone  chan struct{}
	peer      *endpoint // guarded by Server.mu until ready is closed
	principal *principal
}

type relayMessage struct {
	bytes     []byte
	forwarded chan struct{}
}

type Server struct {
	mu                                               sync.Mutex
	config                                           Config
	principals                                       map[[32]byte]*principal
	global                                           bucket
	ctx                                              context.Context
	cancel                                           context.CancelFunc
	closed                                           bool
	workers                                          sync.WaitGroup
	now                                              func() time.Time
	waitTimeout, idleTimeout, writeTimeout, lifetime time.Duration
}

func New(config Config) (*Server, error) {
	if err := config.Validate(); err != nil {
		return nil, err
	}
	config.Routes = append([]Route(nil), config.Routes...)
	config.STUNURLs = append([]string(nil), config.STUNURLs...)
	if config.TURN != nil {
		t := *config.TURN
		t.URLs = append([]string(nil), t.URLs...)
		config.TURN = &t
	}
	ctx, cancel := context.WithCancel(context.Background())
	s := &Server{config: config, principals: map[[32]byte]*principal{}, global: newBucket(120, 60), ctx: ctx, cancel: cancel, now: time.Now,
		waitTimeout: 25 * time.Second, idleTimeout: 30 * time.Second, writeTimeout: 5 * time.Second, lifetime: time.Hour}
	for _, r := range config.Routes {
		state := &routeState{}
		for role, token := range []string{r.HostToken, r.ClientToken} {
			s.principals[sha256.Sum256([]byte(token))] = &principal{route: state, role: role, requests: newBucket(10, 5), ice: newBucket(2, 1.0/30)}
		}
	}
	return s, nil
}

// Close cancels and drains hijacked sockets, which http.Server.Shutdown does not.
func (s *Server) Close() {
	s.mu.Lock()
	s.closed = true
	s.cancel()
	s.mu.Unlock()
	s.workers.Wait()
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if r.TLS == nil || r.TLS.Version < tls.VersionTLS13 {
		http.Error(w, "TLS 1.3 required", http.StatusUpgradeRequired)
		return
	}
	if r.Method != http.MethodGet || r.URL.RawQuery != "" || r.URL.ForceQuery || r.URL.RawPath != "" || (r.URL.Path != "/v1/tunnel" && r.URL.Path != "/v1/ice") {
		http.Error(w, "Unsupported request", http.StatusBadRequest)
		return
	}
	if len(r.Header.Values("Origin")) != 0 || r.ContentLength != 0 || len(r.TransferEncoding) != 0 {
		http.Error(w, "Unsupported request", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		http.Error(w, "Unavailable", http.StatusServiceUnavailable)
		return
	}
	if !s.global.allow(s.now(), 1) {
		s.mu.Unlock()
		http.Error(w, "Try later", http.StatusTooManyRequests)
		return
	}
	headers := r.Header.Values("Authorization")
	var p *principal
	if len(headers) == 1 && len(headers[0]) == 50 && strings.HasPrefix(headers[0], "Bearer ") {
		p = s.principals[sha256.Sum256([]byte(headers[0][7:]))]
	}
	if p == nil {
		s.mu.Unlock()
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}
	if !p.requests.allow(s.now(), 1) {
		s.mu.Unlock()
		http.Error(w, "Try later", http.StatusTooManyRequests)
		return
	}
	// Register every accepted handler before Close may start waiting.
	s.workers.Add(1)
	s.mu.Unlock()
	defer s.workers.Done()
	if r.URL.Path == "/v1/ice" {
		s.ice(w, p)
		return
	}
	if r.Header.Get("Sec-WebSocket-Protocol") != Subprotocol {
		http.Error(w, "Unsupported tunnel protocol", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	if s.closed || p.route.count[p.role] >= MaxConnectionsPerRole {
		s.mu.Unlock()
		http.Error(w, "Tunnel capacity unavailable", http.StatusServiceUnavailable)
		return
	}
	p.route.count[p.role]++
	s.mu.Unlock()
	defer func() { s.mu.Lock(); p.route.count[p.role]--; s.mu.Unlock() }()
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{Subprotocol}, CompressionMode: websocket.CompressionDisabled})
	if err != nil {
		return
	}
	defer c.CloseNow()
	c.SetReadLimit(MaxFrameBytes)
	ctx, cancel := context.WithTimeout(s.ctx, s.lifetime)
	e := &endpoint{conn: c, ctx: ctx, cancel: cancel, ready: make(chan struct{}), data: make(chan relayMessage, 1), readDone: make(chan struct{}), principal: p}
	go s.read(e)
	defer func() { s.detach(e); c.CloseNow(); <-e.readDone }()
	s.match(e)
	wait := time.NewTimer(s.waitTimeout)
	defer wait.Stop()
	select {
	case <-e.ready:
	case <-ctx.Done():
		return
	case <-wait.C:
		return
	}
	if !s.write(e, websocket.MessageText, []byte(Ready)) {
		return
	}
	// Each handler writes only its own socket, so Ready always precedes TLS data.
	for {
		select {
		case <-ctx.Done():
			return
		case <-e.peer.ctx.Done():
			return
		case b := <-e.peer.data:
			written := s.write(e, websocket.MessageBinary, b.bytes)
			close(b.forwarded)
			if !written {
				return
			}
		}
	}
}

func (s *Server) match(e *endpoint) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if e.ctx.Err() != nil {
		return
	}
	r := e.principal.route
	opposite := 1 - e.principal.role
	for len(r.waiting[opposite]) > 0 {
		peer := r.waiting[opposite][0]
		r.waiting[opposite] = r.waiting[opposite][1:]
		if peer.ctx.Err() != nil {
			continue
		}
		peer.peer = e
		e.peer = peer
		close(peer.ready)
		close(e.ready)
		return
	}
	if e.ctx.Err() == nil {
		r.waiting[e.principal.role] = append(r.waiting[e.principal.role], e)
	}
}

func (s *Server) detach(e *endpoint) {
	e.cancel()
	s.mu.Lock()
	r, role := e.principal.route, e.principal.role
	for i, pending := range r.waiting[role] {
		if pending == e {
			r.waiting[role] = append(r.waiting[role][:i], r.waiting[role][i+1:]...)
			break
		}
	}
	peer := e.peer
	s.mu.Unlock()
	if peer != nil {
		peer.cancel()
	}
}

func (s *Server) read(e *endpoint) {
	defer close(e.readDone)
	defer e.cancel()
	bytes, frames := newBucket(256*1024, 64*1024), newBucket(128, 64)
	var total int64
	for {
		ctx, cancel := context.WithTimeout(e.ctx, s.idleTimeout)
		typ, b, err := e.conn.Read(ctx)
		cancel()
		if err != nil || typ != websocket.MessageBinary || len(b) == 0 {
			return
		}
		total += int64(len(b))
		if total > MaxBytesPerDirection || !bytes.allow(s.now(), float64(len(b))) || !frames.allow(s.now(), 1) {
			return
		}
		message := relayMessage{bytes: b, forwarded: make(chan struct{})}
		select {
		case e.data <- message:
		case <-e.ctx.Done():
			return
		}
		// Finish forwarding before observing the sender's next frame/EOF. An
		// HTTP server may close immediately after its last TLS record; cancelling
		// the peer while that record is still queued can truncate a valid reply.
		select {
		case <-message.forwarded:
		case <-e.ctx.Done():
			return
		}
	}
}

func (s *Server) write(e *endpoint, typ websocket.MessageType, b []byte) bool {
	ctx, cancel := context.WithTimeout(e.ctx, s.writeTimeout)
	defer cancel()
	return e.conn.Write(ctx, typ, b) == nil
}
