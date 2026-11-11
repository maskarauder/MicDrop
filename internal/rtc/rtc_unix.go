// SPDX-License-Identifier: MPL-2.0
//go:build (linux && amd64) || (darwin && arm64)

package rtc

/*
#cgo linux LDFLAGS: -ldl

#include "../../native/rtc/capi.h"
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  void* handle;
  uint32_t (*abi_version)(void);
  int (*create_configured)(int, const char*, int, int, mdr_peer**, char*, size_t);
  int (*create_duplex_configured)(int, const char*, const char*, int, int, mdr_peer**, char*, size_t);
  int (*offer)(mdr_peer*, char*, size_t, char*, size_t);
  int (*trickle_offer)(mdr_peer*, char*, size_t, char*, size_t);
  int (*local_ice)(mdr_peer*, char*, size_t, int*, char*, size_t);
  int (*add_ice)(mdr_peer*, const char*, int, const char*, const char*, char*, size_t);
  int (*remove_ice)(mdr_peer*, const char*, int, const char*, const char*, char*, size_t);
  int (*restart_offer)(mdr_peer*, char*, size_t, char*, size_t);
  int (*answer)(mdr_peer*, const char*, char*, size_t);
  int (*microphone_mute)(mdr_peer*, int, char*, size_t);
  int (*configure_ice)(mdr_peer*, const mdr_ice_server*, size_t, int, char*, size_t);
  int (*status)(mdr_peer*, char*, size_t);
  void (*destroy)(mdr_peer*);
} mdr_unix_lib;

static int mdr_unix_load(const char* path, mdr_unix_lib* out, int* wrong_abi) {
  memset(out, 0, sizeof(*out));
  *wrong_abi = 0;
  void* h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (!h) {
    return 1;
  }
  out->handle = h;
  *(void**)(&out->abi_version) = dlsym(h, "mdr_abi_version");
  *(void**)(&out->create_configured) = dlsym(h, "mdr_create_configured");
  *(void**)(&out->create_duplex_configured) = dlsym(h, "mdr_create_duplex_configured");
  *(void**)(&out->offer) = dlsym(h, "mdr_offer");
  *(void**)(&out->trickle_offer) = dlsym(h, "mdr_trickle_offer");
  *(void**)(&out->local_ice) = dlsym(h, "mdr_local_ice");
  *(void**)(&out->add_ice) = dlsym(h, "mdr_add_ice");
  *(void**)(&out->remove_ice) = dlsym(h, "mdr_remove_ice");
  *(void**)(&out->restart_offer) = dlsym(h, "mdr_restart_offer");
  *(void**)(&out->answer) = dlsym(h, "mdr_answer");
  *(void**)(&out->microphone_mute) = dlsym(h, "mdr_microphone_mute");
  *(void**)(&out->configure_ice) = dlsym(h, "mdr_configure_ice");
  *(void**)(&out->status) = dlsym(h, "mdr_status");
  *(void**)(&out->destroy) = dlsym(h, "mdr_destroy");

  if (!out->abi_version || !out->create_configured || !out->create_duplex_configured ||
      !out->offer || !out->trickle_offer || !out->local_ice || !out->add_ice ||
      !out->remove_ice || !out->restart_offer || !out->answer || !out->microphone_mute ||
      !out->configure_ice || !out->status || !out->destroy) {
    dlclose(h);
    memset(out, 0, sizeof(*out));
    return 2;
  }
  if (out->abi_version() != 8) {
    *wrong_abi = 1;
    dlclose(h);
    memset(out, 0, sizeof(*out));
    return 3;
  }
  return 0;
}

static int mdr_unix_create(
    const mdr_unix_lib* lib, int source, const char* endpoint,
    int renomination, int continuous, uintptr_t* peer_out,
    char* err_buf, size_t err_size) {
  mdr_peer* raw = NULL;
  int rc = lib->create_configured(source, endpoint, renomination, continuous, &raw, err_buf, err_size);
  *peer_out = (uintptr_t)raw;
  return rc;
}

static int mdr_unix_create_duplex(
    const mdr_unix_lib* lib, int probe, const char* capture_endpoint,
    const char* render_endpoint, int renomination, int continuous,
    uintptr_t* peer_out, char* err_buf, size_t err_size) {
  mdr_peer* raw = NULL;
  int rc = lib->create_duplex_configured(
      probe, capture_endpoint, render_endpoint, renomination, continuous, &raw, err_buf, err_size);
  *peer_out = (uintptr_t)raw;
  return rc;
}

static int mdr_unix_offer_kind(
    const mdr_unix_lib* lib, uintptr_t peer, int kind,
    char* sdp, size_t capacity, char* err_buf, size_t err_size) {
  mdr_peer* p = (mdr_peer*)peer;
  if (kind == 1) return lib->trickle_offer(p, sdp, capacity, err_buf, err_size);
  if (kind == 2) return lib->restart_offer(p, sdp, capacity, err_buf, err_size);
  return lib->offer(p, sdp, capacity, err_buf, err_size);
}

static int mdr_unix_local_ice(
    const mdr_unix_lib* lib, uintptr_t peer,
    char* sdp, size_t capacity, int* complete, char* err_buf, size_t err_size) {
  return lib->local_ice((mdr_peer*)peer, sdp, capacity, complete, err_buf, err_size);
}

static int mdr_unix_change_ice(
    const mdr_unix_lib* lib, uintptr_t peer, int remove,
    const char* mid, int index, const char* ufrag, const char* candidate,
    char* err_buf, size_t err_size) {
  if (remove) {
    return lib->remove_ice((mdr_peer*)peer, mid, index, ufrag, candidate, err_buf, err_size);
  }
  return lib->add_ice((mdr_peer*)peer, mid, index, ufrag, candidate, err_buf, err_size);
}

static int mdr_unix_configure_ice(
    const mdr_unix_lib* lib, uintptr_t peer,
    const mdr_ice_server* servers, size_t count, int force_relay,
    char* err_buf, size_t err_size) {
  return lib->configure_ice((mdr_peer*)peer, servers, count, force_relay, err_buf, err_size);
}

static int mdr_unix_answer(
    const mdr_unix_lib* lib, uintptr_t peer, const char* sdp,
    char* err_buf, size_t err_size) {
  return lib->answer((mdr_peer*)peer, sdp, err_buf, err_size);
}

static int mdr_unix_microphone_mute(
    const mdr_unix_lib* lib, uintptr_t peer, int muted,
    char* err_buf, size_t err_size) {
  return lib->microphone_mute((mdr_peer*)peer, muted, err_buf, err_size);
}

static int mdr_unix_status(const mdr_unix_lib* lib, uintptr_t peer, char* json, size_t capacity) {
  return lib->status((mdr_peer*)peer, json, capacity);
}

static void mdr_unix_destroy(const mdr_unix_lib* lib, uintptr_t peer) {
  lib->destroy((mdr_peer*)peer);
}
*/
import "C"

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"unsafe"
)

