package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/rendezvous"
)

func TestInitIsPrivateDoesNotPrintCredentialsAndNeverOverwrites(t *testing.T) {
	path := filepath.Join(t.TempDir(), "private", "config.json")
	var output bytes.Buffer
	ctx := context.Background()
	if run(ctx, []string{"init", "--config", path}, &output, &output) != 0 {
		t.Fatal(output.String())
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	c, err := rendezvous.DecodeConfig(bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{c.Routes[0].HostToken, c.Routes[0].ClientToken} {
		if strings.Contains(output.String(), secret) {
			t.Fatal("printed private credential")
		}
	}
	if runtime.GOOS != "windows" {
		info, _ := os.Stat(path)
		dir, _ := os.Stat(filepath.Dir(path))
		if info.Mode().Perm() != 0600 || dir.Mode().Perm() != 0700 {
			t.Fatal("private permissions not set")
		}
	}
	if run(ctx, []string{"init", "--config", path}, &output, &output) == 0 {
		t.Fatal("overwrote private config")
	}
	after, _ := os.ReadFile(path)
	if !bytes.Equal(b, after) {
		t.Fatal("existing config changed")
	}
	if run(ctx, []string{"check", "--config", path}, &output, &output) != 0 {
		t.Fatal("generated config rejected")
	}
	if run(ctx, []string{"serve", "--config", path}, &output, &output) != 2 {
		t.Fatal("served without TLS material")
	}
}

type cancelWriter struct {
	cancel context.CancelFunc
	output bytes.Buffer
}

func (w *cancelWriter) Write(b []byte) (int, error) {
	n, err := w.output.Write(b)
	if bytes.Contains(b, []byte("is running")) {
		w.cancel()
	}
	return n, err
}

func TestServeStopsCleanlyAndRejectsBadConfiguration(t *testing.T) {
	root := t.TempDir()
	configPath := filepath.Join(root, "config.json")
	c := rendezvous.Config{Version: 1, Routes: []rendezvous.Route{{ID: "test", HostToken: rendezvous.NewToken(), ClientToken: rendezvous.NewToken()}}}
	b, _ := json.Marshal(c)
	if err := os.WriteFile(configPath, b, 0600); err != nil {
		t.Fatal(err)
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour)}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	pkcs8, _ := x509.MarshalPKCS8PrivateKey(key)
	certPath, keyPath := filepath.Join(root, "cert.pem"), filepath.Join(root, "key.pem")
	if os.WriteFile(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0600) != nil || os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pkcs8}), 0600) != nil {
		t.Fatal("write TLS fixture")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	w := &cancelWriter{cancel: cancel}
	if run(ctx, []string{"serve", "--config", configPath, "--listen", "127.0.0.1:0", "--tls-cert", certPath, "--tls-key", keyPath}, w, w) != 0 || !strings.Contains(w.output.String(), "Rendezvous stopped.") {
		t.Fatal(w.output.String())
	}
	var output bytes.Buffer
	if run(context.Background(), []string{"check", "--config", filepath.Join(root, "missing")}, &output, &output) == 0 {
		t.Fatal("accepted missing config")
	}
	if os.WriteFile(configPath, []byte(`{"unexpected":"secret-value"}`), 0600) != nil {
		t.Fatal("write invalid config")
	}
	if run(context.Background(), []string{"check", "--config", configPath}, &output, &output) == 0 || strings.Contains(output.String(), "secret-value") {
		t.Fatal("invalid config accepted or disclosed")
	}
}

func TestExportContainsOnlySelectedRouteAndNeverOverwrites(t *testing.T) {
	root := t.TempDir()
	configPath := filepath.Join(root, "config.json")
	outputPath := filepath.Join(root, "remote.json")
	c := rendezvous.Config{Version: 1, Routes: []rendezvous.Route{
		{ID: "host-1", HostToken: rendezvous.NewToken(), ClientToken: rendezvous.NewToken()},
		{ID: "other", HostToken: rendezvous.NewToken(), ClientToken: rendezvous.NewToken()},
	}, TURN: &rendezvous.TURNConfig{URLs: []string{"turn:relay.example.test:3478?transport=udp"}, SharedSecret: rendezvous.NewToken()}}
	b, _ := json.Marshal(c)
	if err := os.WriteFile(configPath, b, 0600); err != nil {
		t.Fatal(err)
	}
	args := []string{"export", "--config", configPath, "--url", "https://signal.example.test:8443", "--output", outputPath, "--force-relay"}
	var output bytes.Buffer
	if run(context.Background(), args, &output, &output) != 0 {
		t.Fatal(output.String())
	}
	b, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatal(err)
	}
	remote, err := rendezvous.DecodeRemote(bytes.NewReader(b))
	if err != nil || !remote.ForceRelay || remote.HostToken != c.Routes[0].HostToken || remote.ClientToken != c.Routes[0].ClientToken {
		t.Fatal("wrong export")
	}
	for _, secret := range []string{c.Routes[0].HostToken, c.Routes[0].ClientToken, c.TURN.SharedSecret, c.Routes[1].HostToken, c.Routes[1].ClientToken} {
		if strings.Contains(output.String(), secret) {
			t.Fatal("secret printed")
		}
	}
	for _, secret := range []string{c.TURN.SharedSecret, c.Routes[1].HostToken, c.Routes[1].ClientToken} {
		if bytes.Contains(b, []byte(secret)) {
			t.Fatal("unrelated credential exported")
		}
	}
	if run(context.Background(), args, &output, &output) == 0 {
		t.Fatal("overwrote export")
	}
	if runtime.GOOS != "windows" {
		info, _ := os.Stat(outputPath)
		if info.Mode().Perm() != 0600 {
			t.Fatal("export permissions")
		}
	}
}
