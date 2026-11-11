package rtc

import "errors"

type offerError struct {
	stage string
	cause error
}

func (e *offerError) Error() string { return e.cause.Error() }
func (e *offerError) Unwrap() error { return e.cause }

type OfferFailure struct {
	Stage   string `json:"stage"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

// DescribeOfferFailure allowlists native messages. An HTTP/configuration error
// can contain a URL or credential; never copy arbitrary error text into a log.
func DescribeOfferFailure(err error) OfferFailure {
	f := OfferFailure{Stage: "local_description", Code: "offer_failed", Message: "WebRTC could not create the local offer."}
	var setup *offerError
	if errors.As(err, &setup) {
		err = setup.cause
		switch setup.stage {
		case "ice_configuration_fetch":
			return OfferFailure{Stage: setup.stage, Code: "ice_configuration_unavailable", Message: "Remote ICE configuration could not be retrieved."}
		case "ice_configuration_apply":
			return OfferFailure{Stage: setup.stage, Code: "ice_configuration_rejected", Message: "Native WebRTC could not apply the ICE configuration."}
		}
	}
	if err == nil {
		return f
	}
	switch err.Error() {
	case "ICE candidate gathering timed out", "LAN candidate gathering timed out":
		f.Stage, f.Code, f.Message = "ice_gathering", "ice_gathering_timeout", "ICE gathering reached its deadline without an eligible set of candidates."
	case "ICE gathering finished without usable candidates":
		f.Stage, f.Code, f.Message = "ice_gathering", "ice_candidates_unavailable", "ICE gathering finished without candidates that satisfy the session's policy."
	case "WebRTC description failed or timed out":
		f.Code, f.Message = "description_failed_or_timed_out", "WebRTC could not finish setting the local description before its deadline."
	case "Session description unavailable":
		f.Code, f.Message = "description_unavailable", "The local WebRTC description is unavailable."
	case "session closed":
		f.Code, f.Message = "session_closed", "The session closed before offer creation."
	}
	return f
}
