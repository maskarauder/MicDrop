package main

import (
	"github.com/maskarauder/MicDrop/internal/rendezvous"
	"github.com/maskarauder/MicDrop/internal/rtc"
)

func remoteICEProvider(forceRelay bool, fetch func() (rendezvous.ICEConfiguration, error)) rtc.ICEProvider {
	return func(local bool) (rtc.ICEConfig, error) {
		result := rtc.ICEConfig{ForceRelay: forceRelay}
		if local && !forceRelay {
			return result, nil
		}
		value, err := fetch()
		if err != nil {
			return rtc.ICEConfig{}, err
		}
		for _, server := range value.Servers {
			for _, url := range server.URLs {
				result.Servers = append(result.Servers, rtc.ICEServer{URL: url, Username: server.Username, Credential: server.Credential})
			}
		}
		return result, nil
	}
}
