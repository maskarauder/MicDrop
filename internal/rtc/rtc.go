// Package rtc exposes the native WebRTC DLL without putting Go on an audio thread.
package rtc

// Options are chosen before native creation. Zero values retain LAN behavior.
type Options struct {
	EnableRenomination bool
	ContinuousICE      bool
}

type Status struct {
	State                string   `json:"state"`
	CaptureFailed        bool     `json:"capture_failed"`
	SourceRate           uint32   `json:"source_rate_hz"`
	SourceChannels       uint32   `json:"source_channels"`
	PCMFramesSent        uint64   `json:"pcm_frames_sent"`
	DecodedFrames        uint64   `json:"decoded_nonzero_frames"`
	DistinctStereoFrames uint64   `json:"decoded_distinct_stereo_frames"`
	PacketsSent          uint64   `json:"packets_sent"`
	BytesSent            uint64   `json:"bytes_sent"`
	Opus                 bool     `json:"opus"`
	EncoderChannels      uint32   `json:"encoder_channels"`
	EncoderPacketMS      uint32   `json:"encoder_packet_ms_at_creation"`
	InitialBitrate       uint32   `json:"encoder_bitrate_bps_at_creation"`
	TargetBitrate        *float64 `json:"target_bitrate_bps"`
	Direction            string   `json:"audio_direction,omitempty"`
	BridgeFailed         bool     `json:"bridge_failed"`
	BridgeErrorHRESULT   int32    `json:"bridge_error_hresult,omitempty"`
	BridgeErrorOperation string   `json:"bridge_error_operation,omitempty"`
	MicrophoneMuted      bool     `json:"microphone_muted"`
	ReturnPackets        uint64   `json:"return_packets_received"`
	ReturnBytes          uint64   `json:"return_bytes_received"`
	BridgeFrames         uint64   `json:"bridge_frames_submitted"`
	BridgeNonzeroFrames  uint64   `json:"bridge_nonzero_frames_provided"`
	BridgeBufferFrames   uint32   `json:"bridge_buffer_frames"`
	BridgeMixRate        uint32   `json:"bridge_mix_rate_hz"`
	BridgeMixChannels    uint32   `json:"bridge_mix_channels"`
	ICERestarts          uint64   `json:"ice_restarts,omitempty"`
	RecoveryPending      bool     `json:"ice_recovery_pending,omitempty"`
	ICEGenerationCurrent bool     `json:"ice_generation_current"`

	ContinuousICE   *ContinuousStatus `json:"continuous_ice_status,omitempty"`
	TrickleICE      *TrickleStatus    `json:"trickle_ice,omitempty"`
	ICEGathering    *ICEGathering     `json:"ice_gathering,omitempty"`
	MediaTransport  *MediaTransport   `json:"media_transport,omitempty"`
	RouteSelection  *RouteSelection   `json:"route_selection,omitempty"`
	TLSVerification *TLSVerification  `json:"tls_certificate_verification,omitempty"`
}

// TLSVerification counts Windows trust-store fallback checks for TURN/TLS.
// It excludes names, certificates and credentials. Success here is a chain
// result only: WebRTC separately verifies the hostname and establishes TURN.
type TLSVerification struct {
	Checks        uint32 `json:"checks"`
	Failures      uint32 `json:"failures"`
	LastErrorCode uint32 `json:"last_error_code"`
}

// ICEGathering describes setup progress, not the selected or proven media path.
// It intentionally excludes candidate addresses, URLs, SDP and credentials.
type ICEGathering struct {
	Result              string `json:"result"`
	ElapsedMS           int64  `json:"elapsed_ms"`
	RelayOnly           bool   `json:"relay_only"`
	HostCandidates      uint32 `json:"host_candidates"`
	ReflexiveCandidates uint32 `json:"reflexive_candidates"`
	RelayCandidates     uint32 `json:"relay_candidates"`
	OtherCandidates     uint32 `json:"other_candidates"`
	MediaSections       uint32 `json:"media_sections"`
	ReadySections       uint32 `json:"ready_sections"`
	CandidateErrors     uint32 `json:"candidate_errors"`
	LastErrorCode       int    `json:"last_error_code"`
}

// RestartPeer renegotiates connectivity on the existing authenticated peer.
// It never allocates a new microphone session or changes its audio direction.
type RestartPeer interface {
	Peer
	RestartOffer() (string, error)
}

// MicrophonePeer is implemented only by an explicitly configured return peer.
// Control is serialized with the session's authenticated answer/status/stop.
type MicrophonePeer interface {
	Peer
	SetMicrophoneMuted(bool) error
}

type Peer interface {
	Offer() (string, error)
	Answer(string) error
	Status() (Status, error)
	Close()
}