const (
	offerInitial = 0
	offerTrickle = 1
	offerRestart = 2
)

func rtcSharedLibName() string {
	if runtime.GOOS == "darwin" {
		return "libmicdrop_rtc.dylib"
	}
	return "libmicdrop_rtc.so"
}

func candidateRTCPaths(exePath string) []string {
	name := rtcSharedLibName()
	dir := filepath.Dir(exePath)
	paths := []string{filepath.Join(dir, name)}
	if runtime.GOOS == "darwin" &&
		filepath.Base(dir) == "MacOS" &&
		filepath.Base(filepath.Dir(dir)) == "Contents" {
		paths = append(paths, filepath.Clean(filepath.Join(dir, "..", "Frameworks", name)))
	}
	return paths
}

// Keep libmicdrop_rtc.{so,dylib} pinned for the process lifetime once verified.
// Unloading and reloading libwebrtc/BoringSSL leaks one-time TLS/thread state.
var loadRTCLib = sync.OnceValues(func() (*C.mdr_unix_lib, error) {
	exe, err := os.Executable()
	if err != nil {
		return nil, err
	}
	if resolved, linkErr := filepath.EvalSymlinks(exe); linkErr == nil && filepath.IsAbs(resolved) {
		exe = resolved
	}
	lib := (*C.mdr_unix_lib)(C.calloc(1, C.size_t(unsafe.Sizeof(C.mdr_unix_lib{}))))
	if lib == nil {
		return nil, errors.New("out of memory loading WebRTC library")
	}
	for _, candidate := range candidateRTCPaths(exe) {
		if !filepath.IsAbs(candidate) {
			continue
		}
		if info, statErr := os.Stat(candidate); statErr != nil || info.IsDir() {
			continue
		}
		cPath := C.CString(candidate)
		var wrongABI C.int
		rc := C.mdr_unix_load(cPath, lib, &wrongABI)
		C.free(unsafe.Pointer(cPath))
		if rc == 0 {
			return lib, nil
		}
		C.free(unsafe.Pointer(lib))
		if wrongABI != 0 {
			return nil, errors.New("incompatible WebRTC ABI")
		}
		return nil, errors.New("incompatible WebRTC shared library")
	}
	C.free(unsafe.Pointer(lib))
	return nil, fmt.Errorf("cannot load %s beside the executable; extract the complete host artifact", rtcSharedLibName())
})

