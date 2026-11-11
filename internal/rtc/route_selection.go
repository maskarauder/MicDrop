package rtc

// RouteSelection records actual SDP capability and sampled changes of the
// selected audio pair within an ICE generation. It never contains a pair ID.
type RouteSelection struct {
	Version            int    `json:"version"`
	LocalRenomination  bool   `json:"local_renomination"`
	RemoteRenomination bool   `json:"remote_renomination"`
	Negotiated         bool   `json:"negotiated"`
	Generation         uint64 `json:"generation"`
	ObservedSwitches   uint64 `json:"observed_switches"`
}

func (r *RouteSelection) Valid() bool {
	return r == nil || (r.Version == 1 && r.Generation <= 1000000 && r.ObservedSwitches <= 1000000 &&
		r.Negotiated == (r.LocalRenomination && r.RemoteRenomination))
}
