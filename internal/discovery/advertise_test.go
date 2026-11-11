package discovery

import (
	"errors"
	"net"
	"reflect"
	"strings"
	"testing"
)

func TestRecordPublishesOnlyPublicAddressHints(t *testing.T) {
	key := strings.Repeat("ab", 32)
	got, err := RecordFor(net.ParseIP("192.168.1.20"), 9844, key)
	if err != nil {
		t.Fatal(err)
	}
	want := Record{Instance: "MicDrop-abababababab", Hostname: "micdrop-abababababab.local.",
		Address: "192.168.1.20", Port: 9844, TXT: []string{"v=1", "p=3", "id=" + key}}
	if !reflect.DeepEqual(got, want) || ServiceType != "_micdrop._tcp" {
		t.Fatalf("unexpected discovery wire contract: %+v", got)
	}
}

func TestRecordRejectsInvalidEndpointAndIdentity(t *testing.T) {
	key := strings.Repeat("a", 64)
	for _, address := range []string{"", "0.0.0.0", "127.0.0.1", "8.8.8.8", "169.254.1.2", "224.0.0.251", "fc00::1", "::1"} {
		if _, err := RecordFor(net.ParseIP(address), 9844, key); err == nil {
			t.Errorf("accepted invalid address %q", address)
		}
	}
	for _, port := range []int{-1, 0, 65536} {
		if _, err := RecordFor(net.ParseIP("10.0.0.20"), port, key); err == nil {
			t.Errorf("accepted port %d", port)
		}
	}
	for _, bad := range []string{"", key[:63], key + "a", strings.Repeat("A", 64), strings.Repeat("z", 64), key + "\n"} {
		if _, err := RecordFor(net.ParseIP("10.0.0.20"), 9844, bad); err == nil {
			t.Errorf("accepted invalid key %q", bad)
		}
	}
}

func TestInterfaceMustOwnTheExactListeningAddress(t *testing.T) {
	ip := net.ParseIP("192.168.1.20")
	flags := net.FlagUp | net.FlagMulticast
	interfaces := []net.Interface{
		{Index: 1, Name: "down", Flags: net.FlagMulticast},
		{Index: 2, Name: "loopback", Flags: flags | net.FlagLoopback},
		{Index: 3, Name: "no-multicast", Flags: net.FlagUp},
		{Index: 4, Name: "unreadable", Flags: flags},
		{Index: 5, Name: "other-private", Flags: flags},
		{Index: 6, Name: "selected", Flags: flags},
	}
	addresses := func(i net.Interface) ([]net.Addr, error) {
		if i.Index == 4 {
			return nil, errors.New("adapter disappeared")
		}
		if i.Index == 5 {
			return []net.Addr{&net.IPNet{IP: net.ParseIP("192.168.1.21"), Mask: net.CIDRMask(24, 32)}}, nil
		}
		return []net.Addr{&net.IPNet{IP: ip, Mask: net.CIDRMask(24, 32)}}, nil
	}
	got, err := MatchInterface(ip, interfaces, addresses)
	if err != nil || got.Index != 6 {
		t.Fatalf("selected %+v: %v", got, err)
	}
	if _, err := MatchInterface(ip, interfaces[:5], addresses); err == nil {
		t.Fatal("fell back to an adapter that does not own the listening address")
	}
}

func TestCloseAbsentAdvertisement(t *testing.T) {
	var advertisement *Advertisement
	advertisement.Close() // Startup failure must not break host teardown.
}