type nativePeer struct {
	mu                    sync.Mutex
	lib                   *C.mdr_unix_lib
	handle                C.uintptr_t
	continuous, relayOnly bool
	iceProvider           ICEProvider
	localSignaling        bool
	microphone            bool
}

func cStringChecked(s string) (*C.char, error) {
	if strings.IndexByte(s, 0) >= 0 {
		return nil, errors.New("string contains NUL byte")
	}
	return C.CString(s), nil
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
	renomination, continuous := C.int(0), C.int(0)
	if len(options) == 1 && options[0].EnableRenomination {
		renomination = 1
	}
	if len(options) == 1 && options[0].ContinuousICE {
		continuous = 1
	}
	lib, err := loadRTCLib()
	if err != nil {
		return nil, err
	}
	cEndpoint, err := cStringChecked(endpoint)
	if err != nil {
		return nil, err
	}
	defer C.free(unsafe.Pointer(cEndpoint))

	p := &nativePeer{
		lib:        lib,
		microphone: source == 3 || source == 5 || source == 6,
		continuous: continuous == 1,
	}
	message := make([]byte, 512)
	var rc C.int
	if source == 5 || source == 6 {
		cRender, renderErr := cStringChecked(microphoneEndpoint)
		if renderErr != nil {
			return nil, renderErr
		}
		defer C.free(unsafe.Pointer(cRender))
		rc = C.mdr_unix_create_duplex(
			lib, C.int(source-5), cEndpoint, cRender, renomination, continuous,
			&p.handle, (*C.char)(unsafe.Pointer(&message[0])), C.size_t(len(message)))
	} else {
		rc = C.mdr_unix_create(
			lib, C.int(source), cEndpoint, renomination, continuous,
			&p.handle, (*C.char)(unsafe.Pointer(&message[0])), C.size_t(len(message)))
	}
	if rc != 0 {
		return nil, nativeError(message)
	}
	return p, nil
}

func nativeError(message []byte) error {
	message = bytes.TrimRight(message, "\x00")
	if len(message) == 0 {
		return errors.New("native WebRTC operation failed")
	}
	return errors.New(string(message))
}

func (p *nativePeer) SetMicrophoneMuted(muted bool) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.handle == 0 || !p.microphone {
		return errors.New("microphone session unavailable")
	}
	value := C.int(0)
	if muted {
		value = 1
	}
	message := make([]byte, 512)
	rc := C.mdr_unix_microphone_mute(
		p.lib, p.handle, value, (*C.char)(unsafe.Pointer(&message[0])), C.size_t(len(message)))
	if rc != 0 {
		return nativeError(message)
	}
	return nil
}

func (p *nativePeer) Offer() (string, error)        { return p.localOffer(offerInitial) }
func (p *nativePeer) TrickleOffer() (string, error) { return p.localOffer(offerTrickle) }
func (p *nativePeer) RestartOffer() (string, error) { return p.localOffer(offerRestart) }

func (p *nativePeer) LocalICE() (string, bool, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.handle == 0 {
		return "", false, errors.New("session closed")
	}
	sdp, message := make([]byte, 65537), make([]byte, 512)
	var complete C.int
	rc := C.mdr_unix_local_ice(
		p.lib, p.handle, (*C.char)(unsafe.Pointer(&sdp[0])), C.size_t(len(sdp)),
		&complete, (*C.char)(unsafe.Pointer(&message[0])), C.size_t(len(message)))
	if rc != 0 {
		return "", false, nativeError(message)
	}
	return string(bytes.TrimRight(sdp, "\x00")), complete != 0, nil
}

func (p *nativePeer) ForceRelay() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.relayOnly
}
func (p *nativePeer) ContinuousICE() bool            { return p.continuous }
func (p *nativePeer) AddICE(c ICECandidate) error    { return p.changeICE(c, 0) }
func (p *nativePeer) RemoveICE(c ICECandidate) error { return p.changeICE(c, 1) }

