// Package rendezvous provides a bounded byte relay for paired TLS signaling.
// It never terminates the inner TLS session or handles audio/media packets.
package rendezvous

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/url"
	"strconv"
	"strings"
)

const MaxConfigBytes = 64 * 1024

type Config struct {
	Version  int         `json:"version"`
	Routes   []Route     `json:"routes"`
	STUNURLs []string    `json:"stun_urls,omitempty"`
	TURN     *TURNConfig `json:"turn,omitempty"`
}

// Tokens authorize relay resources only. Inner paired TLS authorizes audio.
type Route struct {
	ID          string `json:"id"`
	HostToken   string `json:"host_token"`
	ClientToken string `json:"client_token"`
}

type TURNConfig struct {
	URLs         []string `json:"urls"`
	SharedSecret string   `json:"shared_secret"`
}

func NewToken() string {
	var b [32]byte
	_, _ = rand.Read(b[:]) // crypto/rand.Read either succeeds or terminates the process.
	return base64.RawURLEncoding.EncodeToString(b[:])
}

func validToken(s string) bool {
	b, err := base64.RawURLEncoding.Strict().DecodeString(s)
	return err == nil && len(b) == 32 && base64.RawURLEncoding.EncodeToString(b) == s
}

func DecodeConfig(r io.Reader) (Config, error) {
	var c Config
	b, err := io.ReadAll(io.LimitReader(r, MaxConfigBytes+1))
	if err != nil || len(b) > MaxConfigBytes {
		return c, errors.New("cannot read bounded rendezvous configuration")
	}
	d := json.NewDecoder(strings.NewReader(string(b)))
	d.DisallowUnknownFields()
	if d.Decode(&c) != nil || d.Decode(new(any)) != io.EOF {
		return Config{}, errors.New("invalid rendezvous configuration JSON")
	}
	if err := c.Validate(); err != nil {
		return Config{}, err
	}
	return c, nil
}

func (c Config) Validate() error {
	if c.Version != 1 || len(c.Routes) < 1 || len(c.Routes) > 16 {
		return errors.New("configuration requires version 1 and 1 to 16 routes")
	}
	tokens, names := map[string]bool{}, map[string]bool{}
	for _, r := range c.Routes {
		if len(r.ID) < 1 || len(r.ID) > 32 || strings.Trim(r.ID, "abcdefghijklmnopqrstuvwxyz0123456789-") != "" || names[r.ID] {
			return errors.New("route IDs must be unique lowercase labels of up to 32 characters")
		}
		names[r.ID] = true
		for _, token := range []string{r.HostToken, r.ClientToken} {
			if !validToken(token) || tokens[token] {
				return errors.New("every relay token must be a distinct base64url-encoded 32-byte secret")
			}
			tokens[token] = true
		}
	}
	if len(c.STUNURLs) > 4 {
		return errors.New("at most four STUN URLs are supported")
	}
	for _, u := range c.STUNURLs {
		if !validICEURL(u, false) {
			return errors.New("invalid STUN URL")
		}
	}
	if c.TURN != nil {
		if len(c.TURN.URLs) < 1 || len(c.TURN.URLs) > 4 || !validToken(c.TURN.SharedSecret) || tokens[c.TURN.SharedSecret] {
			return errors.New("TURN requires 1 to 4 URLs and a separate 32-byte shared secret")
		}
		for _, u := range c.TURN.URLs {
			if !validICEURL(u, true) {
				return errors.New("invalid TURN URL")
			}
		}
	}
	return nil
}

// Restrict the initial ICE URI contract to an explicit host/port and transport.
func validICEURL(raw string, turn bool) bool {
	if len(raw) > 512 || strings.ContainsAny(raw, "\r\n\t /#%@") {
		return false
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host != "" || u.User != nil || u.Path != "" || u.Fragment != "" {
		return false
	}
	if (!turn && (u.Scheme != "stun" || u.RawQuery != "" || u.ForceQuery)) || (turn && u.Scheme != "turn" && u.Scheme != "turns") {
		return false
	}
	if turn && u.RawQuery != "transport=udp" && u.RawQuery != "transport=tcp" {
		return false
	}
	if u.Scheme == "turns" && u.RawQuery != "transport=tcp" {
		return false
	}
	host, port, err := net.SplitHostPort(u.Opaque)
	p, e := strconv.Atoi(port)
	if err != nil || e != nil || p < 1 || p > 65535 || host == "" || len(host) > 253 {
		return false
	}
	if net.ParseIP(host) != nil {
		return true
	}
	for _, label := range strings.Split(host, ".") {
		if len(label) < 1 || len(label) > 63 || strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") || strings.Trim(strings.ToLower(label), "abcdefghijklmnopqrstuvwxyz0123456789-") != "" {
			return false
		}
	}
	return true
}
