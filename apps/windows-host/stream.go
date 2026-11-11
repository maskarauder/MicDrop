package main

import (
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/maskarauder/MicDrop/internal/desktop"
	"github.com/maskarauder/MicDrop/internal/diagnostics"
	"github.com/maskarauder/MicDrop/internal/discovery"
	"github.com/maskarauder/MicDrop/internal/pairing"
	"github.com/maskarauder/MicDrop/internal/rendezvous"
	"github.com/maskarauder/MicDrop/internal/rtc"
	"github.com/maskarauder/MicDrop/internal/session"
	windowsaudio "github.com/maskarauder/MicDrop/native/platform/windows"
)

func runStream(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	return runStreamControlled(ctx, args, stdout, stderr, nil)
}

func runStreamControlled(ctx context.Context, args []string, stdout, stderr io.Writer, ui *desktopStream) int {
	if ctx.Err() != nil {
		return 0
	}
	flags := flag.NewFlagSet("stream", flag.ContinueOnError)
	flags.SetOutput(stderr)
	host := flags.String("host", "", "this PC's private LAN IPv4 address (see ipconfig)")
	port := flags.Int("port", 9844, "LAN HTTPS control port")
	device := flags.String("device", "", "Windows output endpoint; empty selects the default at each session start")
	microphoneDevice := flags.String("microphone-device", "", "explicit cable render endpoint for paired microphone/duplex sessions; use bridge-devices")
	probe := flags.Bool("probe", false, "send a quiet 440 Hz left / 660 Hz right stereo probe instead of desktop output")
	logDirectory := flags.String("log-dir", "diagnostics-private", "directory for one unique combined JSONL log per session")
	logRetention := flags.Int("log-retention", 0, "keep the most recent X connection logs (0 keeps all; maximum 10000)")
	legacyLog := flags.String("log", "", "removed; use --log-dir for per-session logs")
	lifetime := flags.Duration("invitation-ttl", 12*time.Hour, "connection link lifetime (1m to 23h); restart host to reset")
	noLog := flags.Bool("no-log", false, "disable automatic combined diagnostics")
	remote := flags.Bool("remote", false, "use LAN plus the imported rendezvous route; requires --paired; disables LAN discovery")
	paired := flags.Bool("paired", false, "use persistent mutually authenticated device pairing (v3)")
	noDiscovery := flags.Bool("no-discovery", false, "disable LAN discovery advertisements; requires --paired")
	pair := flags.Bool("pair", false, "open a five-minute pairing window; requires --paired")
	revokeAll := flags.Bool("revoke-all", false, "remove all approved phones before accepting connections; requires --paired (omit on later starts)")
	stateDirectory := flags.String("state-dir", "", "absolute protected identity directory; requires --paired")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	ip := net.ParseIP(*host)
	if *legacyLog != "" {
		fmt.Fprintln(stderr, "--log was replaced by --log-dir: each session now gets its own unique file")
		return 2
	}
	if flags.NArg() != 0 || ip == nil || ip.To4() == nil || !ip.IsPrivate() || *port < 1 || *port > 65535 {
		fmt.Fprintln(stderr, "stream requires --host <this PC's private LAN IPv4 address> and a valid --port")
		return 2
	}
	if *lifetime < time.Minute || *lifetime > 23*time.Hour || *logDirectory == "" {
		fmt.Fprintln(stderr, "Use --invitation-ttl between 1m and 23h and a nonempty --log-dir")
		return 2
	}
	if *logRetention < 0 || *logRetention > 10000 {
		fmt.Fprintln(stderr, "--log-retention must be between 0 and 10000")
		return 2
	}
	if !*paired && (*pair || *stateDirectory != "" || *noDiscovery || *revokeAll || *remote) {
		fmt.Fprintln(stderr, "--pair, --state-dir, --no-discovery, --revoke-all and --remote require --paired")
		return 2
	}
	microphoneFlag := false
	flags.Visit(func(f *flag.Flag) {
		if f.Name == "microphone-device" {
			microphoneFlag = true
		}
	})
	if microphoneFlag {
		if !*paired {
			fmt.Fprintln(stderr, "--microphone-device requires --paired; microphone return uses approved phone identities")
			return 2
		}
		if err := (windowsaudio.BridgeConfig{RenderEndpointID: *microphoneDevice, Duration: time.Second}).Validate(); err != nil {
			fmt.Fprintln(stderr, err)
			return 2
		}
	}
	if *paired {
		invalid := false
		flags.Visit(func(f *flag.Flag) {
			if f.Name == "invitation-ttl" {
				invalid = true
			}
		})
		if invalid {
			fmt.Fprintln(stderr, "--invitation-ttl applies only to legacy connection links; pairing windows last five minutes")
			return 2
		}
	}
	if runtime.GOOS != "windows" || runtime.GOARCH != "amd64" {
		fmt.Fprintln(stderr, "WebRTC streaming requires Windows x64")
		return 1
	}
	// Session setup/finalization callbacks also write to the console.
	outputMu := &sync.Mutex{}
	stdout = &lockedWriter{mu: outputMu, writer: stdout}
	stderr = &lockedWriter{mu: outputMu, writer: stderr}
	streamContext, cancelStream := context.WithCancel(ctx)
	defer cancelStream()
	reason := "host_stopped"
	now := time.Now()
	var manager *pairing.Manager
	var config *tls.Config
	var fingerprint, secret string
	var err error
	if *paired {
		var closer io.Closer
		var pending func(pairing.Pending)
		if ui != nil {
			pending = func(p pairing.Pending) {
				ui.emit(desktop.Event{Kind: "pending", Pending: desktop.Pending{ID: p.ID, Name: p.Label, Key: p.Fingerprint}})
			}
		}
		manager, config, closer, err = openPairedStream(ip, *stateDirectory, stdout, pending)
		if err != nil {
			fmt.Fprintln(stderr, "Cannot open protected pairing state. Check identity status and stop any other paired listener using this state directory.")
			return 1
		}
		defer closer.Close()
	} else {
		var certificate tls.Certificate
		certificate, fingerprint, err = session.Identity(ip, now)
		if err != nil {
			fmt.Fprintln(stderr, "Unable to create TLS identity")
			return 1
		}
		config = &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{certificate}}
		secret, err = session.Secret()
		if err != nil {
			fmt.Fprintln(stderr, "Unable to create invitation")
			return 1
		}
	}
	var listener net.Listener
	var remoteConfig rendezvous.RemoteConfig
	var iceCache *rendezvous.ICECache
	var formatInvitation func(string) string
	if *remote {
		remoteConfig, err = loadRemote(*stateDirectory)
		if err != nil {
			fmt.Fprintln(stderr, "Remote settings unavailable. Use remote import --config <private JSON> first.")
			return 1
		}
		iceCache = rendezvous.NewICECache(remoteConfig, nil)
		listener, err = rendezvous.Listen(streamContext, remoteConfig, nil)
		formatInvitation = remoteConfig.Invitation
		fmt.Fprintf(stdout, "Remote signaling: %s · Force TURN relay: %t\n", remoteConfig.URL, remoteConfig.ForceRelay)
	} else {
		listener, err = net.Listen("tcp4", net.JoinHostPort(*host, strconv.Itoa(*port)))
	}
	if err != nil {
		fmt.Fprintln(stderr, "Cannot listen on that address/port; use this PC's LAN address and an unused port")
		return 1
	}
	defer listener.Close()
	var localListener net.Listener
	if *remote {
		localListener, err = net.Listen("tcp4", net.JoinHostPort(*host, strconv.Itoa(*port)))
		if err != nil {
			fmt.Fprintln(stderr, "Direct LAN signaling unavailable: cannot bind the configured LAN address/port. Rendezvous remains available.")
		} else {
			defer localListener.Close()
			fmt.Fprintln(stdout, "Direct LAN signaling available at the configured host/port. Connect tries LAN first; network recovery tries rendezvous first.")
		}
	}
	expires := now.Add(*lifetime)
	var retention *diagnostics.Retention
	if !*noLog && *logRetention > 0 {
		retention = diagnostics.NewRetention(streamContext, *logDirectory, *logRetention, func(err error) {
			message := "Some old connection logs could not be removed; audio can continue."
			fmt.Fprintln(stderr, message)
			ui.emit(desktop.Event{Kind: "message", Message: message})
		})
	}
	var desktopSession atomic.Uint64
	makeFactory := func(microphone, duplex bool) session.Factory {
		return func(started time.Time, offer session.OfferOptions) (session.Resources, error) {
			sessionID := desktopSession.Add(1)
			ui.emit(desktopSessionBegin(sessionID, offer))
			source := diagnostics.DesktopCapture
			if duplex {
				source = diagnostics.DuplexCapture
				if *probe {
					source = diagnostics.DuplexProbe
				}
			} else if microphone {
				source = diagnostics.PhoneMicrophone
			} else if *probe {
				source = diagnostics.StereoProbe
			}
			var recorder *diagnostics.Log
			var path string
			if !*noLog {
				var logErr error
				recorder, path, logErr = diagnostics.CreateInDirectory(*logDirectory, source, started)
				retention.Request()
				if logErr != nil {
					fmt.Fprintln(stderr, "Combined log could not be created. Audio can continue; use Android's copy report fallback.")
				}
			}
			fmt.Fprintln(stdout, "Session initializing.")
			if recorder != nil {
				fmt.Fprintln(stdout, "Combined session log:", path)
			}
			resources := session.Resources{ID: sessionID, Log: recorder, End: func(ended string, logError error, finalStatus *rtc.Status) {
				retention.Request()
				if logError != nil {
					fmt.Fprintln(stderr, logError)
				}
				fmt.Fprintln(stdout, "Session ended:", ended)
				ui.emit(desktop.Event{Kind: "session_end", Session: sessionID, Message: ended})
				if ended == "offer_failed" {
					if finalStatus != nil && finalStatus.ICEGathering != nil {
						g := finalStatus.ICEGathering
						fmt.Fprintf(stderr, "ICE gathering: %s; relay candidates: %d; elapsed: %d ms.\n", g.Result, g.RelayCandidates, g.ElapsedMS)
					}
					if recorder != nil {
						fmt.Fprintln(stderr, "See offer_failure and Windows ICE gathering details in the combined log.")
					}
				}
				if ended == "microphone_bridge_failed" {
					if finalStatus != nil && finalStatus.BridgeErrorOperation != "" {
						fmt.Fprintf(stderr, "Microphone bridge failed: %s (HRESULT 0x%08X).\n", finalStatus.BridgeErrorOperation, uint32(finalStatus.BridgeErrorHRESULT))
					} else {
						fmt.Fprintln(stderr, "Microphone bridge failed; native failure details are unavailable.")
					}
					fmt.Fprintln(stderr, "Check the final Windows status in the combined log. If the cable endpoint changed, refresh the --microphone-device render ID with bridge-devices.")
				}
				if recorder != nil {
					if logError == nil {
						fmt.Fprintln(stdout, "Combined session log finalized:", path)
					} else {
						fmt.Fprintln(stdout, "Combined session log (finalization incomplete):", path)
					}
				}
				// A session can finish while the entire host is stopping. Expiry
				// closes the session inside Check, before the main loop returns.
				if streamContext.Err() == nil && (*paired || time.Now().Before(expires)) {
					if *paired {
						fmt.Fprintln(stdout, "Waiting for a paired phone to reconnect.")
					} else {
						fmt.Fprintln(stdout, "Waiting for another connection with the same link (until host shutdown or link expiry).")
					}
				}
			}, LogWarning: func() {
				fmt.Fprintln(stderr, "Combined logging stopped (disk error or size limit); audio continues. Use Android's copy report fallback.")
			}}
			var peer rtc.Peer
			var openErr error
			if ui != nil {
				devices, deviceErr := desktopAudioDevices()
				if deviceErr == nil {
					deviceErr = desktop.ValidateDevices(desktop.Settings{CaptureDevice: *device, MicrophoneDevice: *microphoneDevice}, devices)
				}
				if deviceErr != nil {
					return resources, deviceErr
				}
			}
			peerOptions := rtc.Options{EnableRenomination: iceCache != nil, ContinuousICE: iceCache != nil && offer.ContinuousICE}
			if duplex {
				fmt.Fprintln(stdout, "Duplex session. Desktop audio and phone microphone share this connection; cable output starts muted.")
				peer, openErr = rtc.OpenDuplex(*device, *microphoneDevice, *probe, peerOptions)
			} else if microphone {
				fmt.Fprintln(stdout, "Phone microphone session. Desktop loopback capture is off; cable output starts muted.")
				peer, openErr = rtc.OpenMicrophone(*microphoneDevice, peerOptions)
			} else {
				peer, openErr = rtc.Open(*device, *probe, peerOptions)
			}
			if openErr == nil && iceCache != nil {
				openErr = rtc.SetICEProvider(peer, remoteICEProvider(remoteConfig.ForceRelay, func() (rendezvous.ICEConfiguration, error) {
					return iceCache.Get(streamContext)
				}))
			}
			resources.Peer = peer
			return resources, openErr
		}
	}
	factory := makeFactory(false, false)
	var control *session.Host
	if *paired {
		control, err = session.NewPairedHost(manager, factory)
		if err != nil {
			fmt.Fprintln(stderr, "Cannot initialize paired listener")
			return 1
		}
	} else {
		control = session.NewHost(secret, expires, factory)
	}
	if microphoneFlag {
		control.EnableMicrophoneReturn(makeFactory(true, false))
		control.EnableDuplex(makeFactory(true, true))
	}
	if *revokeAll {
		// Argument checks, the exclusive protected-state lock and listener bind
		// have succeeded. Clear approvals before serving HTTP or opening --pair.
		if err := revokeAllPairings(manager, control, stdout); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
	}
	server := streamServer(control, config, !*remote)
	servers := []*http.Server{server}
	done := make(chan error, 2)
	serve := func(server *http.Server, listener net.Listener) {
		go func() {
			err := server.Serve(tls.NewListener(listener, server.TLSConfig))
			cancelStream()
			done <- err
		}()
	}
	serve(server, listener)
	if localListener != nil {
		localServer := streamServer(control, config, true)
		servers = append(servers, localServer)
		serve(localServer, localListener)
	}
	var advertisement *discovery.Advertisement
	defer func() {
		cancelStream()
		shutdownStreams(servers, func() {
			control.Close(reason)
			advertisement.Close()
		})
		fmt.Fprintln(stdout, "Stopped.")
	}()
	var commands <-chan string
	if *paired {
		if !*noDiscovery && !*remote {
			advertisement, err = discovery.Start(ip, *port, manager.HostKey())
			if err != nil {
				fmt.Fprintln(stderr, "LAN discovery unavailable. QR/manual connections still work; check multicast and Private-network firewall access.")
			} else {
				fmt.Fprintln(stdout, "LAN discovery:", advertisement.Name, "(Android: Find Windows on LAN).")
			}
		} else {
			fmt.Fprintln(stdout, "LAN discovery disabled. QR/manual connections remain available.")
		}
		fmt.Fprintln(stdout, "Paired playback ready. Stop ends only the current stream; restarting Windows preserves approved phones.")
		if microphoneFlag {
			fmt.Fprintln(stdout, "Phone microphone and duplex available to approved devices. Android: Send phone microphone, or Listen + send microphone for both directions.")
		}
		fmt.Fprintln(stdout, pairingHelp)
		if *pair {
			if err := printPairing(manager, ip.String(), *port, stdout, formatInvitation); err != nil {
				fmt.Fprintln(stderr, err)
				return 1
			}
		}
		if ui == nil {
			commands = pairingCommands(streamContext, os.Stdin)
		}
	} else {
		invitation := session.Invitation{Host: ip.String(), Port: *port, Fingerprint: fingerprint, Token: secret, ExpiresAt: expires.Unix()}
		fmt.Fprintln(stdout, "Paste this private, reusable connection link into MicDrop on Android:")
		fmt.Fprintln(stdout, invitation.String())
		fmt.Fprintln(stdout, "Connection link expires:", expires.Format(time.RFC3339))
		fmt.Fprintln(stdout, "Stop ends only the current stream. Reconnect on Android to start another; Ctrl+C stops the host and revokes this link.")
	}
	fmt.Fprintln(stdout, "Waiting for a connection. No capture or session log is opened while idle.")
	var desktopCommands <-chan desktop.Command
	if ui != nil {
		desktopCommands = ui.Commands
		message := "LAN control: " + net.JoinHostPort(*host, strconv.Itoa(*port))
		if *remote {
			message += " · Remote configured (reachability checked when connecting)"
			if localListener == nil {
				message = "LAN listener unavailable; remote configured. Stop and check the adapter/port."
			}
		}
		ui.emit(desktop.Event{Kind: "ready", Message: message})
		ui.phones(manager)
	}
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case command, ok := <-desktopCommands:
			if !ok {
				desktopCommands = nil
				continue
			}
			if streamContext.Err() == nil {
				ui.command(command, manager, control, ip.String(), *port, formatInvitation)
			}
		case line, ok := <-commands:
			if !ok {
				commands = nil
				if streamContext.Err() == nil {
					fmt.Fprintln(stdout, "Console input closed; local approval commands are unavailable.")
				}
				continue
			}
			if pairingCommand(line, manager, control, ip.String(), *port, stdout, stderr, formatInvitation) {
				return 0
			}
		case <-ctx.Done():
			return 0
		case <-done:
			reason = "listener_stopped"
			fmt.Fprintln(stderr, "Control listener stopped")
			return 1
		case <-ticker.C:
			sessionID := desktopSession.Load()
			status, checkErr := control.Check()
			if status != nil {
				ui.emit(desktop.Event{Kind: "session_status", Session: sessionID, State: status.State})
				if ui != nil {
					if phone := control.PhoneStatus(); phone != nil && phone.Session == sessionID {
						row := desktopPhoneState(phone, status)
						ui.emit(desktop.Event{Kind: "phone_state", Session: sessionID, Connection: &row})
					}
				}
			}
			if status != nil && !*paired {
				_ = writeJSON(stdout, status)
			}
			if checkErr != nil {
				reason = "connection_link_expired"
				fmt.Fprintln(stdout, checkErr)
				return 0
			}
		}
	}
}

func streamServer(control http.Handler, config *tls.Config, local bool) *http.Server {
	if local {
		control = session.LocalSignaling(control)
	}
	return &http.Server{Handler: control, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second,
		WriteTimeout: 40 * time.Second, IdleTimeout: 20 * time.Second, MaxHeaderBytes: 4096,
		ErrorLog: log.New(io.Discard, "", 0), TLSConfig: config}
}

func shutdownStreams(servers []*http.Server, stopMedia func()) {
	// Stop capture first, then allow an in-flight Stop acknowledgment to flush.
	// Closing the listener/connections immediately can turn an intentional Stop
	// into an unconfirmed one even after the handler accepted it.
	stopMedia()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	var finished sync.WaitGroup
	for _, server := range servers {
		finished.Add(1)
		go func() {
			defer finished.Done()
			_ = server.Shutdown(ctx)
			_ = server.Close() // Bound cleanup even if a handler fails to finish.
		}()
	}
	finished.Wait()
}

// Both streams share the lock in case stdout and stderr use the same writer.
type lockedWriter struct {
	mu     *sync.Mutex
	writer io.Writer
}

func (w *lockedWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.writer.Write(p)
}
