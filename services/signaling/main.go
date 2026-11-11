// micdrop-rendezvous provides opt-in signaling and short-lived TURN credentials.
package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/maskarauder/MicDrop/internal/rendezvous"
	"golang.org/x/net/netutil"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	os.Exit(run(ctx, os.Args[1:], os.Stdout, os.Stderr))
}

func run(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 || (args[0] != "init" && args[0] != "check" && args[0] != "serve" && args[0] != "export") {
		fmt.Fprintln(stderr, "Usage: micdrop-rendezvous init|check|serve|export --config <private-file>")
		return 2
	}
	flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
	flags.SetOutput(stderr)
	configFile := flags.String("config", "rendezvous-private/config.json", "private service configuration")
	var listen, certFile, keyFile, certName string
	var certReload time.Duration
	var endpoint, route, output string
	var forceRelay bool
	if args[0] == "export" {
		flags.StringVar(&endpoint, "url", "", "public HTTPS rendezvous URL")
		flags.StringVar(&route, "route", "host-1", "route ID to export")
		flags.StringVar(&output, "output", "", "new private Windows configuration file")
		flags.BoolVar(&forceRelay, "force-relay", false, "require TURN for the media path")
	}
	if args[0] == "serve" || args[0] == "check" {
		flags.StringVar(&certFile, "tls-cert", "", "PEM certificate chain for the rendezvous hostname")
		flags.StringVar(&keyFile, "tls-key", "", "private PEM certificate key")
		flags.StringVar(&certName, "tls-name", "", "require loaded certificates to cover this public hostname")
	}
	if args[0] == "serve" {
		flags.StringVar(&listen, "listen", "127.0.0.1:8443", "TLS listening address; explicitly choose a public interface when deploying")
		flags.DurationVar(&certReload, "tls-reload-interval", time.Minute, "recheck certificate files without closing tunnels (1s to 24h)")
	}
	if flags.Parse(args[1:]) != nil || flags.NArg() != 0 || *configFile == "" {
		return 2
	}
	if args[0] == "init" {
		return initialize(*configFile, stdout, stderr)
	}
	f, err := os.Open(*configFile)
	if err != nil {
		fmt.Fprintln(stderr, "Cannot read the private service configuration.")
		return 1
	}
	config, err := rendezvous.DecodeConfig(f)
	f.Close()
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if args[0] == "export" {
		if output == "" || forceRelay && config.TURN == nil {
			fmt.Fprintln(stderr, "export requires --output; --force-relay requires configured TURN.")
			return 2
		}
		for _, r := range config.Routes {
			if r.ID != route {
				continue
			}
			c := rendezvous.RemoteConfig{Version: 1, URL: endpoint, HostToken: r.HostToken, ClientToken: r.ClientToken, ForceRelay: forceRelay}
			if c.Validate() != nil {
				fmt.Fprintln(stderr, "export requires a valid --url https://hostname[:port].")
				return 2
			}
			if err := writePrivateConfig(output, c); err != nil {
				fmt.Fprintln(stderr, "Cannot create export; existing files are never overwritten.")
				return 1
			}
			fmt.Fprintln(stdout, "Created private Windows configuration. Transfer it securely, import with windows-host remote import --config <file>, then remove the plaintext transfer copy.")
			return 0
		}
		fmt.Fprintln(stderr, "Unknown route ID.")
		return 2
	}
	if args[0] == "check" {
		if certFile != "" || keyFile != "" || certName != "" {
			if certFile == "" || keyFile == "" {
				fmt.Fprintln(stderr, "TLS checking requires both --tls-cert and --tls-key.")
				return 2
			}
			if _, err := newCertificateReloader(certFile, keyFile, certName); err != nil {
				fmt.Fprintln(stderr, "TLS certificate check failed. Check read permissions, matching files, dates and hostname.")
				return 1
			}
			fmt.Fprintln(stdout, "TLS certificate/key are readable and valid. Client trust and network reachability still require a connection test.")
		}
		fmt.Fprintf(stdout, "Configuration valid: %d route(s); TURN configured: %t.\n", len(config.Routes), config.TURN != nil)
		return 0
	}
	if certFile == "" || keyFile == "" {
		fmt.Fprintln(stderr, "serve requires --tls-cert and --tls-key; plaintext is unavailable.")
		return 2
	}
	if certReload < time.Second || certReload > 24*time.Hour {
		fmt.Fprintln(stderr, "--tls-reload-interval must be between 1s and 24h.")
		return 2
	}
	cert, err := newCertificateReloader(certFile, keyFile, certName)
	if err != nil {
		fmt.Fprintln(stderr, "Cannot load a valid rendezvous TLS certificate/key. Check read permissions, matching files, certificate dates and --tls-name.")
		return 1
	}
	if ctx.Err() != nil {
		return 0
	}
	listener, err := net.Listen("tcp", listen)
	if err != nil {
		fmt.Fprintln(stderr, "Cannot listen on the configured rendezvous address.")
		return 1
	}
	defer listener.Close()
	relay, err := rendezvous.New(config)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	defer relay.Close()
	server := &http.Server{Handler: relay, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 4096, ErrorLog: log.New(io.Discard, "", 0)}
	secure := tls.NewListener(netutil.LimitListener(listener, 160), &tls.Config{MinVersion: tls.VersionTLS13, GetCertificate: cert.getCertificate, NextProtos: []string{"http/1.1"}})
	done := make(chan error, 1)
	go func() { done <- server.Serve(secure) }()
	fmt.Fprintln(stdout, "MicDrop rendezvous is running. TLS certificate reload is automatic; configuration changes require a restart.")
	ticker := time.NewTicker(certReload)
	defer ticker.Stop()
	reloadFailed := false
	for {
		select {
		case <-ticker.C:
			changed, err := cert.reload(time.Now())
			if err != nil {
				if !reloadFailed {
					fmt.Fprintln(stderr, "TLS certificate reload failed. Retaining the last valid certificate until expiry; check read permissions, matching files, dates and hostname. Retrying automatically.")
				}
				reloadFailed = true
			} else {
				if changed {
					fmt.Fprintln(stdout, "TLS certificate reloaded. Existing connections remain open.")
				} else if reloadFailed {
					fmt.Fprintln(stdout, "TLS certificate files are readable and valid again.")
				}
				reloadFailed = false
			}
		case <-ctx.Done():
			relay.Close()
			shutdown, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			_ = server.Shutdown(shutdown)
			_ = server.Close()
			<-done
			fmt.Fprintln(stdout, "Rendezvous stopped.")
			return 0
		case err := <-done:
			if err != nil && err != http.ErrServerClosed {
				fmt.Fprintln(stderr, "Rendezvous listener failed.")
				return 1
			}
			return 0
		}
	}
}

func initialize(path string, stdout, stderr io.Writer) int {
	config := rendezvous.Config{Version: 1, Routes: []rendezvous.Route{{ID: "host-1", HostToken: rendezvous.NewToken(), ClientToken: rendezvous.NewToken()}}}
	if err := writePrivateConfig(path, config); err != nil {
		fmt.Fprintln(stderr, "Cannot create private configuration; existing files are never overwritten.")
		return 1
	}
	fmt.Fprintln(stdout, "Created private service configuration. Credentials are stored only in that file; keep it out of logs and source control.")
	return 0
}
func writePrivateConfig(path string, config any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	ok := false
	defer func() {
		f.Close()
		if !ok {
			_ = os.Remove(path)
		}
	}()
	enc := json.NewEncoder(f)
	enc.SetIndent("", "  ")
	if enc.Encode(config) != nil || f.Sync() != nil {
		return fmt.Errorf("cannot save configuration")
	}
	if f.Close() != nil {
		return fmt.Errorf("cannot finish configuration")
	}
	ok = true
	return nil
}
