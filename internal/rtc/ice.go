package rtc

import "errors"

type ICEServer struct{ URL, Username, Credential string }
type ICEConfig struct {
	Servers    []ICEServer
	ForceRelay bool
}
type ICEProvider func(localSignaling bool) (ICEConfig, error)

// Configuration is refreshed before each offer, including recovery. Providers
// must bound network work and never log credentials. A remote-capable host may
// omit external ICE on a direct offer unless its forced-relay policy requires it.
func SetICEProvider(p Peer, provider ICEProvider) error {
	configurable, ok := p.(interface{ setICEProvider(ICEProvider) })
	if !ok {
		return errors.New("remote ICE is unavailable in this engine")
	}
	configurable.setICEProvider(provider)
	return nil
}
