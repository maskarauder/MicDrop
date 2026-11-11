package rendezvous

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// RemoteConfig belongs to Windows, never to a diagnostics report. Only the
// client role credential is carried in the private phone invitation.
type RemoteConfig struct {
	Version     int    `json:"version"`
	URL         string `json:"url"`
	HostToken   string `json:"host_token"`
	ClientToken string `json:"client_token"`
	ForceRelay  bool   `json:"force_relay"`
}

func validEndpoint(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil {
		return false
	}
	if u.Port() != "" {
		port, err := strconv.Atoi(u.Port())
		if err != nil || port < 1 || port > 65535 {
			return false
		}
	}
	return err == nil && len(raw) <= 512 && u.Scheme == "https" && u.Hostname() != "" &&
		u.User == nil && (u.Path == "" || u.Path == "/") && u.RawPath == "" && u.RawQuery == "" &&
		!u.ForceQuery && u.Fragment == "" && !strings.ContainsAny(raw, "\r\n\t ")
}

func DecodeRemote(r io.Reader) (RemoteConfig, error) {
	var c RemoteConfig
	b, err := io.ReadAll(io.LimitReader(r, 4097))
	if err != nil || len(b) > 4096 {
		return c, errors.New("cannot read remote configuration")
	}
	defer clear(b)
	d := json.NewDecoder(strings.NewReader(string(b)))
	d.DisallowUnknownFields()
	if d.Decode(&c) != nil || d.Decode(new(any)) != io.EOF || c.Validate() != nil {
		return RemoteConfig{}, errors.New("invalid remote configuration")
	}
	return c, nil
}

func (c RemoteConfig) Validate() error {
	if c.Version != 1 || !validEndpoint(c.URL) || !validToken(c.HostToken) || !validToken(c.ClientToken) || c.HostToken == c.ClientToken {
		return errors.New("remote configuration requires HTTPS and distinct host/client credentials")
	}
	return nil
}

func (c RemoteConfig) Invitation(connection string) string {
	b, _ := json.Marshal(struct {
		URL        string `json:"url"`
		Token      string `json:"token"`
		Connection string `json:"connection"`
		ForceRelay bool   `json:"force_relay"`
	}{c.URL, c.ClientToken, connection, c.ForceRelay})
	return "micdrop://remote/v1/" + base64.RawURLEncoding.EncodeToString(b)
}

// ICECache keeps short-lived credentials off disk and limits issuance across
// reconnects. A failed refresh is never replaced by stale or public defaults.
type ICECache struct {
	mu          sync.Mutex
	config      RemoteConfig
	client      *http.Client
	value       ICEConfiguration
	nextAttempt time.Time
	now         func() time.Time
}

func NewICECache(c RemoteConfig, client *http.Client) *ICECache {
	return &ICECache{config: c, client: client, now: time.Now}
}

func (c *ICECache) Get(ctx context.Context) (ICEConfiguration, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.config.Validate(); err != nil {
		return ICEConfiguration{}, err
	}
	clock := c.now
	if clock == nil {
		clock = time.Now
	}
	now := clock()
	if now.Add(time.Minute).Unix() < c.value.ExpiresAt {
		return c.value, nil
	}
	if now.Before(c.nextAttempt) {
		return ICEConfiguration{}, errors.New("remote ICE configuration temporarily unavailable")
	}
	c.nextAttempt = now.Add(30 * time.Second)
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	client := c.client
	if client == nil {
		client = http.DefaultClient
	}
	copyClient := *client
	copyClient.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	r, err := http.NewRequestWithContext(ctx, "GET", strings.TrimSuffix(c.config.URL, "/")+"/v1/ice", nil)
	if err != nil {
		return ICEConfiguration{}, errors.New("invalid remote endpoint")
	}
	r.Header.Set("Authorization", "Bearer "+c.config.HostToken)
	response, err := copyClient.Do(r)
	if err != nil {
		// Local network handoffs can fail transiently before the new route stabilizes;
		// allow a retry within the ICE recovery window while still bounding loops.
		c.nextAttempt = now.Add(3 * time.Second)
		return ICEConfiguration{}, errors.New("cannot reach remote ICE service")
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return ICEConfiguration{}, errors.New("remote ICE service rejected request")
	}
	b, err := io.ReadAll(io.LimitReader(response.Body, 16385))
	if err != nil || len(b) > 16384 {
		return ICEConfiguration{}, errors.New("invalid remote ICE response")
	}
	defer clear(b)
	var value ICEConfiguration
	d := json.NewDecoder(strings.NewReader(string(b)))
	d.DisallowUnknownFields()
	if d.Decode(&value) != nil || d.Decode(new(any)) != io.EOF || value.Validate(now, c.config.ForceRelay) != nil {
		return ICEConfiguration{}, errors.New("invalid remote ICE configuration (forced relay requires TURN)")
	}
	c.value = value
	return value, nil
}