func (p *nativePeer) changeICE(c ICECandidate, remove C.int) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.handle == 0 {
		return errors.New("session closed")
	}
	cMID, e1 := cStringChecked(c.MID)
	cUfrag, e2 := cStringChecked(c.Ufrag)
	cCand, e3 := cStringChecked(c.Candidate)
	if cMID != nil {
		defer C.free(unsafe.Pointer(cMID))
	}
	if cUfrag != nil {
		defer C.free(unsafe.Pointer(cUfrag))
	}
	if cCand != nil {
		defer C.free(unsafe.Pointer(cCand))
	}
	if e1 != nil || e2 != nil || e3 != nil {
		return errors.New("invalid ICE candidate")
	}
	message := make([]byte, 512)
	rc := C.mdr_unix_change_ice(
		p.lib, p.handle, remove, cMID, C.int(c.Index), cUfrag, cCand,
		(*C.char)(unsafe.Pointer(&message[0])), C.size_t(len(message)))
	if rc != 0 {
		return nativeError(message)
	}
	return nil
}

func (p *nativePeer) localOffer(kind C.int) (string, error) {
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
	rc := C.mdr_unix_offer_kind(
		p.lib, p.handle, kind,
		(*C.char)(unsafe.Pointer(&sdp[0])), C.size_t(len(sdp)),
		(*C.char)(unsafe.Pointer(&message[0])), C.size_t(len(message)))
	if rc != 0 {
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

func (p *nativePeer) applyICE(config ICEConfig) error {
	if len(config.Servers) > 8 {
		return errors.New("too many ICE servers")
	}
	var cServers *C.mdr_ice_server
	var allocated []*C.char
	defer func() {
		for _, ptr := range allocated {
			C.free(unsafe.Pointer(ptr))
		}
		if cServers != nil {
			C.free(unsafe.Pointer(cServers))
		}
	}()
	if len(config.Servers) > 0 {
		cServers = (*C.mdr_ice_server)(C.calloc(
			C.size_t(len(config.Servers)), C.size_t(unsafe.Sizeof(C.mdr_ice_server{}))))
		if cServers == nil {
			return errors.New("out of memory configuring ICE")
		}
		slice := unsafe.Slice(cServers, len(config.Servers))
		for i, s := range config.Servers {
			if len(s.URL) > 512 || len(s.Username) > 512 || len(s.Credential) > 512 {
				return errors.New("invalid ICE server")
			}
			u, e1 := cStringChecked(s.URL)
			if u != nil {
				allocated = append(allocated, u)
			}
			user, e2 := cStringChecked(s.Username)
			if user != nil {
				allocated = append(allocated, user)
			}
			cred, e3 := cStringChecked(s.Credential)
			if cred != nil {
				allocated = append(allocated, cred)
			}
			if e1 != nil || e2 != nil || e3 != nil {
				return errors.New("invalid ICE server")
			}
			slice[i] = C.mdr_ice_server{url: u, username: user, credential: cred}
		}
	}
	force := C.int(0)
	if config.ForceRelay {
		force = 1
	}
	message := make([]byte, 512)
	rc := C.mdr_unix_configure_ice(
		p.lib, p.handle, cServers, C.size_t(len(config.Servers)), force,
		(*C.char)(unsafe.Pointer(&message[0])), C.size_t(len(message)))
	if rc != 0 {
		return nativeError(message)
	}
	p.relayOnly = config.ForceRelay
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
	cSDP, err := cStringChecked(sdp)
	if err != nil {
		return err
	}
	defer C.free(unsafe.Pointer(cSDP))
	message := make([]byte, 512)
	rc := C.mdr_unix_answer(
		p.lib, p.handle, cSDP, (*C.char)(unsafe.Pointer(&message[0])), C.size_t(len(message)))
	if rc != 0 {
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
	rc := C.mdr_unix_status(p.lib, p.handle, (*C.char)(unsafe.Pointer(&buffer[0])), C.size_t(len(buffer)))
	if rc != 0 {
		return status, errors.New("WebRTC statistics unavailable")
	}
	err := json.Unmarshal(bytes.TrimRight(buffer, "\x00"), &status)
	return status, err
}

func (p *nativePeer) Close() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.handle != 0 {
		C.mdr_unix_destroy(p.lib, p.handle)
		p.handle = 0
	}
}
