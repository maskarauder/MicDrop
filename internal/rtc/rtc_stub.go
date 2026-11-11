//go:build !((windows && amd64) || (linux && amd64) || (darwin && arm64))

package rtc

import "errors"

func Open(_ string, _ bool, _ ...Options) (Peer, error) {
	return nil, errors.New("the WebRTC streaming harness requires Windows x64, Linux x64, or macOS arm64")
}

func OpenMicrophone(_ string, _ ...Options) (Peer, error) {
	return nil, errors.New("WebRTC microphone return requires Windows x64, Linux x64, or macOS arm64")
}

func OpenDuplex(_, _ string, _ bool, _ ...Options) (Peer, error) {
	return nil, errors.New("WebRTC duplex requires Windows x64, Linux x64, or macOS arm64")
}
