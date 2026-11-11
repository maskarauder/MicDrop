//go:build !windows

package rtc

import "errors"

func Open(_ string, _ bool, _ ...Options) (Peer, error) {
	return nil, errors.New("the WebRTC streaming harness requires Windows x64")
}

func OpenMicrophone(_ string, _ ...Options) (Peer, error) {
	return nil, errors.New("WebRTC microphone return requires the Windows x64 artifact")
}

func OpenDuplex(_, _ string, _ bool, _ ...Options) (Peer, error) {
	return nil, errors.New("WebRTC duplex requires the Windows x64 artifact")
}
