package rtc

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"syscall"
	"unsafe"
)

type rtcDLL struct {
	dll                                       *syscall.DLL
	create, createDuplex                      *syscall.Proc
	offer, answer, status, destroy            *syscall.Proc
	microphoneMute                            *syscall.Proc
	restartOffer                              *syscall.Proc
	configureICE                              *syscall.Proc
	trickleOffer, localICE, addICE, removeICE *syscall.Proc
}

// Keep micdrop_rtc.dll pinned for the process lifetime once verified. Unloading
// and reloading libwebrtc/BoringSSL per session leaks static allocations and can
// leave thread-exit FLS callbacks pointing into unmapped code.
var loadRTCDLL = sync.OnceValues(func() (*rtcDLL, error) {
	exe, err := os.Executable()
	if err != nil {
		return nil, err
	}
	path := filepath.Join(filepath.Dir(exe), "micdrop_rtc.dll")
	wide, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	// Resolve only beside this executable and in trusted system directories.
	load := syscall.NewLazyDLL("kernel32.dll").NewProc("LoadLibraryExW")
	handle, _, _ := load.Call(uintptr(unsafe.Pointer(wide)), 0, 0x100|0x1000)
	runtime.KeepAlive(wide)
	if handle == 0 {
		return nil, fmt.Errorf("cannot load micdrop_rtc.dll beside the executable; extract the complete Windows artifact")
	}
	dll := &syscall.DLL{Name: path, Handle: syscall.Handle(handle)}
	lib := &rtcDLL{dll: dll}
	var abi *syscall.Proc
	for name, dest := range map[string]**syscall.Proc{
		"mdr_abi_version":              &abi,
		"mdr_create_configured":        &lib.create,
		"mdr_create_duplex_configured": &lib.createDuplex,
		"mdr_offer":                    &lib.offer,
		"mdr_answer":                   &lib.answer,
		"mdr_status":                   &lib.status,
		"mdr_destroy":                  &lib.destroy,
		"mdr_microphone_mute":          &lib.microphoneMute,
		"mdr_restart_offer":            &lib.restartOffer,
		"mdr_configure_ice":            &lib.configureICE,
		"mdr_trickle_offer":            &lib.trickleOffer,
		"mdr_local_ice":                &lib.localICE,
		"mdr_add_ice":                  &lib.addICE,
		"mdr_remove_ice":               &lib.removeICE,
	} {
		*dest, err = dll.FindProc(name)
		if err != nil {
			dll.Release()
			return nil, errors.New("incompatible WebRTC DLL")
		}
	}
	version, _, _ := abi.Call()
	if version != 8 {
		dll.Release()
		return nil, errors.New("incompatible WebRTC ABI")
	}
	return lib, nil
})

type nativePeer struct {
	mu                    sync.Mutex
	lib                   *rtcDLL
	handle                uintptr
	continuous, relayOnly bool
	iceProvider           ICEProvider
	localSignaling        bool
	microphone            bool
}

func Open(endpoint string, probe bool, options ...Options) (Peer, error) {
	source := 0
	if probe {
		source = 1
	}
	return open(endpoint, source, "", options...)
}

func OpenMicrophone(endpoint string, options ...Options) (Peer, error) {
	return open(endpoint, 3, "", options...)
}

func OpenDuplex(endpoint, microphoneEndpoint string, probe bool, options ...Options) (Peer, error) {
	source := 5
	if probe {
		source = 6
	}
	return open(endpoint, source, microphoneEndpoint, options...)
}

