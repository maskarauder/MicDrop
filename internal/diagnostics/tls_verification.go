package diagnostics

// TLSVerification is Android's bounded platform trust fallback result. It
// excludes certificate contents/names, server addresses and exception messages.
// A trusted chain alone does not prove a completed TURN/TLS connection.
type TLSVerification struct {
	Version    int    `json:"version"`
	Checks     int    `json:"checks"`
	Failures   int    `json:"failures"`
	LastResult string `json:"last_result"`
}

func (v *TLSVerification) valid() bool {
	if v == nil {
		return true
	}
	if v.Version != 1 || v.Checks < 0 || v.Checks > 1_000_000 || v.Failures < 0 || v.Failures > v.Checks ||
		!member(v.LastResult, "not_checked|trusted|invalid_certificate|rejected|unavailable") {
		return false
	}
	if v.Checks == 0 {
		return v.LastResult == "not_checked"
	}
	return v.LastResult != "not_checked" && (v.LastResult == "trusted" || v.Failures > 0)
}
