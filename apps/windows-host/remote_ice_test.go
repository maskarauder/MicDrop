package main

import (
	"errors"
	"testing"

	"github.com/maskarauder/MicDrop/internal/rendezvous"
)

func TestDirectICEWorksWithoutServiceButForcedRelayDoesNotBypassIt(t *testing.T) {
	for _, force := range []bool{false, true} {
		calls := 0
		provider := remoteICEProvider(force, func() (rendezvous.ICEConfiguration, error) {
			calls++
			return rendezvous.ICEConfiguration{}, errors.New("service unavailable")
		})
		config, err := provider(true)
		if force {
			if err == nil || calls != 1 {
				t.Fatal("forced relay bypassed credential fetch")
			}
		} else if err != nil || calls != 0 || len(config.Servers) != 0 || config.ForceRelay {
			t.Fatal("LAN fallback depended on remote service")
		}
		before := calls
		if _, err = provider(false); err == nil || calls != before+1 {
			t.Fatal("rendezvous recovery did not refresh remote ICE")
		}
	}
}