func (c ICEConfiguration) Validate(now time.Time, force bool) error {
	invalid := errors.New("invalid ICE configuration")
	if c.Version != 1 || c.ExpiresAt <= now.Add(time.Minute).Unix() || c.ExpiresAt > now.Add(CredentialLifetime+time.Minute).Unix() || len(c.Servers) > 8 {
		return invalid
	}
	count, turnCount := 0, 0
	for _, s := range c.Servers {
		if len(s.URLs) == 0 {
			return invalid
		}
		for _, u := range s.URLs {
			count++
			turn := strings.HasPrefix(u, "turn:") || strings.HasPrefix(u, "turns:")
			if !validICEURL(u, turn) {
				return invalid
			}
			if turn {
				turnCount++
				if s.Username == "" || s.Credential == "" || len(s.Username) > 512 || len(s.Credential) > 512 || strings.ContainsAny(s.Username+s.Credential, "\x00\r\n") {
					return invalid
				}
			} else if s.Username != "" || s.Credential != "" {
				return invalid
			}
		}
	}
	if count > 8 || (force && turnCount == 0) {
		return invalid
	}
	return nil
}

// Listen presents outbound rendezvous streams to the existing paired TLS/HTTP
// server. No inbound firewall opening or change to audio authorization occurs.
func Listen(ctx context.Context, c RemoteConfig, client *http.Client) (net.Listener, error) {
	if err := c.Validate(); err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(ctx)
	return &remoteListener{ctx: ctx, cancel: cancel, config: c, client: client, slots: make(chan struct{}, 4), minPollWait: 5 * time.Second}, nil
}

type remoteListener struct {
	ctx         context.Context
	cancel      context.CancelFunc
	config      RemoteConfig
	client      *http.Client
	slots       chan struct{}
	minPollWait time.Duration
}

func (l *remoteListener) Accept() (net.Conn, error) {
	select {
	case l.slots <- struct{}{}:
	case <-l.ctx.Done():
		return nil, net.ErrClosed
	}
	delay := time.Second
	for {
		c, err := Dial(l.ctx, l.config.URL, l.config.HostToken, l.client)
		if err == nil {
			return &leasedConn{Conn: c, release: func() { <-l.slots }}, nil
		}
		if l.ctx.Err() != nil {
			<-l.slots
			return nil, net.ErrClosed
		}
		var poll peerUnavailableError
		if errors.As(err, &poll) && l.minPollWait > 0 && poll.waited >= l.minPollWait {
			delay = time.Second
			continue
		}
		timer := time.NewTimer(delay)
		select {
		case <-timer.C:
		case <-l.ctx.Done():
			timer.Stop()
			<-l.slots
			return nil, net.ErrClosed
		}
		delay = min(delay*2, 10*time.Second)
	}
}
func (l *remoteListener) Close() error   { l.cancel(); return nil }
func (l *remoteListener) Addr() net.Addr { return relayAddress{} }

type relayAddress struct{}

func (relayAddress) Network() string { return "rendezvous" }
func (relayAddress) String() string  { return "remote" }

type leasedConn struct {
	net.Conn
	once    sync.Once
	release func()
}

func (c *leasedConn) Close() error { err := c.Conn.Close(); c.once.Do(c.release); return err }
