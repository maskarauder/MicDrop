package rendezvous

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/url"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// Dial joins the route/role selected by an operator-provisioned token. The
// returned stream MUST be wrapped in the existing paired TLS client/server.
// The context bounds its lifetime; a deadline failure closes the whole stream.
// client=nil uses normal system trust. Tests may supply their own trusted CA.
func Dial(ctx context.Context, baseURL, token string, client *http.Client) (net.Conn, error) {
	u, err := url.Parse(baseURL)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || (u.Path != "" && u.Path != "/") || u.RawPath != "" || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || !validToken(token) {
		return nil, errors.New("invalid rendezvous endpoint or credential")
	}
	if client == nil {
		client = http.DefaultClient
	}
	copyClient := *client
	copyClient.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	u.Scheme = "wss"
	u.Path = "/v1/tunnel"
	dialCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	c, resp, err := websocket.Dial(dialCtx, u.String(), &websocket.DialOptions{HTTPClient: &copyClient, HTTPHeader: http.Header{"Authorization": []string{"Bearer " + token}}, Subprotocols: []string{Subprotocol}, CompressionMode: websocket.CompressionDisabled})
	cancel()
	if err != nil {
		if resp != nil && resp.Body != nil {
			resp.Body.Close()
		}
		return nil, errors.New("rendezvous connection failed")
	}
	if c.Subprotocol() != Subprotocol {
		c.CloseNow()
		return nil, errors.New("unsupported rendezvous protocol")
	}
	c.SetReadLimit(MaxFrameBytes)
	waitStarted := time.Now()
	readyCtx, readyCancel := context.WithTimeout(ctx, 30*time.Second)
	typ, data, err := c.Read(readyCtx)
	readyCancel()
	if err != nil || typ != websocket.MessageText || string(data) != Ready {
		c.CloseNow()
		if err != nil && ctx.Err() == nil {
			return nil, peerUnavailableError{waited: time.Since(waitStarted)}
		}
		return nil, errors.New("rendezvous peer unavailable")
	}
	conn := websocket.NetConn(ctx, c, websocket.MessageBinary)
	// NetConn disables its read limit; restore the protocol's frame bound.
	c.SetReadLimit(MaxFrameBytes)
	return &tunnelConn{Conn: conn, websocket: c}, nil
}

type peerUnavailableError struct {
	waited time.Duration
}

func (peerUnavailableError) Error() string { return "rendezvous peer unavailable" }

type tunnelConn struct {
	net.Conn
	websocket *websocket.Conn
	writeMu   sync.Mutex
}

func (c *tunnelConn) Close() error { _ = c.websocket.CloseNow(); return c.Conn.Close() }
func (c *tunnelConn) Write(b []byte) (int, error) {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	total := 0
	for len(b) > 0 {
		n, err := c.Conn.Write(b[:min(len(b), 16*1024)])
		total += n
		b = b[n:]
		if err != nil {
			return total, err
		}
	}
	return total, nil
}
