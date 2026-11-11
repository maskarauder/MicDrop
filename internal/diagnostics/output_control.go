package diagnostics

// Address-free observations, negotiated separately so older hosts keep receiving
// their original schema. This does not prove audibility or physical latency.
type OutputControl struct {
	Version            int    `json:"version"`
	Selection          string `json:"selection"`
	RequestedEnabled   bool   `json:"requested_enabled"`
	Phase              string `json:"phase"`
	Pause              string `json:"pause"`
	DefaultMatches     *bool  `json:"default_matches"`
	SystemRouteKnown   bool   `json:"system_route_known"`
	Transfers          int    `json:"transfers"`
	TransferResult     string `json:"transfer_result"`
	PlayoutRecreations int    `json:"playout_recreations"`
	NearbyPermission   *bool  `json:"nearby_permission"`
}

func (o *OutputControl) valid() bool {
	return o == nil || (o.Version == 1 && member(o.Selection, "default|phone|wired|usb|bluetooth|le|hearing_aid|other") &&
		member(o.Phase, "verifying|restoring|waiting|verified|stopped") &&
		member(o.Pause, "none|route|bluetooth|unavailable|selected_bluetooth|focus|focus_manual") &&
		member(o.TransferResult, "none|requested|rejected") &&
		o.Transfers >= 0 && o.Transfers <= 1_000_000 && o.PlayoutRecreations >= 0 && o.PlayoutRecreations <= 1_000_000 &&
		(o.Selection == "default" || o.DefaultMatches == nil))
}