func open(endpoint string, source int, microphoneEndpoint string, options ...Options) (Peer, error) {
	if len(options) > 1 {
		return nil, errors.New("invalid peer options")
	}
	renomination, continuous := uintptr(0), uintptr(0)
	if len(options) == 1 && options[0].EnableRenomination {
		renomination = 1
	}
	if len(options) == 1 && options[0].ContinuousICE {
		continuous = 1
	}
	lib, err := loadRTCDLL()
	if err != nil {
		return nil, err
	}
	p := &nativePeer{lib: lib, microphone: source == 3 || source == 5 || source == 6, continuous: continuous == 1}
	id, err := syscall.BytePtrFromString(endpoint)
	if err != nil {
		return nil, err
	}
	message := make([]byte, 512)
	var result uintptr
	if source == 5 || source == 6 {
		renderID, stringErr := syscall.BytePtrFromString(microphoneEndpoint)
		if stringErr != nil {
			return nil, stringErr
		}
		probe := uintptr(source - 5)
		result, _, _ = lib.createDuplex.Call(probe, uintptr(unsafe.Pointer(id)), uintptr(unsafe.Pointer(renderID)), renomination, continuous, uintptr(unsafe.Pointer(&p.handle)), uintptr(unsafe.Pointer(&message[0])), uintptr(len(message)))
		runtime.KeepAlive(renderID)
	} else {
		result, _, _ = lib.create.Call(uintptr(source), uintptr(unsafe.Pointer(id)), renomination, continuous, uintptr(unsafe.Pointer(&p.handle)), uintptr(unsafe.Pointer(&message[0])), uintptr(len(message)))
	}
	runtime.KeepAlive(id)
	if result != 0 {
		return nil, nativeError(message)
	}
	return p, nil
}

func (p *nativePeer) SetMicrophoneMuted(muted bool) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.handle == 0 || !p.microphone {
		return errors.New("microphone session unavailable")
	}
	value := uintptr(0)
	if muted {
		value = 1
	}
	message := make([]byte, 512)
	result, _, _ := p.lib.microphoneMute.Call(p.handle, value, uintptr(unsafe.Pointer(&message[0])), uintptr(len(message)))
	if result != 0 {
		return nativeError(message)
	}
	return nil
}

func nativeError(message []byte) error {
	message = bytes.TrimRight(message, "\x00")
	if len(message) == 0 {
		return errors.New("native WebRTC operation failed")
	}
	return errors.New(string(message))
}
func (p *nativePeer) Offer() (string, error) {
	return p.localOffer(p.lib.offer)
}
func (p *nativePeer) TrickleOffer() (string, error) { return p.localOffer(p.lib.trickleOffer) }

func (p *nativePeer) LocalICE() (string, bool, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.handle == 0 {
		return "", false, errors.New("session closed")
	}
	sdp, message := make([]byte, 65537), make([]byte, 512)
	var complete int32
	result, _, _ := p.lib.localICE.Call(p.handle, uintptr(unsafe.Pointer(&sdp[0])), uintptr(len(sdp)),
		uintptr(unsafe.Pointer(&complete)), uintptr(unsafe.Pointer(&message[0])), uintptr(len(message)))
	if result != 0 {
		return "", false, nativeError(message)
	}
	return string(bytes.TrimRight(sdp, "\x00")), complete != 0, nil
}

func (p *nativePeer) ForceRelay() bool               { p.mu.Lock(); defer p.mu.Unlock(); return p.relayOnly }
func (p *nativePeer) ContinuousICE() bool            { return p.continuous }
func (p *nativePeer) AddICE(c ICECandidate) error    { return p.changeICE(c, p.lib.addICE) }
func (p *nativePeer) RemoveICE(c ICECandidate) error { return p.changeICE(c, p.lib.removeICE) }
func (p *nativePeer) changeICE(c ICECandidate, operation *syscall.Proc) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.handle == 0 {
		return errors.New("session closed")
	}
	mid, e1 := syscall.BytePtrFromString(c.MID)
	ufrag, e2 := syscall.BytePtrFromString(c.Ufrag)
	candidate, e3 := syscall.BytePtrFromString(c.Candidate)
	if e1 != nil || e2 != nil || e3 != nil {
		return errors.New("invalid ICE candidate")
	}
	message := make([]byte, 512)
	result, _, _ := operation.Call(p.handle, uintptr(unsafe.Pointer(mid)), uintptr(c.Index), uintptr(unsafe.Pointer(ufrag)),
		uintptr(unsafe.Pointer(candidate)), uintptr(unsafe.Pointer(&message[0])), uintptr(len(message)))
	runtime.KeepAlive(mid)
	runtime.KeepAlive(ufrag)
	runtime.KeepAlive(candidate)
	if result != 0 {
		return nativeError(message)
	}
	return nil
}
func (p *nativePeer) RestartOffer() (string, error) {
	return p.localOffer(p.lib.restartOffer)
}
func (p *nativePeer) localOffer(operation *syscall.Proc) (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.handle == 0 {
		return "", errors.New("session closed")
	}
	if p.iceProvider != nil {
		config, err := p.iceProvider(p.localSignaling)
		if err != nil {
			return "", &offerError{stage: "ice_configuration_fetch", cause: err}
		}
		if err = p.applyICE(config); err != nil {
			return "", &offerError{stage: "ice_configuration_apply", cause: err}
		}
	}
	sdp, message := make([]byte, 65537), make([]byte, 512)
	result, _, _ := operation.Call(p.handle, uintptr(unsafe.Pointer(&sdp[0])), uintptr(len(sdp)), uintptr(unsafe.Pointer(&message[0])), uintptr(len(message)))
	if result != 0 {
		return "", nativeError(message)
	}
	return string(bytes.TrimRight(sdp, "\x00")), nil
}

