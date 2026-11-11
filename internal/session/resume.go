package session

import "net/http"

const sessionResumeHeader = "X-MicDrop-Session-Resume"
const sessionResumeReasonHeader = "X-MicDrop-Session-Resume-Reason"

// Fixed presentation labels. A well-formed unknown token is unspecified, so a
// newer phone's reason never turns a resume into a failed offer.
var sessionResumeReasons = map[string]bool{"manual": true, "automatic": true, "focus_regain": true}

// This authenticated v3 offer hint affects only desktop notification continuity.
// It cannot resume media, bypass pairing, or grant microphone capture consent.
func readSessionResume(r *http.Request, version int) (bool, string, bool) {
	values := r.Header.Values(sessionResumeHeader)
	reasons := r.Header.Values(sessionResumeReasonHeader)
	if len(values) == 0 {
		return false, "", len(reasons) == 0
	}
	if version != 3 || len(values) != 1 || values[0] != "1" {
		return false, "", false
	}
	if len(reasons) == 0 {
		return true, "", true
	}
	if len(reasons) != 1 || !resumeReasonToken(reasons[0]) {
		return false, "", false
	}
	if !sessionResumeReasons[reasons[0]] {
		return true, "", true
	}
	return true, reasons[0], true
}

func resumeReasonToken(value string) bool {
	if len(value) == 0 || len(value) > 32 {
		return false
	}
	for _, c := range value {
		if (c < 'a' || c > 'z') && c != '_' {
			return false
		}
	}
	return true
}
