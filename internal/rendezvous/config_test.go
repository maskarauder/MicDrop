package rendezvous

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func testConfig() Config {
	return Config{Version: 1, Routes: []Route{{ID: "test", HostToken: NewToken(), ClientToken: NewToken()}}}
}

func TestConfigRejectsUnsafeOrUnboundedConfiguration(t *testing.T) {
	for name, edit := range map[string]func(*Config){
		"version":            func(c *Config) { c.Version = 2 },
		"no routes":          func(c *Config) { c.Routes = nil },
		"many routes":        func(c *Config) { c.Routes = make([]Route, 17) },
		"duplicate identity": func(c *Config) { c.Routes = append(c.Routes, c.Routes[0]) },
		"duplicate token":    func(c *Config) { c.Routes[0].ClientToken = c.Routes[0].HostToken },
		"short token":        func(c *Config) { c.Routes[0].ClientToken = "secret" },
		"token padding":      func(c *Config) { c.Routes[0].HostToken += "=" },
		"path in ID":         func(c *Config) { c.Routes[0].ID = "../private" },
		"TURN secret reuse": func(c *Config) {
			c.TURN = &TURNConfig{URLs: []string{"turn:relay.example:3478?transport=udp"}, SharedSecret: c.Routes[0].HostToken}
		},
		"unexpected STUN query": func(c *Config) { c.STUNURLs = []string{"stun:relay.example:3478?password=secret"} },
		"missing port":          func(c *Config) { c.STUNURLs = []string{"stun:relay.example"} },
		"userinfo": func(c *Config) {
			c.TURN = &TURNConfig{URLs: []string{"turn:user@relay.example:3478?transport=udp"}, SharedSecret: NewToken()}
		},
		"wrong TLS transport": func(c *Config) {
			c.TURN = &TURNConfig{URLs: []string{"turns:relay.example:5349?transport=udp"}, SharedSecret: NewToken()}
		},
		"credential URI": func(c *Config) { c.STUNURLs = []string{"https://relay.example"} },
	} {
		t.Run(name, func(t *testing.T) {
			c := testConfig()
			edit(&c)
			if c.Validate() == nil {
				t.Fatal("accepted invalid configuration")
			}
		})
	}
	c := testConfig()
	c.STUNURLs = []string{"stun:relay.example:3478", "stun:[::1]:3478"}
	c.TURN = &TURNConfig{URLs: []string{"turn:relay.example:3478?transport=udp", "turns:relay.example:5349?transport=tcp"}, SharedSecret: NewToken()}
	b, _ := json.Marshal(c)
	if _, err := DecodeConfig(strings.NewReader(string(b))); err != nil {
		t.Fatal(err)
	}
	for _, b := range []string{string(b) + " {}", `{"version":1,"unknown":"private"}`, strings.Repeat(" ", MaxConfigBytes+1), `{"routes":null}`} {
		if _, err := DecodeConfig(strings.NewReader(b)); err == nil {
			t.Fatal("accepted invalid JSON")
		}
	}
}

func TestBucketRefillDoesNotAccumulateUnboundedCredit(t *testing.T) {
	b := newBucket(2, 1)
	now := timeFixture()
	if !b.allow(now, 2) || b.allow(now, 1) || b.allow(now.Add(time.Second/2), 1) || !b.allow(now.Add(time.Second), 1) {
		t.Fatal("rate boundary failed")
	}
	if b.allow(now.Add(24*time.Hour), 3) {
		t.Fatal("credit exceeded burst")
	}
}