func (p *nativePeer) setICEProvider(provider ICEProvider) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.iceProvider = provider
}
func (p *nativePeer) SetLocalSignaling(local bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.localSignaling = local
}

type nativeICEServer struct {
	url, username, credential *byte
}

type configureICECall func(handle uintptr, servers *nativeICEServer, count, force uintptr, message *byte, messageLen uintptr) uintptr

func (p *nativePeer) callConfigureICE(handle uintptr, servers *nativeICEServer, count, force uintptr, message *byte, messageLen uintptr) uintptr {
	result, _, _ := p.lib.configureICE.Call(
		handle,
		uintptr(unsafe.Pointer(servers)),
		count,
		force,
		uintptr(unsafe.Pointer(message)),
		messageLen,
	)
	runtime.KeepAlive(servers)
	runtime.KeepAlive(message)
	return result
}

func (p *nativePeer) applyICE(config ICEConfig) error {
	if err := applyICEWith(p.callConfigureICE, p.handle, config); err != nil {
		return err
	}
	p.relayOnly = config.ForceRelay
	return nil
}

func applyICEWith(call configureICECall, handle uintptr, config ICEConfig) error {
	if len(config.Servers) > 8 {
		return errors.New("too many ICE servers")
	}
	servers := make([]nativeICEServer, len(config.Servers))
	for i, s := range config.Servers {
		values := []string{s.URL, s.Username, s.Credential}
		dest := []**byte{&servers[i].url, &servers[i].username, &servers[i].credential}
		for j, value := range values {
			if len(value) > 512 {
				return errors.New("invalid ICE server")
			}
			b, err := syscall.BytePtrFromString(value)
			if err != nil {
				return errors.New("invalid ICE server")
			}
			*dest[j] = b
		}
	}
	var serversPtr *nativeICEServer
	if len(servers) > 0 {
		serversPtr = &servers[0]
	}
	force := uintptr(0)
	if config.ForceRelay {
		force = 1
	}
	message := make([]byte, 512)
	result := call(handle, serversPtr, uintptr(len(servers)), force, &message[0], uintptr(len(message)))
	runtime.KeepAlive(servers)
	runtime.KeepAlive(message)
	if result != 0 {
		return nativeError(message)
	}
	return nil
}
func (p *nativePeer) Answer(sdp string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.handle == 0 {
		return errors.New("session closed")
	}
	if len(sdp) > 65536 {
		return errors.New("SDP too large")
	}
	value, err := syscall.BytePtrFromString(sdp)
	if err != nil {
		return err
	}
	message := make([]byte, 512)
	result, _, _ := p.lib.answer.Call(p.handle, uintptr(unsafe.Pointer(value)), uintptr(unsafe.Pointer(&message[0])), uintptr(len(message)))
	runtime.KeepAlive(value)
	if result != 0 {
		return nativeError(message)
	}
	return nil
}
func (p *nativePeer) Status() (Status, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	var status Status
	if p.handle == 0 {
		return status, errors.New("session closed")
	}
	buffer := make([]byte, 4096)
	result, _, _ := p.lib.status.Call(p.handle, uintptr(unsafe.Pointer(&buffer[0])), uintptr(len(buffer)))
	if result != 0 {
		return status, errors.New("WebRTC statistics unavailable")
	}
	err := json.Unmarshal(bytes.TrimRight(buffer, "\x00"), &status)
	return status, err
}
func (p *nativePeer) Close() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.handle != 0 {
		p.lib.destroy.Call(p.handle)
		p.handle = 0
	}
}
